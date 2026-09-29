#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
configuration=${1:-release}
app_dir="$project_dir/dist/Skin Tone Studio.app"
archive_path="$project_dir/dist/Skin Tone Studio.zip"
dmg_path="$project_dir/dist/Skin Tone Studio.dmg"
staging_root=$(mktemp -d /tmp/skin-tone-studio-build.XXXXXX)
staging_app="$staging_root/Skin Tone Studio.app"
contents_dir="$staging_app/Contents"
trap 'rm -rf "$staging_root"' EXIT

# Signing: uses the first "Developer ID Application" identity in the keychain unless SIGN_IDENTITY
# is set; SIGN_IDENTITY=- forces an ad-hoc build. Set NOTARY_PROFILE to a profile created with
# `xcrun notarytool store-credentials` to notarize and staple the app and disk image.
sign_identity=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -n 1)}
sign_identity=${sign_identity:--}
notary_profile=${NOTARY_PROFILE:-}
entitlements="$project_dir/Resources/SkinToneStudio.entitlements"

sign() {
    if [[ "$sign_identity" == "-" ]]; then
        codesign --force --sign - "$@"
    else
        codesign --force --timestamp --options runtime --sign "$sign_identity" "$@"
    fi
}

notarize() {
    [[ -n "$notary_profile" ]] || return 0
    xcrun notarytool submit "$1" --keychain-profile "$notary_profile" --wait
}

cd "$project_dir"
swift build -c "$configuration" --product SkinToneStudio
binary_dir=$(swift build -c "$configuration" --show-bin-path)

mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources" "$contents_dir/Frameworks"
cp "$binary_dir/SkinToneStudio" "$contents_dir/MacOS/SkinToneStudio"
ditto --norsrc "$binary_dir/Sparkle.framework" "$contents_dir/Frameworks/Sparkle.framework"
cp "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"
cp "$project_dir/Resources/AppIcon.icns" "$contents_dir/Resources/AppIcon.icns"
ditto --norsrc "$project_dir/.build/checkouts/Sparkle/LICENSE" \
    "$contents_dir/Resources/Sparkle-LICENSE.txt"
printf 'APPL????' > "$contents_dir/PkgInfo"

install_name_tool -add_rpath '@executable_path/../Frameworks' "$contents_dir/MacOS/SkinToneStudio"

chmod -R u+w "$staging_app"
xattr -cr "$staging_app"
# Sign inside-out (never --deep): Sparkle's helpers first, then the framework, then the app.
sparkle="$contents_dir/Frameworks/Sparkle.framework/Versions/B"
sign "$sparkle/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
sign "$sparkle/Autoupdate"
sign "$sparkle/Updater.app"
sign "$contents_dir/Frameworks/Sparkle.framework"
sign --entitlements "$entitlements" "$staging_app"
if [[ -d "$app_dir" ]]; then
    rm -rf "$app_dir"
fi
mv "$staging_app" "$app_dir"
xattr -d com.apple.FinderInfo "$app_dir" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "$app_dir" 2>/dev/null || true
codesign --verify --deep --strict "$app_dir"
rm -f "$archive_path"
ditto -c -k --norsrc --keepParent "$app_dir" "$archive_path"
if [[ -n "$notary_profile" && "$sign_identity" != "-" ]]; then
    notarize "$archive_path"
    xcrun stapler staple "$app_dir"
    # Re-archive so the Sparkle update ZIP carries the stapled ticket.
    rm -f "$archive_path"
    ditto -c -k --norsrc --keepParent "$app_dir" "$archive_path"
fi

dmg_root="$staging_root/dmg"
mkdir -p "$dmg_root"
ditto --norsrc "$app_dir" "$dmg_root/Skin Tone Studio.app"
ln -s /Applications "$dmg_root/Applications"
codesign --verify --deep --strict "$dmg_root/Skin Tone Studio.app"
rm -f "$dmg_path"
hdiutil create -quiet -volname "Skin Tone Studio" -srcfolder "$dmg_root" -ov -format UDZO "$dmg_path"
if [[ "$sign_identity" != "-" ]]; then
    codesign --force --timestamp --sign "$sign_identity" "$dmg_path"
    if [[ -n "$notary_profile" ]]; then
        notarize "$dmg_path"
        xcrun stapler staple "$dmg_path"
    fi
fi
echo "Signed with: $sign_identity${notary_profile:+ (notarized)}"
echo "Built: $app_dir"
echo "Archive: $archive_path"
echo "Disk image: $dmg_path"
