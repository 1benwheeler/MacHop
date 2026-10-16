#!/bin/bash
# Tests and builds MacHop, installs it as /Applications/MacHop.app and starts it.
# Your settings, permissions and chosen iPhone carry over (same signing identity).
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/test.sh >/dev/null 2>&1 || { echo "Tests failed, so MacHop wasn't installed. Run scripts/test.sh to see why." >&2; exit 1; }
scripts/build.sh >/dev/null
osascript -e 'tell application id "local.machop" to quit' 2>/dev/null || true
for _ in $(seq 1 20); do pgrep -x MacHop >/dev/null || break; sleep 0.5; done
rm -rf /Applications/MacHop.app
ditto build/MacHop.app /Applications/MacHop.app
codesign --verify --strict /Applications/MacHop.app
open /Applications/MacHop.app
echo "Installed /Applications/MacHop.app"
