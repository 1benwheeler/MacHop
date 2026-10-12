#!/bin/bash
# Builds build/MacHop.app (optimized, universal: Apple silicon and Intel), signs it
# and verifies it.
#   scripts/build.sh                 # sign with the local identity (scripts/setup-signing.sh)
#   MACHOP_SIGN_IDENTITY=- scripts/build.sh                            # ad-hoc
#   MACHOP_SIGN_IDENTITY="Developer ID Application: …" scripts/build.sh  # distribution
set -euo pipefail
cd "$(dirname "$0")/.."

app=build/MacHop.app

# One build per architecture, combined into a universal binary.
binary=build/MacHop-universal
mkdir -p build
parts=()
for arch in arm64 x86_64; do
    swift build -c release --product MacHop --triple "$arch-apple-macosx14.0"
    parts+=("$(swift build -c release --triple "$arch-apple-macosx14.0" --show-bin-path)/MacHop")
done
lipo -create "${parts[@]}" -output "$binary"
# MacHop loads nothing through @rpath, so drop the search paths SwiftPM adds: fewer
# places a planted library could be looked for.
while read -r path; do
    install_name_tool -delete_rpath "$path" "$binary" 2>/dev/null || true
done < <(otool -l "$binary" | awk '/LC_RPATH/ {getline; getline; print $2}' | sort -u)

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/MacHop"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp -R Resources/Licenses "$app/Contents/Resources/"
cp THIRD-PARTY-NOTICES.md LICENSE Resources/AppIcon.icns "$app/Contents/Resources/"

scripts/sign.sh "$app" local.machop
codesign --verify --strict --verbose=1 "$app"
plutil -lint "$app/Contents/Info.plist" >/dev/null
echo "Built $app"
codesign -dr - "$app" 2>&1 | sed -n 's/^designated => /Designated requirement: /p'
shasum -a 256 "$app/Contents/MacOS/MacHop" | awk '{print "Executable SHA-256: " $1}'
