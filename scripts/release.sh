#!/bin/bash
# Builds the download for a GitHub release: dist/MacHop-<version>.zip, tested and
# signed with your MacHop identity (scripts/setup-signing.sh). Always sign releases
# with the same identity: macOS ties MacHop's permissions to it, so users keep
# Accessibility and Bluetooth access across updates.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/test.sh >/dev/null
scripts/build.sh >/dev/null
app=build/MacHop.app
if ! codesign -dr - "$app" 2>&1 | grep -q "certificate leaf"; then
    echo "error: $app is ad-hoc signed. Run scripts/setup-signing.sh (or restore your signing folder) first." >&2
    exit 1
fi
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
mkdir -p dist
zip="dist/MacHop-$version.zip"
rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
echo "Built $zip"
shasum -a 256 "$zip"
