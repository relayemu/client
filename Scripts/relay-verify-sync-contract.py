#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
# SPDX-License-Identifier: GPL-3.0-or-later
"""Verify the pinned public Relay Sync contract without private dependencies."""

import argparse
import copy
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import struct
import tempfile
import uuid


ROOT = Path(__file__).resolve().parent.parent
CONTRACTS = {'1.0.1': {'schema': 1,
           'openapi_version': '1.0.0',
           'source_commit': '34643ca0a079e2133c6023635afb3feee9795add',
           'source_manifest': 'b9fad721037815597a6e3ebf6dd0d72b7928f234218896a3406ab7b59c9ed078',
           'snapshot_manifest': '91d3fde7c95213d927c3ea96ce8e4837e28e67c8fd22b794b946d5dc9d471c04'},
 '1.1.1': {'schema': 2,
           'openapi_version': '1.1.0',
           'source_commit': '2a6876a70bd281c3601538df9e6e66202af7c3b7',
           'source_manifest': '06e9357bfb24c5b62ef75d71ec4dabbefdb9f01f58ecbbe417dc8d815d0d2ac7',
           'snapshot_manifest': '5c66194aa192ca17c82624039d332672b0bb5ec90284454f0da7fb58c44a57d7'},
 '1.2.0': {'schema': 3,
           'schemas': [2, 3],
           'vector_schema': 2,
           'openapi_version': '1.2.0',
           'source_commit': 'fecc7e889dc5bbf90474bb3a7ca48aec78a0aef3',
           'source_manifest': 'e45f7d86b4b678c77fb62708f14fe4d0a269e9f4cdabb92c2ab8d7387badd1d1',
           'snapshot_manifest': 'eadd9d44ef0a400a716fedc403143391233cf237ec2ce9d212319a01da8e8e18'},
 '1.3.0': {'schema': 3,
           'schemas': [2, 3],
           'vector_schema': 2,
           'openapi_version': '1.3.0',
           'source_commit': 'ddf9770caac1b53ed73c5d4c8259378e2e0654dd',
           'source_manifest': 'efabe390dbc3ff90a057fc37e6da1c100b65cf4963fd152badd7586e0c83a818',
           'snapshot_manifest': 'cf8fe3e092aec837bdac9fcb2c46602d1c92674cb83399c7d39f8877e922c527'}}
MAX_ARTWORK_BYTES = 1048576
RETAINED_MANIFESTS = {'1.0.1': '53cff71cc9e1691842d4446fd6c98b73d58eb26ce9f32de8f643f8a511528420', '1.1.1': '063f3541d06a535336619d59c43a3bcbd29107e3b3ac7e59a026ff1f9dc9f256', '1.2.0': 'eeff61e1f0a381df53f664b8c0da3cc5caa6738f5bfc88d9b986242285a5b6ac', '1.3.0': '74386ae97bbac1c2f1f5c36bdcc2090a462a865a5966d74a80cccb5a7ce57ddb'}
TRANSFORMED = {"openapi.yaml", "VERSION.json", "testdata/semantic-schema-2.json"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def manifest_entries(data):
    entries = {}
    for line in data.decode("utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        require(match is not None, "Malformed checksum entry")
        checksum, name = match.groups()
        path = PurePosixPath(name)
        require(not path.is_absolute() and str(path) == name and
                all(part not in (".", "..") for part in name.split("/")) and
                "\\" not in name, "Unsafe checksum path")
        require(name not in entries, "Duplicate checksum entry")
        entries[name] = checksum
    require(entries, "Empty checksum manifest")
    return entries


def load_json(root, name):
    return json.loads((root / name).read_text())


def canonical_uuid(value):
    require(isinstance(value, str) and str(uuid.UUID(value)) == value,
            "Noncanonical wire UUID")


def fingerprint(value):
    require(isinstance(value, str) and
            re.fullmatch(r"sha256:[0-9a-f]{64}", value),
            "Noncanonical content fingerprint")


def validate_vectors(root, schema):
    proof = load_json(root, "testdata/proof-of-possession-v1.json")
    require(proof["algorithm"] == "relay-pop-v1" and
            proof["vectorKind"] == "encoding-only" and
            proof["localDataPattern"] == "UTF-8 relay repeated 20000 times",
            "Unknown proof fixture framing")
    data = b"relay" * 20000
    nonce = bytes.fromhex(proof["nonceHex"])
    require(len(nonce) == 32, "Invalid proof nonce")
    hasher = hashlib.sha256(b"relay-pop-v1\0" + nonce)
    previous_end = 0
    for item in proof["ranges"]:
        offset, length = item["offset"], item["length"]
        require(type(offset) is int and type(length) is int and
                offset >= previous_end and length > 0 and
                offset + length <= len(data), "Invalid proof range")
        hasher.update(struct.pack(">QQ", offset, length))
        hasher.update(data[offset:offset + length])
        previous_end = offset + length
    require(hasher.hexdigest() == proof["expectedDigestHex"],
            "Proof-of-possession digest mismatch")

    game = load_json(root, "testdata/push-game.json")
    divergence = load_json(root, "testdata/push-battery-divergence.json")
    prerequisite = divergence["prerequisites"]
    fingerprint(prerequisite["gameFingerprint"])
    canonical_uuid(prerequisite["parentRevisionID"])
    requests = [game] + [push["request"] for push in divergence["pushes"]]
    operation_ids, revision_ids, installations = set(), set(), set()
    require(len(divergence["pushes"]) == 2, "Expected two divergent writers")
    for request in requests:
        require(set(request) == {"operations"} and
                1 <= len(request["operations"]) <= 100,
                "Invalid deterministic push envelope")
        for operation in request["operations"]:
            require(set(operation) == {"operationId", "schema", "kind", "action", "object"},
                    "Unexpected operation fields")
            canonical_uuid(operation["operationId"])
            require(operation["operationId"] not in operation_ids,
                    "Reused operation UUID")
            operation_ids.add(operation["operationId"])
            require(type(operation["schema"]) is int and operation["schema"] == schema and
                    operation["action"] == "upsert" and
                    operation["kind"] in ("game", "battery_revision"),
                    "Unsupported vector schema/kind/action")
            obj = operation["object"]
            if schema == 2:
                require(type(obj.get("generation")) is int and obj["generation"] == 0,
                        "Initial divergence vector requires explicit generation zero")
            fingerprint(obj["fingerprint"])
            require(obj["fingerprint"] == prerequisite["gameFingerprint"],
                    "Divergence changed game identity")
            if operation["kind"] == "game":
                require(type(obj["addedAt"]) is int and type(obj["updatedAt"]) is int and
                        946684800000 <= obj["addedAt"] <= obj["updatedAt"],
                        "Invalid game wire timestamps")
    for push in divergence["pushes"]:
        canonical_uuid(push["authenticatedInstallationID"])
        obj = push["request"]["operations"][0]["object"]
        canonical_uuid(obj["revisionID"])
        require(obj["revisionID"] not in revision_ids and
                obj["revisionID"] != prerequisite["parentRevisionID"],
                "Divergent heads collapsed or self-parented")
        revision_ids.add(obj["revisionID"])
        require(obj["parentIDs"] == [prerequisite["parentRevisionID"]],
                "Divergent heads must share parent A")
        require(obj["installationID"] == push["authenticatedInstallationID"],
                "Battery writer differs from authenticated installation")
        installations.add(obj["installationID"])
        fingerprint(obj["dataFingerprint"])
        require(obj["dataFingerprint"] in prerequisite["ownedPayloadReferences"] and
                type(obj["dataSize"]) is int and obj["dataSize"] > 0,
                "Missing verified payload prerequisite")
        require(type(obj["createdAt"]) is int and obj["createdAt"] >= 946684800000,
                "Invalid battery wire timestamp")
    require(len(installations) == 2 and len(revision_ids) == 2,
            "Expected two separate installations and heads")
    if schema == 2:
        require(prerequisite["generation"] == 0,
                "Divergence prerequisites changed membership")
        validate_semantic_vectors(root)


def validate_semantic_vectors(root):
    """Check portable examples and postconditions, without implementing a server."""
    vector = load_json(root, "testdata/semantic-schema-2.json")
    require(vector["schema"] == 2 and type(vector["nowMs"]) is int and
            vector["requestHeaders"] == {"X-Relay-Sync-Schema": "2"},
            "Invalid semantic vector negotiation")
    expected_statuses = {
        "foreign-source-provenance": ["applied", "applied"],
        "classification-is-immutable": ["applied", "rejected"],
        "auto-retention-permanent-uuid-suppression": ["applied", "applied", "ignored"],
        "quick-retention-permanent-uuid-suppression": ["applied", "applied", "ignored"],
        "reimport-keeps-old-work-retired":
            ["applied", "applied", "applied", "ignored", "applied", "ignored"],
        "same-barrier-reimport-alpha-first": ["applied"] * 4,
        "same-barrier-reimport-zulu-first": ["applied", "applied", "applied", "duplicate"],
    }
    cases = {case["name"]: case for case in vector["cases"]}
    require(len(vector["cases"]) == len(cases) == 7 and
            set(cases) == set(expected_statuses), "Missing or duplicate semantic scenario")
    required_fields = {
        "game": {"fingerprint", "generation", "systemID", "title", "isFavorite", "addedAt", "updatedAt"},
        "play_session": {"sessionID", "fingerprint", "generation", "installationID",
                         "deviceKind", "coreID", "startedAt", "pausedMs"},
        "save_state": {"stateID", "fingerprint", "generation", "stateKind", "coreID",
                       "coreVersion", "stateCompatibilityVersion", "formatVersion",
                       "createdAt", "payloadFingerprint", "payloadSize", "installationID", "deviceKind"},
        "tombstone": {"targetKind", "targetKey", "fingerprint", "generation", "deletedAt", "installationID"},
    }
    operation_ids = set()
    for name, case in cases.items():
        canonical_uuid(case["authenticatedInstallationID"])
        require(case["expectedStatuses"] == expected_statuses[name] and
                len(case["operations"]) == len(case["expectedStatuses"]),
                "Semantic scenario result contract changed")
        memberships = set()
        for operation in case["operations"]:
            require(set(operation) == {"operationId", "schema", "kind", "action", "object"},
                    "Unexpected semantic operation fields")
            canonical_uuid(operation["operationId"])
            require(operation["operationId"] not in operation_ids,
                    "Reused semantic operation UUID")
            operation_ids.add(operation["operationId"])
            require(type(operation["schema"]) is int and operation["schema"] == 2 and
                    operation["action"] == "upsert" and operation["kind"] in required_fields,
                    "Invalid semantic operation schema/kind/action")
            obj = operation["object"]
            require(required_fields[operation["kind"]] <= set(obj),
                    "Missing semantic object field")
            require(type(obj["generation"]) is int and 0 <= obj["generation"] <= 2147483647,
                    "Invalid or implicit semantic generation")
            fingerprint(obj["fingerprint"])
            memberships.add(obj["fingerprint"])
            for field in ("installationID", "sessionID", "stateID"):
                if field in obj:
                    canonical_uuid(obj[field])
            for field in ("addedAt", "updatedAt", "startedAt", "endedAt", "createdAt", "deletedAt"):
                if field in obj:
                    require(type(obj[field]) is int and
                            946684800000 <= obj[field] <= vector["nowMs"] + 300000,
                            "Invalid semantic fixture timestamp")
            if operation["kind"] == "game":
                require(obj["addedAt"] <= obj["updatedAt"] and
                        type(obj["isFavorite"]) is bool and
                        re.fullmatch(r"[a-z0-9-]{1,32}", obj["systemID"]) and
                        isinstance(obj["title"], str) and 0 < len(obj["title"]) <= 200,
                        "Invalid semantic game fields")
            elif operation["kind"] == "save_state":
                fingerprint(obj["payloadFingerprint"])
                require(obj["stateKind"] in ("auto", "quick", "manual") and
                        type(obj["payloadSize"]) is int and 0 < obj["payloadSize"] <= 268435456,
                        "Invalid semantic state fields")
            elif operation["kind"] == "play_session":
                require(type(obj["pausedMs"]) is int and obj["pausedMs"] >= 0 and
                        obj.get("endedAt", obj["startedAt"]) >= obj["startedAt"],
                        "Invalid semantic session fields")
            elif obj["targetKind"] == "game":
                require(obj["targetKey"] == obj["fingerprint"],
                        "Game tombstone changed fingerprint")
            else:
                require(obj["targetKind"] == "state", "Unknown tombstone target")
                canonical_uuid(obj["targetKey"])
        require(len(memberships) == 1, "Semantic scenario changes game fingerprint")

    case = cases["foreign-source-provenance"]
    source = case["operations"][1]["object"]
    require(source["installationID"] != case["authenticatedInstallationID"] and
            case["expected"]["sourceInstallationID"] == source["installationID"] and
            case["expected"]["submittingInstallationID"] == case["authenticatedInstallationID"] and
            case["expected"]["sessionID"] == source["sessionID"] and
            case["expected"]["activeGeneration"] == source["generation"] == 0,
            "Foreign source provenance was collapsed into submission authority")

    case = cases["classification-is-immutable"]
    original, conflicting = [operation["object"] for operation in case["operations"]]
    require(original["generation"] == conflicting["generation"] == 0 and
            original["systemID"] != conflicting["systemID"] and
            original["updatedAt"] < conflicting["updatedAt"] and
            original["title"] != conflicting["title"] and
            case["expected"]["canonicalSystemID"] == original["systemID"] and
            case["expected"]["title"] == original["title"],
            "Classification rejection no longer protects established metadata")

    for kind in ("auto", "quick"):
        case = cases[f"{kind}-retention-permanent-uuid-suppression"]
        _, tombstone, replay = [operation["object"] for operation in case["operations"]]
        require(tombstone["targetKind"] == "state" and replay["stateKind"] == kind and
                replay["stateID"] == tombstone["targetKey"] == case["expected"]["stateID"] and
                replay["createdAt"] > tombstone["deletedAt"] and
                replay["generation"] == tombstone["generation"] == 0 and
                case["expected"]["stateAbsent"] is True,
                "Permanent state suppression fixture lost its later-timestamp replay")

    case = cases["reimport-keeps-old-work-retired"]
    initial, retired, reimport, stale, current, stale_delete = [
        operation["object"] for operation in case["operations"]]
    require(initial["generation"] == retired["generation"] == stale["generation"] ==
            stale_delete["generation"] == case["expected"]["retiredThrough"] == 0 and
            reimport["generation"] == current["generation"] == case["expected"]["activeGeneration"] == 1 and
            reimport["addedAt"] <= retired["deletedAt"] and
            stale["startedAt"] > retired["deletedAt"] and
            current["startedAt"] < retired["deletedAt"] and
            stale_delete["deletedAt"] > retired["deletedAt"] and
            case["expected"]["absentSessionIDs"] == [stale["sessionID"]] and
            case["expected"]["presentSessionIDs"] == [current["sessionID"]],
            "Retirement/reimport fixture now depends on timestamps or relabels old work")

    for first in ("alpha", "zulu"):
        case = cases[f"same-barrier-reimport-{first}-first"]
        initial, retired, left, right = [operation["object"] for operation in case["operations"]]
        require(initial["generation"] == retired["generation"] == 0 and
                left["generation"] == right["generation"] == retired["generation"] + 1 and
                left["updatedAt"] == right["updatedAt"] and
                left["addedAt"] == right["addedAt"] and
                left["title"].lower() == first and {left["title"], right["title"]} == {"Alpha", "Zulu"} and
                case["concurrentGroups"] == [[2, 3]] and
                case["expected"] == {"activeGeneration": 1, "retiredThrough": 0,
                                     "title": "Zulu", "canonicalSystemID": "gba"},
                "Same-barrier reimport permutation lost its common successor or convergence")


ARTWORK_CASES = {
    "later-cover-wins": ["applied", "applied", "duplicate"],
    "later-reset-wins": ["applied", "applied", "applied", "duplicate"],
    "tie-breaks-by-fingerprint-and-a-cover-beats-a-reset": ["applied", "applied", "applied", "applied", "duplicate"],
    "waits-for-its-game": ["deferred", "applied"],
    "operation-schema-must-match-negotiation": ["applied", "rejected"],
}


def validate_artwork_object(obj, action, now_ms):
    cover_fields = {"artworkFingerprint", "artworkSize"}
    base = {"fingerprint", "generation", "updatedAt", "installationID"}
    require(set(obj) == (base | cover_fields if action == "upsert" else base),
            "An artwork upsert names a cover and its size; a delete names neither")
    fingerprint(obj["fingerprint"])
    canonical_uuid(obj["installationID"])
    require(type(obj["generation"]) is int and 0 <= obj["generation"] <= 2147483647,
            "Invalid artwork generation")
    require(type(obj["updatedAt"]) is int and 946684800000 <= obj["updatedAt"] <= now_ms + 300000,
            "Invalid artwork timestamp")
    if action == "upsert":
        fingerprint(obj["artworkFingerprint"])
        require(type(obj["artworkSize"]) is int and 1 <= obj["artworkSize"] <= MAX_ARTWORK_BYTES,
                "Invalid artwork size")


def replay_artwork_case(case, negotiated, now_ms):
    """A reference model of the published rules: last writer wins by
    (updatedAt, artworkFingerprint or ""), a stale value is a duplicate before
    any ownership check, a later cover must be owned, a cover waits for its game,
    and an operation's schema equals the negotiated schema."""
    owned = {(item["game"], item["cover"]): item["size"] for item in case["ownedCovers"]}
    games, values, deferred, statuses = set(), {}, [], []

    def apply(obj, action):
        game = obj["fingerprint"]
        if (game, obj["generation"]) not in games:
            return "deferred"
        cover = obj.get("artworkFingerprint") if action == "upsert" else None
        order = (obj["updatedAt"], cover or "")
        if game in values and order <= (values[game][0], values[game][1] or ""):
            return "duplicate"
        if cover is not None and owned.get((game, cover)) != obj["artworkSize"]:
            return "rejected"
        values[game] = (obj["updatedAt"], cover)
        return "applied"

    for operation in case["operations"]:
        require(set(operation) == {"operationId", "schema", "kind", "action", "object"},
                "Unexpected artwork scenario operation fields")
        canonical_uuid(operation["operationId"])
        obj = operation["object"]
        if operation["schema"] != negotiated:
            statuses.append("rejected")
            continue
        if operation["kind"] == "game":
            require(operation["action"] == "upsert", "Invalid game action")
            fingerprint(obj["fingerprint"])
            games.add((obj["fingerprint"], obj["generation"]))
            statuses.append("applied")
            for waiting in [item for item in deferred if item[0]["fingerprint"] == obj["fingerprint"]]:
                deferred.remove(waiting)
                require(apply(*waiting) != "deferred", "A deferred cover did not follow its game")
            continue
        require(operation["kind"] == "artwork" and operation["action"] in ("upsert", "delete"),
                "Unknown schema-3 kind or action")
        validate_artwork_object(obj, operation["action"], now_ms)
        status = apply(obj, operation["action"])
        if status == "deferred":
            deferred.append((obj, operation["action"]))
        statuses.append(status)
    return statuses, values


def validate_artwork_vectors(root):
    vector = load_json(root, "testdata/semantic-schema-3.json")
    require(vector["schema"] == 3 and type(vector["nowMs"]) is int and
            vector["requestHeaders"] == {"X-Relay-Sync-Schema": "3"},
            "Invalid schema-3 vector negotiation")
    cases = {case["name"]: case for case in vector["cases"]}
    require(len(vector["cases"]) == len(cases) == len(ARTWORK_CASES) and set(cases) == set(ARTWORK_CASES),
            "Missing or duplicate schema-3 scenario")
    operation_ids = set()
    for name, case in cases.items():
        require(case["expectedStatuses"] == ARTWORK_CASES[name], "Schema-3 scenario result contract changed")
        for operation in case["operations"]:
            require(operation["operationId"] not in operation_ids, "Reused schema-3 operation UUID")
            operation_ids.add(operation["operationId"])
        for item in case["ownedCovers"]:
            fingerprint(item["game"]); fingerprint(item["cover"])
            require(type(item["size"]) is int and 1 <= item["size"] <= MAX_ARTWORK_BYTES, "Invalid owned cover")
        statuses, values = replay_artwork_case(case, vector["schema"], vector["nowMs"])
        require(statuses == case["expectedStatuses"], f"Reference model disagrees with scenario {name}")
        game = case["expected"]["game"]
        if case["expected"].get("absent"):
            require(game not in values, f"Scenario {name} stored a value it must refuse")
        else:
            require(game in values and values[game][1] == case["expected"]["cover"],
                    f"Reference model disagrees with the surviving cover of {name}")


def validate_transfer_vectors(root):
    vector = load_json(root, "testdata/transfer-v2.json")
    require(vector["channel"] == "relay-transfer/2" and vector["hello"]["version"] == 2,
            "Unexpected Transfer channel")
    files = vector["hello"]["files"]
    require(len(files) == 2 and len(vector["payloadsHex"]) == 2,
            "Interleaving fixture requires two files")
    payloads = [bytearray(), bytearray()]
    for frame_hex in vector["framesHex"]:
        frame = bytes.fromhex(frame_hex)
        require(4 < len(frame) <= 65540, "Invalid Transfer frame bound")
        index = int.from_bytes(frame[:4], "big")
        require(index < 2, "Unknown Transfer frame index")
        payloads[index].extend(frame[4:])
    for index, file in enumerate(files):
        payload = bytes(payloads[index])
        require(payload.hex() == vector["payloadsHex"][index] and len(payload) == file["size"] and
                digest(payload) == file["sha256"], "Transfer stream or digest mismatch")
    require(vector["endIDs"] == [file["id"] for file in files], "Transfer terminal order mismatch")


def verify(root, revision):
    pin = CONTRACTS[revision]
    require(not root.is_symlink(), "Symlink contract root")
    manifest = (root / "SHA256SUMS").read_bytes()
    require(digest(manifest) == pin["snapshot_manifest"], "Public manifest pin mismatch")
    entries = manifest_entries(manifest)
    actual = set()
    for path in root.rglob("*"):
        require(not path.is_symlink(), "Symlink in immutable contract")
        if path.is_file():
            actual.add(path.relative_to(root).as_posix())
    require(actual == set(entries) | {"SHA256SUMS"}, "Contract inventory mismatch")
    for name, checksum in entries.items():
        require(digest((root / name).read_bytes()) == checksum,
                f"Contract checksum mismatch: {name}")
    source_manifest = (root / "SOURCE_SHA256SUMS").read_bytes()
    require(digest(source_manifest) == RETAINED_MANIFESTS[revision], "Source manifest pin mismatch")
    source_entries = manifest_entries(source_manifest)
    provenance = load_json(root, "PROVENANCE.json")
    require(provenance.get("semanticSchemas", [pin["schema"]]) == pin.get("schemas", [pin["schema"]]),
            "Unexpected negotiated schema set")
    require(provenance["protocolVersion"] == revision and
            provenance["apiMajor"] == 1 and provenance["semanticSchema"] == pin["schema"] and
            provenance["sourceCommit"] == pin["source_commit"] and
            provenance["sourceManifestSHA256"] == pin["source_manifest"] and
            provenance["snapshotKind"] == "public-client-projection" and
            set(provenance["transformations"]) == (TRANSFORMED & set(source_entries)),
            "Unexpected protocol provenance")
    require(set(source_entries) == set(entries) - {"PROVENANCE.json", "SOURCE_SHA256SUMS"}, "Retained source inventory mismatch")
    for name, checksum in source_entries.items():
        if name not in TRANSFORMED:
            require(entries[name] == checksum, f"Unrecorded projection change: {name}")
    version = load_json(root, "VERSION.json")
    require(version["artifactRevision"] == revision and version["apiMajor"] == 1 and
            version["semanticSchema"] == pin["schema"] and version["status"] == "frozen" and
            version.get("semanticSchemas", [pin["schema"]]) == pin.get("schemas", [pin["schema"]]),
            "Unexpected protocol version")
    openapi = (root / "openapi.yaml").read_text()
    require(re.search(r"^  version: " + re.escape(pin["openapi_version"]) + r"$",
                      openapi, re.MULTILINE), "Unexpected OpenAPI version")
    validate_vectors(root, pin.get("vector_schema", pin["schema"]))
    if revision == "1.3.0":
        validate_transfer_vectors(root)
    if pin["schema"] >= 3:
        validate_artwork_vectors(root)


def expect_rejection(check, message):
    try:
        check()
    except (ValueError, OSError, KeyError, TypeError, IndexError):
        return
    raise ValueError(message)


def self_test():
    """Exercise tamper, injection and invalid-vector rejection independently."""
    for bad in [b"0" * 64 + b"  ../secret\n", b"0" * 64 + b"  /secret\n",
                b"0" * 64 + b"  docs//file\n",
                (b"0" * 64 + b"  duplicate\n") * 2]:
        expect_rejection(lambda: manifest_entries(bad),
                         "Checksum parser accepted an unsafe manifest")
    for revision, pin in CONTRACTS.items():
        contract = ROOT / "Contracts/RelaySync" / ("v" + revision)
        with tempfile.TemporaryDirectory(prefix="relay-contract-") as temporary:
            root = Path(temporary) / "contract"
            mutations = [
                lambda: (root / "testdata/push-game.json").write_text("{}\n"),
                lambda: (root / "unexpected.txt").write_text("unmanifested content"),
                lambda: (root / "linked").symlink_to(root / "VERSION.json"),
            ]
            for mutate in mutations:
                shutil.copytree(contract, root)
                mutate()
                expect_rejection(lambda: verify(root, revision),
                                 "Verifier accepted modified contract")
                shutil.rmtree(root)
            shutil.copytree(contract, root)
            original = load_json(root, "testdata/proof-of-possession-v1.json")
            for change in ("digest", "range"):
                altered = copy.deepcopy(original)
                if change == "digest":
                    altered["expectedDigestHex"] = "0" * 64
                else:
                    altered["ranges"][0]["offset"] = 100000
                (root / "testdata/proof-of-possession-v1.json").write_text(json.dumps(altered))
                expect_rejection(lambda: validate_vectors(root, pin.get("vector_schema", pin["schema"])),
                                 "Vector verifier accepted invalid proof")
            if revision == "1.3.0":
                transfer = load_json(root, "testdata/transfer-v2.json")
                altered = copy.deepcopy(transfer)
                altered["framesHex"][0] = "000000026162"
                (root / "testdata/transfer-v2.json").write_text(json.dumps(altered))
                expect_rejection(lambda: validate_transfer_vectors(root),
                                 "Transfer verifier accepted an unknown stream index")
                (root / "testdata/transfer-v2.json").write_text(json.dumps(transfer))
            if pin["schema"] >= 3:
                artwork = load_json(root, "testdata/semantic-schema-3.json")
                mutations = [
                    lambda value: value.update(requestHeaders={"X-Relay-Sync-Schema": "2"}),
                    lambda value: value["cases"][0]["expectedStatuses"].__setitem__(2, "applied"),
                    lambda value: value["cases"][0]["expected"].update(cover=value["cases"][0]["ownedCovers"][1]["cover"]),
                    lambda value: value["cases"][1]["operations"][2]["object"].update(artworkSize=10),
                    lambda value: value["cases"][0]["operations"][1]["object"].pop("artworkSize"),
                    lambda value: value["cases"][0]["operations"][1]["object"].update(artworkSize=MAX_ARTWORK_BYTES + 1),
                    lambda value: value["cases"][2]["operations"][3]["object"].update(updatedAt=1788520000500),
                    lambda value: value["cases"][3]["operations"].reverse(),
                    lambda value: value["cases"][4]["operations"][1].update(schema=3),
                    lambda value: value["cases"].pop(),
                ]
                for mutate in mutations:
                    altered = copy.deepcopy(artwork)
                    mutate(altered)
                    (root / "testdata/semantic-schema-3.json").write_text(json.dumps(altered))
                    expect_rejection(lambda: validate_artwork_vectors(root),
                                     "Artwork verifier accepted an invalid schema-3 scenario")
                (root / "testdata/semantic-schema-3.json").write_text(json.dumps(artwork))
            if pin.get("vector_schema", pin["schema"]) == 2:
                (root / "testdata/proof-of-possession-v1.json").write_text(json.dumps(original))
                semantic = load_json(root, "testdata/semantic-schema-2.json")
                mutations = [
                    lambda value: value["cases"][0]["operations"][0]["object"].pop("generation"),
                    lambda value: value["cases"][0]["operations"][0]["object"].update(generation=2147483648),
                    lambda value: value["cases"][0]["operations"][0]["object"].update(generation=True),
                    lambda value: value["cases"][0]["operations"][1]["object"].update(
                        installationID=value["cases"][0]["authenticatedInstallationID"]),
                    lambda value: value["cases"][2]["expectedStatuses"].__setitem__(2, "applied"),
                    lambda value: value["cases"][4]["operations"][3]["object"].update(generation=1),
                    lambda value: value["cases"][5]["operations"][2]["object"].update(generation=2),
                    lambda value: value["cases"][6]["expectedStatuses"].__setitem__(3, "applied"),
                    lambda value: value["cases"].pop(),
                ]
                for mutate in mutations:
                    altered = copy.deepcopy(semantic)
                    mutate(altered)
                    (root / "testdata/semantic-schema-2.json").write_text(json.dumps(altered))
                    expect_rejection(lambda: validate_vectors(root, pin.get("vector_schema", pin["schema"])),
                                     "Semantic verifier accepted an invalid schema-2 scenario")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    try:
        for revision in CONTRACTS:
            verify(ROOT / "Contracts/RelaySync" / ("v" + revision), revision)
        if args.self_test:
            self_test()
    except (ValueError, OSError, KeyError, TypeError, IndexError) as error:
        parser.exit(1, f"Relay Sync contract verification failed: {error}\n")
    print("Relay Sync " + ", ".join(CONTRACTS) +
          ": provenance, complete manifests, proof/divergence, 7 schema-2 and 5 schema-3 scenarios verified" +
          ("; rejection self-tests passed" if args.self_test else ""))
