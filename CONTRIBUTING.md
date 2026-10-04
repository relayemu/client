# Contributing to Relay

Use the public issue tracker at https://github.com/relayemu/client for bugs and
feature requests. Send vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

Contributions retain your copyright and use GPL-3.0-or-later, without copyright
assignment. Add SPDX copyright and licence headers to new source files. Only
contribute material you have the right to distribute under the required terms.
Do not add games, firmware, advertising or tracking.

Keep changes focused and include a meaningful regression test for behavior
changes. English is the source language; French uses the informal “tu”. Follow
the existing native UI and String Catalogs. Preserve atomic saves, untrusted
import/cloud validation and the real-time emulation boundary.

Keep vendored changes minimal, retain upstream notices and pins, and document
integration changes beside the affected component. Run the relevant tests and
`python3 Scripts/relay-licenses.py --check`. [BUILDING.md](BUILDING.md) describes
the independent client build and test setup.
