# PCSX-ReARMed for Relay

Upstream is pinned by `../RELAY_VENDOR.json`. All 1,322 regular archive files
match the pinned archive byte for byte. Relay additions are this directory,
`Package.swift` and the provenance manifest. GPL-3.0-or-later applies to the
Relay bridge; compiled upstream PCSX sources use GPL-2.0-or-later.

The native product is `PCSXRelay`, consumed only by `RelayPCSXAdapter`.
`RelayDiscCodec` is a separate, frontend-free reader used by RelayLibrary.
Neither product is a dynamic core loader. The Apple build selects the CPU
interpreter, ARM64 GTE assembly and the NEON software GPU. `DRC_DISABLE` excludes
the recompiler. The existing `TVOS` guard is set on every Apple platform to
exclude the upstream Apple `ptrace` call. No physical CD access or async GPU
thread is enabled. zlib comes from the operating system.

The wrappers include unmodified upstream C files: `PCSXPlatform.c` avoids
SwiftPM's special treatment of a file called `main.c`; `PCSXGPU.c` gives the
GPU translation unit its upstream per-file defines; `PCSXPad.c` exposes the
existing analog switch and omitted controller wire state; `PCSXSPUFreeze.c` validates this pinned SPU state's
lengths and sample geometry before restoration. The generated revision header
replaces a Git-dependent upstream build step. The generated `config.h` keeps
the upstream version and expands its 256-byte path limit to Apple's 1,024-byte
limit consistently across the core, so managed simulator/device paths are valid.

## Runtime contract

One PCSX instance owns the upstream global machine at a time. The emulation
thread serializes frames, state operations and card snapshots with `coreMutex`.
Input is atomic. The presenter and audio consumer use separate bounded buffers.
The audio callback uses `try_lock` and reports missing frames rather than
blocking on emulation. PAL/NTSC fractional timing comes from the core; the
clock follower adjusts pacing by at most 0.5%. Fast-forward is 2x and silent.
Pausing/resuming flushes stale audio. Relay's existing audio output and display
presenter remain responsible for device output.

The bridge accepts only the managed CUE/M3U produced by RelayLibrary. CHD is
validated and converted there, including four-frame track padding and CDDA
endianness. Untrusted CHD metadata never enters PCSX's historical CHD parser.
PBP is deliberately unsupported by the Relay importer. No host CD device,
multitap, plugin UI, cheats, network link or firmware download is exposed.

Both memory cards are concatenated into a 262,144-byte battery payload. The
core's disk writes are disabled. The app checkpoints changed card bytes through
BatterySaveManager/AtomicFile every two seconds and at lifecycle boundaries.
Cards retain the ordinary immutable revision, conflict and sync model.

Portable states contain a 64-byte `RLPSX001` header, both cards, the fixed
4,456,448-byte pinned raw state, and a SHA-256 checksum. Disc count/index,
controller type, analog mode, request position and reconnect timer are restored.
The latter two fields make input work immediately after fresh-device Auto Resume.
Real BIOS ROM bytes are zeroed
before any payload leaves the bridge; the header carries only its SHA-256.
Restore requires the same real BIOS, or the same HLE mode, on the other device.
A mismatch is distinct from corruption. Bounded state IO and SPU preflight
reject invalid streams, and failed loads restore the previous machine snapshot.
This is a pinned compatibility class, not an importer for other emulators'
states. `pcsx-da2cb8e-relay1` is shared across Relay's arm64 Apple targets.

Only verified user-imported SCPH-5500/5501/5502 BIOS files are offered to the
core. None is distributed here. HLE is available, with limited compatibility;
its successful execution of the authored counter does not establish retail
compatibility. The bridge builds against the pinned source in this directory.
