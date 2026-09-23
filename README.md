# Material Lab

Material Lab is a general-purpose, local tool for creating editable game PBR texture estimates from photographs or other color images. It is independent of any game engine. The repository contains:

- core/: one versioned C++23 derivation library and the material-lab CLI.
- apps/macos/: native macOS 27 Material Lab app for reviewing images, adjusting recipes, inspecting maps, and exporting bundles.
- apps/ios/: native iOS 27 Material Capture app for camera capture, on-device derivation, and local transfer to Mac.
- assets/branding/: source artwork for the native app icon sets.

An RGB image does not uniquely determine surface height, normal, ambient occlusion, or roughness. Derived maps are estimates. Roughness begins with an artist-selected material prior. Metalness is exported only when an artist explicitly assigns it. Capture mode and confidence remain in provenance. Material Lab never automatically imports results into a game.

## Build

Requirements: Xcode 27, Apple Silicon Mac, CMake, Ninja; XcodeGen is needed to regenerate the iOS project after editing project.yml.

    ./scripts/build_and_run.sh cli
    ./scripts/build_and_run.sh mac
    ./scripts/build_and_run.sh ios-sim

The Mac mode builds and opens build/macos/MaterialLab.app; mac-build only builds it. The iOS simulator mode builds the app and does not need signing. The CLI mode builds and runs core tests. The optional local pre-upscale workflow is documented in [docs/UPSCALE.md](docs/UPSCALE.md). Simulator UI and direct-link tests are recorded in [docs/verification/](docs/verification/); a real iPhone is required to validate physical camera and device permission behavior.

## Sources and limits

The derivation approach follows the distinction between inferred geometry and assigned material parameters discussed by Adobe MaterIA: https://perso.telecom-paristech.fr/boubek/papers/MaterIA/MaterIA_lowres.pdf . Horizon-based AO is informed by HBAO: https://developer.download.nvidia.com/presentations/2008/SIGGRAPH/HBAO_SIG08b.pdf . Exported packed material conventions follow glTF 2.0: https://github.com/KhronosGroup/glTF/blob/main/specification/2.0/Specification.adoc . See [implementation status](docs/STATUS.md) and docs/ for format, provenance, and verification notes.
