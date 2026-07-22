#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
configuration=${1:-release}
app_dir="$project_dir/dist/Skin Tone Studio.app"
archive_path="$project_dir/dist/Skin Tone Studio.zip"
staging_root=$(mktemp -d /tmp/skin-tone-studio-build.XXXXXX)
staging_app="$staging_root/Skin Tone Studio.app"
contents_dir="$staging_app/Contents"
trap 'rm -rf "$staging_root"' EXIT

cd "$project_dir"
swift build -c "$configuration" --product SkinToneStudio
binary_dir=$(swift build -c "$configuration" --show-bin-path)

mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp "$binary_dir/SkinToneStudio" "$contents_dir/MacOS/SkinToneStudio"
cp "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"
cp "$project_dir/Resources/AppIcon.icns" "$contents_dir/Resources/AppIcon.icns"
printf 'APPL????' > "$contents_dir/PkgInfo"

xattr -cr "$staging_app"
codesign --force --deep --sign - "$staging_app"
if [[ -d "$app_dir" ]]; then
    rm -rf "$app_dir"
fi
mv "$staging_app" "$app_dir"
xattr -d com.apple.FinderInfo "$app_dir" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "$app_dir" 2>/dev/null || true
codesign --verify --deep --strict "$app_dir"
rm -f "$archive_path"
ditto -c -k --norsrc --keepParent "$app_dir" "$archive_path"
echo "Built: $app_dir"
echo "Archive: $archive_path"
