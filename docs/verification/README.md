# Verification artifacts

- [Mac/iOS decoded map parity](MAC_IOS_PARITY_2026-09-23.md) records pixel-exact agreement for the nine mandatory maps using an actual iOS simulator `.pbrcapture` and the macOS CLI on the same canonical source and recipe.
- [Analytic maps and relighting](analytic-maps-and-relighting.png) uses a synthetic authored R16 height field with a bump, pit, and ridge. The color image and height override passed through the shared CLI. The sheet shows exported maps and three tangent-space Lambertian relights. It checks map direction and export behavior visually; it does not show unique height recovery from albedo.
- [macOS Normal 3×3 view](macos-normal-3x3.png) and [macOS relight 3×3 view](macos-relight-3x3.png) are screenshots of the running native app after deriving a simulator-imported checkerboard capture. The flat preset correctly produces a flat normal, while the relighting preview exposes a strong albedo seam. The app reports opposite-edge diagnostics and labels the maps as estimates.
- [iOS map review](ios-map-review.png) and [iOS export/link controls](ios-export-link.png) are screenshots from the iOS 27 simulator after Photos import, semantic labeling, on-device derivation, and map review. The Files exporter saved a `.pbrcapture` with nine maps; the macOS CLI validated that saved file.

The simulator has no physical camera feed. These artifacts do not claim physical-camera image quality, Constant Color hardware behavior, real-device local-network permission UX, or game-runtime admission.
