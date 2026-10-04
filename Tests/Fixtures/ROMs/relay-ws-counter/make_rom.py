#!/usr/bin/env python3
"""Generates Relay's WonderSwan test programs, relay-ws-counter.ws and relay-wsc-counter.wsc.

Two 128 KiB cartridges with the standard footer (the last sixteen bytes: the
far jump the CPU starts on, developer, minimum system, save type, mapper and
the checksum the boot ROM verifies), identical apart from the "needs Color"
bit. Both draw in the monochrome-compatible mode every WonderSwan has.

Behaviour, the same contract as Relay's other counter fixtures:

  * at boot: read byte 0 of the cartridge SRAM, add one, write it back;
  * draw vertical bars on screen 1 so the picture is not blank;
  * loop: every press of A adds one to byte 0 (a press counts once until A is
    released), and screen 1 scrolls horizontally by the counter, so the
    picture changes whenever the count does.

Hand-assembled V30MZ (16-bit x86 real mode), no toolchain required.
Regenerate with:
    python3 make_rom.py
"""
import pathlib
import struct

ROM_SIZE = 0x20000
CODE_OFFSET = 0x10000        # ROM offset of physical 0xF0000: segment F000, offset 0
SRAM_SEGMENT = 0x1000        # cartridge SRAM at 0x10000


class Assembler:
    def __init__(self):
        self.items = []
        self.labels = {}
        self.pc = 0

    def label(self, name):
        self.labels[name] = self.pc

    def raw(self, *values):
        data = bytes(values)
        self.items.append((len(data), lambda labels, d=data: d))
        self.pc += len(data)

    def rel8(self, opcode, name):
        next_pc = self.pc + 2
        def emit(labels, op=opcode, n=name, nxt=next_pc):
            delta = labels[n] - nxt
            if not -128 <= delta <= 127:
                raise ValueError(f"jump to {n} out of range: {delta}")
            return bytes([op, delta & 0xFF])
        self.items.append((2, emit))
        self.pc += 2

    def jmp_near(self, name):
        next_pc = self.pc + 3
        def emit(labels, n=name, nxt=next_pc):
            delta = (labels[n] - nxt) & 0xFFFF
            return bytes([0xE9, delta & 0xFF, delta >> 8])
        self.items.append((3, emit))
        self.pc += 3

    def assemble(self):
        return b"".join(emit(self.labels) for _, emit in self.items)


def word(v): return (v & 0xFF, (v >> 8) & 0xFF)


# x86-16 encodings used here.
def mov_ax(v): return (0xB8, *word(v))
def mov_cx(v): return (0xB9, *word(v))
def mov_di(v): return (0xBF, *word(v))
def mov_sp(v): return (0xBC, *word(v))
def mov_al(v): return (0xB0, v)
MOV_DS_AX, MOV_ES_AX, MOV_SS_AX = (0x8E, 0xD8), (0x8E, 0xC0), (0x8E, 0xD0)
def out_al(port): return (0xE6, port)
def in_al(port): return (0xE4, port)
def mov_mem_al(addr): return (0xA2, *word(addr))
def mov_al_mem(addr): return (0xA0, *word(addr))
def mov_mem_imm8(addr, v): return (0xC6, 0x06, *word(addr), v)
def cmp_al(v): return (0x3C, v)
def test_al(v): return (0xA8, v)
def inc_al(): return (0xFE, 0xC0)
def cmp_mem8_imm(addr, v): return (0x80, 0x3E, *word(addr), v)
REP_STOSW, STOSW, CLI, NOP = (0xF3, 0xAB), (0xAB,), (0xFA,), (0x90,)
JZ, JNZ, JMP_SHORT = 0x74, 0x75, 0xEB

DISP_CTRL, LINE, SCR_BASE, SCR1_X, SCR1_Y = 0x00, 0x02, 0x07, 0x10, 0x11
LCD_CTRL, LUT0, PALETTE0, KEYPAD, SRAM_BANK = 0x14, 0x1C, 0x20, 0xB5, 0xC1
MAP_ADDRESS, TILE_ADDRESS = 0x1000, 0x2000     # screen 1 map, tile memory (tile 1 at +16)
FLAG_ADDRESS = 0x0100                           # "A was down", in work RAM


def program():
    a = Assembler()
    a.raw(*CLI)
    a.raw(*mov_ax(0x0000)); a.raw(*MOV_DS_AX); a.raw(*MOV_ES_AX); a.raw(*MOV_SS_AX); a.raw(*mov_sp(0x0800))

    # --- Cartridge SRAM bank 0: byte 0 += 1 at every launch -------------------
    a.raw(*mov_al(0x00)); a.raw(*out_al(SRAM_BANK))
    a.raw(*mov_ax(SRAM_SEGMENT)); a.raw(*MOV_DS_AX)
    a.raw(*mov_al_mem(0x0000)); a.raw(*inc_al()); a.raw(*mov_mem_al(0x0000))
    a.raw(*mov_ax(0x0000)); a.raw(*MOV_DS_AX)

    # --- Tile 1: two planes per row, plane 0 = $F0: four pixels of colour 1 --
    a.raw(*mov_di(TILE_ADDRESS + 16)); a.raw(*mov_ax(0x00F0)); a.raw(*mov_cx(8)); a.raw(*REP_STOSW)
    # --- Screen 1 map: 32×32 entries of tile 1, palette 0 --------------------
    a.raw(*mov_di(MAP_ADDRESS)); a.raw(*mov_ax(0x0001)); a.raw(*mov_cx(1024)); a.raw(*REP_STOSW)

    # --- Display: LUT entry 0 = white, 1 = black; palette 0 uses them ---------
    a.raw(*mov_al(0xF0)); a.raw(*out_al(LUT0))
    a.raw(*mov_al(0x10)); a.raw(*out_al(PALETTE0)); a.raw(*mov_al(0x00)); a.raw(*out_al(PALETTE0 + 1))
    a.raw(*mov_al(MAP_ADDRESS >> 11)); a.raw(*out_al(SCR_BASE))
    a.raw(*mov_al(0x00)); a.raw(*out_al(SCR1_X)); a.raw(*out_al(SCR1_Y))
    a.raw(*mov_al(0x01)); a.raw(*out_al(DISP_CTRL))      # screen 1 on
    a.raw(*mov_al(0x01)); a.raw(*out_al(LCD_CTRL))       # LCD on
    a.raw(*mov_mem_imm8(FLAG_ADDRESS, 0x00))

    # --- Main loop, once per frame -------------------------------------------
    a.label("loop")
    a.label("wait_end"); a.raw(*in_al(LINE)); a.raw(*cmp_al(144)); a.rel8(JZ, "wait_end")
    a.label("wait_start"); a.raw(*in_al(LINE)); a.raw(*cmp_al(144)); a.rel8(JNZ, "wait_start")
    # Screen 1 scrolls by the counter.
    a.raw(*mov_ax(SRAM_SEGMENT)); a.raw(*MOV_DS_AX)
    a.raw(*mov_al_mem(0x0000)); a.raw(*out_al(SCR1_X))
    a.raw(*mov_ax(0x0000)); a.raw(*MOV_DS_AX)
    # Keypad: select the button group, read it; A is bit 2, high when pressed.
    a.raw(*mov_al(0x40)); a.raw(*out_al(KEYPAD)); a.raw(*NOP); a.raw(*NOP)
    a.raw(*in_al(KEYPAD)); a.raw(*test_al(0x04)); a.rel8(JZ, "a_up")
    a.raw(*cmp_mem8_imm(FLAG_ADDRESS, 0x01)); a.rel8(JZ, "loop")
    a.raw(*mov_mem_imm8(FLAG_ADDRESS, 0x01))
    a.raw(*mov_ax(SRAM_SEGMENT)); a.raw(*MOV_DS_AX)
    a.raw(*mov_al_mem(0x0000)); a.raw(*inc_al()); a.raw(*mov_mem_al(0x0000))
    a.raw(*mov_ax(0x0000)); a.raw(*MOV_DS_AX)
    a.jmp_near("loop")
    a.label("a_up"); a.raw(*mov_mem_imm8(FLAG_ADDRESS, 0x00)); a.jmp_near("loop")
    return a.assemble()


def build(colour: bool) -> bytes:
    rom = bytearray(ROM_SIZE)
    code = program()
    rom[CODE_OFFSET:CODE_OFFSET + len(code)] = code
    footer = ROM_SIZE - 16
    rom[footer:footer + 5] = bytes([0xEA, 0x00, 0x00, 0x00, 0xF0])   # jmp far F000:0000
    rom[footer + 6] = 0x00                  # developer
    rom[footer + 7] = 0x01 if colour else 0x00
    rom[footer + 8] = 0x7A                  # cartridge number
    rom[footer + 9] = 0x00                  # version
    rom[footer + 10] = 0x00                 # ROM size code: 1 Mbit
    rom[footer + 11] = 0x01                 # save: 32 KiB SRAM
    rom[footer + 12] = 0x04                 # flags: horizontal, 16-bit bus
    rom[footer + 13] = 0x00                 # mapper: 2001
    checksum = sum(rom[:ROM_SIZE - 2]) & 0xFFFF
    rom[footer + 14] = checksum & 0xFF
    rom[footer + 15] = checksum >> 8
    return bytes(rom)


if __name__ == "__main__":
    here = pathlib.Path(__file__).parent
    for name, colour in (("relay-ws-counter.ws", False), ("relay-wsc-counter.wsc", True)):
        data = build(colour)
        (here / name).write_bytes(data)
        print(f"{name}: {len(data)} bytes, checksum 0x{data[-2] | (data[-1] << 8):04X}")
