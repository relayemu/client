#!/usr/bin/env python3
"""Generates Relay's PC Engine test program, relay-pce-counter.pce.

An 8 KiB HuCard (one bank, the smallest a HuCard can be). HuCards carry no
save memory, so unlike Relay's other counter fixtures this one keeps its count
in work RAM and proves video, input and save states rather than a battery
save (the catalog says so: `saveMemory: .none`).

Behaviour:

  * draw vertical bars on the background so the picture is not blank;
  * loop: every press of button I (Relay's A) adds one to the counter (a
    press counts once until the button is released), and the background
    scrolls horizontally by the counter, so the picture changes whenever the
    count does.

Hand-assembled HuC6280 (the PC Engine's 6502 with its extra instructions),
no toolchain required. Regenerate with:
    python3 make_rom.py
"""
import pathlib

ROM_SIZE = 0x2000
ORIGIN = 0xE000            # bank 0 is mapped at $E000-$FFFF on power-up


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


# HuC6280 opcodes used here (6502 encodings plus the HuC6280 additions).
SEI, CLD, CSH, TAM, TXS, NOP, JMP = 0x78, 0xD8, 0xD4, 0x53, 0x9A, 0xEA, 0x4C
LDA_IMM, LDX_IMM, LDY_IMM, LDA_ABS, STA_ABS, STZ_ABS = 0xA9, 0xA2, 0xA0, 0xAD, 0x8D, 0x9C
LDA_ZP, STA_ZP, STZ_ZP, INC_ZP, AND_IMM = 0xA5, 0x85, 0x64, 0xE6, 0x29
ST0, ST1, ST2 = 0x03, 0x13, 0x23
INY, DEX, BNE, BEQ = 0xC8, 0xCA, 0xD0, 0xF0

# I/O page (mapped at $0000 through MPR0 = $FF).
VDC_STATUS, VDC_DATA_LO, VDC_DATA_HI = 0x0000, 0x0002, 0x0003
VCE_CONTROL, VCE_ADDR_LO, VCE_ADDR_HI, VCE_DATA_LO, VCE_DATA_HI = 0x0400, 0x0402, 0x0403, 0x0404, 0x0405
JOYPAD, IRQ_DISABLE = 0x1000, 0x1402
FLAG, COUNTER = 0x10, 0x11        # zero page (work RAM through MPR1 = $F8)


def vdc(a, register, value):
    a.raw(ST0, register); a.raw(ST1, value & 0xFF); a.raw(ST2, value >> 8)


def program():
    a = Assembler(ORIGIN)
    a.label("reset")
    a.raw(SEI); a.raw(CSH); a.raw(CLD)
    a.raw(LDA_IMM, 0xFF); a.raw(TAM, 0x01)          # MPR0: hardware page
    a.raw(LDA_IMM, 0xF8); a.raw(TAM, 0x02)          # MPR1: work RAM (zero page and stack)
    a.raw(LDX_IMM, 0xFF); a.raw(TXS)
    a.raw(LDA_IMM, 0x07); a.raw(STA_ABS, IRQ_DISABLE & 0xFF, IRQ_DISABLE >> 8)
    a.raw(STZ_ABS, VCE_CONTROL & 0xFF, VCE_CONTROL >> 8)   # 5.37 MHz dot clock

    # --- VDC: 256×240 picture, display off while the tables are written ------
    vdc(a, 0x05, 0x0000)              # CR
    vdc(a, 0x09, 0x0000)              # MWR: 32×32 map
    vdc(a, 0x0A, 0x0202)              # HSR
    vdc(a, 0x0B, 0x041F)              # HDR: 32 tiles wide
    vdc(a, 0x0C, 0x0F02)              # VPR
    vdc(a, 0x0D, 0x00EF)              # VDW: 240 lines
    vdc(a, 0x0E, 0x0004)              # VCR
    vdc(a, 0x07, 0x0000)              # BXR
    vdc(a, 0x08, 0x0000)              # BYR

    # Tile $40 (VRAM word $0400, past the 1024-word map): planes 0/1 then 2/3;
    # plane 0 = $F0 on every row, so the left four pixels are colour 1 and the
    # right four colour 0.
    vdc(a, 0x00, 0x0400)              # MAWR
    a.raw(ST0, 0x02)                  # VWR
    for _ in range(8):
        a.raw(ST1, 0xF0); a.raw(ST2, 0x00)
    for _ in range(8):
        a.raw(ST1, 0x00); a.raw(ST2, 0x00)

    # Map (VRAM $0000): 1024 entries of tile $40, palette 0.
    vdc(a, 0x00, 0x0000)
    a.raw(ST0, 0x02)
    a.raw(LDX_IMM, 4)
    a.label("map_outer"); a.raw(LDY_IMM, 0)
    a.label("map_inner"); a.raw(ST1, 0x40); a.raw(ST2, 0x00); a.raw(INY); a.rel8(BNE, "map_inner")
    a.raw(DEX); a.rel8(BNE, "map_outer")

    # Palette: colour 0 black, colour 1 white (VCE address auto-increments).
    a.raw(STZ_ABS, VCE_ADDR_LO & 0xFF, VCE_ADDR_LO >> 8); a.raw(STZ_ABS, VCE_ADDR_HI & 0xFF, VCE_ADDR_HI >> 8)
    a.raw(STZ_ABS, VCE_DATA_LO & 0xFF, VCE_DATA_LO >> 8); a.raw(STZ_ABS, VCE_DATA_HI & 0xFF, VCE_DATA_HI >> 8)
    a.raw(LDA_IMM, 0xFF); a.raw(STA_ABS, VCE_DATA_LO & 0xFF, VCE_DATA_LO >> 8)
    a.raw(LDA_IMM, 0x01); a.raw(STA_ABS, VCE_DATA_HI & 0xFF, VCE_DATA_HI >> 8)

    # CR: background on, vertical-blank interrupt enabled. The VDC only raises
    # its VD status flag when that interrupt is enabled; the CPU keeps IRQs
    # masked, so the flag is polled and nothing is ever taken.
    vdc(a, 0x05, 0x0088)
    a.raw(STZ_ZP, FLAG); a.raw(STZ_ZP, COUNTER)

    # --- Main loop, once per frame ------------------------------------------
    a.label("loop")
    a.label("vblank"); a.raw(LDA_ABS, VDC_STATUS & 0xFF, VDC_STATUS >> 8); a.raw(AND_IMM, 0x20); a.rel8(BEQ, "vblank")
    a.raw(ST0, 0x07)                  # BXR = counter
    a.raw(LDA_ZP, COUNTER); a.raw(STA_ABS, VDC_DATA_LO & 0xFF, VDC_DATA_LO >> 8)
    a.raw(STZ_ABS, VDC_DATA_HI & 0xFF, VDC_DATA_HI >> 8)
    # Joypad: SEL high then low, then bit 0 is button I, low when pressed.
    a.raw(LDA_IMM, 0x01); a.raw(STA_ABS, JOYPAD & 0xFF, JOYPAD >> 8); a.raw(NOP); a.raw(NOP)
    a.raw(STZ_ABS, JOYPAD & 0xFF, JOYPAD >> 8); a.raw(NOP); a.raw(NOP)
    a.raw(LDA_ABS, JOYPAD & 0xFF, JOYPAD >> 8); a.raw(AND_IMM, 0x01); a.rel8(BNE, "button_up")
    a.raw(LDA_ZP, FLAG); a.rel8(BNE, "loop")
    a.raw(LDA_IMM, 0x01); a.raw(STA_ZP, FLAG); a.raw(INC_ZP, COUNTER)
    a.abs16(JMP, "loop")
    a.label("button_up"); a.raw(STZ_ZP, FLAG); a.abs16(JMP, "loop")
    a.label("interrupt"); a.raw(0x40)   # RTI
    return a.assemble(), a.labels


def build() -> bytes:
    code, labels = program()
    rom = bytearray(ROM_SIZE)
    rom[0:len(code)] = code
    # Vectors at the end of the bank: IRQ2, IRQ1, timer, NMI, reset.
    for offset in (0x1FF6, 0x1FF8, 0x1FFA, 0x1FFC):
        rom[offset] = labels["interrupt"] & 0xFF; rom[offset + 1] = labels["interrupt"] >> 8
    rom[0x1FFE] = labels["reset"] & 0xFF; rom[0x1FFF] = labels["reset"] >> 8
    return bytes(rom)


if __name__ == "__main__":
    here = pathlib.Path(__file__).parent
    data = build()
    (here / "relay-pce-counter.pce").write_bytes(data)
    print(f"relay-pce-counter.pce: {len(data)} bytes, reset vector ${data[0x1FFF]:02X}{data[0x1FFE]:02X}")
