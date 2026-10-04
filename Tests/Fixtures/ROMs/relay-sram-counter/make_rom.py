#!/usr/bin/env python3
"""Generates relay-sram-counter.gba, a tiny Relay-authored Game Boy Advance test
program used by the save-integrity and smoke tests. Behaviour:

  * at boot it reads SRAM byte 0, increments it and writes it back;
  * it draws vertical bars on background 0 and scrolls them by the counter's
    value, so the picture changes whenever the count does;
  * then it loops: each press of A increments SRAM byte 0 again
    (waits for release before counting a new press).

It carries the string "SRAM_V113" so the emulator selects a 32 KiB SRAM
battery save, a valid header checksum and an ARM branch entry point (what
Relay's importer checks), and no Nintendo logo bitmap: it is a development
fixture for emulators, not a cartridge image.

Hand-assembled ARM instructions, no toolchain required. Regenerate with:
    python3 make_rom.py
"""
import pathlib
import struct

ROM_SIZE = 0x1000
rom = bytearray(ROM_SIZE)

def word(offset, value):
    struct.pack_into("<I", rom, offset, value & 0xFFFFFFFF)

# --- Header (0x00–0xBF) ---------------------------------------------------
word(0x00, 0xEA00002E)                # b 0xC0  (offset (0xC0 - 0x08) / 4 = 0x2E)
rom[0xA0:0xAC] = b"RELAYSRAM   "      # game title
rom[0xAC:0xB0] = b"RSRM"              # game code
rom[0xB0:0xB2] = b"RL"                # maker code
rom[0xB2] = 0x96                      # fixed value
rom[0xBC] = 0x00                      # software version
rom[0xBD] = (-(sum(rom[0xA0:0xBD]) + 0x19)) & 0xFF   # header complement checksum


# --- A very small ARM assembler -------------------------------------------
# Labels resolve on a second pass; literals go in a pool after the code.

class ARM:
    AL, EQ, NE = 0xE, 0x0, 0x1

    def __init__(self, origin):
        self.pc = origin
        self.items = []          # callables (labels, pool) -> 4 bytes
        self.labels = {}
        self.literals = []       # distinct 32-bit values, in first-use order

    def label(self, name): self.labels[name] = self.pc

    def _emit(self, fn):
        self.items.append((self.pc, fn)); self.pc += 4

    def raw(self, value): self._emit(lambda pc, labels, pool, v=value: v)

    def ldr_literal(self, rd, value):
        if value not in self.literals: self.literals.append(value)
        def fn(pc, labels, pool, rd=rd, v=value):
            offset = pool[v] - (pc + 8)
            assert 0 <= offset < 4096, "literal out of reach"
            return 0xE59F0000 | (rd << 12) | offset
        self._emit(fn)

    def mov_imm(self, rd, imm8, rot=0): self.raw(0xE3A00000 | (rd << 12) | (rot << 8) | imm8)
    def add_imm(self, rd, rn, imm): self.raw(0xE2800000 | (rn << 16) | (rd << 12) | imm)
    def subs_imm(self, rd, rn, imm): self.raw(0xE2500000 | (rn << 16) | (rd << 12) | imm)
    def tst_imm(self, rn, imm): self.raw(0xE3100000 | (rn << 16) | imm)
    def ldrb(self, rt, rn): self.raw(0xE5D00000 | (rn << 16) | (rt << 12))
    def strb(self, rt, rn): self.raw(0xE5C00000 | (rn << 16) | (rt << 12))
    def ldrh(self, rt, rn): self.raw(0xE1D000B0 | (rn << 16) | (rt << 12))
    def strh(self, rt, rn, off=0):
        self.raw(0xE1C000B0 | (rn << 16) | (rt << 12) | ((off >> 4) << 8) | (off & 0xF))
    def str_post4(self, rt, rn): self.raw(0xE4800004 | (rn << 16) | (rt << 12))

    def branch(self, cond, name):
        def fn(pc, labels, pool, c=cond, n=name):
            delta = (labels[n] - (pc + 8)) >> 2
            return (c << 28) | 0x0A000000 | (delta & 0xFFFFFF)
        self._emit(fn)

    def assemble(self):
        pool = {}
        addr = self.pc
        for v in self.literals:
            pool[v] = addr; addr += 4
        out = {}
        for pc, fn in self.items:
            out[pc] = fn(pc, self.labels, pool)
        for v, a in pool.items():
            out[a] = v
        return out, addr


SRAM, KEYINPUT, IO, PALETTE = 0x0E000000, 0x04000130, 0x04000000, 0x05000000
TILE1, MAP_BASE = 0x06000020, 0x06004000
BG0CNT, BG0HOFS = 0x08, 0x10

a = ARM(0xC0)
a.ldr_literal(0, SRAM)
a.ldr_literal(2, KEYINPUT)
a.ldr_literal(4, IO)

# Boot: byte 0 += 1.
a.ldrb(1, 0)
a.add_imm(1, 1, 1)
a.strb(1, 0)

# Palette: colour 0 white, colour 1 black.
a.ldr_literal(5, PALETTE)
a.ldr_literal(6, 0x7FFF)
a.strh(6, 5)
a.mov_imm(6, 0)
a.strh(6, 5, 2)

# Tile 1: eight rows of 0x00001111, i.e. the left four pixels in colour 1.
a.ldr_literal(5, TILE1)
a.ldr_literal(6, 0x00001111)
a.mov_imm(7, 8)
a.label("tile")
a.str_post4(6, 5)
a.subs_imm(7, 7, 1)
a.branch(ARM.NE, "tile")

# Map: 32x32 entries of tile 1 at screen block 8 (512 words of 0x00010001).
a.ldr_literal(5, MAP_BASE)
a.ldr_literal(6, 0x00010001)
a.mov_imm(7, 2, 12)                     # 2 ror 24 = 0x200 = 512
a.label("map")
a.str_post4(6, 5)
a.subs_imm(7, 7, 1)
a.branch(ARM.NE, "map")

# BG0: screen block 8, character block 0. Display: mode 0, BG0 on.
a.mov_imm(6, 8, 12)                     # 0x0800
a.strh(6, 4, BG0CNT)
a.mov_imm(6, 1, 12)                     # 0x0100
a.strh(6, 4)                            # DISPCNT

a.label("loop")
a.ldrb(1, 0)
a.strh(1, 4, BG0HOFS)                   # scroll by the counter
a.ldrh(3, 2)
a.tst_imm(3, 1)                         # A is bit 0, active low
a.branch(ARM.NE, "loop")
a.ldrb(1, 0)
a.add_imm(1, 1, 1)
a.strb(1, 0)                            # press increment
a.label("wait")
a.ldrh(3, 2)
a.tst_imm(3, 1)
a.branch(ARM.EQ, "wait")                # until released
a.branch(ARM.AL, "loop")

words, end = a.assemble()
assert end <= 0x200, f"program overlaps the save-type marker: ends at {end:#x}"
for offset, value in words.items():
    word(offset, value)

rom[0x200:0x20A] = b"SRAM_V113\0"     # save-type marker scanned by the emulator

out = pathlib.Path(__file__).with_name("relay-sram-counter.gba")
out.write_bytes(rom)
print(f"wrote {out} ({len(rom)} bytes, code 0xC0-{end:#x})")
