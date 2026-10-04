# RelayBridge — Relay's C interface to Mesen 2

Everything in this directory and `../Package.swift` is written by Relay
(Maiko BOSSUYT, 2026) and licensed GPL-3.0-or-later, the same licence as the Mesen
2 tree around it (GPL-3.0, `../LICENSE`, Copyright (C) 2014-2025 Sour). No
upstream file is modified; `../RELAY_VENDOR.json` records the exact upstream
commit and the SHA-256 of the archive the tree was extracted from.

`include/MesenRelay.h` is the whole surface Relay's Swift adapter
(`Packages/RelayEmulation/Sources/RelayMesenAdapter`) sees. `src/MesenRelay.cpp`
implements it over Mesen's own extension points, the same three interfaces
Mesen's desktop frontend implements:

| Mesen interface | What the bridge does with it |
|---|---|
| `IRenderingDevice` | keeps a copy of the last decoded frame as RGBX8 for Relay's presenter |
| `IAudioDevice` | a bounded stereo ring buffer Relay's `CoreAudioOutput` drains on the audio thread |
| `IInputProvider` | sets the button bits Relay pressed on Mesen's standard controllers |
| `IBatteryProvider` | serves the console's main battery file from Relay's live `<rom>.sav`; Mesen's own file (`.srm` on Super NES) is mirrored back to it after every save |

Save states are Mesen's own serialised form (uncompressed, so Relay's rewind
deltas stay small) behind a 12-byte Relay header carrying Mesen's state format
version and the console type; a mismatch is refused, never converted.

Mesen runs the machine on its own thread with its own frame limiter from
`mesen_relay_load_rom` (held paused) until `mesen_relay_stop`. Every function
may be called from any thread. Mesen keeps some process-wide state
(`FolderUtilities`, `MessageManager`), so Relay runs one Mesen instance at a
time, which is also all the product ever needs.

Upstream: https://github.com/SourMesen/Mesen2
