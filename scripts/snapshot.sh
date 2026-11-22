#!/bin/bash
# Draws every page of MacHop's window, the menu, the iPhone picker and the About box to
# PNG files, off screen, for each place the iPhone can sit (right, above, below). Use it
# to check the UI still builds and looks right, and to refresh the README's pictures.
#   scripts/snapshot.sh <folder>                        # the current sources (debug build)
#   scripts/snapshot.sh <folder> --app build/MacHop.app # a built app: real version and icon
# It's a dry run: no Bluetooth or input capture, and your settings are never changed. For
# a few seconds a second MacHop icon shows in the menu bar and the About box comes forward.
set -euo pipefail
cd "$(dirname "$0")/.."

folder="${1:?usage: scripts/snapshot.sh <folder> [--app <MacHop.app>]}"
if [[ "${2:-}" == "--app" ]]; then
    binary="${3:?--app needs the path to MacHop.app}/Contents/MacOS/MacHop"
else
    swift build --product MacHop >/dev/null
    binary="$(swift build --product MacHop --show-bin-path)/MacHop"
fi
mkdir -p "$folder"
folder="$(cd "$folder" && pwd)"

pages=(phone gestures scrolling settings setup menu picker controls about)
missing=0
for placement in right top bottom; do
    flags=(--dry-run --demo --light)
    [[ $placement == top ]] && flags+=(--demo-top)
    [[ $placement == bottom ]] && flags+=(--demo-bottom)
    mkdir -p "$folder/$placement"
    "$binary" "${flags[@]}" --snapshot-ui "$folder/$placement" >/dev/null 2>&1 || true
    for page in "${pages[@]}"; do
        if [[ ! -s "$folder/$placement/$page.png" ]]; then
            echo "missing: $placement/$page.png" >&2
            missing=$((missing + 1))
        fi
    done
done
if (( missing > 0 )); then
    echo "error: $missing page(s) weren't drawn" >&2
    exit 1
fi
echo "Drew ${#pages[@]} pages for each of 3 placements in $folder"
