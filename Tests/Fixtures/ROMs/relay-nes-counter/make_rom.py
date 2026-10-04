#!/usr/bin/env python3
"""Generates Relay's NES test program, relay-nes-counter.nes.

A 32 KiB NROM cartridge (NES 2.0 header) with 8 KiB of battery-backed PRG RAM
and 8 KiB of CHR RAM. Behaviour, the same contract as the Game Boy fixtures:

  * at boot: add one to byte 0 of the battery RAM ($6000);
  * draw vertical bars over the whole background so the picture is not blank;
  * loop: every press of A adds one to byte 0 (a press counts once until A is
    released), and the background scrolls horizontally by the counter, so the
    picture changes whenever the count does.

Byte 0 of the battery save is therefore the number of launches plus the
number of presses of A, and a press of A is visible in the framebuffer.

Hand-assembled 6502, no toolchain required. Regenerate with:
    python3 make_rom.py
"""
import pathlib

PRG_SIZE = 0x8000  # two 16 KiB banks, mapped at $8000-$FFFF
ORIGIN = 0x8000


class Assembler:
    def __init__(self, origin):
        self.origin = origin
        self.items = []
        self.labels = {}
        self.pc = origin

    def label(self, name):
        self.labels[name] = self.pc

    def raw(self, *values):
        data = bytes(values)
        self.items.append((len(data), lambda labels, d=data: d))
        self.pc += len(data)

    def abs16(self, opcode, name):
        def emit(labels, op=opcode, n=name):
            return bytes([op, labels[n] & 0xFF, (labels[n] >> 8) & 0xFF])
        self.items.append((3, emit))
        self.pc += 3

    def rel8(self, opcode, name):
        next_pc = self.pc + 2
        def emit(labels, op=opcode, n=name, nxt=next_pc):
            delta = labels[n] - nxt
            if not -128 <= delta <= 127:
                raise ValueError(f"branch to {n} out of range: {delta}")
            return bytes([op, delta & 0xFF])
        self.items.append((2, emit))
        self.pc += 2

    def assemble(self):
        return b"".join(emit(self.labels) for _, emit in self.items)


# 6502 opcodes used here.
SEI, CLD, RTI, JMP = 0x78, 0xD8, 0x40, 0x4C
LDA_IMM, LDX_IMM, LDY_IMM = 0xA9, 0xA2, 0xA0
LDA_ABS, STA_ABS, STA_ZP, LDA_ZP, INC_ABS = 0xAD, 0x8D, 0x85, 0xA5, 0xEE
BIT_ABS, AND_IMM, TXS = 0x2C, 0x29, 0x9A
INX, DEX, DEY = 0xE8, 0xCA, 0x88
BPL, BNE, BEQ = 0x10, 0xD0, 0xF0

PPUCTRL, PPUMASK, PPUSTATUS, PPUSCROLL, PPUADDR, PPUDATA = 0x2000, 0x2001, 0x2002, 0x2005, 0x2006, 0x2007
JOY1 = 0x4016
COUNTER = 0x6000   # byte 0 of the battery-backed PRG RAM


def lo(v): return v & 0xFF
def hi(v): return (v >> 8) & 0xFF


def program():
    a = Assembler(ORIGIN)

    a.label("reset")
    a.raw(SEI); a.raw(CLD)
    a.raw(LDX_IMM, 0xFF); a.raw(TXS)
    a.raw(LDA_IMM, 0x00)
    a.raw(STA_ABS, lo(PPUCTRL), hi(PPUCTRL))
    a.raw(STA_ABS, lo(PPUMASK), hi(PPUMASK))

    # The PPU needs two frames after power-on before it accepts writes.
    a.label("warm1"); a.raw(BIT_ABS, lo(PPUSTATUS), hi(PPUSTATUS)); a.rel8(BPL, "warm1")
    a.label("warm2"); a.raw(BIT_ABS, lo(PPUSTATUS), hi(PPUSTATUS)); a.rel8(BPL, "warm2")

    # --- Battery RAM: byte 0 += 1 at every launch --------------------------
    a.raw(INC_ABS, lo(COUNTER), hi(COUNTER))

    # --- CHR RAM tile 1 ($0010): vertical bars, four pixels wide -----------
    # Low bit plane $F0 on every row, high plane $00: the left four pixels are
    # colour 1, the right four colour 0.
    a.raw(LDA_ABS, lo(PPUSTATUS), hi(PPUSTATUS))          # reset the address latch
    a.raw(LDA_IMM, 0x00); a.raw(STA_ABS, lo(PPUADDR), hi(PPUADDR))
    a.raw(LDA_IMM, 0x10); a.raw(STA_ABS, lo(PPUADDR), hi(PPUADDR))
    a.raw(LDX_IMM, 8)
    a.label("tile_low"); a.raw(LDA_IMM, 0xF0); a.raw(STA_ABS, lo(PPUDATA), hi(PPUDATA)); a.raw(DEX); a.rel8(BNE, "tile_low")
    a.raw(LDX_IMM, 8)
    a.label("tile_high"); a.raw(LDA_IMM, 0x00); a.raw(STA_ABS, lo(PPUDATA), hi(PPUDATA)); a.raw(DEX); a.rel8(BNE, "tile_high")

    # --- Palette: background colour black, colour 1 white --------------------
    a.raw(LDA_ABS, lo(PPUSTATUS), hi(PPUSTATUS))
    a.raw(LDA_IMM, 0x3F); a.raw(STA_ABS, lo(PPUADDR), hi(PPUADDR))
    a.raw(LDA_IMM, 0x00); a.raw(STA_ABS, lo(PPUADDR), hi(PPUADDR))
    for colour in (0x0F, 0x30, 0x0F, 0x0F):
        a.raw(LDA_IMM, colour); a.raw(STA_ABS, lo(PPUDATA), hi(PPUDATA))

    # --- Nametable 0: tile 1 everywhere (1024 bytes), then attributes zero --
    a.raw(LDA_ABS, lo(PPUSTATUS), hi(PPUSTATUS))
    a.raw(LDA_IMM, 0x20); a.raw(STA_ABS, lo(PPUADDR), hi(PPUADDR))
    a.raw(LDA_IMM, 0x00); a.raw(STA_ABS, lo(PPUADDR), hi(PPUADDR))
    a.raw(LDA_IMM, 0x01); a.raw(LDX_IMM, 0x00); a.raw(LDY_IMM, 0x04)
    a.label("fill"); a.raw(STA_ABS, lo(PPUDATA), hi(PPUDATA)); a.raw(INX); a.rel8(BNE, "fill"); a.raw(DEY); a.rel8(BNE, "fill")
    a.raw(LDA_ABS, lo(PPUSTATUS), hi(PPUSTATUS))
    a.raw(LDA_IMM, 0x23); a.raw(STA_ABS, lo(PPUADDR), hi(PPUADDR))
    a.raw(LDA_IMM, 0xC0); a.raw(STA_ABS, lo(PPUADDR), hi(PPUADDR))
    a.raw(LDA_IMM, 0x00); a.raw(LDX_IMM, 64)
    a.label("attr"); a.raw(STA_ABS, lo(PPUDATA), hi(PPUDATA)); a.raw(DEX); a.rel8(BNE, "attr")

    # --- Scroll 0,0 and rendering on (background, including the left 8 px) --
    a.raw(LDA_ABS, lo(PPUSTATUS), hi(PPUSTATUS))
    a.raw(LDA_IMM, 0x00); a.raw(STA_ABS, lo(PPUSCROLL), hi(PPUSCROLL)); a.raw(STA_ABS, lo(PPUSCROLL), hi(PPUSCROLL))
    a.raw(STA_ZP, 0x00)                                   # "A was down" flag
    a.raw(LDA_IMM, 0x0A); a.raw(STA_ABS, lo(PPUMASK), hi(PPUMASK))

    # --- Main loop, once per frame ------------------------------------------
    a.label("loop")
    a.label("vblank"); a.raw(BIT_ABS, lo(PPUSTATUS), hi(PPUSTATUS)); a.rel8(BPL, "vblank")
    # Scroll X by the counter (the BIT above reset the latch).
    a.raw(LDA_ABS, lo(COUNTER), hi(COUNTER)); a.raw(STA_ABS, lo(PPUSCROLL), hi(PPUSCROLL))
    a.raw(LDA_IMM, 0x00); a.raw(STA_ABS, lo(PPUSCROLL), hi(PPUSCROLL))
    # Read controller 1: strobe, then the first bit is A.
    a.raw(LDA_IMM, 0x01); a.raw(STA_ABS, lo(JOY1), hi(JOY1))
    a.raw(LDA_IMM, 0x00); a.raw(STA_ABS, lo(JOY1), hi(JOY1))
    a.raw(LDA_ABS, lo(JOY1), hi(JOY1)); a.raw(AND_IMM, 0x01)
    a.rel8(BEQ, "a_up")
    # A is down: count it once.
    a.raw(LDA_ZP, 0x00); a.rel8(BNE, "loop")
    a.raw(LDA_IMM, 0x01); a.raw(STA_ZP, 0x00)
    a.raw(INC_ABS, lo(COUNTER), hi(COUNTER))
    a.abs16(JMP, "loop")
    a.label("a_up")
    a.raw(LDA_IMM, 0x00); a.raw(STA_ZP, 0x00)
    a.abs16(JMP, "loop")

    a.label("interrupt")
    a.raw(RTI)
    return a.assemble(), a.labels


def build() -> bytes:
    code, labels = program()
    prg = bytearray(PRG_SIZE)
    prg[0:len(code)] = code
    # Vectors: NMI and IRQ go to an RTI, RESET to the program.
    for offset, name in ((0x7FFA, "interrupt"), (0x7FFC, "reset"), (0x7FFE, "interrupt")):
        prg[offset] = lo(labels[name]); prg[offset + 1] = hi(labels[name])

    header = bytearray(16)
    header[0:4] = b"NES\x1a"
    header[4] = 2          # PRG ROM: 2 × 16 KiB
    header[5] = 0          # no CHR ROM: 8 KiB CHR RAM below
    header[6] = 0x02       # horizontal mirroring, battery-backed PRG RAM, mapper 0
    header[7] = 0x08       # NES 2.0
    header[10] = 0x70      # PRG-NVRAM 64 << 7 = 8 KiB (battery), no volatile PRG RAM
    header[11] = 0x07      # CHR-RAM 64 << 7 = 8 KiB
    header[12] = 0x00      # NTSC
    return bytes(header + prg)


if __name__ == "__main__":
    here = pathlib.Path(__file__).parent
    data = build()
    (here / "relay-nes-counter.nes").write_bytes(data)
    print(f"relay-nes-counter.nes: {len(data)} bytes")
