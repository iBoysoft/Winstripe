#!/bin/sh
# Runs the full verification suite and asserts the user's real defaults domain is unchanged.
# Usage: scripts/verify-prefs-guard.sh [snapshot-dir]
set -u
cd "$(dirname "$0")/.."
DOMAIN=com.iboysoft.winstripe
B=${WINSTRIPE_BIN:-.build/release/Winstripe}
SNAP=${1:-.shots/prefs-guard-$(date +%Y%m%d-%H%M%S)}
TMP=$(mktemp -d)
dump() { defaults export "$DOMAIN" - 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null; }
dump > "$TMP/before.plist"
fail=0
MACOS11_CLEAN=1 MACOS11_OUT="$TMP/macos11" scripts/build-macos11.sh || fail=1
for t in active-display all-displays theme-stack tray-apps tray-overflow ime-always properties-live preview-click vista7-allapps-separator \
         vista7-scroll-hover win10-search win8-anim launch-theme fullscreen l10n dock-autohide duplicates prefs-isolation screen-change symbol-tint theme-hot-reload app-catalog start-banner; do
  if ! "$B" --$t-selftest > "$TMP/$t.log" 2>&1; then echo "FAIL $t"; tail -3 "$TMP/$t.log"; fail=1; fi
done
"$B" --appearance-preview-dump "$TMP/apd" > "$TMP/apd.log" 2>&1 || { echo "FAIL appearance-preview-dump"; fail=1; }
./scripts/snapshot-baseline.sh "$SNAP" > "$TMP/snap.log" 2>&1 || { echo "FAIL snapshots"; tail -3 "$TMP/snap.log"; fail=1; }
dump > "$TMP/after.plist"
if cmp -s "$TMP/before.plist" "$TMP/after.plist"; then
  echo "PASS prefs guard: $DOMAIN unchanged"
else
  echo "FAIL prefs guard: $DOMAIN changed"; diff "$TMP/before.plist" "$TMP/after.plist" | head -20; fail=1
fi
left=$(ls "$HOME/Library/Preferences" | grep -c "Winstripe\.selftest" || true)
[ "$left" = 0 ] && echo "PASS no leftover selftest suites" || { echo "FAIL $left leftover Winstripe.selftest.* plists"; fail=1; }
echo "selftests+guard fail=$fail"
rm -rf "$TMP"
exit $fail
