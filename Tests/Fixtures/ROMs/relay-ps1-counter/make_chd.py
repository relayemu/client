#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
# SPDX-License-Identifier: CC0-1.0
"""Produce an uncompressed CHD v5 CD with one authored data/audio disc.

The final seven-frame audio track forces four-frame CHD track padding.
No CHDMAN, firmware, third-party SDK or private content is required.
This exercises CHD structure/sector conversion; compressed-codec proof is separate.
"""
from pathlib import Path
import hashlib
import struct
ROOT=Path(__file__).resolve().parent
raw=(ROOT/'relay-ps1-counter.bin').read_bytes()
audio=b'\x34\x12\xcd\xab'*(2352*7//4)
(ROOT/'relay-ps1-tone.bin').write_bytes(audio)
(ROOT/'relay-ps1-audio.cue').write_text('FILE "relay-ps1-counter.bin" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\nFILE "relay-ps1-tone.bin" BINARY\n  TRACK 02 AUDIO\n    INDEX 01 00:00:00\n')
# CHD stores CDDA in big endian; BIN uses little endian.
normalized=bytearray()
for track in (raw, bytes(b for pair in zip(audio[1::2],audio[0::2]) for b in pair)):
 for i in range(0,len(track),2352):normalized+=track[i:i+2352]+bytes(96)
 normalized+=bytes((-len(normalized))%(2448*4))
hunk=2448*4;hunks=len(normalized)//hunk
metadata=[b'TRACK:1 TYPE:MODE2_RAW SUBTYPE:NONE FRAMES:300 PREGAP:0 PGTYPE:MODE1 PGSUB:NONE POSTGAP:0\0',b'TRACK:2 TYPE:AUDIO SUBTYPE:NONE FRAMES:7 PREGAP:0 PGTYPE:MODE1 PGSUB:NONE POSTGAP:0\0']
map_offset=124;meta_offset=map_offset+4*hunks
chain=bytearray()
for i,text in enumerate(metadata):
 next_offset=meta_offset+len(chain)+16+len(text) if i+1<len(metadata) else 0
 chain+=b'CHT2'+struct.pack('>IQ',len(text)|0x01000000,next_offset)+text
first_data=((meta_offset+len(chain)+hunk-1)//hunk)*hunk
header=bytearray(124);header[:8]=b'MComprHD';struct.pack_into('>II',header,8,124,5)
struct.pack_into('>QQQII',header,32,len(normalized),map_offset,meta_offset,hunk,2448)
header[64:84]=hashlib.sha1(normalized).digest()
map_=b''.join(struct.pack('>I',first_data//hunk+i) for i in range(hunks))
output=header+map_+chain;output+=bytes(first_data-len(output));output+=normalized
(ROOT/'relay-ps1-audio.chd').write_bytes(output)
print(f'{len(output)} byte CHD; {hunks} hunks; audio track frames=7 padding=1')
