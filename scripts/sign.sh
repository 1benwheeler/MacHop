#!/bin/bash
# Signs an app bundle with the local MacHop identity (scripts/setup-signing.sh),
# falling back to ad-hoc. Usage: scripts/sign.sh <app> <bundle-identifier>
set -euo pipefail
cd "$(dirname "$0")/.."
app="$1"
identifier="$2"
keychain="$HOME/Library/Application Support/MacHop Signing/machop.keychain-db"
identity="${MACHOP_SIGN_IDENTITY:-}"
if [[ -z "$identity" && -f "$keychain" ]]; then
    # codesign only finds identities in keychains on the user's search list, so the
    # project keychain is added for the duration of signing and the list restored.
    original=$(security list-keychains -d user | tr -d '"' | xargs)
    trap 'security list-keychains -d user -s $original' EXIT
    security list-keychains -d user -s $original "$keychain"
    password=$(security find-generic-password -s "MacHop signing keychain" -w)
    security unlock-keychain -p "$password" "$keychain"
    # The hardened runtime stops code being injected into MacHop at launch (for example
    # with DYLD_INSERT_LIBRARIES), which would otherwise inherit its Accessibility
    # permission. The lab tool is left without it: it needs the camera entitlement.
    runtime=()
    [[ "$identifier" == local.machop ]] && runtime=(--options runtime)
    codesign --force --sign "MacHop Local Signing" --keychain "$keychain" "${runtime[@]}" --identifier "$identifier" "$app"
    security list-keychains -d user -s $original
    trap - EXIT
elif [[ -z "$identity" || "$identity" == "-" ]]; then
    echo "note: ad-hoc signing; macOS permissions will need re-granting after each rebuild (run scripts/setup-signing.sh)"
    codesign --force --sign - --identifier "$identifier" "$app"
else
    codesign --force --options runtime --timestamp --sign "$identity" --identifier "$identifier" "$app"
fi
codesign --verify --strict "$app"
