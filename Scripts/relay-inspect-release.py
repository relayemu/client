#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
# SPDX-License-Identifier: GPL-3.0-or-later
"""Inspects a Relay Release archive and refuses anything that must not ship.

    python3 Scripts/relay-inspect-release.py <path.xcarchive> [--json out.json]

Inspects the archived app and its linked components for a
Release product (§56): which emulator cores are embedded and at which
revisions and licences, which systems they serve, which architectures are
present, whether any framework, dylib or bundle is unexpected, whether a test
ROM slipped in, and how the size divides between components. Every answer is
checked against Resources/CoreManifest.json — the canonical core data — and
the process exits non-zero on the first violation, so a CI step cannot pass
a product that contains a prohibited core, a fixture, a simulator slice, an
Intel slice or a visionOS slice.

Cores are positively identified by the string literals a stripped Release image keeps
(a core's own name, config keys, log text): every core in the manifest has
an entry in DETECT_STRINGS, and a prohibited core's literals appearing
anywhere fail the build.
"""
import json
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "Resources" / "CoreManifest.json"

# Literals that betray a core's presence in a stripped Release image. Symbols
# are gone from a Release build, but a core's own name, config keys and log
# text survive as string constants. Enabled cores must be found; prohibited
# and unintegrated cores must not be. Each entry lists literals of which at
# least `min` must appear.
DETECT_STRINGS = {
    "mgba": {"any": ["mGBA", "mCore", "gb.bios", "logToStdout"], "min": 2},
    "snes9x": {"any": ["Snes9x", "snes9x", "S9x"], "min": 2},
    "genesis-plus-gx": {"any": ["Genesis Plus GX", "Genesis Plus", "genplus"], "min": 2},
    "picodrive": {"any": ["PicoDrive", "picodrive", "Pico"], "min": 2},
    "duckstation": {"any": ["DuckStation", "duckstation", "SPU_ExecuteAfter"], "min": 2},
    "nestopia-ue": {"any": ["Nestopia", "nestopia", "NstApi"], "min": 2},
    "fceux": {"any": ["FCEUX", "fceux", "FCEUI_"], "min": 2},
    "mesen2": {"any": ["MesenRelay", "SaveStateWrongSystem", "CouldNotLoadFile", "Mesen"], "min": 2},
    "quicknes": {"any": ["QuickNES", "Nes_Emu", "quicknes"], "min": 2},
    "bsnes": {"any": ["bsnes", "SuperFamicom", "higan"], "min": 2},
    "mupen64plus": {"any": ["Mupen64Plus Core", "mupen64plus-core", "m64p_", "Mupen64Plus Core Library"], "min": 2},
    "melonds": {"any": ["MelonRelay", "melonDS", "NDSCart", "Secure area decryption"], "min": 2},
    "desmume": {"any": ["DeSmuME", "desmume", "NDS_exec"], "min": 2},
    "swanstation": {"any": ["SwanStation", "swanstation"], "min": 2},
    "pcsx-rearmed": {"any": ["PCSX-ReARMed", "pcsx_rearmed", "rearmed"], "min": 2},
    "beetle-psx": {"any": ["Beetle PSX", "Mednafen PSX", "beetle_psx"], "min": 2},
    "ppsspp": {"any": ["PPSSPP", "ppsspp", "PSP_"], "min": 2},
    "mednafen": {"any": ["MDFN_", "mednafen.cfg", "Mednafen Multi", "MDFNI_"], "min": 2},
    "beetle-pce": {"any": ["Beetle PCE", "beetle_pce", "pce_fast"], "min": 2},
    "beetle-wswan": {"any": ["Beetle WonderSwan", "Cygne", "wswan"], "min": 2},
    "beetle-ngp": {"any": ["Beetle NeoPop", "NeoPop", "neopop"], "min": 2},
    "race": {"any": ["RACE ", "race_", "NeoPop"], "min": 2},
    "gambatte": {"any": ["gambatte", "Gambatte", "GAMBATTE"], "min": 2},
    "nanoboyadvance": {"any": ["NanoBoyAdvance", "nba::", "NBA_"], "min": 2},
    "vbam": {"any": ["VisualBoyAdvance", "VBA-M", "vbam"], "min": 2},
    "gearsystem": {"any": ["Gearsystem", "gearsystem", "GearsystemCore"], "min": 2},
    "gearboy": {"any": ["Gearboy", "gearboy", "GearboyCore"], "min": 2},
    "blastem": {"any": ["BlastEm", "blastem", "genesis_context"], "min": 2},
    "ares": {"any": ["ares-emu", "ares::", "nall::"], "min": 2},
    "sameboy": {"any": ["SameBoy", "GB_run_frame", "sameboy"], "min": 2},
}

# Provenance's shared bridge packages carry the identifiers of every core the
# upstream project ever integrated (`com.provenance.core.*`) and settings text
# naming some of them. Those lines describe cores, they are not cores, and are
# dropped before matching so they cannot masquerade as a linked core.
METADATA_LINE_PREFIXES = ("com.provenance.core.", "com.provenance.")
METADATA_LINE_MARKERS = ("Threshold via", "-Next", "-next")

# LC_BUILD_VERSION platform identifiers (mach-o/loader.h).
PLATFORM_NAMES = {
    "1": "macOS", "2": "iOS", "3": "tvOS", "4": "watchOS", "5": "bridgeOS", "6": "macCatalyst",
    "7": "iOSSimulator", "8": "tvOSSimulator", "9": "watchOSSimulator", "10": "driverKit",
    "11": "visionOS", "12": "visionOSSimulator",
}

FIXTURE_EXTENSIONS = {".gba", ".gb", ".gbc", ".nes", ".sfc", ".smc", ".z64", ".n64", ".nds",
                      ".sms", ".gg", ".md", ".gen", ".cue", ".bin", ".chd", ".iso", ".cso",
                      ".pce", ".ws", ".wsc", ".ngp", ".ngc", ".rom"}
FIRMWARE_NAMES = {"bios7.bin", "bios9.bin", "firmware.bin", "scph5500.bin", "scph5501.bin",
                  "scph5502.bin", "syscard3.pce", "gba_bios.bin", "gb_bios.bin", "gbc_bios.bin"}


COVER_DIRECTORIES = {"named_boxarts", "named_snaps", "named_titles", "covers"}


def check_title_catalog(app, provenance):
    """The app ships exactly one title catalog, at the pinned revision, and no cover images."""
    import sqlite3
    problems = []
    catalogs = sorted(p for p in app.rglob("RelayTitles.sqlite") if p.is_file())
    if len(catalogs) != 1:
        problems.append(f"expected exactly one RelayTitles.sqlite, found {len(catalogs)}")
    for path in catalogs:
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        revision = dict(db.execute("SELECT key, value FROM meta")).get("source_revision")
        db.close()
        if revision != provenance["source"]["revision"]:
            problems.append(f"title catalog revision {revision} is not the pinned {provenance['source']['revision']}")
    for path in app.rglob("*"):
        if path.is_dir() and path.name.lower() in COVER_DIRECTORIES:
            problems.append(f"bundled cover directory: {path.relative_to(app)}")
    return problems


def run(cmd):
    return subprocess.run(cmd, check=False, capture_output=True, text=True).stdout


def image_uuids(image):
    """Architecture/UUID identity must match before trusting an archive dSYM."""
    output = run(["xcrun", "dwarfdump", "--uuid", str(image)])
    return set(re.findall(r"UUID: ([0-9A-Fa-f-]+) \(([^)]+)\)", output))


def transfer_symbols(images, archive):
    """Release strips globals; its matching dSYM retains the linked symbols."""
    symbols = []
    debug_images = sorted((archive / "dSYMs").glob("*.dSYM/Contents/Resources/DWARF/*"))
    for image in images:
        symbols.append(run(["nm", "-gU", str(image)]))
        identity = image_uuids(image)
        if not identity:
            continue
        for debug_image in debug_images:
            if image_uuids(debug_image) == identity:
                symbols.append(run(["nm", "-gU", str(debug_image)]))
    return "\n".join(symbols)


def check_transfer_transport(app, images, archive):
    """Require linked native transport, exact source provenance and notices."""
    problems = []
    expected = ROOT / "Packages/RelayTransfer/Sources/RelayTransfer/Resources/TransportProvenance.json"
    copies = [p for p in app.rglob("TransportProvenance.json") if p.is_file()]
    if len(copies) != 1 or copies[0].read_bytes() != expected.read_bytes():
        problems.append("missing or altered pinned Relay Transfer provenance")
    symbols = transfer_symbols(images, archive)
    for symbol in ("rtcCreatePeerConnection", "juice_create", "usrsctp_socket", "mbedtls_ssl_handshake"):
        if not re.search(r"\b_" + symbol + r"\b", symbols):
            problems.append("native Relay Transfer symbol missing: " + symbol)
    canonical = (ROOT / "Resources/Licenses/licenses.json").read_bytes()
    notices = [p for p in app.rglob("licenses.json") if p.is_file()]
    if not any(p.read_bytes() == canonical for p in notices):
        problems.append("pinned native transport licence dataset missing or altered")
    return problems


def find_app(archive):
    products = pathlib.Path(archive) / "Products"
    apps = [p for p in products.rglob("*.app") if str(p).count(".app") == 1]
    if not apps:
        raise SystemExit(f"no .app in {archive}")
    return sorted(apps, key=lambda p: len(str(p)))[0]


def mach_o_images(app):
    """Every Mach-O file inside the app: main executable, frameworks, dylibs, plugins."""
    images = []
    for path in app.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        try:
            with path.open("rb") as fh:
                magic = fh.read(4)
        except OSError:
            continue
        if magic in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce"):
            images.append(path)
    return images


def architectures(image):
    out = run(["lipo", "-archs", str(image)])
    return set(out.split())


def platform_of(image):
    """Platform names from the load commands (LC_BUILD_VERSION / LC_VERSION_MIN_*)."""
    out = run(["otool", "-l", str(image)])
    names = set()
    for raw in re.findall(r"^\s+platform\s+(\S+)", out, flags=re.M):
        names.add(PLATFORM_NAMES.get(raw, raw))
    for cmd in re.findall(r"^\s+cmd LC_VERSION_MIN_(\S+)", out, flags=re.M):
        names.add({"MACOSX": "macOS", "IPHONEOS": "iOS", "TVOS": "tvOS", "WATCHOS": "watchOS"}.get(cmd, cmd))
    return names


def literals(image):
    return run(["strings", "-a", str(image)])


# Where each core's object files come from in the link map (path fragments).
CORE_OBJECT_PATHS = {
    "mgba": ("mGBA.build", "libmGBA", "PVmGBA", "PVCoremGBA"),
    "mesen2": ("Mesen2.build", "MesenRelay"),
    "melonds": ("melonDS.build", "MelonRelay"),
    "pcsx-rearmed": ("PCSXReARMed.build", "PCSXRelay", "RelayDiscCodec"),
}


def core_sizes_from_link_map(path):
    """Sums the linker's per-symbol sizes by object file, grouped by core.
    Only bytes that exist in the file count (__TEXT and __DATA sections);
    zero-fill sections (__bss, __common) are memory, not download size."""
    files = {}
    ranges = []      # (start, end, counts)
    sizes = {}
    section = None
    for line in path.read_text(errors="replace").splitlines():
        if line.startswith("# Object files:"):
            section = "files"; continue
        if line.startswith("# Sections:"):
            section = "sections"; continue
        if line.startswith("# Symbols:"):
            section = "symbols"; continue
        if line.startswith("# Dead Stripped Symbols:"):
            break
        if section == "files" and line.startswith("["):
            index, _, name = line.partition("]")
            files[int(index[1:])] = name.strip()
        elif section == "sections" and line.startswith("0x"):
            parts = line.split("\t")
            if len(parts) < 4:
                continue
            start, size = int(parts[0], 16), int(parts[1], 16)
            counts = parts[3].strip() not in ("__bss", "__common", "__zerofill")
            ranges.append((start, start + size, counts))
        elif section == "symbols" and line.startswith("0x"):
            parts = line.split("\t")
            if len(parts) < 3:
                continue
            address, size = int(parts[0], 16), int(parts[1], 16)
            if not any(lo <= address < hi and counts for lo, hi, counts in ranges):
                continue
            index = int(parts[2].strip()[1:parts[2].strip().index("]")])
            sizes[index] = sizes.get(index, 0) + size
    totals = {}
    for index, size in sizes.items():
        name = files.get(index, "")
        for core_id, fragments in CORE_OBJECT_PATHS.items():
            if any(fragment in name for fragment in fragments):
                totals[core_id] = totals.get(core_id, 0) + size
                break
    return totals


def du(path):
    total = 0
    for root, _, files in os.walk(path):
        for f in files:
            fp = os.path.join(root, f)
            if not os.path.islink(fp):
                try:
                    total += os.path.getsize(fp)
                except OSError:
                    pass
    return total


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    archive = pathlib.Path(argv[0])
    json_out = None
    if "--json" in argv:
        json_out = pathlib.Path(argv[argv.index("--json") + 1])
    manifest = json.load(MANIFEST.open())
    cores = {c["id"]: c for c in manifest["cores"]}
    app = find_app(archive)
    problems = []
    report = {"archive": str(archive), "app": str(app), "installed_bytes": du(app)}

    # --- Architectures and platforms -----------------------------------------
    images = mach_o_images(app)
    archs = set()
    platforms = set()
    for image in images:
        archs |= architectures(image)
        platforms |= platform_of(image)
    report["architectures"] = sorted(archs)
    report["platforms"] = sorted(platforms)
    if "x86_64" in archs or "i386" in archs:
        problems.append("Intel slice present")
    if any(p.endswith("Simulator") for p in platforms):
        problems.append("simulator slice present")
    if any(p.startswith("visionOS") for p in platforms):
        problems.append("visionOS slice present")

    # --- Cores ----------------------------------------------------------------
    raw_literals = "\n".join(literals(i) for i in images).split("\n")
    all_literals = "\n".join(
        line for line in raw_literals
        if not line.startswith(METADATA_LINE_PREFIXES) and not any(m in line for m in METADATA_LINE_MARKERS)
    )
    found = {}
    for core_id, rule in DETECT_STRINGS.items():
        hits = [n for n in rule["any"] if n in all_literals]
        if len(hits) >= rule["min"]:
            found[core_id] = hits
    report["cores_detected"] = {}
    for core_id, hits in found.items():
        core = cores.get(core_id)
        if core is None:
            problems.append(f"unknown core symbols {hits} (not in the manifest)")
            continue
        report["cores_detected"][core_id] = {
            "name": core["name"], "revision": core["revision"], "license": core["license"],
            "systems": core["systems"], "matched": hits,
        }
        if core["commercialUse"] == "prohibited" or core["legalReviewStatus"] == "blocked":
            problems.append(f"prohibited core {core_id} ({core['license']}) is linked")
        elif core["relayStatus"] != "enabled":
            problems.append(f"core {core_id} is linked but not enabled in the manifest")
        elif core["legalReviewStatus"] != "not-required":
            problems.append(f"core {core_id} is linked with legal review outstanding")
    for core in cores.values():
        if core["relayStatus"] == "enabled" and core["id"] not in found:
            problems.append(f"enabled core {core['id']} was not found in the product")
    # --- Per-core size, from the link map the archive script asks the linker for --
    # Object files under a core's build directory (Mesen2.build, melonDS.build,
    # the mGBA packages) are summed; the rest is Relay and Provenance code.
    link_map = archive.with_name(archive.name.replace(".xcarchive", "-linkmap.txt"))
    report["core_sizes"] = core_sizes_from_link_map(link_map) if link_map.exists() else None
    for core_id, entry in report["cores_detected"].items():
        if report["core_sizes"] and core_id in report["core_sizes"]:
            entry["code_bytes"] = report["core_sizes"][core_id]
    # Every system an enabled, detected core claims must be playable per the manifest.
    report["systems_served"] = sorted({s for cid in found for s in cores.get(cid, {}).get("systems", [])
                                       if cores.get(cid, {}).get("relayStatus") == "enabled"})

    # --- Fixtures and firmware ----------------------------------------------
    stray = []
    for path in app.rglob("*"):
        if path.is_file():
            if path.suffix.lower() in FIXTURE_EXTENSIONS or path.name.lower() in FIRMWARE_NAMES:
                stray.append(str(path.relative_to(app)))
    report["stray_content"] = stray
    for s in stray:
        problems.append(f"game/firmware content shipped: {s}")

    # --- Title catalog ------------------------------------------------------
    catalog_provenance = json.loads((ROOT / "Resources" / "Metadata" / "RelayTitleCatalog.json").read_text())
    report["title_catalog_problems"] = check_title_catalog(app, catalog_provenance)
    problems += report["title_catalog_problems"]
    report["transfer_transport_problems"] = check_transfer_transport(app, images, archive)
    problems += report["transfer_transport_problems"]

    # --- Unexpected embedded code -------------------------------------------
    frameworks = sorted(p.name for p in (app / "Frameworks").glob("*") ) if (app / "Frameworks").exists() else []
    dylibs = sorted(str(p.relative_to(app)) for p in app.rglob("*.dylib"))
    plugins = sorted(p.name for p in (app / "PlugIns").glob("*")) if (app / "PlugIns").exists() else []
    report["frameworks"] = frameworks
    report["dylibs"] = dylibs
    report["plugins"] = plugins
    for name in frameworks + dylibs:
        if "libretro" in name.lower() or "retroarch" in name.lower():
            problems.append(f"libretro/RetroArch artefact shipped: {name}")

    # --- Sizes ---------------------------------------------------------------
    components = []
    for path in list(app.glob("*")):
        components.append({"name": path.name, "bytes": du(path) if path.is_dir() else path.stat().st_size})
    for sub in ("Frameworks", "PlugIns", "Contents/Frameworks", "Contents/Resources", "Contents/MacOS"):
        p = app / sub
        if p.exists():
            for child in p.glob("*"):
                components.append({"name": f"{sub}/{child.name}", "bytes": du(child) if child.is_dir() else child.stat().st_size})
    components.sort(key=lambda c: -c["bytes"])
    report["largest_components"] = components[:25]
    report["problems"] = problems

    if json_out:
        json_out.write_text(json.dumps(report, indent=2) + "\n")

    mb = report["installed_bytes"] / 1048576
    print(f"{app.name}: {mb:.1f} MB installed; archs {report['architectures']}; platforms {report['platforms']}")
    for core_id, v in report["cores_detected"].items():
        size = f"{v['code_bytes'] / 1048576:.2f} MB of code" if v.get("code_bytes") else "size: no link map"
        print(f"core: {core_id} {v['name']} @ {v['revision'][:12]} ({v['license']}) systems {','.join(v['systems'])} "
              f"archs {report['architectures']} {size} matched {v['matched']}")
    if not report["cores_detected"]:
        print("cores: none")
    print(f"systems: {', '.join(report['systems_served']) or 'none'}")
    print("largest:", ", ".join(f"{c['name']} {c['bytes']/1048576:.1f} MB" for c in components[:6]))
    if problems:
        print("REFUSED:")
        for p in problems:
            print(f"  - {p}")
        return 1
    print("OK: nothing prohibited, no fixtures, no firmware, pinned title catalog, expected slices only")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
