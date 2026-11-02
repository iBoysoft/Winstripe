#!/usr/bin/env bash
# Builds Winstripe (release) and wraps the binary into dist/Winstripe.app.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="dist/Winstripe.app"
VERSION="1.0.0"
SWIFT_BIN="$(xcrun --find swift)"
SWIFT_TOOLCHAIN_USR="$(cd "$(dirname "$SWIFT_BIN")/.." && pwd)"
SWIFT_CONCURRENCY_RUNTIME="${WINSTRIPE_SWIFT_CONCURRENCY_RUNTIME:-$SWIFT_TOOLCHAIN_USR/lib/swift-5.5/macosx/libswift_Concurrency.dylib}"

echo "==> macOS 11.0 build (arm64 + x86_64) -c $CONFIG"
# Enforces the 11.0 deployment target; see scripts/build-macos11.sh for why the default
# SwiftPM build system cannot be used for shipping.
MACOS11_OUT=".build/macos11"
CONFIG="$CONFIG" MACOS11_OUT="$MACOS11_OUT" scripts/build-macos11.sh
BIN_DIR="$MACOS11_OUT"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Winstripe" "$APP/Contents/MacOS/Winstripe"

# Sparkle is used by direct-download builds only. SwiftPM exposes its universal
# framework through the binary artifact cache; copy it into the app so the
# executable's @rpath reference and Sparkle's installer services remain inside
# the signed bundle.
SPARKLE_FRAMEWORK="${WINSTRIPE_SPARKLE_FRAMEWORK:-$PWD/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework}"
if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
    SPARKLE_FRAMEWORK="$(find "$PWD/.build/artifacts" -type d -path '*/Sparkle.xcframework/*/Sparkle.framework' -print -quit 2>/dev/null || true)"
fi
if [[ -z "$SPARKLE_FRAMEWORK" || ! -d "$SPARKLE_FRAMEWORK" ]]; then
    echo "FAIL Sparkle.framework not found; set WINSTRIPE_SPARKLE_FRAMEWORK to its path" >&2
    exit 1
fi
cp -R "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/"

# Match Xcode's Archive behavior: ship the active Xcode toolchain's
# back-deployment concurrency runtime and make it discoverable from the app.
# Do not substitute an older Swift runtime here; it may require Core symbols
# that macOS 11's system Swift runtime does not provide.
if [[ ! -f "$SWIFT_CONCURRENCY_RUNTIME" ]]; then
    echo "FAIL missing Swift Concurrency runtime: $SWIFT_CONCURRENCY_RUNTIME" >&2
    exit 1
fi
cp "$SWIFT_CONCURRENCY_RUNTIME" "$APP/Contents/Frameworks/libswift_Concurrency.dylib"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP/Contents/MacOS/Winstripe"
RES="$APP/Contents/Resources"
SRC_RES="Sources/Winstripe/Resources"

# Xcode-style layout: lproj folders, Themes/, Assets.car and AppIcon.icns directly in Contents/Resources,
# read through Bundle.main. The SwiftPM resource bundle is a dev-only artifact and is never shipped.
echo "==> Resources"
for item in "$SRC_RES"/*; do
    name="$(basename "$item")"
    case "$name" in
        Assets.xcassets) ;;                       # compiled by actool below
        *.lproj)
            for strings in "$item"/*.strings; do plutil -lint -s "$strings"; done
            cp -R "$item" "$RES/$name" ;;         # keeps the original case (pt-BR.lproj)
        *) cp -R "$item" "$RES/$name" ;;
    esac
done
scripts/gen-builtin-themes.sh --check
mkdir -p "$RES/Themes"
cp Themes/*.json "$RES/Themes/"

echo "==> Asset catalog (actool)"
PARTIAL_PLIST="$(mktemp -t winstripe-assets).plist"
ACTOOL_LOG="$(mktemp -t winstripe-actool)"
if ! xcrun actool "$SRC_RES/Assets.xcassets" --compile "$RES" --platform macosx --target-device mac \
    --minimum-deployment-target 11.0 --app-icon AppIcon --output-partial-info-plist "$PARTIAL_PLIST" \
    --output-format human-readable-text --warnings --errors --notices >"$ACTOOL_LOG" 2>&1; then
    cat "$ACTOOL_LOG" >&2
    echo "FAIL actool" >&2
    exit 1
fi
if grep -Eiq '(warning|error):' "$ACTOOL_LOG"; then
    cat "$ACTOOL_LOG" >&2
    echo "FAIL actool reported warnings" >&2
    exit 1
fi
rm -f "$ACTOOL_LOG"

printf 'APPL????' > "$APP/Contents/PkgInfo"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>zh-Hans</string><string>zh-Hant</string><string>fr</string><string>es</string><string>pt-BR</string><string>pt</string><string>ja</string><string>ko</string><string>de</string></array>
    <key>CFBundleExecutable</key><string>Winstripe</string>
    <key>CFBundleIdentifier</key><string>com.iboysoft.winstripe</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Winstripe</string>
    <key>CFBundleDisplayName</key><string>Winstripe</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSUIElement</key><true/>
    <key>SUFeedURL</key><string>https://github.com/iBoysoft/Winstripe</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>Winstripe asks apps to reopen a window when you click their taskbar button, like the Dock.</string>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 iBoysoft. MIT License.</string>
</dict>
</plist>
PLIST
/usr/libexec/PlistBuddy -c "Merge $PARTIAL_PLIST" "$APP/Contents/Info.plist" >/dev/null
rm -f "$PARTIAL_PLIST"
plutil -lint -s "$APP/Contents/Info.plist"

echo "==> LaunchAtLogin helper"
MACOSX_DEPLOYMENT_TARGET=11.0 \
PRODUCT_BUNDLE_IDENTIFIER=com.iboysoft.winstripe \
LAUNCH_AT_LOGIN_RESOURCE_BUNDLE="$BIN_DIR/LaunchAtLogin_LaunchAtLogin.bundle" \
LAUNCH_AT_LOGIN_CONTENTS_PATH="$APP/Contents" \
scripts/copy-launch-at-login-helper.sh

echo "==> Layout checks"
fail_layout() { echo "FAIL packaged layout: $1" >&2; exit 1; }
if [[ -n "$(find "$APP" -name '*.bundle' -print -quit)" ]]; then
    fail_layout "nested resource bundle: $(find "$APP" -name '*.bundle' | tr '\n' ' ')"
fi
[[ -f "$RES/Assets.car" ]] || fail_layout "Assets.car missing"
[[ -f "$RES/AppIcon.icns" ]] || fail_layout "AppIcon.icns missing"
for key in CFBundleIconFile CFBundleIconName; do
    [[ "$(/usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist" 2>/dev/null)" == "AppIcon" ]] \
        || fail_layout "Info.plist $key is not AppIcon"
done
for loc in en zh-Hans zh-Hant fr es pt-BR pt ja ko de; do
    [[ -f "$RES/$loc.lproj/Localizable.strings" ]] || fail_layout "$loc.lproj/Localizable.strings missing"
done
for theme in Themes/*.json; do
    cmp -s "$theme" "$RES/$theme" || fail_layout "$RES/$theme missing or different"
done

# Prefer stable local identity when present; fall back to ad-hoc (other machines).
./scripts/sign.sh "$APP"

# The shipped app must find its resources inside itself (Bundle.main), not via the build directory.
if ! "$APP/Contents/MacOS/Winstripe" --resource-bundle-selftest || ! "$APP/Contents/MacOS/Winstripe" --l10n-selftest \
    || ! "$APP/Contents/MacOS/Winstripe" --collections-selftest; then
    echo "FAIL bundled app cannot resolve its resources" >&2
    exit 1
fi

echo "Built $(pwd)/$APP"
