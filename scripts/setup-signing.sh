#!/bin/bash
# Creates a self-signed code-signing identity in its own keychain, outside the
# project (~/Library/Application Support/MacHop Signing), so cleaning a build never
# loses it. Signing every build with the same identity keeps macOS privacy
# permissions (Accessibility, Bluetooth) valid across rebuilds and updates; ad-hoc
# signatures change with every build and silently invalidate them.
#
# The keychain's password is random and kept in your login keychain (service
# "MacHop signing keychain"), never in this repository: macOS ties MacHop's
# permissions to this identity, so its key must stay private.
# Nothing is added to your trust settings. To undo:
#   rm -rf ~/Library/Application\ Support/MacHop\ Signing
#   security delete-generic-password -s "MacHop signing keychain"
set -euo pipefail
cd "$(dirname "$0")/.."

dir="$HOME/Library/Application Support/MacHop Signing"
keychain="$dir/machop.keychain-db"
identity="MacHop Local Signing"

if [[ -f "$keychain" ]] && security find-certificate -c "$identity" "$keychain" >/dev/null 2>&1; then
    echo "Signing identity already exists in $dir"
    exit 0
fi

password=$(/usr/bin/openssl rand -hex 24)
security add-generic-password -U -a "$USER" -s "MacHop signing keychain" -w "$password"
mkdir -p "$dir"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat > "$work/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $identity
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
# The system LibreSSL writes PKCS#12 in the format the macOS keychain imports
# (newer OpenSSL releases default to algorithms it rejects).
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cert.cnf" \
    -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
    -name "$identity" -out "$work/identity.p12" -passout "pass:$password"

rm -f "$keychain"
security create-keychain -p "$password" "$keychain"
security set-keychain-settings "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$work/identity.p12" -k "$keychain" -P "$password" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
echo "Created signing identity \"$identity\" in $dir"
echo "Back up that folder: release builds must keep using the same identity."
