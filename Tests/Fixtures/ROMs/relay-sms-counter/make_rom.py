#!/usr/bin/env python3
"""Generates Relay's Sega test programs, relay-sms-counter.sms and relay-gg-counter.gg.

Two 64 KiB cartridges with the standard "TMR SEGA" header, identical apart
from the region code (Master System export, Game Gear export) and the palette
format each console reads (6-bit bytes on the Master System, 12-bit words on
the Game Gear). 64 KiB is deliberate: it is the size from which the Sega
mapper, and with it battery-backed cartridge RAM, is used.

Behaviour, the same contract as Relay's other counter fixtures:

  * at boot: enable cartridge RAM through the mapper, read byte 0, add one,
    write it back;
  * draw vertical bars on the background so the picture is not blank;
  * loop: every press of button 2 (Relay's A) adds one to byte 0 (a press
    counts once until the button is released), and the background scrolls
    horizontally by the counter, so the picture changes whenever the count
    does.

Hand-assembled Z80, no toolchain required. Regenerate with:
    python3 make_rom.py
"""
import pathlib

ROM_SIZE = 0x10000


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

    def abs16(self, *opcode_then_label):
        *opcode, name = opcode_then_label
        def emit(labels, op=bytes(opcode), n=name):
            return op + bytes([labels[n] & 0xFF, (labels[n] >> 8) & 0xFF])
        self.items.append((len(opcode) + 2, emit))
        self.pc += len(opcode) + 2

    def rel8(self, opcode, name):
        next_pc = self.pc + 2
        def emit(labels, op=opcode, n=name, nxt=next_pc):
            delta = labels[n] - nxt
            if not -128 <= delta <= 127:
                raise ValueError(f"jump to {n} out of range: {delta}")
            return bytes([op, delta & 0xFF])
        self.items.append((2, emit))
        self.pc += 2

    def assemble(self):
        return b"".join(emit(self.labels) for _, emit in self.items)


# Z80 opcodes used here.
DI, IM1, NOP = 0xF3, (0xED, 0x56), 0x00
LD_SP_NN, LD_HL_NN, LD_BC_NN = 0x31, 0x21, 0x01
LD_A_N, LD_B_N, LD_C_N = 0x3E, 0x06, 0x0E
LD_NN_A, LD_A_NN = 0x32, 0x3A
OUT_N_A, IN_A_N = 0xD3, 0xDB
OTIR = (0xED, 0xB3)
INC_A, DEC_C, DEC_BC, LD_A_B, LD_B_A, OR_A, OR_C, AND_N = 0x3C, 0x0D, 0x0B, 0x78, 0x47, 0xB7, 0xB1, 0xE6
JR, JR_NZ, JR_Z, JP = 0x18, 0x20, 0x28, 0xC3

VDP_DATA, VDP_CTRL, JOYPAD = 0xBE, 0xBF, 0xDC
MAPPER_RAM, COUNTER = 0xFFFC, 0x8000   # cartridge RAM bank 0 mapped at $8000


def program(game_gear: bool):
    a = Assembler(0x0000)
    a.raw(DI); a.raw(*IM1)
    a.raw(LD_SP_NN, 0xF0, 0xDF)

    # --- Cartridge RAM: enable it at $8000 and add one to byte 0 --------------
    a.raw(LD_A_N, 0x08); a.raw(LD_NN_A, MAPPER_RAM & 0xFF, MAPPER_RAM >> 8)
    a.raw(LD_A_NN, COUNTER & 0xFF, COUNTER >> 8); a.raw(INC_A); a.raw(LD_NN_A, COUNTER & 0xFF, COUNTER >> 8)

    # --- VDP registers: mode 4, display on, tables at their usual places -------
    a.abs16(LD_HL_NN, "vdp_table"); a.raw(LD_B_N, 22); a.raw(LD_C_N, VDP_CTRL); a.raw(*OTIR)

    # --- Palette: colour 0 black, colour 1 white --------------------------------
    a.raw(LD_A_N, 0x00); a.raw(OUT_N_A, VDP_CTRL); a.raw(LD_A_N, 0xC0); a.raw(OUT_N_A, VDP_CTRL)
    if game_gear:
        for byte in (0x00, 0x00, 0xFF, 0x0F):
            a.raw(LD_A_N, byte); a.raw(OUT_N_A, VDP_DATA)
    else:
        for byte in (0x00, 0x3F):
            a.raw(LD_A_N, byte); a.raw(OUT_N_A, VDP_DATA)

    # --- Tile 1 (VRAM $0020): vertical bars four pixels wide ---------------------
    a.raw(LD_A_N, 0x20); a.raw(OUT_N_A, VDP_CTRL); a.raw(LD_A_N, 0x40); a.raw(OUT_N_A, VDP_CTRL)
    a.raw(LD_C_N, 8)
    a.label("tile_rows")
    for byte in (0xF0, 0x00, 0x00, 0x00):          # four bit planes per row
        a.raw(LD_A_N, byte); a.raw(OUT_N_A, VDP_DATA)
    a.raw(DEC_C); a.rel8(JR_NZ, "tile_rows")

    # --- Name table ($3800): tile 1 in all 32×28 cells --------------------------
    a.raw(LD_A_N, 0x00); a.raw(OUT_N_A, VDP_CTRL); a.raw(LD_A_N, 0x78); a.raw(OUT_N_A, VDP_CTRL)
    a.raw(LD_BC_NN, 0x80, 0x03)                    # 896 entries
    a.label("map_fill")
    a.raw(LD_A_N, 0x01); a.raw(OUT_N_A, VDP_DATA)
    a.raw(LD_A_N, 0x00); a.raw(OUT_N_A, VDP_DATA)
    a.raw(DEC_BC); a.raw(LD_A_B); a.raw(OR_C); a.rel8(JR_NZ, "map_fill")

    # --- Main loop, once per frame -----------------------------------------------
    a.raw(LD_B_N, 0x00)                            # "button was down" flag in B
    a.label("loop")
    a.label("vblank"); a.raw(IN_A_N, VDP_CTRL); a.raw(AND_N, 0x80); a.rel8(JR_Z, "vblank")
    # Scroll X (register 8) = counter.
    a.raw(LD_A_NN, COUNTER & 0xFF, COUNTER >> 8); a.raw(OUT_N_A, VDP_CTRL)
    a.raw(LD_A_N, 0x88); a.raw(OUT_N_A, VDP_CTRL)
    # Button 2 is bit 5 of the joypad port, low when pressed.
    a.raw(IN_A_N, JOYPAD); a.raw(AND_N, 0x20); a.rel8(JR_NZ, "button_up")
    a.raw(LD_A_B); a.raw(OR_A); a.rel8(JR_NZ, "loop")
    a.raw(LD_B_N, 0x01)
    a.raw(LD_A_NN, COUNTER & 0xFF, COUNTER >> 8); a.raw(INC_A); a.raw(LD_NN_A, COUNTER & 0xFF, COUNTER >> 8)
    a.rel8(JR, "loop")
    a.label("button_up"); a.raw(LD_B_N, 0x00); a.rel8(JR, "loop")

    # Register values for OTIR: data byte then $80 | register.
    a.label("vdp_table")
    for register, value in [(0, 0x04), (1, 0xC0), (2, 0xFF), (3, 0xFF), (4, 0xFF), (5, 0xFF),
                            (6, 0xFB), (7, 0x00), (8, 0x00), (9, 0x00), (10, 0xFF)]:
        a.raw(value, 0x80 | register)
    return a.assemble()


def build(game_gear: bool) -> bytes:
    rom = bytearray(ROM_SIZE)
    code = program(game_gear)
    rom[0:len(code)] = code
    header = 0x7FF0
    rom[header:header + 8] = b"TMR SEGA"
    rom[header + 0x0C:header + 0x0F] = bytes([0x26, 0x70, 0x00])         # product code 7026, version 0
    rom[header + 0x0F] = (0x60 if game_gear else 0x40) | 0x0E             # region export; 64 KiB
    # Checksum: every byte outside the header, as the export BIOS computes it.
    total = (sum(rom[0:0x7FF0]) + sum(rom[0x8000:])) & 0xFFFF
    rom[header + 0x0A] = total & 0xFF
    rom[header + 0x0B] = total >> 8
    return bytes(rom)


if __name__ == "__main__":
    here = pathlib.Path(__file__).parent
    for name, gg in (("relay-sms-counter.sms", False), ("relay-gg-counter.gg", True)):
        data = build(gg)
        (here / name).write_bytes(data)
        print(f"{name}: {len(data)} bytes, region byte 0x{data[0x7FFF]:02X}")
