#!/usr/bin/env python3
"""Generates Relay's Super NES test program, relay-snes-counter.sfc.

A 32 KiB LoROM cartridge with 8 KiB of battery-backed SRAM. Behaviour, the
same contract as Relay's other counter fixtures:

  * at boot: add one to byte 0 of the SRAM ($70:0000);
  * draw vertical bars over the whole of BG1 so the picture is not blank;
  * loop: every press of A adds one to byte 0 (a press counts once until A is
    released), and BG1 scrolls horizontally by the counter, so the picture
    changes whenever the count does.

Byte 0 of the battery save is therefore the number of launches plus the
number of presses of A, and a press of A is visible in the framebuffer.

Hand-assembled 65816, no toolchain required. Regenerate with:
    python3 make_rom.py
"""
import pathlib

ROM_SIZE = 0x8000     # one LoROM bank, mapped at $00:8000-$FFFF
ORIGIN = 0x8000
HEADER = 0x7FC0       # ROM offset of the LoROM header


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


# 65816 opcodes used here.
SEI, CLC, XCE, REP, SEP, TXS, RTI, JMP = 0x78, 0x18, 0xFB, 0xC2, 0xE2, 0x9A, 0x40, 0x4C
LDA_IMM, LDX_IMM, LDA_ABS, STA_ABS, LDA_LONG, STA_LONG = 0xA9, 0xA2, 0xAD, 0x8D, 0xAF, 0x8F
LDA_DP, STA_DP, STZ_DP, INC_A, AND_IMM, DEX = 0xA5, 0x85, 0x64, 0x1A, 0x29, 0xCA
BMI, BPL, BNE, BEQ = 0x30, 0x10, 0xD0, 0xF0

INIDISP, BGMODE, BG1SC, BG12NBA, BG1HOFS = 0x2100, 0x2105, 0x2107, 0x210B, 0x210D
VMAIN, VMADDL, VMADDH, VMDATAL, VMDATAH = 0x2115, 0x2116, 0x2117, 0x2118, 0x2119
CGADD, CGDATA, TM = 0x2121, 0x2122, 0x212C
NMITIMEN, HVBJOY, JOY1L = 0x4200, 0x4212, 0x4218
COUNTER = 0x700000   # byte 0 of the battery-backed SRAM


def lo(v): return v & 0xFF
def hi(v): return (v >> 8) & 0xFF
def bank(v): return (v >> 16) & 0xFF


def program():
    a = Assembler(ORIGIN)

    def sta(addr): a.raw(STA_ABS, lo(addr), hi(addr))
    def lda(addr): a.raw(LDA_ABS, lo(addr), hi(addr))
    def lda_imm(v): a.raw(LDA_IMM, v)

    a.label("reset")
    a.raw(SEI); a.raw(CLC); a.raw(XCE)                 # native mode
    a.raw(REP, 0x10); a.raw(LDX_IMM, 0xFF, 0x01); a.raw(TXS)   # 16-bit X, stack at $01FF
    a.raw(SEP, 0x30)                                   # 8-bit accumulator and index
    lda_imm(0x80); sta(INIDISP)                        # forced blank while we set up
    lda_imm(0x00); sta(NMITIMEN)

    # --- Battery SRAM: byte 0 += 1 at every launch --------------------------
    a.raw(LDA_LONG, lo(COUNTER), hi(COUNTER), bank(COUNTER))
    a.raw(INC_A)
    a.raw(STA_LONG, lo(COUNTER), hi(COUNTER), bank(COUNTER))

    # --- Video: mode 0, BG1 tilemap at VRAM word $0400, tiles at $0000 ------
    lda_imm(0x00); sta(BGMODE)
    lda_imm(0x04); sta(BG1SC)
    lda_imm(0x00); sta(BG12NBA)
    lda_imm(0x80); sta(VMAIN)                          # address increments after the high byte

    # Tile 1 (word $0008): low plane $F0, high plane $00 on all eight rows:
    # vertical bars four pixels wide in colour 1 and colour 0.
    lda_imm(0x08); sta(VMADDL); lda_imm(0x00); sta(VMADDH)
    a.raw(LDX_IMM, 8)
    a.label("tile"); lda_imm(0xF0); sta(VMDATAL); lda_imm(0x00); sta(VMDATAH); a.raw(DEX); a.rel8(BNE, "tile")

    # Tilemap: 1024 entries of tile 1 (X is 8-bit, so four passes of 256).
    lda_imm(0x00); sta(VMADDL); lda_imm(0x04); sta(VMADDH)
    for _ in range(4):
        label = f"map{_}"
        a.raw(LDX_IMM, 0x00)
        a.label(label); lda_imm(0x01); sta(VMDATAL); lda_imm(0x00); sta(VMDATAH); a.raw(DEX); a.rel8(BNE, label)

    # Palette: colour 0 black, colour 1 white (15-bit BGR, low byte first).
    lda_imm(0x00); sta(CGADD)
    for word in (0x0000, 0x7FFF):
        lda_imm(lo(word)); sta(CGDATA); lda_imm(hi(word)); sta(CGDATA)

    lda_imm(0x01); sta(TM)                             # BG1 on the main screen
    lda_imm(0x0F); sta(INIDISP)                        # screen on, full brightness
    lda_imm(0x01); sta(NMITIMEN)                       # automatic joypad reading
    a.raw(STZ_DP, 0x00)                                # "A was down" flag

    # --- Main loop, once per frame ------------------------------------------
    a.label("loop")
    a.label("wait_end"); lda(HVBJOY); a.rel8(BMI, "wait_end")      # leave the previous vblank
    a.label("wait_start"); lda(HVBJOY); a.rel8(BPL, "wait_start")  # wait for the next one
    # BG1 horizontal scroll = counter (two writes: low byte, then high byte).
    a.raw(LDA_LONG, lo(COUNTER), hi(COUNTER), bank(COUNTER)); sta(BG1HOFS)
    lda_imm(0x00); sta(BG1HOFS)
    # Wait for the automatic joypad read to finish, then test A (bit 7 of $4218).
    a.label("joy_busy"); lda(HVBJOY); a.raw(AND_IMM, 0x01); a.rel8(BNE, "joy_busy")
    lda(JOY1L); a.raw(AND_IMM, 0x80); a.rel8(BEQ, "a_up")
    a.raw(LDA_DP, 0x00); a.rel8(BNE, "loop")           # already counted this press
    lda_imm(0x01); a.raw(STA_DP, 0x00)
    a.raw(LDA_LONG, lo(COUNTER), hi(COUNTER), bank(COUNTER))
    a.raw(INC_A)
    a.raw(STA_LONG, lo(COUNTER), hi(COUNTER), bank(COUNTER))
    a.abs16(JMP, "loop")
    a.label("a_up")
    a.raw(STZ_DP, 0x00)
    a.abs16(JMP, "loop")

    a.label("interrupt")
    a.raw(RTI)
    return a.assemble(), a.labels


def build() -> bytes:
    code, labels = program()
    rom = bytearray(ROM_SIZE)
    rom[0:len(code)] = code

    title = b"RELAY SNES COUNTER".ljust(21, b" ")
    rom[HEADER:HEADER + 21] = title
    rom[HEADER + 0x15] = 0x20      # LoROM, slow ROM
    rom[HEADER + 0x16] = 0x02      # ROM + RAM + battery
    rom[HEADER + 0x17] = 0x05      # 32 KiB ROM
    rom[HEADER + 0x18] = 0x03      # 8 KiB SRAM
    rom[HEADER + 0x19] = 0x01      # North America
    rom[HEADER + 0x1A] = 0x01      # developer id (not the $33 extended-header marker)
    rom[HEADER + 0x1B] = 0x00      # version

    # Vectors: everything but RESET goes to an RTI.
    handler, reset = labels["interrupt"], labels["reset"]
    for offset in (0x7FE4, 0x7FE6, 0x7FE8, 0x7FEA, 0x7FEE, 0x7FF4, 0x7FF8, 0x7FFA, 0x7FFE):
        rom[offset] = lo(handler); rom[offset + 1] = hi(handler)
    rom[0x7FFC] = lo(reset); rom[0x7FFD] = hi(reset)

    # Checksum over the whole image with the pair set to $FFFF / $0000, which
    # sums to the same value as the final pair (complement + checksum).
    rom[HEADER + 0x1C:HEADER + 0x1E] = b"\xFF\xFF"
    rom[HEADER + 0x1E:HEADER + 0x20] = b"\x00\x00"
    checksum = sum(rom) & 0xFFFF
    complement = checksum ^ 0xFFFF
    rom[HEADER + 0x1C] = lo(complement); rom[HEADER + 0x1D] = hi(complement)
    rom[HEADER + 0x1E] = lo(checksum); rom[HEADER + 0x1F] = hi(checksum)
    return bytes(rom)


if __name__ == "__main__":
    here = pathlib.Path(__file__).parent
    data = build()
    (here / "relay-snes-counter.sfc").write_bytes(data)
    print(f"relay-snes-counter.sfc: {len(data)} bytes, checksum "
          f"0x{data[HEADER + 0x1E] | (data[HEADER + 0x1F] << 8):04X}")
