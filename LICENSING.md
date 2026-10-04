# Licensing

Relay is open source. This file says exactly what that means for each part of
the repository, because "everything here is GPL" would not be true.

## Relay's own code: GPL-3.0-or-later

Every source file written for the Relay client by Maiko BOSSUYT — the Swift packages
under `Packages/`, the app shells under `Apps/`, the scripts under `Scripts/`,
`Resources/`, and public documentation — is licensed under the GNU
General Public License, version 3 or (at your option) any later version. The
full text is in `LICENSE` and in
`LICENSES/GPL-3.0-or-later.txt`. Each Relay-owned source file carries:

    SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
    SPDX-License-Identifier: GPL-3.0-or-later

`REUSE.toml` declares the terms of every directory that is not stamped
file-by-file.

## Third-party code keeps its own licence

Relay does not, and cannot, relicense code it did not write. Inherited and
vendored components remain under their original licences, with their notices
preserved:

- `Vendor/Provenance/` — the Provenance emulator project, BSD-3-Clause with a
  trademark clause (`Vendor/Provenance/LICENSE.md`); it in turn contains code
  from OpenEmu (BSD-3-Clause) and others. Relay links a small subset of it.
- `Vendor/Provenance/Cores/mGBA/Sources/libmGBA/` — mGBA, Mozilla Public
  License 2.0 (`LICENSE` in that directory), with its own third-party pieces
  (blip_buf LGPL-2.1-or-later, inih BSD-3-Clause, rcheevos MIT).
- Other emulator cores are vendored under `Vendor/` with their own licence
  files; each is listed with its exact revision in `Resources/CoreManifest.json`.
- Swift packages fetched at build time (GRDB, Defaults, Checksum, swift-log,
  swift-atomics, swift-crypto, swift-asn1) are MIT or Apache-2.0.

The authoritative list of everything **distributed inside the Relay app**, with
version, revision, licence and copyright, is generated from the manifests and
must not be edited by hand:

- `THIRD_PARTY_LICENSES.md` / `THIRD_PARTY_LICENSES.json` — human and
  machine-readable notices;
- `NOTICE` — the short attribution file;
- `SBOM.spdx.json` — the SPDX software bill of materials;
- `Resources/Licenses/licenses.json` — the canonical dataset the app shows under
  Settings ▸ About Relay ▸ Open Source & Licenses.

They come from `Scripts/relay-licenses.py`; a test fails when they drift.
Combining these components with Relay's GPL-3.0-or-later code is permitted by
their licences (MIT, BSD, Apache-2.0, MPL-2.0 via its Secondary Licence clause,
LGPL-2.1-or-later, GPL-2.0-or-later, GPL-3.0). Relay never includes code whose
licence forbids commercial use or derivative works, whatever the tier.

## Test fixtures

`Tests/Fixtures/` holds development-only test programs: Relay's own counters
are CC0-1.0 (public domain dedication); the 240p Test Suite is GPL-2.0-or-later.
Each directory has its README and LICENSE. None ships in a Release build.

## Brand assets: not code, not GPL

The Relay name, the Baton mark, the wordmark, the app icons and the files under
`Brand/` are brand assets owned by Maiko BOSSUYT. They are not licensed under the
GPL and are governed by `TRADEMARKS.md` and `Brand/LICENSE.md`. The GPL covers
the code that *draws* a mark; it does not grant the right to present a fork as
Relay.

## Contributing

By contributing to Relay you agree that your contribution is licensed under
GPL-3.0-or-later with copyright retained by you; see `CONTRIBUTING.md`. There
is no contributor licence agreement and no copyright assignment.
