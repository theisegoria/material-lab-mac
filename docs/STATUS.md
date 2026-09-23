# Material Lab implementation status — 2026-09-23

Material Lab is a standalone, general-purpose local tool. Its C++23 derivation core is compiled into the macOS 27 and iOS 27 apps and exposed through the Mac CLI. Materials remain estimates, and no bundle is automatically admitted into a game runtime.

## Implemented

- CLI derivation of one image or a reviewed catalog batch; flat-safe and material-prior recipes; optional relief mask or authored R16 height; +Y normal, roughness prior, heightfield AO, bent normal option, cavity/convexity/slope/edge, seam checks, and metalness-gated ORM.
- Versioned `.pbrmaterial` exports with semantic labels, complete recipe, per-map encoding/hash/provenance, source hashes, and a strict validator. An optional no-shell local pre-upscale hook can invoke the offline pinned Real-ESRGAN adapter; [the workflow](UPSCALE.md) retains an original-input and processed-image hash plus a verified receipt.
- Native Mac app with editable labels/categories, source and camera inbox, inspected maps, 3×3 and relighting previews, seam diagnostics, reviewed batch progress/cancellation, explicit export, and Bonjour/TLS pairing with Mac approval.
- Native iPhone app with guided capture, Constant Color when supported and fallback provenance, crop-aware confidence, Photos/Files import, semantic labeling, on-device derivation, map preview, Files export, and pinned local transfer to Mac.
- Coordinated, text-free app icons generated with imagegen, packaged in native Mac and iPhone sizes, and [visually inspected](../assets/branding/README.md).

## Verified here

| Gate | Result |
| --- | --- |
| `./scripts/build_and_run.sh cli` | Build succeeded; 2/2 CTests passed, including synthetic geometry, encoding, catalog, bundle-tamper, and pre-upscale-stub cases. |
| `./scripts/build_and_run.sh mac-build` | Native macOS 27 arm64 app built successfully. |
| `./scripts/build_and_run.sh ios-sim` | Native iOS 27 simulator app built successfully. |
| iOS simulator test suite | 11 discovered: 9 passed, 2 short-lived live-link fixture tests skipped in the ordinary suite, 0 failures. Those link cases ran separately against a live Mac listener. |
| iOS Files export | UI test selected a simulator Photos image, assigned a semantic label, derived maps, tapped Save in Files, and produced a `.pbrcapture`. The final Mac CLI accepted its nine maps. |
| Mac/iOS shared-core parity | All nine decoded maps from actual simulator `.pbrcapture` fixtures matched Mac rederivation pixel for pixel at 256²; [exact method and hashes](verification/MAC_IOS_PARITY_2026-09-23.md). |
| Mac export | The Mac app exporter produced `/private/tmp/painted-tile-6cb97b19.pbrmaterial`; final CLI validation passed nine maps, semantic label, and `runtime_admitted=false`. |
| Direct local link | A simulator-to-Mac Bonjour/TLS pinned transfer received an ACK and imported to the camera inbox. Wrong certificate pin, token, interrupted frame, duplicate ID, expired token, and explicit Mac decline were rejected without a new completed inbox item. |
| Optional pinned upscale | Offline pinned Real-ESRGAN x2 and x4 ran on a tiny synthetic CPU input. A fresh x2 run through the CLI hook exported a validated nine-map bundle; forged pre-upscale hashes, dimensions, and receipt fields are rejected. |
| Visual QA | [Synthetic map/relighting sheet](verification/analytic-maps-and-relighting.png), [Mac native views](verification/README.md), and [iOS simulator views](verification/README.md) were visually inspected. |

## Remaining proof limits

- The user chose simulator-only validation. A simulator cannot establish real-camera focus/glare behavior, Constant Color hardware output, or physical-device local-network permission behavior.
- The Mac console became locked before the final GUI Export click. The native app had been visually inspected during derivation and preview, and its current exporter produced a CLI-validated bundle headlessly. Repeat the click after the desktop is unlocked.
- The successful direct link preceded the final listener cleanup; rejection cases were repeated after it. A final positive transfer on a live unlocked session remains useful confirmation.
- The saved bundle validator proves manifest/map integrity and internal pre-upscale claim consistency. The processed image is temporary and is not included in `.pbrmaterial`, so its hash cannot be independently recomputed from a saved bundle alone. Tiny model smoke runs do not establish texture quality or performance at 1K.
