#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build Relay's offline title catalog from pinned libretro-database DATs.

    python3 Scripts/relay-title-catalog.py               regenerate from the pinned sources
    python3 Scripts/relay-title-catalog.py --check       fail when the committed catalog drifts
    python3 Scripts/relay-title-catalog.py --update REV  pin another libretro-database revision

The catalog maps whole-file SHA-1 (first data track for PlayStation) and
PlayStation disc serials to No-Intro/Redump names. It is a lookup aid only:
Relay identity stays SHA-256. Sources are cached under build/title-catalog/
and verified against Resources/Metadata/RelayTitleCatalog.json. The data is
CC-BY-SA-4.0 (libretro-database LICENSE) and keeps that licence.
"""
from __future__ import annotations

import argparse, hashlib, json, re, sqlite3, sys, tempfile, urllib.parse, urllib.request
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROVENANCE = ROOT / "Resources" / "Metadata" / "RelayTitleCatalog.json"
OUTPUT = ROOT / "Packages" / "RelayTitleCatalog" / "Sources" / "RelayTitleCatalog" / "Resources" / "RelayTitles.sqlite"
CACHE = ROOT / "build" / "title-catalog"
REPOSITORY = "libretro/libretro-database"
SCHEMA = "1"
# Relay SystemID -> DAT path. This order fixes title ids; append, never reorder.
SOURCES = [
    ("gb", "metadat/no-intro/Nintendo - Game Boy.dat"),
    ("gbc", "metadat/no-intro/Nintendo - Game Boy Color.dat"),
    ("gba", "metadat/no-intro/Nintendo - Game Boy Advance.dat"),
    ("nes", "metadat/no-intro/Nintendo - Nintendo Entertainment System.dat"),
    ("snes", "metadat/no-intro/Nintendo - Super Nintendo Entertainment System.dat"),
    ("nds", "metadat/no-intro/Nintendo - Nintendo DS.dat"),
    ("sms", "metadat/no-intro/Sega - Master System - Mark III.dat"),
    ("gg", "metadat/no-intro/Sega - Game Gear.dat"),
    ("pce", "metadat/no-intro/NEC - PC Engine - TurboGrafx 16.dat"),
    ("ws", "metadat/no-intro/Bandai - WonderSwan.dat"),
    ("wsc", "metadat/no-intro/Bandai - WonderSwan Color.dat"),
    ("ps1", "metadat/redump/Sony - PlayStation.dat"),
]
SERIAL_SYSTEMS = {"ps1"}
QUOTED = r'"([^"]*)"'


@dataclass
class DatGame:
    name: str
    sha1s: list[str] = field(default_factory=list)
    serials: list[str] = field(default_factory=list)


def normalise_serial(token: str) -> str | None:
    """'SLUS-01297GH-3' -> 'SLUS-01297'; anything without 4 letters + 5 digits is dropped."""
    match = re.match(r"^([A-Z]{4})[-_ ]?(\d{3})\.?(\d{2})", token.strip().upper())
    return f"{match.group(1)}-{match.group(2)}{match.group(3)}" if match else None


def parse_dat(text: str) -> list[DatGame]:
    """Line-based clrmamepro parser. Names may contain parentheses; rom names are skipped before hashes are read."""
    games, current = [], None
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("game ("):
            current = DatGame(name="")
        elif current is None:
            continue
        elif line == ")":
            if current.name:
                games.append(current)
            current = None
        elif m := re.match(rf"^name {QUOTED}$", line):
            current.name = m.group(1)
        elif m := re.match(rf"^serial {QUOTED}$", line):
            for token in m.group(1).split(","):
                if (serial := normalise_serial(token)) and serial not in current.serials:
                    current.serials.append(serial)
        elif line.startswith("rom ( "):
            rest = re.sub(rf"^rom \( name {QUOTED}", "", line)
            if m := re.search(r"\bsha1 ([0-9A-Fa-f]{40})\b", rest):
                current.sha1s.append(m.group(1).lower())
    return games


def write_catalog(path: Path, systems: list[tuple[str, list[DatGame]]], revision: str) -> None:
    path.unlink(missing_ok=True)
    db = sqlite3.connect(path)
    db.executescript("""
        PRAGMA page_size = 4096;
        PRAGMA journal_mode = DELETE;
        CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE title(id INTEGER PRIMARY KEY, system TEXT NOT NULL, name TEXT NOT NULL, UNIQUE(system, name));
        CREATE TABLE rom(sha1 BLOB NOT NULL, title_id INTEGER NOT NULL, PRIMARY KEY(sha1, title_id)) WITHOUT ROWID;
        CREATE TABLE serial(serial TEXT NOT NULL, title_id INTEGER NOT NULL, PRIMARY KEY(serial, title_id)) WITHOUT ROWID;
    """)
    db.executemany("INSERT INTO meta VALUES (?, ?)", [("schema", SCHEMA), ("source_revision", revision)])
    next_id = 1
    for system, games in systems:
        merged: dict[str, DatGame] = {}
        for game in games:
            entry = merged.setdefault(game.name, DatGame(name=game.name))
            entry.sha1s += [s for s in game.sha1s if s not in entry.sha1s]
            entry.serials += [s for s in game.serials if s not in entry.serials]
        for name in sorted(merged):
            game = merged[name]
            db.execute("INSERT INTO title VALUES (?, ?, ?)", (next_id, system, name))
            db.executemany("INSERT INTO rom VALUES (?, ?)", [(bytes.fromhex(s), next_id) for s in sorted(game.sha1s)])
            if system in SERIAL_SYSTEMS:
                db.executemany("INSERT INTO serial VALUES (?, ?)", [(s, next_id) for s in sorted(game.serials)])
            next_id += 1
    db.commit()
    db.execute("VACUUM")
    db.close()


def content_sha256(path: Path) -> str:
    """Hash of the catalog's rows, independent of SQLite's file-format version."""
    db, digest = sqlite3.connect(path), hashlib.sha256()
    for table, order in (("meta", "key"), ("title", "id"), ("rom", "sha1, title_id"), ("serial", "serial, title_id")):
        for row in db.execute(f"SELECT * FROM {table} ORDER BY {order}"):
            digest.update(("\t".join(v.hex() if isinstance(v, bytes) else str(v) for v in row) + "\n").encode())
    db.close()
    return digest.hexdigest()


def counts(path: Path) -> dict:
    db = sqlite3.connect(path)
    result = {"titles": dict(db.execute("SELECT system, count(*) FROM title GROUP BY system ORDER BY system")),
              "roms": db.execute("SELECT count(*) FROM rom").fetchone()[0],
              "serials": db.execute("SELECT count(*) FROM serial").fetchone()[0]}
    db.close()
    return result


def fetch(revision: str, path: str, expected: str | None) -> bytes:
    cached = CACHE / revision / path
    if not cached.exists():
        url = f"https://raw.githubusercontent.com/{REPOSITORY}/{revision}/{urllib.parse.quote(path)}"
        cached.parent.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(url, timeout=60) as response:
            cached.write_bytes(response.read())
    data = cached.read_bytes()
    actual = hashlib.sha256(data).hexdigest()
    if expected and actual != expected:
        raise SystemExit(f"{path}: SHA-256 {actual} differs from the pinned {expected}")
    return data


def build(provenance: dict, output: Path, pin: bool) -> dict:
    revision, files, systems = provenance["source"]["revision"], [], []
    pinned = {f["path"]: f["sha256"] for f in provenance.get("files", [])}
    for system, path in SOURCES:
        data = fetch(revision, path, None if pin else pinned.get(path) or _missing(path))
        files.append({"system": system, "path": path, "sha256": hashlib.sha256(data).hexdigest()})
        systems.append((system, parse_dat(data.decode("utf-8"))))
    fetch(revision, "LICENSE", None if pin else provenance["source"]["licenseSHA256"])
    write_catalog(output, systems, revision)
    return {**provenance, "files": files,
            "output": {"path": str(OUTPUT.relative_to(ROOT)), "contentSHA256": content_sha256(output), **counts(output)}}


def _missing(path: str):
    raise SystemExit(f"{path}: no pinned SHA-256; run --update")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--update", metavar="REVISION")
    args = parser.parse_args(argv)
    provenance = json.loads(PROVENANCE.read_text())
    if args.update:
        provenance["source"]["revision"] = args.update
        provenance["source"]["licenseSHA256"] = hashlib.sha256(fetch(args.update, "LICENSE", None)).hexdigest()
    if args.check:
        with tempfile.TemporaryDirectory() as tmp:
            regenerated = build(provenance, Path(tmp) / "c.sqlite", pin=False)
        problems = []
        if regenerated["output"] != provenance["output"]:
            problems.append("regenerated catalog differs from the recorded output")
        if content_sha256(OUTPUT) != provenance["output"]["contentSHA256"]:
            problems.append(f"{OUTPUT.relative_to(ROOT)} differs from the recorded content hash")
        for p in problems:
            print(f"DRIFT: {p}", file=sys.stderr)
        print("OK: title catalog current" if not problems else "FAIL", file=sys.stderr if problems else sys.stdout)
        return 1 if problems else 0
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    updated = build(provenance, OUTPUT, pin=bool(args.update))
    PROVENANCE.write_text(json.dumps(updated, indent=2, ensure_ascii=False) + "\n")
    print(f"wrote {OUTPUT.relative_to(ROOT)} ({OUTPUT.stat().st_size} bytes) {updated['output']['contentSHA256']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
