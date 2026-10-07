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
[[ -e "$model" ]] || echo "warning: no learned model at $model; the app will need one imported" >&2

# Remove only this script's outputs: build/dist also holds the CLI archives.
rm -rf "$build" "$dist/staging" "$dist/MaterialLab-$version-macOS.dmg" "$dist/MaterialLab-$version-macOS.dmg.sha256"
mkdir -p "$dist"
(cd "$repo_root/apps/macos" && xcodegen generate -q)
# The Xcode build compiles the model into Contents/Resources/Models when it exists.
xcodebuild -project "$repo_root/apps/macos/MaterialLab.xcodeproj" -scheme MaterialLab -configuration Release \
  -derivedDataPath "$build" CODE_SIGNING_ALLOWED=NO build
app="$build/Build/Products/Release/MaterialLab.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${version//./}" "$app/Contents/Info.plist"
cp "$repo_root/LICENSE" "$repo_root/THIRD_PARTY_NOTICES.md" "$app/Contents/Resources/"

# Sign inside out: the Quick Look extension keeps its sandbox entitlement (--deep would drop it).
codesign --force --options runtime --timestamp --sign "$identity" \
  --entitlements "$repo_root/apps/macos/QuickLookThumbnail/QuickLookThumbnail.entitlements" \
  "$app/Contents/PlugIns/QuickLookThumbnail.appex"
codesign --force --options runtime --timestamp --sign "$identity" "$app"
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
(cd "$dist" && shasum -a 256 "$(basename "$dmg")" | tee "$(basename "$dmg").sha256")
echo "$dmg"
