#!/bin/zsh
# SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
# SPDX-License-Identifier: GPL-3.0-or-later
# Build one Relay shell with xcodebuild (no signing). Usage:
#   Scripts/relay-build.sh <RelayiOS|RelayTV|RelayMac> [Debug|Release] [extra xcodebuild args…]
# Output: build/DerivedData/Build/Products/<Config>[-<platform>]/<Target>.app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:?target}"; CONFIG="${2:-Debug}"; shift $(( $# >= 2 ? 2 : $# ))
case "$TARGET" in
  RelayiOS) DEST="generic/platform=iOS Simulator" ;;
  RelayTV)  DEST="generic/platform=tvOS Simulator" ;;
  RelayMac) DEST="platform=macOS,arch=arm64" ;;
  *) echo "unknown target $TARGET" >&2; exit 2 ;;
esac
python3 "$ROOT/Scripts/relay-build-datachannel.py" --if-needed --jobs "${RELAY_BUILD_JOBS:-2}"
mkdir -p "$ROOT/build/logs"
LOG="$ROOT/build/logs/${TARGET}-${CONFIG}-$(date +%Y%m%d-%H%M%S).log"
echo "building $TARGET ($CONFIG) → $LOG"
xcodebuild -project "$ROOT/Apps/Relay.xcodeproj" -scheme "$TARGET" -configuration "$CONFIG" \
  -destination "$DEST" -derivedDataPath "$ROOT/build/DerivedData" \
  -skipPackagePluginValidation -skipMacroValidation \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  ARCHS=arm64 CODE_SIGNING_ALLOWED=NO "$@" build 2>&1 | tee "$LOG" | /usr/bin/grep -E '(error:|warning: .*Relay|BUILD (SUCCEEDED|FAILED))' || true
tail -3 "$LOG" | /usr/bin/grep -q 'BUILD SUCCEEDED'
