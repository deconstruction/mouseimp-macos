#!/bin/bash
# Creates the self signed "MouseImp Dev" code signing identity in the login
# keychain and prints what it made.
#
#   ./Scripts/make-signing-identity.sh            # create (asks nothing if it exists)
#   ./Scripts/make-signing-identity.sh --remove   # delete certificate and key
#
# Why: an ad-hoc signature is a hash of the binary, so every rebuild looks like a
# different application to macOS and the Accessibility permission has to be
# granted again. A stable certificate keeps the permission across rebuilds.

set -euo pipefail

NAME="MouseImp Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORKDIR="$(cd "$(dirname "$0")/.." && pwd)/.build/signing"

if [ "${1:-}" = "--remove" ]; then
  echo "removing identity '$NAME'"
  security delete-identity -c "$NAME" "$KEYCHAIN" 2>/dev/null || true
  security delete-certificate -c "$NAME" "$KEYCHAIN" 2>/dev/null || true
  rm -rf "$WORKDIR"
  security find-identity -v -p codesigning | grep -q "$NAME" \
    && echo "still present, remove it in Keychain Access" \
    || echo "removed"
  exit 0
fi

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "identity '$NAME' already exists:"
  security find-identity -v -p codesigning | grep "$NAME"
  exit 0
fi

mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo "==> generating a self signed code signing certificate"
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout key.pem -out cert.pem -days 3650 \
  -subj "/CN=$NAME/O=MouseImp for macOS" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

P12PASS="mouseimp-dev"
# LibreSSL (the system openssl) writes the PKCS#12 flavour the keychain tools
# accept; OpenSSL 3+ defaults to one they reject.
P12TOOL=/usr/bin/openssl
[ -x "$P12TOOL" ] || P12TOOL=openssl
"$P12TOOL" pkcs12 -export -out id.p12 -inkey key.pem -in cert.pem \
  -passout pass:"$P12PASS" -descert 2>/dev/null

echo "==> importing into the login keychain (only codesign may use the key)"
security import id.p12 -k "$KEYCHAIN" -P "$P12PASS" -T /usr/bin/codesign >/dev/null

echo "==> trusting it for code signing (login keychain only, no system trust store)"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" cert.pem 2>/dev/null \
  || echo "   (could not change the trust settings - do it in Keychain Access: open the"
echo

echo "==> result"
security find-identity -v -p codesigning | grep "$NAME" || {
  echo "identity not found"; exit 1; }

echo
echo "Now run: ./Scripts/build-app.sh    (it picks '$NAME' up automatically)"
echo "To undo: ./Scripts/make-signing-identity.sh --remove"
