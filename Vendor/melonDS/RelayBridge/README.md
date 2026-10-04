# RelayBridge — Relay's platform layer and C interface for melonDS

Everything in this directory, `../Package.swift` and
`generated/version.h` is written by Relay (Maiko BOSSUYT, 2026) and licensed
GPL-3.0-or-later, the same licence as the melonDS tree around it
(`../LICENSE`, Copyright 2016-2026 melonDS team). No upstream file is
modified; `../RELAY_VENDOR.json` records the exact upstream commit and the
SHA-256 of the archive the tree was extracted from.

melonDS is built the way its own `src/CMakeLists.txt` builds the core, with
three options off: no JIT (the App Store forbids it; the interpreter runs on
every Apple device), no OpenGL renderer (software rendering only) and no GDB
stub. teakra (MIT, the DSi DSP) is compiled as upstream links it. Nothing of
the Qt/SDL frontend is compiled.

- `src/Platform.cpp` implements `src/Platform.h`, the interface every melonDS
  frontend provides: files, threads, semaphores, mutexes, timing, logging and
  the battery-save callback. Wi-Fi, local multiplayer, cameras, microphone,
  add-ons and dynamic libraries answer "nothing there".
- `include/MelonRelay.h` is the whole surface Relay's Swift adapter
  (`Packages/RelayEmulation/Sources/RelayMelonAdapter`) sees;
  `src/MelonRelay.cpp` implements it. The bridge runs the DS on its own thread
  at 59.8261 Hz, copies both screens out as RGBX8 after every frame, drains
  the SPU into a bounded stereo ring that Relay's `CoreAudioOutput` reads on
  the audio thread, and applies buttons and touches before each frame.
  The upstream software renderer already publishes BGRA8 after `ExpandColor`;
  the bridge only reorders those bytes to RGBX8. Re-expanding them as RGB6
  discards channel bits and corrupts both live images and save thumbnails.
- Games boot directly with melonDS's free BIOS (BSD, Gilead Kutnick) and a
  generated firmware image. No Nintendo BIOS or firmware is needed, read or
  bundled.
- Battery saves: melonDS reports every write of the cartridge's save memory;
  the bridge keeps Relay's live `<rom>.sav` equal to it and loads that file
  back into the cartridge at the next launch.
- Save states are melonDS's own savestates behind a 12-byte Relay header; a
  header mismatch is refused, never converted.

Upstream: https://github.com/melonDS-emu/melonDS
