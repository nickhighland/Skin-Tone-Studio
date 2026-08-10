#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
version=$(plutil -extract CFBundleShortVersionString raw "$project_dir/Resources/Info.plist")
tag="v$version"
account="studio.skintone.camera"
release_base="https://github.com/nickhighland/Skin-Tone-Studio/releases/download/$tag"
release_page="https://github.com/nickhighland/Skin-Tone-Studio/releases/tag/$tag"
tools_dir="$project_dir/.build/artifacts/sparkle/Sparkle/bin"
source_zip="$project_dir/dist/Skin Tone Studio.zip"
source_dmg="$project_dir/dist/Skin Tone Studio.dmg"
release_zip="$project_dir/dist/Skin-Tone-Studio-$version.zip"
release_dmg="$project_dir/dist/Skin-Tone-Studio-$version.dmg"
staging_dir=$(mktemp -d /tmp/skin-tone-studio-appcast.XXXXXX)
trap 'rm -rf "$staging_dir"' EXIT

if [[ ! -x "$tools_dir/generate_appcast" ]]; then
    echo "Sparkle tools are missing. Run: swift package resolve"
    exit 1
fi
if [[ ! -f "$source_zip" || ! -f "$source_dmg" ]]; then
    echo "Release artifacts are missing. Run: ./scripts/build-app.sh"
    exit 1
fi

ditto "$source_zip" "$release_zip"
ditto "$source_dmg" "$release_dmg"
ditto "$release_zip" "$staging_dir/${release_zip:t}"

"$tools_dir/generate_appcast" \
    --account "$account" \
    --download-url-prefix "$release_base/" \
    --link "$release_page" \
    --maximum-versions 1 \
    --maximum-deltas 0 \
    "$staging_dir"

ditto "$staging_dir/appcast.xml" "$project_dir/dist/appcast.xml"
echo "Update archive: $release_zip"
echo "Disk image: $release_dmg"
echo "Signed appcast: $project_dir/dist/appcast.xml"
