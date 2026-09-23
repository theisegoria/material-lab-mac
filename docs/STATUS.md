# Material Lab implementation status — 2026-09-23 (algorithm 1.2.0)

Material Lab is a standalone, general-purpose local tool. Its C++23 derivation core is compiled into the macOS 27 and iOS 27 apps and exposed through the Mac CLI. Materials remain estimates, and no bundle is automatically admitted into a game runtime.

## Implemented

- **Core 1.2.0.** +Y / green-up normals with a DirectX option; GTAO cosine-weighted horizon AO with per-pixel open-sky normalization and an analytic bent normal; Scharr gradients and Gaussian-approximating relief bands; micro-contrast roughness variation centred on the prior; delighting; make-tileable with an aligned minimum-error seam cut (default) or a histogram-preserving blend; a guide-normal input that integrates learned normals to height with a multigrid Poisson solver; deterministic row-parallel derivation.
- **Learned geometry.** MoGe-2 ViT-S normals (MIT) converted to a 518² fp16 Core ML model, run with 50 %-overlap tiles. CLI (`--learned-normals`), macOS (Settings › Learned Geometry, built-in model, Learned geometry slider) and iOS. Every export records the model identity, compute units, tiling and a hash of the guide normals.
- **CLI.** Hardened JSON handling (orderly exit 1, no aborts), symlink- and traversal-safe catalogs, a validator that rejects forged manifests, atomic in-memory PNG writing with adaptive filtering, concurrent map encoding, EXIF orientation, unpremultiplied decode, a timed-out and signal-forwarded pre-upscale child, and order-independent recipe flags.
- **macOS app.** Native Liquid Glass design: sidebar, canvas with floating glass controls, inspector with grouped recipe sections, map strip with ⌘1–9, before/after split, 3×3 tile view with a tiling-quality card, RealityKit PBR preview, debounced live re-derivation, per-source recipes, drag and drop, Bonjour/TLS pairing with per-capture approval. Core compiled at -O3.
- **iOS app.** Full-bleed camera with glass controls, level and glare hints, Vision auto-crop, detented recipe sheet, live 512² preview, 512–4K output, tiled / lit sphere / compare modes, capture persistence, always-on privacy scrubbing of originals, Files export and pinned local transfer.

## Verified here

| Gate | Result |
| --- | --- |
| `./scripts/build_and_run.sh cli` | Build succeeded; both CTests pass, including the 1K threaded-determinism test. Core tests assert in Release builds. |
| Core convention and AO | Tests assert +Y ramp encoding, the DirectX flip, exactly unoccluded tilted planes, pit occlusion, and a guide-normal round trip within 0.45 8-bit levels. |
| Core performance (M5, -O3) | 1024² stone: 234 ms (1.0.0) → 106 ms; 2048²: 955 ms → 643 ms, with 2.7× more AO samples. Guided 1024²: 188 ms. |
| Tiling | Seam cut: smooth-pattern wrap mismatch 0.039 → 0.008; 192 vs 1224 intermediate pixels against the blend on stripes. [Brick comparison](verification/tiling-seam-cut-vs-blend.png). |
| Learned normals | Core ML matches stock PyTorch within 0.045° mean / 0.23° p99; brick tops read up (+0.034 green) and bottoms down (−0.045). [Analytic vs learned on brick](verification/learned-normals-brick-compare.png). 1K learned CLI export 1.15 s warm. |
| `./scripts/build_and_run.sh mac-build` | Native macOS 27 arm64 app builds with no warnings; a weight-1 export validates with nine maps. Off-screen renders of every view in light and dark: `verification/macos-1.1-*.png`, `macos-1.2-learned-*.png`. |
| `./scripts/build_and_run.sh ios-sim` | Native iOS 27 simulator app builds; 17 unit tests pass (2 live-link fixtures skipped), 3 UI tests pass; exported `.pbrcapture` files validate with the CLI. Simulator screenshots in light and dark: `verification/ios-1.1-*.png`. |
| Mac/iOS parity (1.0.0) | [Pixel-exact decoded maps](verification/MAC_IOS_PARITY_2026-09-23.md) from real simulator captures. Not yet repeated for 1.2.0. |

## Remaining proof limits

- Simulator-only validation on iOS. No physical camera, Constant Color hardware, or real-device local-network permission behaviour has been tested.
- Whole-window screen capture is unavailable on this machine, so the macOS Liquid Glass surfaces were verified through the app's own off-screen renders, which draw glass and vibrancy as flat regions. The layout, controls and map rendering were checked; the material of the glass itself was not.
- The Neural Engine runs the learned model in fp16; output can differ slightly between chips and OS versions. CPU-only mode is more reproducible.
- Mac/iOS pixel parity has not been re-measured for algorithm 1.2.0.
- Algorithm 1.0.0 bundles have inverted green in their normal maps; the validator warns, and they should be re-derived.
- The release app is Developer ID signed but not notarized.
