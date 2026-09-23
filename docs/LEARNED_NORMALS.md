# Learned guide normals (MoGe-2)

Material Lab can blend geometry from a learned monocular normal estimator into its analytic pipeline. The estimator is **optional**, runs **locally** through Core ML, and never replaces provenance: every export records the model identity and how much it contributed.

## Model

| Item | Value |
| --- | --- |
| Model | Microsoft MoGe-2 ViT-S, normal head (`Ruicheng/moge-2-vits-normal`) |
| Licence | MIT (MoGe code and weights); DINOv2 modules Apache-2.0 |
| Pinned weights | `model.pt`, 140,550,416 bytes, SHA-256 `79a16621928c2bf0ed04659218c55c01075e950507f40bb3332fb4c873d3e1dc`, Hugging Face revision `26b477f41595707c5db6770294c0d1721e8ed4ed` |
| Pinned source | `microsoft/MoGe` commit `74fbce054ebed49800de42d0ad0e83495065719a` |
| Core ML model | `MoGe2Normals.mlpackage`, about 56 MB fp16 ML Program, macOS 15 / iOS 18 or later |

The weights, source checkout, conversion virtualenv and converted models live under `third_party/moge/` and are git-ignored. Nothing is fetched at runtime.

### Rebuilding the model

```sh
cd third_party/moge
python3.11 -m venv .venv
.venv/bin/pip install torch==2.7.0 torchvision==0.22.0 "numpy<2.3" coremltools opencv-python-headless scipy pillow huggingface-hub tqdm click \
  "utils3d_moge @ git+https://github.com/EasternJournalist/utils3d-moge.git@62f09d58509485564e24d5d9f6aac9ee9ebc0c37"
git clone https://github.com/microsoft/MoGe.git src && git -C src checkout 74fbce054ebed49800de42d0ad0e83495065719a
curl -L -o model.pt https://huggingface.co/Ruicheng/moge-2-vits-normal/resolve/26b477f41595707c5db6770294c0d1721e8ed4ed/model.pt
.venv/bin/python ../../scripts/convert_moge2_coreml.py --moge-src src --weights model.pt \
  --output build/MoGe2Normals.mlpackage --verify-image some-texture.png
```

The converter refuses weights whose SHA-256 does not match. It makes two changes, and each depends only on the fixed tile size:

- DINOv2's bicubic positional-embedding resize is evaluated once and stored as a constant, because Core ML has no bicubic upsample.
- MoGe's view-plane UV grids are precomputed.

Verification on a 518² brick photo against the **stock** PyTorch forward pass: mean angular difference **0.045°**, 99th percentile **0.23°** (fp16 Core ML). Warm prediction takes about 60 ms per tile on an M5 through the Python API.

## Model contract

- Input `image`: RGB, 518 × 518 (37 × 37 ViT patches, 1369 tokens).
- Output `normals`: `(1, 3, 518, 518)`, tangent space, +X right, **+Y up**, +Z toward the viewer.
- MoGe itself predicts OpenCV camera-space normals (x right, y down, z forward). The converted model already returns `(nx, −ny, −nz)`.
- User metadata: `materiallab.contract = tangent_normals_plus_y_v1`, plus `materiallab.weights_sha256` and `materiallab.moge_commit`.

A numeric check confirmed the convention on the brick photo. The tops of bricks just below the mortar face up (green +0.034) and the bottoms face down (green −0.045). The model correctly reads the mortar as recessed; the luminance heuristic reads pale mortar as raised.

## Tiling (all clients must match)

1. Let `N` be the square source size. The working size is `W = clamp(N, 518, 1036)`. Resample the sRGB source to `W × W` with high-quality (Lanczos or Core Graphics high) interpolation.
2. Tile origins along each axis start at 0 and step by 259 (50 % overlap). If the final origin is short of `W − 518`, add `W − 518` as a last origin. When `W = 518` there is one tile.
3. Weight each tile's output by `w(x, y) = s(x) · s(y)`, where `s(t) = max(sin(π (t + 0.5) / 518), 1e-3)`. Accumulate the weighted vectors, then normalize per pixel.
4. Resample the `W × W` normal field to `N × N` bilinearly, renormalize, and encode it as linear RGBA8: `round((n · 0.5 + 0.5) · 255)`, alpha 255.
5. Pass the result as `PBRLabInput.guide_normal_rgba8`, with `recipe.guide_normal_weight` in [0, 1]. The core removes low-frequency tilt, integrates the slopes to height, and blends that height with the inferred height (0 = analytic only, 1 = learned only).

Fine detail above `W` comes from the analytic path whenever the weight is below 1.

## Provenance

The `.pbrmaterial` manifest records the following. Clients also record `guide_normals` in `.pbrcapture` envelopes under the `capture` object.

- `recipe.guide_normal_weight` is always present in version 1.2.0 or later.
- When the weight is above 0, a top-level `guide_normals` object records:
  - `estimator`: `"moge-2-vits-normal"`
  - `contract`: `"tangent_normals_plus_y_v1"`
  - `weights_sha256` and `moge_commit`, taken from the model metadata
  - `model_file` (basename)
  - `compute_units`
  - `work_resolution` and `tiles`
  - `normals_sha256`: the SHA-256 of the guide RGBA8 bytes that were fed to the core

The Neural Engine runs in fp16, so results can differ slightly between chips and OS versions. Pass `--learned-cpu-only` (CLI) for a more reproducible run. The height provenance becomes `estimated_from_albedo_and_learned_normals`, or `learned_normals` when the preset is Flat.
