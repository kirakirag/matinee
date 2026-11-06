#!/bin/bash
# Creates the stable local code-signing identity "Matinee Local Signing" in the login keychain, so every install is
# signed the same way and macOS keeps treating it as the same app. Does nothing if it already exists.
# Usage: Scripts/make_signing_identity.sh
# The certificate is not marked trusted: codesign doesn't need that, and the app's designated requirement pins the
# certificate's hash, which is what keeps it the same app across installs.
set -euo pipefail

CN="Matinee Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

identities=$(security find-identity -p codesigning)
if [[ "$identities" == *"\"$CN\""* ]]; then
    echo "$CN already exists."
    exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# A config file rather than -addext, which older LibreSSL (macOS's /usr/bin/openssl) lacks.
cat > "$tmp/cert.conf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CN
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.conf" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
# The p12 password only protects the temporary file.
/usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$CN" -out "$tmp/id.p12" -passout pass:matinee
security import "$tmp/id.p12" -k "$KEYCHAIN" -P matinee -T /usr/bin/codesign

identities=$(security find-identity -p codesigning)
if [[ "$identities" != *"\"$CN\""* ]]; then
    echo "$CN was imported but is not a signing identity; check it in Keychain Access." >&2
    exit 1
fi
echo "Created $CN."
