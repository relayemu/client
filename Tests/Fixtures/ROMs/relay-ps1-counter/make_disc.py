#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
# SPDX-License-Identifier: CC0-1.0
"""Assemble a Relay-authored MIPS-I program and ISO9660 CUE/BIN disc.

No SDK, BIOS, proprietary boot sector, or external assembler is used.
The program polls the emulated controller and memory card through SIO,
counts boots/Cross presses in a real card file, and emits a looping SPU tone.
"""
from pathlib import Path
import struct

ROOT=Path(__file__).resolve().parent
BASE=0x80010000
R={name:i for i,name in enumerate('zero at v0 v1 a0 a1 a2 a3 t0 t1 t2 t3 t4 t5 t6 t7 s0 s1 s2 s3 s4 s5 s6 s7 t8 t9 k0 k1 gp sp fp ra'.split())}
words=[]; labels={}; fixups=[]
def reg(r): return R[r] if isinstance(r,str) else r
def emit(w): words.append(w&0xffffffff)
def label(n): labels[n]=len(words)
def li(r,v):
 r=reg(r);emit(0x3c000000|r<<16|(v>>16)&65535);emit(0x34000000|r<<21|r<<16|v&65535)
def la(r,n): fixups.append((len(words),'addr',(r,n)));li(r,0)
def imm(op,t,s,v):emit(op<<26|reg(s)<<21|reg(t)<<16|v&65535)
def mov(t,s):emit(reg(s)<<21|reg(t)<<11|0x21)
def bit(op,d,s,t):emit(reg(s)<<21|reg(t)<<16|reg(d)<<11|op)
def shift(d,t,n):emit(reg(t)<<16|reg(d)<<11|n<<6)
def load(t,off,s,op=35):imm(op,t,s,off);emit(0)
def store(t,off,s,op=43):imm(op,t,s,off)
def branch(op,s,t,n):fixups.append((len(words),'branch',n));emit(op<<26|reg(s)<<21|reg(t)<<16);emit(0)
def jump(n,link=False):fixups.append((len(words),'jump',n));emit((3 if link else 2)<<26);emit(0)
def ret(r='ra'):emit(reg(r)<<21|8);emit(0)
def send(v):li('a0',v);jump('transfer',True)
def io_begin():
 li('t0',0x1f801040);store('zero',10,'t0',41);li('t1',0x0d);store('t1',8,'t0',41)
 li('t1',0x88);store('t1',14,'t0',41);li('t1',0x1003);store('t1',10,'t0',41)
def io_end():li('t0',0x1f801040);store('zero',10,'t0',41)
def gpu(value,offset=0):li('t0',0x1f801810);li('t1',value);store('t1',offset,'t0')
def spu(off,value):li('t0',0x1f801c00);li('t1',value);store('t1',off,'t0',41)

label('start');li('sp',0x801fff00);emit(0x40806000) # disable CPU interrupts; poll hardware
li('t0',0x1f801074);store('zero',0,'t0')
for c in (0,0x03000000,0x05000000,0x06c60260,0x07042018,0x08000001):gpu(c,4)
# A short authored ADPCM waveform at SPU RAM 0x1000, with loop-end/start flags.
spu(0x1aa,0xc010);spu(0x1a6,0x0200)
for v in (0x0708,0x7531,0x1357,0xeca8,0x8ace,0x7531,0x1357,0xeca8):spu(0x1a8,v)
spu(0x1aa,0xc000);spu(0x180,0x3fff);spu(0x182,0x3fff)
spu(0,0x2000);spu(2,0x2000);spu(4,0x0400);spu(6,0x0200);spu(8,0x00ff);spu(10,0x1fc0);spu(14,0x0200);spu(0x188,1)
# The game owns card block 1. Read its payload and recognize our own marker.
li('a1',65);la('a2','progress');jump('card_read',True)
la('s2','progress');load('t0',0,'s2');li('t1',0x594c4552);li('s0',0)
branch(5,'t0','t1','fresh');load('s0',4,'s2',36)
label('fresh');store('t1',0,'s2');imm(9,'s0','s0',1);imm(12,'s0','s0',255);store('s0',4,'s2',40)
li('a1',1);la('a2','directory');jump('card_write',True)
li('a1',64);la('a2','save_title');jump('card_write',True)
li('a1',65);mov('a2','s2');jump('card_write',True);li('s1',0)
label('frame');li('t0',0x1f801070);store('zero',0,'t0')
label('vblank');load('t1',0,'t0');imm(12,'t1','t1',1);branch(4,'t1','zero','vblank')
io_begin();send(1);send(0x42);mov('s3','v0');send(0);send(0);mov('s4','v0');send(0);shift('v0','v0',8);bit(0x25,'s4','s4','v0')
# Consume analog data as well; digital pads return 0xff after their packet.
send(0);send(0);send(0);mov('s5','v0');send(0);io_end()
imm(14,'s4','s4',0xffff);imm(12,'s4','s4',0x4000)
branch(4,'s4','zero','not_pressed');branch(5,'s1','zero','not_pressed')
imm(9,'s0','s0',1);imm(12,'s0','s0',255);store('s0',4,'s2',40)
li('a1',65);mov('a2','s2');jump('card_write',True)
# card_write uses s4/s5; refresh the edge latch explicitly.
li('s4',0x4000)
label('not_pressed');mov('s1','s4')
# Display count in red, a stable green field, and analog X in blue.
li('t0',0x1f801810);li('t1',0x02004000);bit(0x25,'t1','t1','s0');
shift('t2','s5',16);bit(0x25,'t1','t1','t2');store('t1',0,'t0');store('zero',0,'t0');li('t1',0x00f00140);store('t1',0,'t0')
# Public test mailbox in guest RAM: real game counter, pad id, analog sample.
li('t0',0x80100000);store('s0',0,'t0');store('s3',4,'t0');store('s5',8,'t0');jump('frame')

# SIO byte transaction. t0/t1/t2 are scratch; all saved registers preserved.
label('transfer');li('t0',0x1f801040)
label('tx_ready');load('t1',4,'t0',37);imm(12,'t1','t1',1);branch(4,'t1','zero','tx_ready')
store('a0',0,'t0',40)
# Allow the emulated serial device time to complete even on hardware models
# whose RX ready flag is already set by the preceding byte.
li('t2',180)
label('serial_delay');imm(9,'t2','t2',-1);branch(5,'t2','zero','serial_delay')
label('rx_ready');load('t1',4,'t0',37);imm(12,'t1','t1',2);branch(4,'t1','zero','rx_ready')
load('v0',0,'t0',36);ret()

label('card_read');mov('s6','ra');mov('s5','a2');io_begin()
for b in (0x81,0x52,0,0):send(b)
# Only sectors below 256 are used by this authored program.
send(0);mov('a0','a1');jump('transfer',True)
for b in (0,0,0,0):send(b)
li('s7',128)
label('read_bytes');send(0);store('v0',0,'s5',40);imm(9,'s5','s5',1);imm(9,'s7','s7',-1);branch(5,'s7','zero','read_bytes')
send(0);send(0);io_end();ret('s6')

label('card_write');mov('s6','ra');mov('s5','a2');mov('s4','a1');io_begin()
for b in (0x81,0x57,0,0):send(b)
send(0);mov('a0','a1');jump('transfer',True);li('s7',128)
label('write_bytes');load('a0',0,'s5',36);bit(0x26,'s4','s4','a0');jump('transfer',True);imm(9,'s5','s5',1);imm(9,'s7','s7',-1);branch(5,'s7','zero','write_bytes')
mov('a0','s4');jump('transfer',True);send(0);send(0);send(0);io_end();ret('s6')

def data(name,bytes_):
 while len(words)%4:emit(0)
 label(name)
 assert len(bytes_)%4==0
 for w in struct.unpack('<%dI'%(len(bytes_)//4),bytes_):emit(w)
dir_=bytearray(128);dir_[0]=0x51;struct.pack_into('<I',dir_,4,8192);dir_[8:10]=b'\xff\xff';name=b'BASLUS-99999RELAY';dir_[10:10+len(name)]=name
for b in dir_[:127]:dir_[127]^=b
data('directory',dir_)
title=bytearray(128);title[:4]=b'SC\x11\x01';title[4:23]=b'Relay PS1 counter 1';data('save_title',title)
data('progress',bytes(128))
for i,kind,value in fixups:
 if kind=='addr':
  r,n=value;r=reg(r);v=BASE+labels[n]*4;words[i]=0x3c000000|r<<16|(v>>16)&65535;words[i+1]=0x34000000|r<<21|r<<16|v&65535
 elif kind=='branch':words[i]|=(labels[value]-i-1)&65535
 else:words[i]|=((BASE+labels[value]*4)>>2)&0x3ffffff
body=struct.pack('<%dI'%len(words),*words);body+=bytes((-len(body))%2048)
header=bytearray(2048);header[:8]=b'PS-X EXE';struct.pack_into('<IIII',header,0x10,BASE,0,BASE,len(body));struct.pack_into('<II',header,0x30,0x801fff00,0)
exe=header+body

# ISO9660, canonical fixed dates and names. No licensed console boot data.
def both32(v):return struct.pack('<I',v)+struct.pack('>I',v)
def both16(v):return struct.pack('<H',v)+struct.pack('>H',v)
def record(name,lba,size,directory=False):
 n=33+len(name)+(1 if len(name)%2==0 else 0);r=bytearray(n);r[0]=n;r[2:10]=both32(lba);r[10:18]=both32(size);r[18:25]=bytes([126,9,11,0,0,0,0]);r[25]=2 if directory else 0;r[28:32]=both16(1);r[32]=len(name);r[33:33+len(name)]=name;return r
cnf=b'BOOT = cdrom:\\RELAY.EXE;1\r\nTCB = 4\r\nEVENT = 10\r\nSTACK = 801fff00\r\n'
sectors=[bytearray(2048) for _ in range(300)]
pvd=sectors[16];pvd[:7]=b'\x01CD001\x01';pvd[8:40]=b'PLAYSTATION'.ljust(32,b' ');pvd[40:72]=b'RELAY_PS1_COUNTER'.ljust(32,b' ');pvd[80:88]=both32(len(sectors));pvd[120:124]=both16(1);pvd[124:128]=both16(1);pvd[128:132]=both16(2048);pvd[132:140]=both32(10);pvd[140:144]=struct.pack('<I',18);pvd[148:152]=struct.pack('>I',19);pvd[156:190]=record(b'\0',20,2048,True);pvd[881]=1
sectors[17][:7]=b'\xffCD001\x01';sectors[18][:10]=b'\x01\x00'+struct.pack('<I',20)+struct.pack('<H',1)+b'\0\0';sectors[19][:10]=b'\x01\x00'+struct.pack('>I',20)+struct.pack('>H',1)+b'\0\0'
records=b''.join([record(b'\0',20,2048,True),record(b'\x01',20,2048,True),record(b'SYSTEM.CNF;1',21,len(cnf)),record(b'RELAY.EXE;1',22,len(exe))]);sectors[20][:len(records)]=records;sectors[21][:len(cnf)]=cnf
for i in range(len(exe)//2048):sectors[22+i][:]=exe[i*2048:(i+1)*2048]
# MODE2/2352 Form 1. Compute the standard EDC/ECC in a separate function.
def edc(data):
 crc=0
 for b in data:
  crc^=b
  for _ in range(8):crc=(crc>>1)^(0xd8018001 if crc&1 else 0)
 return crc
f=[];b=[0]*256
for i in range(256):
 j=i<<1
 if j&256:j^=0x11d
 f.append(j);b[i^j]=i
def ecc(src,major,minor,mult,inc):
 size=major*minor;out=bytearray(major*2)
 for m in range(major):
  idx=(m>>1)*mult+(m&1);a=z=0
  for _ in range(minor):
   v=src[idx];idx=(idx+inc)%size;a^=v;z^=v;a=f[a]
  a=b[f[a]^z];out[m]=a;out[m+major]=a^z
 return out
def bcd(x):return (x//10)*16+x%10
raw=bytearray()
for lba,payload in enumerate(sectors):
 s=bytearray(2352);s[:12]=b'\0'+b'\xff'*10+b'\0';t=lba+150;s[12:16]=bytes([bcd(t//4500),bcd(t//75%60),bcd(t%75),2]);s[16:20]=bytes([0,0,8,0]);s[20:24]=s[16:20];s[24:2072]=payload;struct.pack_into('<I',s,2072,edc(s[16:2072]));address=bytes(s[12:16]);s[12:16]=bytes(4);s[2076:2248]=ecc(s[12:2076],86,24,2,86);s[2248:2352]=ecc(s[12:2248],52,43,86,88);s[12:16]=address;raw+=s
(ROOT/'relay-ps1-counter.bin').write_bytes(raw)
(ROOT/'relay-ps1-counter.cue').write_text('FILE "relay-ps1-counter.bin" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n')
# EXE is a build/debug aid; only the disc fixture is a checked-in test asset.
import sys
if '--exe' in sys.argv:(ROOT/'relay-ps1-counter.exe').write_bytes(exe)
print(f'{len(words)} instructions/data words; {len(raw)} byte disc')
