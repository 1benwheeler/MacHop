#!/bin/bash
# Runs the automated test suite. Works with full Xcode or Command Line Tools only.
#   scripts/test.sh                      # everything
#   scripts/test.sh --filter Simulation  # a subset (any `swift test` arguments)
set -euo pipefail
cd "$(dirname "$0")/.."

developer_dir=$(xcode-select -p)
flags=()
if [[ "$developer_dir" == *CommandLineTools* ]]; then
    # Command Line Tools ship Swift Testing but not on the default search paths,
    # and omit the interface of its Foundation overlay, so that overlay is disabled.
    frameworks="$developer_dir/Library/Developer/Frameworks"
    flags=(-Xswiftc -F -Xswiftc "$frameworks"
           -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays
           -Xlinker -F -Xlinker "$frameworks"
           -Xlinker -rpath -Xlinker "$frameworks"
           -Xswiftc -plugin-path -Xswiftc "$developer_dir/usr/lib/swift/host/plugins/testing")
fi
exec swift test "${flags[@]}" "$@"
