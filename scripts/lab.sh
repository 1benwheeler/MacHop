#!/bin/bash
# Runs machop-lab as "MacHop Lab.app", so its Camera (iPhone screen) and Screen
# Recording (Mac screenshots) permissions belong to it rather than your terminal.
#   scripts/lab.sh doctor | look <dir> | send '<json>' | acceptance | …
set -euo pipefail
cd "$(dirname "$0")/.."
app="build/MacHop Lab.app"
# Build every time (quick when nothing changed), so the lab always matches the sources.
swift build -c release --product machop-lab >/dev/null
rebuild=false
[[ "${1:-}" == "--rebuild" ]] && rebuild=true && shift
if [[ $rebuild == true || ! -d "$app" || .build/release/machop-lab -nt "$app/Contents/MacOS/machop-lab" ]]; then
    rm -rf "$app" && mkdir -p "$app/Contents/MacOS"
    cp .build/release/machop-lab "$app/Contents/MacOS/"
    cp Resources/Lab/Info.plist "$app/Contents/"
    # An unsigned lab is refused by MacHop, so don't leave one behind.
    scripts/sign.sh "$app" local.machop.lab >/dev/null || { rm -rf "$app"; exit 1; }
fi
out=$(mktemp) err=$(mktemp)
status=0
open -W -n --stdout "$out" --stderr "$err" "$app" --args --cwd "$PWD" "$@" || status=$?
cat "$out"
cat "$err" >&2
rm -f "$out" "$err"
exit $status
