#!/usr/bin/env bash
# Create (or repair) the Winstripe Local code-signing identity in a dedicated keychain.
# No Apple Developer account required. Private material stays under .signing/ (gitignored).
# Optional: without it, scripts/sign.sh signs ad-hoc. A stable identity keeps the app's code
# identity (and its Accessibility permission) across rebuilds.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIGN_DIR="$ROOT/.signing"
KC_PATH="${WINSTRIPE_KEYCHAIN:-$HOME/Library/Keychains/Winstripe.keychain-db}"
KC_PASS="${WINSTRIPE_KEYCHAIN_PASSWORD:-WinstripeLocalDev}"
P12_PASS="$KC_PASS"
IDENTITY="${WINSTRIPE_SIGN_IDENTITY:-Winstripe Local}"
LOGIN="$HOME/Library/Keychains/login.keychain-db"

mkdir -p "$SIGN_DIR"
chmod 700 "$SIGN_DIR"

if [[ ! -f "$SIGN_DIR/WinstripeLocal.p12" ]]; then
  cat > "$SIGN_DIR/codesign.cnf" <<'CNF'
[ req ]
distinguished_name = req_distinguished_name
prompt             = no
x509_extensions    = codesign_ext

[ req_distinguished_name ]
CN = Winstripe Local
O  = Winstripe Local Dev
C  = US

[ codesign_ext ]
basicConstraints       = critical,CA:FALSE
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
subjectKeyIdentifier   = hash
CNF
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$SIGN_DIR/WinstripeLocal.key" \
    -out "$SIGN_DIR/WinstripeLocal.crt" \
    -config "$SIGN_DIR/codesign.cnf"
  openssl pkcs12 -export \
    -inkey "$SIGN_DIR/WinstripeLocal.key" \
    -in "$SIGN_DIR/WinstripeLocal.crt" \
    -out "$SIGN_DIR/WinstripeLocal.p12" \
    -name "$IDENTITY" \
    -passout "pass:$P12_PASS"
  chmod 600 "$SIGN_DIR"/WinstripeLocal.* "$SIGN_DIR/codesign.cnf"
  echo "Generated $SIGN_DIR/WinstripeLocal.p12"
fi

if [[ ! -f "$KC_PATH" ]]; then
  security create-keychain -p "$KC_PASS" "$KC_PATH"
fi
security set-keychain-settings -t 21600 -u "$KC_PATH"
security unlock-keychain -p "$KC_PASS" "$KC_PATH"

# Ensure Winstripe keychain is on the user search list (ahead of login)
security list-keychains -d user -s "$KC_PATH" "$LOGIN"

# Import if identity not already in this keychain
if ! security find-certificate -c "$IDENTITY" "$KC_PATH" >/dev/null 2>&1; then
  security import "$SIGN_DIR/WinstripeLocal.p12" \
    -k "$KC_PATH" \
    -P "$P12_PASS" \
    -A \
    -T /usr/bin/codesign \
    -T /usr/bin/security
fi
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KC_PATH" >/dev/null

cat > "$SIGN_DIR/keychain.env" <<ENV
# Local-only; never commit.
WINSTRIPE_KEYCHAIN="$KC_PATH"
WINSTRIPE_KEYCHAIN_PASSWORD="$KC_PASS"
WINSTRIPE_SIGN_IDENTITY="$IDENTITY"
ENV
chmod 600 "$SIGN_DIR/keychain.env"

echo "Identity: $IDENTITY"
security find-identity -p codesigning || true
echo "Done. Optional once (GUI password): security add-trusted-cert -d -r trustRoot -p codeSign \"$SIGN_DIR/WinstripeLocal.crt\""
