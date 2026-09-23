#!/usr/bin/env bash
# Build, bundle the learned-normals model, Developer ID sign and package Material Lab for macOS as a .dmg.
# Usage: scripts/package_macos_release.sh VERSION [SIGNING_IDENTITY]
# Needs third_party/moge/build/MoGe2Normals.mlpackage (see docs/LEARNED_NORMALS.md) to bundle the model.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:?usage: package_macos_release.sh VERSION [IDENTITY]}"
identity="${2:-Developer ID Application}"
build="$repo_root/build/macos-release"
dist="$repo_root/build/dist"
model="$repo_root/third_party/moge/build/MoGe2Normals.mlpackage"
model_args=()
[[ -e "$model" ]] && model_args=(-DMATERIAL_LAB_BUNDLE_MODEL="$model")

rm -rf "$build" "$dist" && mkdir -p "$dist"
cmake -S "$repo_root/apps/macos" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release "${model_args[@]}"
cmake --build "$build" --target MaterialLab
app="$build/MaterialLab.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${version//./}" "$app/Contents/Info.plist"
cp "$repo_root/LICENSE" "$repo_root/THIRD_PARTY_NOTICES.md" "$app/Contents/Resources/"

codesign --force --deep --options runtime --timestamp --sign "$identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

staging="$dist/staging"
mkdir -p "$staging"
ditto "$app" "$staging/Material Lab.app"
ln -s /Applications "$staging/Applications"
cp "$repo_root/LICENSE" "$repo_root/THIRD_PARTY_NOTICES.md" "$staging/"
dmg="$dist/MaterialLab-$version-macOS.dmg"
hdiutil create -volname "Material Lab $version" -srcfolder "$staging" -fs APFS -format UDZO -ov "$dmg" >/dev/null
codesign --force --timestamp --sign "$identity" "$dmg"
rm -rf "$staging"
shasum -a 256 "$dmg" | tee "$dmg.sha256"
echo "$dmg"
