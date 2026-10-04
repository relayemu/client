#!/bin/zsh
# SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
# SPDX-License-Identifier: GPL-3.0-or-later
# Produce unsigned Release archives of the three Relay shells and measure them.
# Usage: Scripts/relay-archive.sh <label> [RelayiOS|RelayTV|RelayMac …]   → build/archives/<Target>-<label>.xcarchive + JSON
# device destinations, CODE_SIGNING_ALLOWED=NO, per-component measurement with
# linker also writes a map file next to the archive so relay-inspect-release.py
# can attribute code size to each core.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="${1:?label}"; shift
TARGETS=("$@"); [ ${#TARGETS[@]} -eq 0 ] && TARGETS=(RelayiOS RelayTV RelayMac)
mkdir -p "$ROOT/build/archives" "$ROOT/build/logs"
for TARGET in "${TARGETS[@]}"; do
  case "$TARGET" in
    RelayiOS) DEST="generic/platform=iOS" ;;
    RelayTV)  DEST="generic/platform=tvOS" ;;
    RelayMac) DEST="generic/platform=macOS" ;;
  esac
  ARCHIVE="$ROOT/build/archives/${TARGET}-${LABEL}.xcarchive"
  LOG="$ROOT/build/logs/${TARGET}-archive-${LABEL}.log"
  rm -rf "$ARCHIVE"
  echo "== archiving $TARGET → $ARCHIVE"
  xcodebuild -project "$ROOT/Apps/Relay.xcodeproj" -scheme "$TARGET" -configuration Release \
    -destination "$DEST" -derivedDataPath "$ROOT/build/DerivedData" -archivePath "$ARCHIVE" \
    -skipPackagePluginValidation -skipMacroValidation -jobs "${RELAY_BUILD_JOBS:-4}" ARCHS=arm64 CODE_SIGNING_ALLOWED=NO \
    -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
    LD_GENERATE_MAP_FILE=YES archive \
    > "$LOG" 2>&1 || { tail -20 "$LOG"; exit 1; }
  tail -3 "$LOG" | /usr/bin/grep -q 'ARCHIVE SUCCEEDED'
  # The app target's link map (every module writes one; only the executable's matters).
  MAP="$(/usr/bin/find "$ROOT/build/DerivedData/Build/Intermediates.noindex/ArchiveIntermediates/$TARGET" -name "${TARGET}-LinkMap-normal-arm64.txt" | head -1)"
  [ -n "$MAP" ] && cp "$MAP" "$ROOT/build/archives/${TARGET}-${LABEL}-linkmap.txt"
done
echo "archives done"
