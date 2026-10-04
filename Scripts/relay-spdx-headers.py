#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
# SPDX-License-Identifier: GPL-3.0-or-later
"""Adds or verifies SPDX headers on Relay-owned source files.

Relay-owned code is licensed GPL-3.0-or-later.
This script stamps every Relay-owned source file with the two REUSE lines and
never touches anything under Vendor/, Tests/Fixtures/ or Brand/, whose terms
are declared in REUSE.toml instead.

    python3 Scripts/relay-spdx-headers.py          # add missing headers
    python3 Scripts/relay-spdx-headers.py --check  # exit 1 if any file lacks one
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
HOLDER = "2026 Maiko BOSSUYT"
LICENSE = "GPL-3.0-or-later"

# Relay-owned directories and the comment syntax per extension.
OWNED_PREFIXES = ("Packages/", "Apps/", "Scripts/", "Resources/")
EXCLUDED_PREFIXES = ("Vendor/", "Tests/Fixtures/", "Brand/", "Apps/Relay.xcodeproj/")
COMMENT = {".swift": "//", ".py": "#", ".sh": "#", ".zsh": "#", ".ts": "//", ".mjs": "//", ".js": "//", ".css": "/*"}


def tracked_files():
    out = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        if line.startswith(OWNED_PREFIXES) and not line.startswith(EXCLUDED_PREFIXES):
            yield ROOT / line


def header_for(ext):
    c = COMMENT[ext]
    if c == "/*":
        return f"/* SPDX-FileCopyrightText: {HOLDER} */\n/* SPDX-License-Identifier: {LICENSE} */\n"
    return f"{c} SPDX-FileCopyrightText: {HOLDER}\n{c} SPDX-License-Identifier: {LICENSE}\n"


def main(argv):
    check = "--check" in argv
    missing, added = [], 0
    for path in tracked_files():
        if path.suffix not in COMMENT:
            continue
        text = path.read_text(errors="replace")
        if "SPDX-License-Identifier:" in text[:600]:
            continue
        missing.append(path)
        if check:
            continue
        header = header_for(path.suffix)
        if text.startswith("#!") or text.startswith("// swift-tools-version"):
            # A shebang or a SwiftPM tools-version line must stay first.
            first, rest = text.split("\n", 1)
            text = first + "\n" + header + rest
        else:
            text = header + text
        path.write_text(text)
        added += 1
    if check:
        for p in missing:
            print(f"missing SPDX header: {p.relative_to(ROOT)}")
        print(f"{len(missing)} file(s) without a header")
        return 1 if missing else 0
    print(f"added headers to {added} file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
