#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
# SPDX-License-Identifier: CC0-1.0
"""Add an automatically started continuous 512 Hz PSG tone to the CC0 SRAM
counter fixture. No compiler, SDK, BIOS, logo or commercial ROM is required.
The original generated counter is an explicit, digest-checked source input.
"""
import hashlib
import pathlib
import struct

HERE = pathlib.Path(__file__).resolve().parent
source = HERE.parent / 'relay-sram-counter' / 'relay-sram-counter.gba'
original = source.read_bytes()
assert hashlib.sha256(original).hexdigest() == '4525d25b8d5de6173698039b9638f49979dfd7b7665be367622f89ff8b961c47', 'regenerate/review the counter source before changing this digest'
rom = bytearray(original)
rom[0xA0:0xAC] = b'RELAYTONE   '
rom[0xAC:0xB0] = b'RTON'
rom[0xBD] = (-(sum(rom[0xA0:0xBD]) + 0x19)) & 0xFF

# A short ARM entry prologue in previously unused ROM padding; the original
# counter program at 0xC0 and SRAM marker at 0x200 are unchanged.
origin = 0x300
writes = [
    (0x04000084, 0x0080),  # SOUNDCNT_X: PSG master enable first
    (0x04000080, 0x2277),  # SOUNDCNT_L: channel 2 on L/R, both PSG volumes 7
    (0x04000082, 0x0002),  # SOUNDCNT_H: PSG ratio 100%, DirectSound disabled
    (0x04000088, 0x0200),  # SOUNDBIAS: neutral bias, 32768 Hz output mode
    (0x04000068, 0xF080),  # SOUND2CNT_L: 50% duty, volume 15, no envelope step
    (0x0400006C, 0x8700),  # SOUND2CNT_H: trigger, no length expiry, frequency 1792
]
# PSG frequency is 131072/(2048-1792) = 512 Hz; the GBA core continues to
# produce its normal ~59.7275 Hz console frame cadence independently.
pool = origin + 4 * (3 * len(writes) + 1)
words = []
for index, (address, value) in enumerate(writes):
    pc = origin + 4 * len(words)
    words.extend([
        0xE59F8000 | ((pool + 8 * index) - (pc + 8)),      # ldr r8, =address
        0xE59F9000 | ((pool + 8 * index + 4) - (pc + 12)), # ldr r9, =value
        0xE1C890B0,                                      # strh r9, [r8]
    ])
pc = origin + 4 * len(words)
words.append(0xEA000000 | (((0xC0 - (pc + 8)) // 4) & 0xFFFFFF))
for address, value in writes:
    words.extend([address, value])
assert origin + 4 * len(words) < len(rom)
struct.pack_into('<I', rom, 0, 0xEA000000 | ((origin - 8) // 4))
for index, value in enumerate(words):
    struct.pack_into('<I', rom, origin + 4 * index, value)
assert rom[0xC0:0x300] == original[0xC0:0x300]
assert (sum(rom[0xA0:0xBE]) + 0x19) & 0xFF == 0
# Independently decode the generated prologue and prove its MMIO writes.
registers = {}
observed = []
for index in range(3 * len(writes)):
    pc = origin + 4 * index
    instruction = struct.unpack_from('<I', rom, pc)[0]
    if instruction & 0xFFFF0000 in (0xE59F0000,):
        registers[(instruction >> 12) & 15] = struct.unpack_from('<I', rom, pc + 8 + (instruction & 0xFFF))[0]
    else:
        assert instruction == 0xE1C890B0
        observed.append((registers[8], registers[9]))
assert observed == writes
out = HERE / 'relay-sram-tone.gba'
out.write_bytes(rom)
print(f'{hashlib.sha256(rom).hexdigest()}  {out.name} ({len(rom)} bytes)')
