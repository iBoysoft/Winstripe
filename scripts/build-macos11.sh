#!/usr/bin/env bash
# Builds Winstripe for the macOS 11.0 deployment target (arm64 + x86_64) and fails on any compiler
# error or warning, or if a binary's LC_BUILD_VERSION minos is not 11.0. Writes a universal binary
# and the resource bundle to $MACOS11_OUT (default .build/macos11).
#
# Why: the default SwiftPM build system ("swiftbuild", Swift 6.4 / Xcode 27) raises the package's
# .macOS(.v11) to macOS 12.0 and ignores -Xswiftc -target, so macOS 12-only APIs pass availability
# checking and the shipped binary refuses to launch on macOS 11. The native build system honours
# an explicit -target.
#
# MACOS11_CLEAN=1 rebuilds from scratch so warnings in unchanged files are reported too.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
CACHE="${SWIFTPM_CACHE_PATH:-/tmp/swiftpm-cache}"
OUT="${MACOS11_OUT:-.build/macos11}"
MIN=11.0
mkdir -p "$OUT"
fail=0
for arch in arm64 x86_64; do
    scratch="$OUT/$arch"
    [[ "${MACOS11_CLEAN:-0}" == 1 ]] && rm -rf "$scratch"
    log="$OUT/build-$arch.log"
    if ! swift build -c "$CONFIG" --build-system native --cache-path "$CACHE" --scratch-path "$scratch" \
        --arch "$arch" -Xswiftc -target -Xswiftc "$arch-apple-macos$MIN" -Xcc -target -Xcc "$arch-apple-macos$MIN" > "$log" 2>&1; then
        echo "FAIL macOS $MIN $arch build"
        grep -E "error:" "$log" | sort -u | head -60
        fail=1
        continue
    fi
    diagnostics=$(grep -E "(error|warning):" "$log" | grep -v "'--build-system native' has been deprecated" | sort -u || true)
    if [[ -n "$diagnostics" ]]; then
        echo "FAIL macOS $MIN $arch diagnostics:"
        echo "$diagnostics" | head -60
        fail=1
    fi
    bin="$scratch/$arch-apple-macosx/$CONFIG/Winstripe"
    minos=$(vtool -show-build "$bin" | awk '/minos/ {print $2; exit}')
    if [[ "$minos" != "$MIN" ]]; then echo "FAIL $arch minos=$minos (expected $MIN)"; fail=1; fi
done
[[ $fail == 0 ]] || exit 1
lipo -create "$OUT/arm64/arm64-apple-macosx/$CONFIG/Winstripe" "$OUT/x86_64/x86_64-apple-macosx/$CONFIG/Winstripe" \
    -output "$OUT/Winstripe"
rm -rf "$OUT/Winstripe_Winstripe.bundle"
cp -R "$OUT/arm64/arm64-apple-macosx/$CONFIG/Winstripe_Winstripe.bundle" "$OUT/"
rm -rf "$OUT/LaunchAtLogin_LaunchAtLogin.bundle"
cp -R "$OUT/arm64/arm64-apple-macosx/$CONFIG/LaunchAtLogin_LaunchAtLogin.bundle" "$OUT/"
echo "PASS macOS $MIN build ($(lipo -archs "$OUT/Winstripe"), 0 warnings, minos $MIN)"
