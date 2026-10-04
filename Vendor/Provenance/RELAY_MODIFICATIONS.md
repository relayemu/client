# Relay integration changes

Provenance upstream: https://github.com/Provenance-Emu/Provenance, revision
`0f5dae7805385ea632b277cd2723a6c89f69d517`. The mGBA fork is pinned to
`2abe0f4993b65030e33e0a3b5b6ca1c1e9247f01`. Original copyright and licence
texts remain in this directory and in `Resources/Licenses/texts`.

Relay adds native Apple package/bridge integration, macOS compile guards,
Game Boy/Game Boy Color build sources, in-memory save and battery access,
native-memory/frame callbacks for achievements, and bounded audio resampling.
Unused plugins and the unplayed Drums audio example are excluded.

The complete modified source is included in this repository. The enabled core
trees and upstream pins are under `Vendor/`; the mGBA integration diff is
[`Cores/mGBA/RELAY_MODIFICATIONS.diff`](Cores/mGBA/RELAY_MODIFICATIONS.diff).
