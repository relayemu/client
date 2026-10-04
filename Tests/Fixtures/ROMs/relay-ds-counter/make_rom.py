#!/usr/bin/env python3
"""Generates Relay's Nintendo DS test program, relay-ds-counter.nds.

A 64 KiB retail-style cartridge (game code RLAY, so the emulator gives it the
8 KiB EEPROM save memory a retail cart has) whose ARM9 and ARM7 programs are
hand-assembled here; no toolchain, no Nintendo code, no encrypted secure area
(the ARM9 binary sits at 0x8000, past the secure area, so it is copied as is).

Behaviour, the same contract as Relay's other counter fixtures, plus touch:

  * at boot: read byte 0 of the EEPROM, add one, write it back;
  * draw vertical bars on both screens so the picture is not blank;
  * loop: every press of A adds one to byte 0 (a press counts once until A is
    released); the top screen scrolls horizontally by the counter, so the
    picture changes whenever the count does;
  * the ARM7 reads the touch panel every frame and publishes the pen state and
    X position in main RAM; while the pen is down the ARM9 paints a red column
    at that X on the bottom screen, so a touch is visible in the bottom frame.

Byte 0 of the battery save is therefore the number of launches plus the
number of presses of A.

Regenerate with:  python3 make_rom.py
"""
import pathlib
import struct

# --- A very small ARM assembler ------------------------------------------
# Only what these two programs use: data processing with immediates and
# shifted registers, LDR/STR (word, byte, halfword) with immediate offsets,
# branches, BL, and `ldr rd, =imm32` through a literal pool at the end.

AL, EQ, NE, CS, CC, MI, PL = 14, 0, 1, 2, 3, 4, 5
R0, R1, R2, R3, R4, R5, R6, R7, R8, R9, R10, R11, R12, SP, LR, PC = range(16)


def rotate_immediate(value):
    """Encodes a 32-bit constant as an 8-bit immediate with an even rotation."""
    value &= 0xFFFFFFFF
    for rotation in range(0, 32, 2):
        rotated = ((value << rotation) | (value >> (32 - rotation))) & 0xFFFFFFFF
        if rotated < 0x100:
            return ((rotation // 2) << 8) | rotated
    raise ValueError(f"cannot encode immediate 0x{value:X}")


class Assembler:
    def __init__(self, origin):
        self.origin = origin
        self.words = []          # (emit(labels, pool_base) -> int)
        self.labels = {}
        self.literals = []       # 32-bit constants, appended to the code

    @property
    def pc(self):
        return self.origin + 4 * len(self.words)

    def label(self, name):
        self.labels[name] = self.pc

    def word(self, value):
        self.words.append(lambda labels, pool: value)

    def dp(self, opcode, rd, rn, op2, set_flags=False, cond=AL):
        immediate = isinstance(op2, int) and not isinstance(op2, Register)
        if immediate:
            op2 = rotate_immediate(op2)
            i_bit = 1 << 25
        else:
            op2 = op2.encode()
            i_bit = 0
        self.word((cond << 28) | i_bit | (opcode << 21) | (int(set_flags) << 20) | (rn << 16) | (rd << 12) | op2)

    # Data processing
    def mov(self, rd, op2, cond=AL): self.dp(13, rd, 0, op2, cond=cond)
    def mvn(self, rd, op2): self.dp(15, rd, 0, op2)
    def add(self, rd, rn, op2): self.dp(4, rd, rn, op2)
    def sub(self, rd, rn, op2): self.dp(2, rd, rn, op2)
    def and_(self, rd, rn, op2): self.dp(0, rd, rn, op2)
    def orr(self, rd, rn, op2): self.dp(12, rd, rn, op2)
    def bic(self, rd, rn, op2): self.dp(14, rd, rn, op2)
    def cmp(self, rn, op2): self.dp(10, 0, rn, op2, set_flags=True)
    def tst(self, rn, op2): self.dp(8, 0, rn, op2, set_flags=True)

    # Memory
    def _mem(self, load, byte, rd, rn, offset, cond=AL):
        assert 0 <= offset < 4096
        self.word((cond << 28) | (1 << 26) | (1 << 24) | (1 << 23) | (int(byte) << 22) | (int(load) << 20) | (rn << 16) | (rd << 12) | offset)

    def ldr(self, rd, rn, offset=0): self._mem(True, False, rd, rn, offset)
    def str(self, rd, rn, offset=0): self._mem(False, False, rd, rn, offset)
    def ldrb(self, rd, rn, offset=0): self._mem(True, True, rd, rn, offset)
    def strb(self, rd, rn, offset=0): self._mem(False, True, rd, rn, offset)

    def _memh(self, load, rd, rn, offset):
        assert 0 <= offset < 256
        self.word((AL << 28) | (1 << 24) | (1 << 23) | (1 << 22) | (int(load) << 20) | (rn << 16) | (rd << 12)
                  | ((offset >> 4) << 8) | (0xB << 4) | (offset & 0xF))

    def ldrh(self, rd, rn, offset=0): self._memh(True, rd, rn, offset)
    def strh(self, rd, rn, offset=0): self._memh(False, rd, rn, offset)

    def ldr_literal(self, rd, value):
        index = len(self.literals)
        self.literals.append(value & 0xFFFFFFFF)
        here = self.pc
        def emit(labels, pool):
            offset = pool + 4 * index - (here + 8)
            assert 0 <= offset < 4096
            return (AL << 28) | (1 << 26) | (1 << 24) | (1 << 23) | (1 << 20) | (PC << 16) | (rd << 12) | offset
        self.words.append(emit)

    # Branches
    def _branch(self, name, link, cond):
        here = self.pc
        def emit(labels, pool):
            offset = (labels[name] - (here + 8)) >> 2
            return (cond << 28) | (5 << 25) | (int(link) << 24) | (offset & 0xFFFFFF)
        self.words.append(emit)

    def b(self, name, cond=AL): self._branch(name, False, cond)
    def bl(self, name): self._branch(name, True, AL)
    def ret(self): self.mov(PC, Register(LR))

    def assemble(self):
        pool = self.pc
        out = bytearray()
        for emit in self.words:
            out += struct.pack("<I", emit(self.labels, pool))
        for value in self.literals:
            out += struct.pack("<I", value)
        return bytes(out)


class Register:
    """A register operand, optionally shifted: Register(R1, lsl=4) or lsr=."""
    def __init__(self, reg, lsl=0, lsr=0):
        self.reg, self.lsl, self.lsr = reg, lsl, lsr

    def encode(self):
        if self.lsr:
            return (self.lsr << 7) | (1 << 5) | self.reg
        return (self.lsl << 7) | self.reg


# --- Hardware ---------------------------------------------------------------
IO = 0x04000000
DISPCNT_A, DISPSTAT, BG3CNT_A, BG3PA_A, BG3PD_A, BG3X_A = 0x0000, 0x0004, 0x000E, 0x0030, 0x0036, 0x0038
KEYINPUT, KEYXY = 0x0130, 0x0136
EXMEMCNT = 0x0204
AUXSPICNT, AUXSPIDATA = 0x01A0, 0x01A2
SPICNT, SPIDATA = 0x01C0, 0x01C2
VRAMCNT_A, VRAMCNT_C = 0x0240, 0x0242
POWCNT1 = 0x0304
DISPCNT_B, BG3CNT_B, BG3PA_B, BG3PD_B = 0x1000, 0x100E, 0x1030, 0x1036
VRAM_A_BG, VRAM_B_BG = 0x06000000, 0x06200000
SHARED_TOUCH = 0x027FF000       # word written by the ARM7: bit 8 pen down, bits 0-7 X

WHITE, BLACK, RED = 0xFFFF, 0x8000, 0x801F   # 15-bit BGR with the bitmap alpha bit


def arm9_program():
    a = Assembler(0x02000000)
    a.label("start")
    a.ldr_literal(R10, IO)                       # r10 = I/O base for the whole program

    # Power and VRAM: both 2D engines on, engine A on the top screen, bank A
    # to engine A's background memory, bank C to engine B's.
    # (Halfword stores reach 255 bytes past their base, so engine B and the
    # cartridge SPI get bases of their own: r7 and r12.)
    a.ldr_literal(R1, 0x8203); a.str(R1, R10, POWCNT1)
    a.mov(R1, 0x81); a.strb(R1, R10, VRAMCNT_A)
    a.mov(R1, 0x84); a.strb(R1, R10, VRAMCNT_C)
    a.ldr_literal(R7, IO + DISPCNT_B)
    a.ldr_literal(R12, IO + AUXSPICNT)
    # Direct boot hands the cartridge slot to the ARM7 (EXMEMCNT bit 11); take it
    # back so this program can talk to the EEPROM itself.
    a.ldr_literal(R6, IO + EXMEMCNT)
    a.ldrh(R1, R6, 0); a.bic(R1, R1, 0x800); a.strh(R1, R6, 0)

    # Both engines: graphics mode 5 with BG3 as a 256×192 direct-colour bitmap.
    a.ldr_literal(R1, 0x00010805)
    a.str(R1, R10, DISPCNT_A); a.str(R1, R7, 0)
    a.ldr_literal(R1, 0x4084)
    a.strh(R1, R10, BG3CNT_A); a.strh(R1, R7, BG3CNT_B - DISPCNT_B)
    a.mov(R1, 0x100)
    a.strh(R1, R10, BG3PA_A); a.strh(R1, R10, BG3PD_A)
    a.strh(R1, R7, BG3PA_B - DISPCNT_B); a.strh(R1, R7, BG3PD_B - DISPCNT_B)

    # Vertical bars, four pixels wide, on both screens.
    for base in (VRAM_A_BG, VRAM_B_BG):
        a.ldr_literal(R0, base)
        a.ldr_literal(R2, 256 * 192)                # pixels left
        a.mov(R3, 0)                                # x
        a.label(f"fill_{base:X}")
        a.tst(R3, 4)
        a.ldr_literal(R1, WHITE)
        a.ldr_literal(R4, BLACK)
        a.mov(R1, Register(R4), cond=NE)
        a.strh(R1, R0, 0)
        a.add(R0, R0, 2)
        a.add(R3, R3, 1)
        a.and_(R3, R3, 0xFF)
        a.sub(R2, R2, 1)
        a.cmp(R2, 0)
        a.b(f"fill_{base:X}", NE)

    # Battery: byte 0 of the EEPROM += 1 at every launch. r8 holds the counter.
    a.bl("eeprom_read")
    a.add(R8, R0, 1)
    a.and_(R8, R8, 0xFF)
    a.bl("eeprom_write")
    a.mov(R9, 0)                                    # "A was down" flag

    # --- Main loop, once per frame ------------------------------------------
    a.label("loop")
    a.label("wait_end"); a.ldrh(R1, R10, DISPSTAT); a.tst(R1, 1); a.b("wait_end", NE)
    a.label("wait_start"); a.ldrh(R1, R10, DISPSTAT); a.tst(R1, 1); a.b("wait_start", EQ)
    # Top screen scrolls by the counter (BG3X is an 8.8 fixed-point reference).
    a.mov(R1, Register(R8, lsl=8)); a.str(R1, R10, BG3X_A)
    # A (bit 0 of KEYINPUT, low when pressed): count a press once.
    a.ldr(R1, R10, KEYINPUT); a.tst(R1, 1)
    a.b("a_up", NE)
    a.cmp(R9, 1); a.b("touch", EQ)
    a.mov(R9, 1)
    a.add(R8, R8, 1); a.and_(R8, R8, 0xFF)
    a.bl("eeprom_write")
    a.b("touch")
    a.label("a_up"); a.mov(R9, 0)
    # Touch: the ARM7 publishes pen state and X; paint a red column while down.
    a.label("touch")
    a.ldr_literal(R0, SHARED_TOUCH); a.ldr(R1, R0, 0)
    a.tst(R1, 0x100); a.b("loop", EQ)
    a.and_(R1, R1, 0xFF)                            # x
    a.ldr_literal(R0, VRAM_B_BG)
    a.add(R0, R0, Register(R1, lsl=1))               # column start
    a.ldr_literal(R2, RED)
    a.mov(R3, 192)
    a.label("column"); a.strh(R2, R0, 0); a.add(R0, R0, 512); a.sub(R3, R3, 1); a.cmp(R3, 0); a.b("column", NE)
    a.b("loop")

    # --- EEPROM over the cartridge SPI --------------------------------------
    # spi(r0 = byte, r1 = 1 to keep chip select) -> r0 = byte received.
    a.label("spi")
    a.ldr_literal(R2, 0xA000)                       # slot enabled, serial mode
    a.cmp(R1, 0)
    a.dp(12, R2, R2, 0x40, cond=NE)                 # orr r2, r2, #0x40: keep chip select
    a.strh(R2, R12, 0)                              # AUXSPICNT
    a.strb(R0, R12, 2)                              # AUXSPIDATA
    a.label("spi_busy"); a.ldrh(R3, R12, 0); a.tst(R3, 0x80); a.b("spi_busy", NE)
    a.ldrb(R0, R12, 2)
    a.ret()

    # eeprom_read -> r0 = byte 0.  (READ 0x03, address 0x0000, one data byte)
    a.label("eeprom_read")
    a.mov(R11, Register(LR))
    a.mov(R0, 0x03); a.mov(R1, 1); a.bl("spi")
    a.mov(R0, 0); a.mov(R1, 1); a.bl("spi")
    a.mov(R0, 0); a.mov(R1, 1); a.bl("spi")
    a.mov(R0, 0); a.mov(R1, 0); a.bl("spi")
    a.mov(PC, Register(R11))

    # eeprom_write: byte 0 = r8.  (WREN, then WRITE 0x02, address, data)
    a.label("eeprom_write")
    a.mov(R11, Register(LR))
    a.mov(R0, 0x06); a.mov(R1, 0); a.bl("spi")
    a.mov(R0, 0x02); a.mov(R1, 1); a.bl("spi")
    a.mov(R0, 0); a.mov(R1, 1); a.bl("spi")
    a.mov(R0, 0); a.mov(R1, 1); a.bl("spi")
    a.mov(R0, Register(R8)); a.mov(R1, 0); a.bl("spi")
    a.mov(PC, Register(R11))
    return a.assemble()


def arm7_program():
    a = Assembler(0x03800000)
    a.label("start")
    a.ldr_literal(R10, IO)
    a.ldr_literal(R12, IO + SPICNT)
    a.label("loop")
    # Touch X through the panel's SPI: command 0xD0 (start, X channel, 12-bit),
    # then two bytes of result: 7 bits then 5 bits.
    a.mov(R0, 0xD0); a.mov(R1, 1); a.bl("spi")
    a.mov(R0, 0); a.mov(R1, 1); a.bl("spi"); a.mov(R4, Register(R0))
    a.mov(R0, 0); a.mov(R1, 0); a.bl("spi")
    a.mov(R4, Register(R4, lsl=5))
    a.orr(R4, R4, Register(R0, lsr=3))            # 12-bit ADC value
    a.mov(R4, Register(R4, lsr=4))                 # screen pixels
    a.and_(R4, R4, 0xFF)
    # Pen down is bit 6 of KEYXY, low when down.
    a.ldr(R1, R10, KEYXY); a.tst(R1, 0x40)
    a.dp(12, R4, R4, 0x100, cond=EQ)               # orr r4, r4, #0x100 when down
    a.ldr_literal(R0, SHARED_TOUCH); a.str(R4, R0, 0)
    a.b("loop")

    # spi(r0 = byte, r1 = 1 to keep chip select) -> r0, on the ARM7 SPI bus, touch panel.
    a.label("spi")
    a.ldr_literal(R2, 0x8202)                      # enabled, touch panel, 1 MHz
    a.cmp(R1, 0)
    a.dp(12, R2, R2, 0x800, cond=NE)               # hold chip select
    a.strh(R2, R12, 0)                             # SPICNT
    a.strb(R0, R12, 2)                             # SPIDATA
    a.label("spi_busy"); a.ldrh(R3, R12, 0); a.tst(R3, 0x80); a.b("spi_busy", NE)
    a.ldrb(R0, R12, 2)
    a.ret()
    return a.assemble()


def crc16(data):
    crc = 0xFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


ROM_SIZE = 0x10000
ARM9_OFFSET, ARM9_RAM = 0x8000, 0x02000000
ARM7_OFFSET, ARM7_RAM = 0x9000, 0x03800000


def build():
    arm9 = arm9_program()
    arm7 = arm7_program()
    assert len(arm9) < ARM7_OFFSET - ARM9_OFFSET and len(arm7) < 0x1000
    rom = bytearray(ROM_SIZE)
    rom[0x000:0x00C] = b"RELAY DS CNT"
    rom[0x00C:0x010] = b"RLAY"          # game code: not "####", so it is a retail-style cart
    rom[0x010:0x012] = b"01"
    rom[0x014] = 0x00                   # capacity: 128 KiB (the file is padded to it)
    struct.pack_into("<IIII", rom, 0x020, ARM9_OFFSET, ARM9_RAM, ARM9_RAM, len(arm9))
    struct.pack_into("<IIII", rom, 0x030, ARM7_OFFSET, ARM7_RAM, ARM7_RAM, len(arm7))
    struct.pack_into("<II", rom, 0x060, 0x00586000, 0x001808F8)   # cartridge bus timings, the usual values
    struct.pack_into("<II", rom, 0x080, ROM_SIZE, 0x4000)         # total size, header size
    # 0x0C0: the logo area stays zero; Relay ships no Nintendo bitmap.
    struct.pack_into("<H", rom, 0x15E, crc16(rom[:0x15E]))
    rom[ARM9_OFFSET:ARM9_OFFSET + len(arm9)] = arm9
    rom[ARM7_OFFSET:ARM7_OFFSET + len(arm7)] = arm7
    return bytes(rom), len(arm9), len(arm7)


if __name__ == "__main__":
    here = pathlib.Path(__file__).parent
    data, n9, n7 = build()
    (here / "relay-ds-counter.nds").write_bytes(data)
    print(f"relay-ds-counter.nds: {len(data)} bytes, ARM9 {n9} bytes, ARM7 {n7} bytes, header CRC 0x{crc16(data[:0x15E]):04X}")
