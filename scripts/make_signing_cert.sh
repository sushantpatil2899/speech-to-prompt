#!/usr/bin/env bash
# Creates a self-signed code-signing certificate "SpeechToPrompt Local Signing" in your
# login keychain. build_app.sh signs with it, so the app keeps the same identity across
# rebuilds and macOS remembers its permissions (Microphone, Input Monitoring, Accessibility).
#
# Only needed if you don't have an "Apple Development" certificate (that one needs full Xcode).
# The certificate never leaves your Mac and is only trusted for code signing, by you.
#
# macOS will ask for your login password once, to mark the certificate as trusted for code signing.
set -euo pipefail

NAME="SpeechToPrompt Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OPENSSL=/usr/bin/openssl   # macOS LibreSSL: its .p12 files import cleanly (Homebrew/conda OpenSSL 3 needs -legacy)

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
  echo "✓ \"$NAME\" already exists"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -passout pass:speechtoprompt -out "$TMP/identity.p12"

# -T: let codesign use the key without prompting each build.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P speechtoprompt -T /usr/bin/codesign
echo "Marking it trusted for code signing (macOS asks for your password)…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "✓ Created \"$NAME\". scripts/build_app.sh will use it automatically."
else
  echo "The certificate was imported but isn't listed as a code-signing identity."
  echo "Open Keychain Access, find \"$NAME\", and check that its private key is under it."
  exit 1
fi
