# PBR Material Lab core and CLI

`PBRMaterialLab.cpp` is a deterministic C++23 derivation core with a stable C ABI in `include/PBRMaterialLab.h`. It has no Apple or game-engine dependency and is compiled into both native apps. The macOS `material-lab` CLI uses ImageIO to decode source images into straight RGBA8 sRGB, then writes self-contained `.pbrmaterial` directories. The C API expects callers on other platforms to supply an already converted sRGB buffer.

## Build and run

```sh
cmake -S core -B build/material-lab-core -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build/material-lab-core
ctest --test-dir build/material-lab-core --output-on-failure
build/material-lab-core/material-lab --input surface.png --output output/surface.pbrmaterial --label "stone wall" --preset stone
build/material-lab-core/material-lab --validate output/surface.pbrmaterial
build/material-lab-core/material-lab --validate capture.pbrcapture
```

For a reviewed batch, `--catalog catalog.json --output output` accepts `items`, `materials`, or `assets`. Each record needs a catalog-relative `path` or `relative_path`, an optional `id`, and `label` or `material_label`. It is selected by `reviewed: true` or `review_status: "approved"` / `"reviewed"`. `--include-unreviewed` deliberately opts in to candidates. Duplicate IDs and unsafe relative paths fail.

Optional controls include `--height-strength`, `--polarity`, `--roughness`, `--roughness-variation`, `--ao-radius`, `--no-tile`, `--bent-normal`, and `--metalness`. Raw `--relief-mask-r8` uses one byte per pixel (0 suppresses inferred relief, 255 keeps it). Raw `--height-override-r16le` uses two little-endian bytes per pixel and bypasses inference. Neither alters the source albedo. The CLI accepts an image prepared by any external pre-upscaler as ordinary input. It can also run an explicitly selected local executable **before** derivation with repeated `--pre-upscale-arg` tokens. Both `{input}` and `{output}` placeholders are required; each token is passed directly through `posix_spawn`, without a shell. The executable may have its own network behavior, so choose a trusted offline tool. The bundle records original and processed SHA-256 hashes, executable hash, argument template, dimensions, hashes of local argument files, and a verified optional `{output}.upscale.json` receipt. No upscaler is linked into the core or run by default.

For the sibling offline pinned Real-ESRGAN helper, set `PINNED_PYTHON` to its pinned Python 3.11 virtualenv interpreter and `VENDOR_PROJECT_ROOT` to the project that owns the verified model and dependency tree:

```sh
build/material-lab-core/material-lab --input surface.png --output output/upscaled.pbrmaterial --preset stone \
  --pre-upscale-exec "$PINNED_PYTHON" \
  --pre-upscale-arg "$PWD/scripts/pinned_realesrgan.py" \
  --pre-upscale-arg --vendor-project-root --pre-upscale-arg "$VENDOR_PROJECT_ROOT" \
  --pre-upscale-arg --input --pre-upscale-arg '{input}' \
  --pre-upscale-arg --output --pre-upscale-arg '{output}' \
  --pre-upscale-arg --scale --pre-upscale-arg 2
```

The helper verifies its external pinned tree and writes a model/backend receipt; Material Lab checks the receipt hashes and embeds it as provenance. The bundled CLI test uses a small local resize stub to verify the hook without model dependencies.

## Inference contract

- Decode source color to linear RGB for luminance analysis. The CLI converts profile-tagged input through ImageIO to sRGB. Untagged input is treated as sRGB; record the source profile separately if that assumption matters.
- Flat is the default preset and produces neutral height and normals even for painted contrast. Stone, fabric, organic, coated metal, and bare metal presets use differing weights of 2, 8, and 24 pixel high-pass scales. These are editable visual priors, not inverse-rendered physical geometry.
- Optional R8 mask suppresses only inferred relief. An authored R16 height override takes precedence over mask and preset. Height is normalized 16-bit with neutral flat height 0.5.
- Derive +Y tangent-space normals from central differences, with RGB in linear 8-bit format, opaque alpha, blue upper hemisphere, and unit length within the receiving cooker's tolerance. AO uses eight horizon directions and six radius samples per direction; 1 means unoccluded. Bent normals are an optional horizon diagnostic. Cavity, convexity, slope, and edge are heightfield diagnostics.
- Perceptual roughness starts from an assigned material prior. Optional height variation is intentionally restrained. ORM is exported only when metalness was explicitly assigned: R=AO, G=perceptual roughness, B=assigned metalness. RGB alone does not establish intrinsic roughness, metalness, F0, emission, opacity, thickness, or physical gameplay properties.
- Spatial filters may wrap at tile boundaries, but wrap does not repair nonmatching source edges. Seam metrics report opposite-edge height values, gradients, and linear albedo differences. A 3×3 preview belongs to the app UI; derived map bytes remain one tile each.

## Bundle format

The companion iPhone app transfers a bounded single-file `.pbrcapture` JSON envelope over the direct link and through Files/AirDrop. The CLI validates its 64 MiB limit, source PNG hash and 2..4096 square dimensions, optional original/derived hashes and dimensions, map encodings, and absence of GPS/location metadata. The desktop app imports a valid capture into its inbox before explicit export.

Each `.pbrmaterial` directory has `manifest.json` and PNGs named `albedo`, `height`, `normal`, `roughness`, `ao`, `cavity`, `convexity`, `slope`, `edge`, with optional `bent_normal` and `orm`. The manifest identifies source SHA-256, semantic label, preset and every parameter, algorithm version, map SHA-256/encoding/provenance, seam metrics, and `runtime_admitted: false`. The CLI validates required maps, identity, hash, PNG decode, dimensions, and encoding. Albedo is sRGB RGBA8; height is R16 UNorm grayscale; all other maps are linear RGBA8. Optional game-engine cook/admission is a separate explicit step.

`PBRLabDerive` is synchronous and keeps every output buffer owned by its `PBRLabResult` until `PBRLabFreeResult`. The optional callback receives progress and can cancel by returning zero. The ABI version string is `1.0.0`. Callers may derive on background threads with separate input/output objects; no global mutable state is used.
