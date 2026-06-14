#!/bin/bash
# Create a STABLE self-signed code-signing identity for Transcriber.
#
# Why: TCC (Microphone / Screen Recording) binds a permission grant to the app's code
# signature. An ad-hoc signature ("-") changes on every rebuild, so each rebuild invalidates
# previously-granted permissions ("toggle is on but the app is still denied"). A self-signed
# certificate gives the app a stable designated requirement, so you grant permissions ONCE and
# they survive rebuilds. The cert lives in an isolated keychain with a known password so this
# runs without interactive prompts.
set -euo pipefail

IDENTITY="Transcriber Local Signing"
KEYCHAIN="$HOME/Library/Keychains/transcriber-signing.keychain-db"
PW="transcriber-local"

if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "Signing identity '$IDENTITY' already present."
    exit 0
fi

echo "==> Creating self-signed code-signing identity '$IDENTITY'…"
TMP="$(mktemp -d)"
cat > "$TMP/cfg.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $IDENTITY
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cfg.cnf" 2>/dev/null
openssl pkcs12 -export -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -passout "pass:$PW" -name "$IDENTITY" 2>/dev/null

security delete-keychain "$KEYCHAIN" 2>/dev/null || true
security create-keychain -p "$PW" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"            # no auto-lock
security unlock-keychain -p "$PW" "$KEYCHAIN"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PW" -A -T /usr/bin/codesign
# allow codesign to use the private key without an interactive prompt
security set-key-partition-list -S apple-tool:,apple:,unsigned: -s -k "$PW" "$KEYCHAIN" >/dev/null 2>&1 || true
# add to the user keychain search list (keep the existing ones)
security list-keychains -d user -s "$KEYCHAIN" \
    $(security list-keychains -d user | sed -e 's/[\"]//g' -e 's/^ *//' | tr '\n' ' ')

rm -rf "$TMP"
echo "==> Done. Identities now available:"
security find-identity -p codesigning | grep -i transcriber || true
