#!/usr/bin/env python3
"""Generates Relay's Game Boy and Game Boy Color test programs.

Two 32 KiB cartridges, identical apart from the Game Boy Color flag:

    relay-gb-counter.gb    a Game Boy cartridge (CGB flag 0x00)
    relay-gbc-counter.gbc  a Game Boy Color cartridge (CGB flag 0xC0)

Behaviour of both:

  * at boot: enable the cartridge's battery-backed RAM, read byte 0, add one,
    write it back;
  * draw a striped background so the picture is not blank;
  * loop: every press of A adds one to byte 0 (a press counts once until A is
    released), and the background scrolls by the counter's value, so the
    picture changes whenever the count does.

That gives the smoke tests a system whose video, input and battery save can
each be observed without any commercial ROM: the frame checksum changes when
A is pressed, and byte 0 of the battery save is the number of presses plus the
number of launches.

The header carries the four bytes 0xCE 0xED 0x66 0x66 at 0x104, which is the
format magic mGBA's `GBIsROM` looks for, and a valid header checksum. The
48-byte Nintendo logo bitmap is deliberately NOT included: this is a
development fixture for emulators, not a cartridge image.

Hand-assembled SM83, no toolchain required. Regenerate with:
    python3 make_rom.py
"""
import pathlib

ROM_SIZE = 0x8000  # 32 KiB, two banks: the smallest a Game Boy cartridge has

# --- A very small two-pass assembler --------------------------------------
# Each item is either raw bytes or a callable resolved once labels are known.

class Assembler:
    def __init__(self, origin):
        self.origin = origin
        self.items = []      # (size, emit) where emit(labels) -> bytes
        self.labels = {}
        self.pc = origin

    def label(self, name):
        self.labels[name] = self.pc

    def raw(self, *values):
        data = bytes(values)
        self.items.append((len(data), lambda labels, d=data: d))
        self.pc += len(data)

    def abs16(self, opcode, name):
        """An instruction taking a 16-bit absolute address label."""
        here = self.pc
        def emit(labels, op=opcode, n=name):
            return bytes([op, labels[n] & 0xFF, (labels[n] >> 8) & 0xFF])
        self.items.append((3, emit))
        self.pc += 3

    def rel8(self, opcode, name):
        """A relative jump to a label; the offset is from the next instruction."""
        next_pc = self.pc + 2
        def emit(labels, op=opcode, n=name, nxt=next_pc):
            delta = labels[n] - nxt
            if not -128 <= delta <= 127:
                raise ValueError(f"relative jump to {n} out of range: {delta}")
            return bytes([op, delta & 0xFF])
        self.items.append((2, emit))
        self.pc += 2

    def assemble(self):
        out = bytearray()
        for _, emit in self.items:
            out += emit(self.labels)
        return bytes(out)


# --- Opcodes used here ----------------------------------------------------
NOP, DI = 0x00, 0xF3
LD_SP_D16, LD_HL_D16, LD_BC_D16 = 0x31, 0x21, 0x01
LD_A_D8, LD_B_D8, LD_C_D8 = 0x3E, 0x06, 0x0E
LD_MEM16_A = 0xEA
LDH_MEM8_A, LDH_A_MEM8 = 0xE0, 0xF0
LD_A_HL, LD_HL_A, LD_HLI_A = 0x7E, 0x77, 0x22
INC_A, DEC_BC, DEC_C = 0x3C, 0x0B, 0x0D
LD_A_B, LD_B_A, LD_A_C, LD_C_A = 0x78, 0x47, 0x79, 0x4F
OR_C, AND_D8, CP_D8, XOR_A = 0xB1, 0xE6, 0xFE, 0xAF
JR, JR_NZ, JR_Z = 0x18, 0x20, 0x28
JP = 0xC3

# Hardware registers (offsets inside 0xFF00).
P1, LCDC, SCY, SCX, LY, BGP, BCPS, BCPD = 0x00, 0x40, 0x42, 0x43, 0x44, 0x47, 0x68, 0x69


def program():
    a = Assembler(0x0150)

    a.raw(DI)
    a.raw(LD_SP_D16, 0xFE, 0xFF)              # ld sp, $FFFE

    # --- Battery RAM: enable it, select bank 0, add one to byte 0 ---------
    a.raw(LD_A_D8, 0x0A)
    a.raw(LD_MEM16_A, 0x00, 0x00)             # ld [$0000], a   MBC3 RAM enable
    a.raw(XOR_A)
    a.raw(LD_MEM16_A, 0x00, 0x40)             # ld [$4000], a   RAM bank 0
    a.raw(LD_HL_D16, 0x00, 0xA0)              # ld hl, $A000
    a.raw(LD_A_HL)
    a.raw(INC_A)
    a.raw(LD_HL_A)                            # byte 0 += 1 at every launch

    # --- Wait for VBlank, then switch the LCD off to touch video memory ----
    a.label("wait_vblank")
    a.raw(LDH_A_MEM8, LY)
    a.raw(CP_D8, 144)
    a.rel8(JR_NZ, "wait_vblank")
    a.raw(XOR_A)
    a.raw(LDH_MEM8_A, LCDC)                   # LCD off

    # --- Tile 1: vertical bars, four pixels wide --------------------------
    # Tiles live at $8000, so tile 1 starts at $8010. Each row is two bytes:
    # the low bit plane then the high one. Low $F0 with high $00 paints the
    # left four pixels in colour 1 and the right four in colour 0, so the
    # screen shows vertical bars that visibly move when SCX changes.
    a.raw(LD_HL_D16, 0x10, 0x80)
    a.raw(LD_C_D8, 8)                         # eight rows
    a.label("tile_rows")
    a.raw(LD_A_D8, 0xF0)
    a.raw(LD_HLI_A)                           # low bit plane
    a.raw(LD_A_D8, 0x00)
    a.raw(LD_HLI_A)                           # high bit plane
    a.raw(DEC_C)
    a.rel8(JR_NZ, "tile_rows")

    # --- Background map: tile 1 over the whole of $9800..$9BFF ------------
    a.raw(LD_HL_D16, 0x00, 0x98)
    a.raw(LD_BC_D16, 0x00, 0x04)              # 1024 entries
    a.label("map_fill")
    a.raw(LD_A_D8, 0x01)
    a.raw(LD_HLI_A)
    a.raw(DEC_BC)
    a.raw(LD_A_B)
    a.raw(OR_C)
    a.rel8(JR_NZ, "map_fill")

    # --- Palettes and LCD back on -----------------------------------------
    a.raw(LD_A_D8, 0xE4)
    a.raw(LDH_MEM8_A, BGP)                    # Game Boy: 0 white … 3 black
    # Game Boy Color ignores BGP and reads its own palette RAM: select
    # background palette 0 with auto-increment, then write four colours
    # (white, black, dark grey, light grey as 15-bit little-endian words).
    # A Game Boy has no such registers and drops the writes.
    a.raw(LD_A_D8, 0x80)
    a.raw(LDH_MEM8_A, BCPS)
    for colour in (0x7FFF, 0x0000, 0x294A, 0x5294):
        a.raw(LD_A_D8, colour & 0xFF)
        a.raw(LDH_MEM8_A, BCPD)
        a.raw(LD_A_D8, colour >> 8)
        a.raw(LDH_MEM8_A, BCPD)
    a.raw(XOR_A)
    a.raw(LDH_MEM8_A, SCY)
    a.raw(LD_A_D8, 0x91)                      # LCD on, BG on, tile data at $8000
    a.raw(LDH_MEM8_A, LCDC)

    # --- Main loop --------------------------------------------------------
    # b holds "A was down on the previous pass", so a held button counts once.
    a.raw(LD_B_D8, 0x00)

    a.label("loop")
    # Scroll the background by the counter, so the picture follows the count.
    a.raw(LD_HL_D16, 0x00, 0xA0)
    a.raw(LD_A_HL)
    a.raw(LDH_MEM8_A, SCX)

    # Read the A button: write $10 to P1 to select the button row, then read
    # it back a few times, as the hardware needs a moment to settle.
    a.raw(LD_A_D8, 0x10)
    a.raw(LDH_MEM8_A, P1)
    a.raw(LDH_A_MEM8, P1)
    a.raw(LDH_A_MEM8, P1)
    a.raw(LDH_A_MEM8, P1)
    a.raw(AND_D8, 0x01)                       # bit 0 low means A is down
    a.rel8(JR_NZ, "a_is_up")

    # A is down: count it only if it was up on the previous pass.
    a.raw(LD_A_B)
    a.raw(CP_D8, 0x01)
    a.rel8(JR_Z, "loop")
    a.raw(LD_B_D8, 0x01)
    a.raw(LD_HL_D16, 0x00, 0xA0)
    a.raw(LD_A_HL)
    a.raw(INC_A)
    a.raw(LD_HL_A)
    a.rel8(JR, "loop")

    a.label("a_is_up")
    a.raw(LD_B_D8, 0x00)
    a.rel8(JR, "loop")

    return a.assemble()


def build(cgb_flag: int, title: bytes) -> bytes:
    rom = bytearray(b"\x00" * ROM_SIZE)

    # Entry point at 0x100.
    rom[0x100] = NOP
    rom[0x101] = JP
    rom[0x102] = 0x50
    rom[0x103] = 0x01

    # 0x104: the four header bytes mGBA's GBIsROM matches. The remaining 44
    # bytes of the logo area stay zero: Relay does not ship Nintendo's bitmap.
    rom[0x104:0x108] = bytes([0xCE, 0xED, 0x66, 0x66])

    rom[0x134:0x134 + len(title)] = title      # title, 0x134..0x142
    rom[0x143] = cgb_flag                      # Game Boy Color flag
    rom[0x144:0x146] = b"RL"                   # new licensee code
    rom[0x146] = 0x00                          # no Super Game Boy support
    rom[0x147] = 0x13                          # MBC3 + RAM + battery
    rom[0x148] = 0x00                          # 32 KiB ROM
    rom[0x149] = 0x02                          # 8 KiB battery RAM
    rom[0x14A] = 0x01                          # non-Japanese
    rom[0x14B] = 0x33                          # licensee code is in 0x144
    rom[0x14C] = 0x00                          # version

    # Header checksum: x = x - byte - 1 over 0x134..0x14C.
    checksum = 0
    for byte in rom[0x134:0x14D]:
        checksum = (checksum - byte - 1) & 0xFF
    rom[0x14D] = checksum

    code = program()
    rom[0x150:0x150 + len(code)] = code

    # Global checksum (0x14E..0x14F): the sum of every other byte, big-endian.
    total = (sum(rom) - rom[0x14E] - rom[0x14F]) & 0xFFFF
    rom[0x14E] = (total >> 8) & 0xFF
    rom[0x14F] = total & 0xFF
    return bytes(rom)


if __name__ == "__main__":
    here = pathlib.Path(__file__).parent
    for name, flag, title in [("relay-gb-counter.gb", 0x00, b"RELAY GB CNT"),
                              ("relay-gbc-counter.gbc", 0xC0, b"RELAY GBC CNT")]:
        data = build(flag, title)
        (here / name).write_bytes(data)
        print(f"{name}: {len(data)} bytes, header checksum 0x{data[0x14D]:02X}, "
              f"CGB flag 0x{data[0x143]:02X}")
