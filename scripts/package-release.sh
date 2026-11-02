#!/usr/bin/env bash
# Builds the Winstripe scheme with Xcode as a universal Release app and zips it. No certificate is
# needed: the project's default "Sign to Run Locally" signs ad-hoc, which Apple silicon requires to launch.
# Extra arguments go to xcodebuild. Prints the zip's path last.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${WINSTRIPE_RELEASE_DIR:-build/release}"
DERIVED="$OUT/DerivedData"
APP="$DERIVED/Build/Products/Release/Winstripe.app"
BIN="$APP/Contents/MacOS/Winstripe"

xcodebuild -version >&2
xcodebuild -project Winstripe.xcodeproj -scheme Winstripe -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
    -disableAutomaticPackageResolution ONLY_ACTIVE_ARCH=NO "$@" build >&2

for arch in arm64 x86_64; do
    lipo "$BIN" -verify_arch "$arch" || { echo "FAIL the app has no $arch slice" >&2; exit 1; }
done
# Xcode keeps the Hardened Runtime flag Sparkle ships with, so an ad-hoc build re-signs its code without it,
# inside out, keeping identifiers and entitlements. A real identity from Signing.local.xcconfig keeps the flag.
if [[ "$(codesign -dv "$APP" 2>&1)" == *"(adhoc"* ]]; then
    while IFS= read -r path; do
        if [[ -d "$path" ]] || file -b "$path" | grep -q 'Mach-O'; then
            codesign --force --sign - --timestamp=none --preserve-metadata=identifier,entitlements "$path" >&2
        fi
    done < <(find "$APP" -depth \( -type d \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' \) \) -o \
        \( -type f \( -name '*.dylib' -o -perm -111 \) -not -path "$APP/Contents/MacOS/*" \))
fi
codesign --verify --deep --strict "$APP" >&2
"$BIN" --resource-bundle-selftest >&2
"$BIN" --l10n-selftest >&2

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="$OUT/Winstripe-$VERSION.zip"
rm -f "$ZIP"
# ditto keeps the symlinks and code signatures inside the frameworks, which plain zip can break.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "$ZIP"
