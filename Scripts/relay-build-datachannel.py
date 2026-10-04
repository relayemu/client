#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build the pinned, data-only native transport without changing upstream sources."""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import hashlib
import datetime

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "Vendor/RelayDataChannel"
OUTPUT = ROOT / "test-artefacts/transfer/native-build"
ARTIFACT = ROOT / "Packages/RelayTransfer/Artifacts/RelayDataChannel.xcframework"
SLICES = [("macos", "Darwin", "macosx", "15.0"), ("ios", "iOS", "iphoneos", "18.0"),
          ("ios-sim", "iOS", "iphonesimulator", "18.0"), ("tvos", "tvOS", "appletvos", "18.0"),
          ("tvos-sim", "tvOS", "appletvsimulator", "18.0")]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--slice", choices=[s[0] for s in SLICES], help="Build one slice for diagnosis without packing")
    parser.add_argument("--verify-only", action="store_true", help="Verify the immutable source tree without compiling")
    parser.add_argument("--if-needed", action="store_true", help="Reuse a complete artifact with matching source revisions")
    args = parser.parse_args()
    source_manifest = json.loads((VENDOR / "SOURCE_MANIFEST.json").read_text())
    actual = {str(p.relative_to(VENDOR / "upstream")): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in (VENDOR / "upstream").rglob("*")
              if p.is_file() and "__pycache__" not in p.parts and p.suffix != ".pyc"}
    if actual != source_manifest:
        raise SystemExit("Pinned native source differs from SOURCE_MANIFEST.json")
    if args.verify_only:
        print("Native pinned source verified: " + str(len(actual)) + " files")
        return
    revisions = json.loads((VENDOR / "RELAY_VENDOR.json").read_text())
    environment = os.environ.copy()
    environment.setdefault("DEVELOPER_DIR", subprocess.check_output(["xcode-select", "-p"], text=True).strip())
    xcode_version = subprocess.check_output(["xcodebuild", "-version"], env=environment, text=True).strip()
    inputs = {
        "script": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "buildConfiguration": {str(p.relative_to(VENDOR)): hashlib.sha256(p.read_bytes()).hexdigest()
                               for p in sorted((VENDOR / "RelayBuild").rglob("*")) if p.is_file()},
        "sourceManifest": hashlib.sha256((VENDOR / "SOURCE_MANIFEST.json").read_bytes()).hexdigest(),
        "developerDirectory": environment["DEVELOPER_DIR"], "xcodeVersion": xcode_version,
    }
    receipt = ARTIFACT / "relay-build-provenance.json"
    if args.if_needed and receipt.exists():
        existing = json.loads(receipt.read_text())
        artifact_hashes = {str(p.relative_to(ARTIFACT)): hashlib.sha256(p.read_bytes()).hexdigest()
                           for p in sorted(ARTIFACT.rglob("*")) if p.is_file() and p != receipt}
        if existing.get("pins") == revisions and existing.get("buildInputs") == inputs and existing.get("artifactFiles") == artifact_hashes and all((ARTIFACT / name / "libRelayDataChannel.a").exists()
                for name in ["macos-arm64", "ios-arm64", "ios-arm64-simulator", "tvos-arm64", "tvos-arm64-simulator"]):
            print("Reusing verified native artifact")
            return
    if not 1 <= args.jobs <= 4:
        parser.error("jobs must be between 1 and 4; shared host default is 2")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    config_flags = shlex.join(["-DMBEDTLS_USER_CONFIG_FILE=\"relay-mbedtls-config.h\"", "-I" + str(VENDOR / "RelayBuild")])

    def run(command, log):
        with log.open("a") as stream:
            subprocess.run([str(s) for s in command], env=environment, stdout=stream, stderr=subprocess.STDOUT, check=True)

    for name, system, sdk, minimum in SLICES:
        if args.slice and args.slice != name:
            continue
        base = OUTPUT / name
        base.mkdir(parents=True, exist_ok=True)
        prefix = base / "prefix"
        log = base / "build.log"
        common = ["-G", "Ninja", "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_OSX_ARCHITECTURES=arm64",
                  "-DCMAKE_OSX_SYSROOT=" + sdk, "-DCMAKE_OSX_DEPLOYMENT_TARGET=" + minimum,
                  "-DCMAKE_POSITION_INDEPENDENT_CODE=ON", "-DCMAKE_C_FLAGS=" + config_flags,
                  "-DCMAKE_CXX_FLAGS=" + config_flags, "-DCMAKE_INSTALL_PREFIX=" + str(prefix)]
        if system != "Darwin":
            common += ["-DCMAKE_SYSTEM_NAME=" + system]
        print("Building " + name + " (arm64, " + str(args.jobs) + " jobs)", flush=True)
        run(["cmake", "-S", VENDOR / "upstream/mbedtls", "-B", base / "mbedtls", *common,
             "-DENABLE_PROGRAMS=OFF", "-DENABLE_TESTING=OFF", "-DUSE_SHARED_MBEDTLS_LIBRARY=OFF"], log)
        run(["cmake", "--build", base / "mbedtls", "--target", "install", "--parallel", args.jobs], log)
        run(["cmake", "-S", VENDOR / "upstream/libdatachannel", "-B", base / "datachannel", *common,
             "-DCMAKE_PREFIX_PATH=" + str(prefix), "-DCMAKE_FIND_ROOT_PATH=" + str(prefix),
             "-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH", "-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH",
             "-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH", "-DUSE_MBEDTLS=ON", "-DBUILD_SHARED_LIBS=OFF",
             "-DNO_MEDIA=ON", "-DNO_WEBSOCKET=ON", "-DNO_EXAMPLES=ON", "-DNO_TESTS=ON"], log)
        run(["cmake", "--build", base / "datachannel", "--target", "datachannel-static", "--parallel", args.jobs], log)
        libraries = [base / "datachannel/libdatachannel-static.a"]
        libraries += sorted((base / "datachannel/deps").rglob("*.a"))
        libraries += sorted((prefix / "lib").glob("libmbed*.a"))
        run(["xcrun", "libtool", "-static", "-o", base / "libRelayDataChannel.a", *libraries], log)
    if args.slice:
        return
    headers = OUTPUT / "headers"
    shutil.copytree(VENDOR / "upstream/libdatachannel/include/rtc", headers / "rtc", dirs_exist_ok=True)
    shutil.copyfile(VENDOR / "RelayBuild/module.modulemap", headers / "module.modulemap")
    # Replace only this task's generated artifact, never upstream or another build.
    if ARTIFACT.exists():
        shutil.rmtree(ARTIFACT)
    ARTIFACT.parent.mkdir(parents=True, exist_ok=True)
    command = ["xcodebuild", "-create-xcframework"]
    for name, _, _, _ in SLICES:
        command += ["-library", OUTPUT / name / "libRelayDataChannel.a", "-headers", headers]
    run([*command, "-output", ARTIFACT], OUTPUT / "xcframework.log")
    provenance = {
        "pins": revisions,
        "buildInputs": inputs,
        "architecture": "arm64", "slices": [s[0] for s in SLICES],
        "developerDirectory": environment["DEVELOPER_DIR"], "jobs": args.jobs,
        "builtAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "xcodeVersion": xcode_version,
        "artifactFiles": {str(p.relative_to(ARTIFACT)): hashlib.sha256(p.read_bytes()).hexdigest()
                          for p in sorted(ARTIFACT.rglob("*")) if p.is_file()},
        "libraries": {str(p.relative_to(ARTIFACT)): hashlib.sha256(p.read_bytes()).hexdigest()
                      for p in sorted(ARTIFACT.rglob("*.a"))},
    }
    receipt.write_text(json.dumps(provenance, indent=2) + "\n")
    (OUTPUT / "build-provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    print("Built " + str(ARTIFACT), flush=True)


if __name__ == "__main__":
    main()
