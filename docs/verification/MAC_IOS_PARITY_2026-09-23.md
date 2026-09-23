# Mac/iOS derivation parity — 2026-09-23

An actual iOS 27 simulator run of `MaterialCaptureTests` wrote a `.pbrcapture` envelope. The standalone macOS `material-lab --validate` accepted it with nine derived maps. I decoded the envelope's canonical PNG source, ran the macOS CLI using the captured recipe, decoded both sets of PNG maps, and compared every sample in NumPy. This tests the same C++23 core through independent iOS and macOS image adapters and PNG encoders.

| Fixture parameter | Value |
| --- | --- |
| Capture ID | `241E56EA-04DA-4884-AF29-1356E51D7A3E` |
| Canonical source SHA-256 | `e20f406d5923bc295c4b87903bdc6f55a7ae1057bba269513c08165262e12bbe` |
| Source size | 256 × 256 PNG |
| Algorithm | `PBRLabVersion() = 1.0.0` |
| Recipe | stone; height strength 0.22; polarity +1; perceptual roughness base 0.78; roughness variation 0.15; AO radius 10 pixels; tile wrap on; bent normal off; metalness unassigned |

`albedo`, `height`, `normal`, `roughness`, `ao`, `cavity`, `convexity`, `slope`, and `edge` were **pixel-exact** after PNG decoding: zero differing samples and maximum/mean absolute difference of zero for each map. `height` was compared as 16-bit integer samples; the remaining maps were compared as 8-bit channel samples. The PNG file bytes themselves were not expected to match because encoders may use different metadata or compression.

The same CLI build passed both CTest targets after fallback-photo validation was added. The capture fixture did not include fallback photo bytes; CLI synthetic tests separately verify valid fallback MIME/SHA/dimensions and reject fallback hash or dimension tampering. This parity result is from simulator-generated input, not a physical camera capture or a material-quality approval.
