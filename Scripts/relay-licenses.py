#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generates every licence artefact Relay publishes, from the manifests.

Inputs (never edited by this script):
    Resources/CoreManifest.json          emulator cores (enabled ones ship)
    Resources/Components.json            everything else that ships, curated
    Apps/Relay.xcodeproj/…/Package.resolved   exact versions of Swift packages
    Apps/project.yml                     Relay's marketing version
    Resources/Licenses/texts/*, LICENSES/*    licence texts at pinned revisions

Outputs (generated; a test fails when they drift):
    Resources/Licenses/licenses.json     the canonical shipped-components dataset
    Packages/RelayUI/Sources/RelayUI/licenses.json   the app's bundled copy
    THIRD_PARTY_LICENSES.md / .json      human and machine notices
    NOTICE                               short attribution file
    SBOM.spdx.json                       SPDX 2.3 software bill of materials

    python3 Scripts/relay-licenses.py          # regenerate
    python3 Scripts/relay-licenses.py --check  # exit 1 when any output is stale
"""
import hashlib
import json
import pathlib
import re
import sys
import uuid

ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "Resources" / "CoreManifest.json"
COMPONENTS = ROOT / "Resources" / "Components.json"
RESOLVED = ROOT / "Apps" / "Relay.xcodeproj" / "project.xcworkspace" / "xcshareddata" / "swiftpm" / "Package.resolved"
PROJECT_YML = ROOT / "Apps" / "project.yml"

OUT_DATASET = ROOT / "Resources" / "Licenses" / "licenses.json"
OUT_APP = ROOT / "Packages" / "RelayUI" / "Sources" / "RelayUI" / "licenses.json"
OUT_MD = ROOT / "THIRD_PARTY_LICENSES.md"
OUT_JSON = ROOT / "THIRD_PARTY_LICENSES.json"
OUT_NOTICE = ROOT / "NOTICE"
OUT_SBOM = ROOT / "SBOM.spdx.json"

CATEGORIES = [
    ("cores", "Emulator cores"),
    ("relay", "Relay"),
    ("libraries", "Third-party libraries"),
    ("media", "Media and emulation plumbing"),
    ("data", "Game catalog"),
]

LICENSE_NAMES = {
    "GPL-3.0-or-later": "GNU General Public License v3.0 or later",
    "GPL-3.0-only": "GNU General Public License v3.0",
    "GPL-2.0-or-later": "GNU General Public License v2.0 or later",
    "LGPL-2.1-or-later": "GNU Lesser General Public License v2.1 or later",
    "MPL-2.0": "Mozilla Public License 2.0",
    "CC-BY-SA-4.0": "Creative Commons Attribution-ShareAlike 4.0 International",
    "MIT": "MIT License",
    "MIT-0": "MIT No Attribution",
    "Apache-2.0": "Apache License 2.0",
    "BSD-3-Clause": "BSD 3-Clause License",
    "BSD-2-Clause": "BSD 2-Clause License",
    "ISC": "ISC License",
    "CC0-1.0": "CC0 1.0 Universal",
    "Zlib": "zlib License",
}


def read(path):
    return (ROOT / path).read_text() if path else None


def relay_version():
    m = re.search(r'MARKETING_VERSION:\s*"([^"]+)"', PROJECT_YML.read_text())
    return m.group(1) if m else "0.0.0"


def resolved_pins():
    pins = {}
    for pin in json.load(RESOLVED.open())["pins"]:
        state = pin["state"]
        pins[pin["identity"]] = {"version": state.get("version") or state.get("branch"),
                                 "revision": state.get("revision"), "location": pin["location"]}
    return pins


def build_dataset():
    manifest = json.load(MANIFEST.open())
    components = json.load(COMPONENTS.open())["components"]
    pins = resolved_pins()
    version = relay_version()
    entries = []

    for core in manifest["cores"]:
        if core["relayStatus"] != "enabled":
            continue
        entries.append({
            "id": core["id"], "category": "cores", "name": core["name"],
            "version": core["version"], "revision": core["revision"],
            "license": core["license"], "licenseName": LICENSE_NAMES.get(core["license"], core["license"]),
            "licenseNote": core.get("licenseNote"),
            "copyright": core.get("copyright", ""), "upstream": core["upstream"],
            "upstreamBase": core.get("upstreamBase"),
            "description": "Emulator core for " + ", ".join(core["systems"]) + ".",
            "systems": core["systems"],
            "modifications": core.get("modificationsNote"),
            "sourceLocation": core["build"].get("path"),
            "licenseText": read(core.get("licenseText")) or "",
            "noticeText": None,
            "shipped": True,
        })

    for comp in components:
        v = comp["version"]
        if v["kind"] == "spm":
            pin = pins.get(v["identity"])
            if pin is None:
                raise SystemExit(f"{comp['id']}: identity {v['identity']} not in Package.resolved")
            version_str, revision = pin["version"], pin["revision"]
        elif v["kind"] == "relay-marketing-version":
            version_str, revision = version, None
        else:
            version_str, revision = v["value"], v.get("revision")
        entries.append({
            "id": comp["id"], "category": comp["category"], "name": comp["name"],
            "version": version_str, "revision": revision,
            "license": comp["license"], "licenseName": LICENSE_NAMES.get(comp["license"], comp["license"]),
            "licenseNote": comp.get("licenseNote"),
            "copyright": comp["copyright"], "upstream": comp["upstream"], "upstreamBase": None,
            "description": comp["description"], "systems": None,
            "modifications": comp.get("modifications"), "sourceLocation": comp.get("sourceLocation"),
            "licenseText": read(comp.get("licenseText")) or "",
            "noticeText": read(comp.get("noticeText")),
            "shipped": comp["shipped"],
        })

    shipped = [e for e in entries if e["shipped"]]
    categories = []
    for cid, title in CATEGORIES:
        items = sorted([e for e in shipped if e["category"] == cid], key=lambda e: e["name"].lower())
        if items:
            categories.append({"id": cid, "title": title, "components": items})
    return {
        "schemaVersion": 1,
        "generatedFrom": ["Resources/CoreManifest.json", "Resources/Components.json", "Package.resolved"],
        "relayVersion": version,
        "sourceRepository": "https://github.com/relayemu/client",
        "relayLicense": "GPL-3.0-or-later",
        "categories": categories,
        "buildTools": [e for e in entries if not e["shipped"]],
    }


def render_md(ds):
    lines = ["# Third-party licences", "",
             "Generated by `Scripts/relay-licenses.py` from `Resources/CoreManifest.json`,",
             "`Resources/Components.json` and the resolved Swift package graph. Do not edit by hand.", "",
             f"Every component below is distributed inside the Relay client (Relay {ds['relayVersion']}).",
             "Relay's own code is GPL-3.0-or-later; see `LICENSING.md`. Build-only tooling is listed at the end",
             "and is not distributed.", ""]
    for cat in ds["categories"]:
        lines += [f"## {cat['title']}", ""]
        for c in cat["components"]:
            lines += [f"### {c['name']}", "",
                      f"- Version: {c['version']}" + (f" (`{c['revision']}`)" if c.get("revision") else ""),
                      f"- Licence: {c['license']}" + (f" — {c['licenseNote']}" if c.get("licenseNote") else ""),
                      f"- Copyright: {c['copyright']}",
                      f"- Upstream: {c['upstream']}"]
            if c.get("upstreamBase"): lines.append(f"- Based on: {c['upstreamBase']}")
            if c.get("systems"): lines.append(f"- Systems: {', '.join(c['systems'])}")
            if c.get("modifications"): lines.append(f"- Relay modifications: {c['modifications']}")
            if c.get("sourceLocation"): lines.append(f"- Source in this repository: `{c['sourceLocation']}`")
            lines += ["", f"- {c['description']}", ""]
            if c["licenseText"]:
                lines += ["<details><summary>Licence text</summary>", "", "```text"]
                lines += c["licenseText"].rstrip("\n").split("\n")
                lines += ["```", ""]
                if c.get("noticeText"):
                    lines += ["```text"] + c["noticeText"].rstrip("\n").split("\n") + ["```", ""]
                lines += ["</details>", ""]
    if ds["buildTools"]:
        lines += ["## Build-time tooling (not distributed)", ""]
        for c in ds["buildTools"]:
            lines.append(f"- {c['name']} {c['version']} — {c['license']} — {c['upstream']}")
        lines.append("")
    return "\n".join(lines) + "\n"


def render_json(ds):
    comps = []
    for cat in ds["categories"]:
        for c in cat["components"]:
            comps.append({"name": c["name"], "id": c["id"], "category": cat["id"], "version": c["version"],
                          "commit": c.get("revision"), "upstream": c["upstream"], "license": c["license"],
                          "copyright": c["copyright"], "modifications": c.get("modifications"),
                          "source_offer_required": c["license"] in ("GPL-3.0-or-later", "GPL-3.0-only", "GPL-2.0-or-later", "LGPL-2.1-or-later", "MPL-2.0"),
                          "systems": c.get("systems")})
    return json.dumps({"generatedFrom": ds["generatedFrom"], "relayVersion": ds["relayVersion"], "components": comps}, indent=2) + "\n"


def render_notice(ds):
    lines = [f"Relay {ds['relayVersion']}", "Copyright © 2026 Maiko BOSSUYT", "",
             "Relay is free software: you can redistribute it and/or modify it under the terms of the",
             "GNU General Public License as published by the Free Software Foundation, either version 3",
             "of the License, or (at your option) any later version. See LICENSE.", "",
             "The Relay name, the Baton mark and the app icons are brand assets of Maiko BOSSUYT and are",
             "not covered by the GPL; see TRADEMARKS.md.", "",
             "Relay includes the following third-party software, each under its own licence",
             "(full texts in THIRD_PARTY_LICENSES.md):", ""]
    for cat in ds["categories"]:
        for c in cat["components"]:
            if c["id"] == "relay-client": continue
            lines.append(f"  {c['name']} {c['version']} — {c['license']} — {c['copyright']}")
    lines += ["", "Generated by Scripts/relay-licenses.py; do not edit."]
    return "\n".join(lines) + "\n"


def render_sbom(ds):
    def spdx_id(s): return "SPDXRef-" + re.sub(r"[^A-Za-z0-9.-]", "-", s)
    ns_seed = json.dumps([[c["id"], c["version"], c.get("revision")] for cat in ds["categories"] for c in cat["components"]], sort_keys=True)
    packages, relationships, extracted = [], [], {}
    root_id = spdx_id("relay-client")
    for cat in ds["categories"]:
        for c in cat["components"]:
            pid = spdx_id(c["id"])
            lic = c["license"] if c["license"] in LICENSE_NAMES else "LicenseRef-" + re.sub(r"[^A-Za-z0-9.-]", "-", c["license"])
            if lic.startswith("LicenseRef-") and lic not in extracted:
                extracted[lic] = {"licenseId": lic, "name": c.get("licenseName", c["license"]),
                                  "extractedText": c.get("licenseText") or "NOASSERTION"}
            packages.append({
                "SPDXID": pid, "name": c["name"], "versionInfo": c["version"],
                "downloadLocation": c["upstream"] if c["upstream"].startswith("http") else "NOASSERTION",
                "filesAnalyzed": False,
                "licenseConcluded": lic, "licenseDeclared": lic,
                "copyrightText": c["copyright"] or "NOASSERTION",
                "supplier": "NOASSERTION",
                "comment": (f"revision {c['revision']}; " if c.get("revision") else "") + c["description"],
            })
            if pid != root_id:
                relationships.append({"spdxElementId": root_id, "relatedSpdxElement": pid, "relationshipType": "CONTAINS"})
    doc = {
        "spdxVersion": "SPDX-2.3", "dataLicense": "CC0-1.0", "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"Relay-{ds['relayVersion']}",
        "documentNamespace": "https://github.com/relayemu/client/sbom/" + str(uuid.uuid5(uuid.NAMESPACE_URL, ns_seed)),
        "creationInfo": {"created": "2026-01-01T00:00:00Z", "creators": ["Tool: relay-licenses.py"],
                         "comment": "Deterministic: the timestamp is fixed so the file only changes when the components do."},
        "packages": packages,
        "hasExtractedLicensingInfos": list(extracted.values()),
        "relationships": [{"spdxElementId": "SPDXRef-DOCUMENT", "relatedSpdxElement": root_id, "relationshipType": "DESCRIBES"}] + relationships,
    }
    return json.dumps(doc, indent=2) + "\n"


def main(argv):
    ds = build_dataset()
    dataset_text = json.dumps(ds, indent=2, ensure_ascii=False) + "\n"
    outputs = {OUT_DATASET: dataset_text, OUT_APP: dataset_text,
               OUT_MD: render_md(ds), OUT_JSON: render_json(ds), OUT_NOTICE: render_notice(ds), OUT_SBOM: render_sbom(ds)}
    if "--check" in argv:
        stale = [p for p, t in outputs.items() if not p.exists() or p.read_text() != t]
        for p in stale: print(f"stale: {p.relative_to(ROOT)}", file=sys.stderr)
        print("licence artefacts current" if not stale else f"{len(stale)} stale artefact(s)")
        return 1 if stale else 0
    for p, t in outputs.items():
        p.parent.mkdir(parents=True, exist_ok=True); p.write_text(t); print("wrote", p.relative_to(ROOT))
    shipped = sum(len(c["components"]) for c in ds["categories"])
    print(f"{shipped} shipped components, {len(ds['buildTools'])} build tools; dataset {len(dataset_text)//1024} KiB")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
