#!/usr/bin/env bash
# Copies the LaunchAtLogin helper app into the app's LoginItems directory.
set -euo pipefail

resource_bundle="${LAUNCH_AT_LOGIN_RESOURCE_BUNDLE:-${BUILT_PRODUCTS_DIR:-}/LaunchAtLogin_LaunchAtLogin.bundle}"
if [[ ! -d "$resource_bundle" ]]; then
    echo "LaunchAtLogin resource bundle not found; skipping helper copy" >&2
    exit 0
fi

if [[ -n "${MACOSX_DEPLOYMENT_TARGET:-}" && "$(printf '%s\n' "${MACOSX_DEPLOYMENT_TARGET}" 10.14.4 | sort -V | head -n1)" == "10.14.4" ]]; then
    helper_name="LaunchAtLoginHelper"
    checksum="0a3d09438fb595802d554ce0a7c4ba8e1d2d91d5170362adc965da82e70d74cb"
else
    helper_name="LaunchAtLoginHelper-with-runtime"
    checksum="98ef556b490e02f4084a11d8a07c33a880177a9816b355885a11f58c95876d62"
fi

helper_zip="$resource_bundle/$helper_name.zip"
[[ -f "$helper_zip" ]] || helper_zip="$resource_bundle/Contents/Resources/$helper_name.zip"
[[ -f "$helper_zip" ]] || { echo "missing LaunchAtLogin helper archive: $helper_name.zip" >&2; exit 1; }

actual_checksum="$(shasum -a 256 "$helper_zip" | awk '{print $1}')"
[[ "$actual_checksum" == "$checksum" ]] || {
    echo "wrong checksum for LaunchAtLogin helper: $actual_checksum" >&2
    exit 1
}

contents_path="${LAUNCH_AT_LOGIN_CONTENTS_PATH:-${BUILT_PRODUCTS_DIR:-}/${CONTENTS_FOLDER_PATH:-Contents}}"
login_items="$contents_path/Library/LoginItems"
login_helper_path="$login_items/LaunchAtLoginHelper.app"
rm -rf "$login_helper_path"
mkdir -p "$login_items"
unzip -q "$helper_zip" -d "$login_items"

bundle_identifier="${PRODUCT_BUNDLE_IDENTIFIER:-com.iboysoft.winstripe}-LaunchAtLoginHelper"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_identifier" "$login_helper_path/Contents/Info.plist"

# The helper archive is intentionally shipped with an ad-hoc signature by the
# LaunchAtLogin package.  A custom Xcode copy phase runs before Xcode signs the
# outer app, and Xcode does not discover this nested app on its own.  Re-sign it
# here with the archive's identity so archive validation sees a complete
# signing chain (including the Swift runtime dylibs inside the helper).
#
# Xcode's "Sign to Run Locally" (the project default) expands the identity to
# "-"; re-sign ad-hoc then too, because rewriting CFBundleIdentifier above
# invalidates the helper's original signature.
#
# The hand-built bundle path does not provide an Xcode signing identity; its
# outer sign.sh pass signs nested code after this script returns.
signing_identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [[ -n "$signing_identity" && "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]]; then
    helper_entitlements="$resource_bundle/LaunchAtLogin.entitlements"
    [[ -f "$helper_entitlements" ]] || helper_entitlements="$resource_bundle/Contents/Resources/LaunchAtLogin.entitlements"

    sign_args=(--force --deep --options=runtime --sign "$signing_identity")
    if [[ -n "${CODE_SIGN_ENTITLEMENTS:-}" && -f "$helper_entitlements" ]]; then
        sign_args+=(--entitlements "$helper_entitlements")
    fi

    echo "Signing LaunchAtLogin helper with Xcode identity ${EXPANDED_CODE_SIGN_IDENTITY_NAME:-$signing_identity}"
    codesign "${sign_args[@]}" "$login_helper_path"
fi

# The helper is supplied as a prebuilt archive by LaunchAtLogin, so Xcode does
# not create a dSYM for it when archiving the containing app. Generate one from
# the extracted universal binary and place it next to the app dSYM so archive
# validation can match both helper UUIDs.
if [[ "${DEBUG_INFORMATION_FORMAT:-}" == "dwarf-with-dsym" && -n "${DWARF_DSYM_FOLDER_PATH:-}" ]]; then
    helper_binary="$login_helper_path/Contents/MacOS/LaunchAtLoginHelper"
    helper_dsym="$DWARF_DSYM_FOLDER_PATH/LaunchAtLoginHelper.app.dSYM"
    if [[ -f "$helper_binary" ]]; then
        mkdir -p "$DWARF_DSYM_FOLDER_PATH"
        dsymutil "$helper_binary" -o "$helper_dsym"
        echo "Generated LaunchAtLogin helper dSYM at $helper_dsym"
    fi
fi

# The package resource bundle is only a build-time container for the helper
# archive. Xcode copies it into the app's Resources directory, where its two
# ad-hoc-signed helper archives would still be inspected by archive/notary
# validation. Keep only the extracted, re-signed LoginItems app in a release
# archive. For a hand-built bundle this path normally does not exist.
if [[ "${ONLY_ACTIVE_ARCH:-NO}" != "YES" ]]; then
    embedded_resource_bundle="$contents_path/Resources/$(basename "$resource_bundle")"
    if [[ -d "$embedded_resource_bundle" ]]; then
        rm -rf "$embedded_resource_bundle"
        echo "Removed build-only LaunchAtLogin resource bundle"
    fi
fi
echo "Copied LaunchAtLogin helper to $login_helper_path"
