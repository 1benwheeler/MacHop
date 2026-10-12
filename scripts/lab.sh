#!/bin/bash
# Runs machop-lab as "MacHop Lab.app", so its Camera (iPhone screen) and Screen
# Recording (Mac screenshots) permissions belong to it rather than your terminal.
#   scripts/lab.sh doctor | look <dir> | send '<json>' | acceptance | …
set -euo pipefail
cd "$(dirname "$0")/.."
app="build/MacHop Lab.app"
if [[ ! -d "$app" || .build/release/machop-lab -nt "$app/Contents/MacOS/machop-lab" || "${1:-}" == "--rebuild" ]]; then
    [[ "${1:-}" == "--rebuild" ]] && shift
    swift build -c release --product machop-lab >/dev/null
    rm -rf "$app" && mkdir -p "$app/Contents/MacOS"
    cp .build/release/machop-lab "$app/Contents/MacOS/"
    cp Resources/Lab/Info.plist "$app/Contents/"
    scripts/sign.sh "$app" local.machop.lab >/dev/null
fi
out=$(mktemp) err=$(mktemp)
status=0
open -W -n --stdout "$out" --stderr "$err" "$app" --args --cwd "$PWD" "$@" || status=$?
cat "$out"
cat "$err" >&2
rm -f "$out" "$err"
exit $status
