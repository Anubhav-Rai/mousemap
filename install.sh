#!/bin/bash
# Build mousemap, install it to ~/.local/bin and start it (now and at login).
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p build ~/.local/bin
swiftc -O -swift-version 5 -o build/mousemap mousemap.swift

# Sign with a local self-signed certificate, kept in its own keychain here.
# macOS ties the permission to the signature; an ad-hoc signature changes with
# every build, this one doesn't, so rebuilds keep the permission.
keychain="$PWD/.signing/mousemap.keychain-db"
password=mousemap   # protects nothing valuable: a local-only signing key
if [ ! -f "$keychain" ]; then
    mkdir -p .signing
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=mousemap local signing" \
        -addext "extendedKeyUsage=codeSigning" -addext "keyUsage=critical,digitalSignature" \
        -keyout .signing/key.pem -out .signing/cert.pem 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey .signing/key.pem -in .signing/cert.pem \
        -out .signing/identity.p12 -passout pass:$password
    security create-keychain -p $password "$keychain"
    security import .signing/identity.p12 -k "$keychain" -P $password -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple: -s -k $password "$keychain" >/dev/null
    rm .signing/key.pem .signing/identity.p12
fi
security unlock-keychain -p $password "$keychain"
identity=$(security find-certificate -c "mousemap local signing" -Z "$keychain" | awk '/SHA-1/ { print $NF }')

# Copy then rename, so a running copy of the old binary isn't overwritten in place.
cp build/mousemap ~/.local/bin/mousemap.new
codesign --force --sign "$identity" --keychain "$keychain" --identifier local.mousemap ~/.local/bin/mousemap.new 2>/dev/null
mv -f ~/.local/bin/mousemap.new ~/.local/bin/mousemap

~/.local/bin/mousemap on

cat <<'EOF'

If mousemap isn't allowed yet, allow it in
  System Settings > Privacy & Security > Device Control and Data Access
  (called "Accessibility" on older macOS)
EOF
