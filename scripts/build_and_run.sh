#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
mode="${1:-help}"
case "$mode" in
  cli)
    cmake -S "$repo_root/core" -B "$repo_root/build/core" -G Ninja
    cmake --build "$repo_root/build/core"
    ctest --test-dir "$repo_root/build/core" --output-on-failure
    ;;
  mac|mac-build)
    # The Xcode project is generated from apps/macos/project.yml (xcodegen); it is the primary Mac build.
    (cd "$repo_root/apps/macos" && xcodegen generate -q)
    xcodebuild -project "$repo_root/apps/macos/MaterialLab.xcodeproj" -scheme MaterialLab \
      -configuration Release -derivedDataPath "$repo_root/build/macos-xcode" build
    if [[ "$mode" == mac ]]; then
      open "$repo_root/build/macos-xcode/Build/Products/Release/MaterialLab.app"
    fi
    ;;
  mac-cmake)
    # Fallback CMake build of the same sources (used by the off-screen snapshot harness scripts).
    cmake -S "$repo_root/apps/macos" -B "$repo_root/build/macos" -G Ninja
    cmake --build "$repo_root/build/macos" --target MaterialLab
    ;;
  ios-sim)
    (cd "$repo_root/apps/ios" && xcodegen generate -q)
    xcodebuild -project "$repo_root/apps/ios/MaterialCapture.xcodeproj" \
      -scheme MaterialCapture \
      -sdk iphonesimulator \
      -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath "$repo_root/build/ios-derived" \
      CODE_SIGNING_ALLOWED=NO build
    ;;
  *)
    cat <<'HELP'
Usage: scripts/build_and_run.sh <cli|mac|mac-build|mac-cmake|ios-sim>
  cli       Build CLI and run core tests
  mac       Build and open macOS app
  mac-build Build macOS app only (Xcode project)
  mac-cmake Build macOS app with the fallback CMake build
  ios-sim   Build iOS Simulator app without signing
HELP
    if [[ "$mode" != help ]]; then exit 2; fi
    ;;
esac
