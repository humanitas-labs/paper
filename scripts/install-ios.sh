#!/bin/bash
# Builds Paper for iOS and installs it on a connected iPhone or iPad.
#
#   scripts/install-ios.sh [device]
#
# Installs a Release build, the one to use day to day; set CONFIGURATION=Debug
# for a debug build.
# `device` is a name or identifier from `xcrun devicectl list devices`; with
# none, the first available device is used. Needs `Local.xcconfig` at the
# repository root with `DEVELOPMENT_TEAM = <team ID>` (see
# PaperMobile/Signing.xcconfig), and, the first time, the device connected
# by cable, trusted, and in Developer Mode (Settings ▸ Privacy & Security).
set -euo pipefail
cd "$(dirname "$0")/.."
configuration=${CONFIGURATION:-Release}

if ! grep -qs '^DEVELOPMENT_TEAM *= *[A-Z0-9]' Local.xcconfig; then
    echo "Local.xcconfig has no DEVELOPMENT_TEAM; see PaperMobile/Signing.xcconfig." >&2
    exit 1
fi

devices=$(mktemp)
trap 'rm -f "$devices"' EXIT
xcrun devicectl list devices --json-output "$devices" >/dev/null
device=${1:-$(python3 -c '
import json, sys
found = json.load(open(sys.argv[1]))["result"]["devices"]
ready = [d for d in found if d.get("connectionProperties", {}).get("pairingState") == "paired"]
print(ready[0]["identifier"] if ready else "")
' "$devices")}
if [ -z "$device" ]; then
    echo "No paired device. Connect the phone by cable, unlock it, and trust this Mac." >&2
    exit 1
fi

xcodegen generate --quiet
xcodebuild -project Paper.xcodeproj -scheme PaperMobile -configuration "$configuration" \
    -destination "generic/platform=iOS" -derivedDataPath build/ios \
    -allowProvisioningUpdates build | grep -E 'error:|BUILD' || true

app=build/ios/Build/Products/$configuration-iphoneos/Paper.app
[ -d "$app" ] || { echo "Build failed; run xcodebuild without the filter for details." >&2; exit 1; }
xcrun devicectl device install app --device "$device" "$app"
xcrun devicectl device process launch --device "$device" org.humanitas.paper.ios || true
