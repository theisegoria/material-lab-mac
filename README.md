# Material Lab

Material Lab turns a photograph into an editable set of game-ready PBR texture maps, entirely on your Mac or iPhone. It is a local tool with no accounts and no uploads. It is independent of any game engine and never imports anything into one: you review the maps, then hand the bundle to whatever cooker or DCC pipeline you use.

- **core/**: a versioned, deterministic C++23 derivation library with a stable C ABI, plus the `material-lab` CLI.
- **apps/macos/**: the native macOS 27 Material Lab app. Import photos, tune the recipe with live re-derivation, inspect every map, relight it, spin it on a PBR sphere, tile it, and export.
- **apps/ios/**: the native iOS 27 Material Capture app. Guided camera capture, on-device derivation, and a pinned local link to the Mac.
- **scripts/**: model conversion, an offline pre-upscale adapter, and release packaging.

An RGB photo does not uniquely determine height, normal, occlusion, or roughness. Everything Material Lab derives is an estimate, with its recipe and provenance recorded next to it. Roughness starts from an artist-selected prior; metalness is exported only when you assign it.

## What it derives

From one square sRGB photo: albedo, 16-bit height, tangent-space normal, roughness, ambient occlusion, cavity, convexity, slope and edge maps, with optional bent normals and a packed ORM.

- **Relief** from multi-scale luminance bands with material presets, or from the built-in **learned geometry** stage: Microsoft's MoGe-2 normal estimator (MIT), converted to Core ML and run on the Neural Engine. It reads recesses that a brightness heuristic gets backwards, such as the mortar between bricks.
- **Ambient occlusion** with GTAO's cosine-weighted horizon integral on the heightfield, plus an analytic bent normal.
- **Delighting** that removes uneven lighting from the photo before it becomes false relief.
- **Make tileable** with an aligned minimum-error seam cut for structured textures (brick, tiles, planks), or a histogram-preserving blend for fine noise.
- **Normal convention** selectable between +Y (glTF, OpenGL, Blender, Unity) and −Y (DirectX, Unreal).

Derivation runs on all cores and is bit-for-bit repeatable. A 1K image takes about 0.1 s on an M5; the learned stage adds about 0.3 s.

The method is documented in [docs/DERIVATION.md](docs/DERIVATION.md), the learned stage in [docs/LEARNED_NORMALS.md](docs/LEARNED_NORMALS.md), and the file formats in [docs/BUNDLE_FORMAT.md](docs/BUNDLE_FORMAT.md).

## Download

The macOS app ships as a signed `.dmg` on the [Releases](../../releases) page, with the learned-geometry model built in. It is signed with a Developer ID but not yet notarized, so the first launch needs a confirmation in System Settings › Privacy & Security.

## Build from source

Requirements: Xcode 27, an Apple Silicon Mac, CMake and Ninja. XcodeGen regenerates the iOS project after editing `project.yml`.

    ./scripts/build_and_run.sh cli        # builds the CLI and runs the core and CLI tests
    ./scripts/build_and_run.sh mac        # builds and opens build/macos/MaterialLab.app
    ./scripts/build_and_run.sh ios-sim    # builds the iOS app for the simulator, unsigned

The learned-geometry model is not in the repository. [docs/LEARNED_NORMALS.md](docs/LEARNED_NORMALS.md) shows how to fetch the pinned weights and convert them; the app also accepts a model installed through Settings. `scripts/package_macos_release.sh VERSION` builds, bundles the model, signs and packages the `.dmg`.

## Command line

    build/core/material-lab --input photo.png --output brick.pbrmaterial --label "red brick" --preset stone \
        --polarity -1 --equalize 0.6 --seamless 0.15 --learned-normals third_party/moge/build/MoGe2Normals.mlmodelc
    build/core/material-lab --validate brick.pbrmaterial

See [core/README.md](core/README.md) for every flag, catalog batches, and the optional offline pre-upscale hook.

## Status and evidence

[docs/STATUS.md](docs/STATUS.md) lists what has been verified and how. Verification images are in [docs/verification/](docs/verification/).

## Licence

Material Lab is MIT-licensed. The bundled MoGe-2 model is MIT (Microsoft) with Apache-2.0 DINOv2 modules (Meta); see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Derivation methods follow MaterIA (Adobe), GTAO (Jimenez et al.), histogram-preserving blending (Heitz & Neyret), and image quilting (Efros & Freeman); the glTF 2.0 specification defines the export conventions.
