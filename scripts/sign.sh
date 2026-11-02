#!/usr/bin/env bash
# Sign an .app with "Winstripe Local" (or $WINSTRIPE_SIGN_IDENTITY) when that
# identity is in the keychain; otherwise ad-hoc, which needs no certificate.
# WINSTRIPE_SIGN_IDENTITY=- forces ad-hoc signing.
#
# An identity matches exactly or as a prefix of a keychain identity's name, so
# "Apple Distribution" finds "Apple Distribution: Org Name (TEAMID)". Only the
# built-in defaults fall back to ad-hoc when missing; an identity requested via
# WINSTRIPE_SIGN_IDENTITY (environment or .signing/keychain.env) must exist.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-}"
if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "usage: $0 path/to/App.app" >&2
  exit 2
fi

EXPLICIT=0
[[ -n "${WINSTRIPE_SIGN_IDENTITY:-}" ]] && EXPLICIT=1
IDENTITY="${WINSTRIPE_SIGN_IDENTITY:-Winstripe Local}"
KC_PATH="${WINSTRIPE_KEYCHAIN:-$HOME/Library/Keychains/Winstripe.keychain-db}"
KC_PASS="${WINSTRIPE_KEYCHAIN_PASSWORD:-}"
ENTITLEMENTS="${WINSTRIPE_SIGN_ENTITLEMENTS:-}"

if [[ -f "$ROOT/.signing/keychain.env" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT/.signing/keychain.env"
  [[ -n "${WINSTRIPE_SIGN_IDENTITY:-}" ]] && EXPLICIT=1
  IDENTITY="${WINSTRIPE_SIGN_IDENTITY:-$IDENTITY}"
  KC_PATH="${WINSTRIPE_KEYCHAIN:-$KC_PATH}"
  KC_PASS="${WINSTRIPE_KEYCHAIN_PASSWORD:-$KC_PASS}"
fi

# Prints the full name of the keychain identity matching $IDENTITY: an exact
# match (even untrusted is enough for local codesign) first, then the first
# name starting with $IDENTITY, preferring valid identities.
identity_names() {
  security find-identity -p codesigning "$@" 2>/dev/null | sed -n 's/^ *[0-9]*) [0-9A-F]* "\([^"]*\)".*/\1/p'
}
resolve_identity() {
  local names valid name
  names="$(identity_names)"
  valid="$(identity_names -v)"
  while IFS= read -r name; do
    [[ "$name" == "$IDENTITY" ]] && { printf '%s\n' "$name"; return 0; }
  done <<<"$names"
  while IFS= read -r name; do
    [[ -n "$name" && "$name" == "$IDENTITY"* ]] && { printf '%s\n' "$name"; return 0; }
  done <<<"$valid"$'\n'"$names"
  return 1
}

if [[ "$IDENTITY" == "-" ]]; then
  echo "==> Ad-hoc code signing"
elif RESOLVED="$(resolve_identity)"; then
  IDENTITY="$RESOLVED"
  if [[ -f "$KC_PATH" && -n "$KC_PASS" ]]; then
    security unlock-keychain -p "$KC_PASS" "$KC_PATH" >/dev/null 2>&1 || true
  fi
  echo "==> Code signing with identity: $IDENTITY"
elif [[ "$EXPLICIT" == "1" ]]; then
  echo "error: no code signing identity matching \"$IDENTITY\" (WINSTRIPE_SIGN_IDENTITY) in the keychain." >&2
  echo "       Install it, fix WINSTRIPE_SIGN_IDENTITY / .signing/keychain.env, or use WINSTRIPE_SIGN_IDENTITY=- for ad-hoc." >&2
  exit 1
else
  # No certificate needed: ad-hoc ("Sign to Run Locally") signing runs on this Mac.
  echo "==> No \"$IDENTITY\" identity found; falling back to ad-hoc signing"
  echo "==> Ad-hoc code signing"
  IDENTITY="-"
fi

SIGN_ARGS=(--force --sign "$IDENTITY" --timestamp=none)
if [[ -n "$ENTITLEMENTS" ]]; then
  [[ -f "$ENTITLEMENTS" ]] || { echo "missing entitlements: $ENTITLEMENTS" >&2; exit 1; }
fi

# Sign embedded code inside-out before the outer app, as Xcode does: `find -depth`
# lists children before their parents, so loose Mach-O files (dylibs, Sparkle's
# Autoupdate) are signed before the XPC services, helper apps and frameworks
# that contain them, and each bundle is sealed after its contents. Nested code
# keeps its own entitlements and flags (e.g. Sparkle's sandboxed XPC services).
NESTED_ARGS=("${SIGN_ARGS[@]}" --preserve-metadata=entitlements,flags)
while IFS= read -r nested; do
  if [[ -d "$nested" ]] || { [[ ! -L "$nested" ]] && file -b "$nested" | grep -q 'Mach-O'; }; then
    codesign "${NESTED_ARGS[@]}" "$nested"
  fi
done < <(find "$APP/Contents" -depth \( -type d \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' \) \) -o \
  \( -type f \( -name '*.dylib' -o -perm -111 \) -not -path "$APP/Contents/MacOS/*" \))

if [[ -n "$ENTITLEMENTS" ]]; then
  codesign "${SIGN_ARGS[@]}" --entitlements "$ENTITLEMENTS" "$APP"
else
  codesign "${SIGN_ARGS[@]}" "$APP"
fi
codesign --verify --deep --strict "$APP"
