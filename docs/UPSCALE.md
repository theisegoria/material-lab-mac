# Optional offline pre-upscale

The Mac CLI can pass an image through a local pre-upscaler before deriving maps. This is opt-in. The iPhone derives from its selected capture resolution. An upscaler creates plausible image detail; it does not measure surface geometry or improve the physical certainty of derived maps.

`--pre-upscale-exec` names an absolute local executable. Repeat `--pre-upscale-arg` for each argument token. Include `{input}` and `{output}` templates across those arguments. Material Lab uses `posix_spawn` with an argument array, never a shell command, and checks the output is a bounded square image before derivation. The bundle records input/output hashes, output dimensions, executable hash, argument templates, hashes of local argument files, and a verified receipt if the upscaler writes `{output}.upscale.json`.

## Existing pinned Real-ESRGAN tree

`scripts/pinned_realesrgan.py` is a standalone offline adapter for a separately pinned Real-ESRGAN vendor tree. It does not copy model weights, install dependencies, fetch files, or alter the vendor project. It verifies the vendor manifest and installed wheel versions, uses its pinned virtual environment and x2plus or x4plus model, converts embedded input ICC profiles to sRGB, then writes a tagged sRGB PNG and a hash-rich receipt. CPU and MPS are explicit choices; MPS does not silently fall back to CPU. The adapter requires Python isolated mode (`-I`) so `PYTHONPATH` cannot shadow pinned packages. Tiled inference uses overlap padding; custom tile and pad values must both be even for x2 to preserve pixel-unshuffle phase. Every output still needs visual review for artificial detail and tile seams.

For example, with a local vendor project that contains `script/vendor_realesrgan.py`, `third_party/realesrgan/.venv`, and its pinned model weights:

```sh
PINNED_PYTHON='/absolute/vendor-project/third_party/realesrgan/.venv/bin/python3.11'
VENDOR_PROJECT_ROOT='/absolute/vendor-project'
./build/core/material-lab \
  --input ./source-512.png --output ./weathered-stone.pbrmaterial \
  --label 'weathered stone' --preset stone \
  --pre-upscale-exec "$PINNED_PYTHON" \
  --pre-upscale-arg -I \
  --pre-upscale-arg "$PWD/scripts/pinned_realesrgan.py" \
  --pre-upscale-arg --vendor-project-root --pre-upscale-arg "$VENDOR_PROJECT_ROOT" \
  --pre-upscale-arg --input --pre-upscale-arg '{input}' \
  --pre-upscale-arg --output --pre-upscale-arg '{output}' \
  --pre-upscale-arg --scale --pre-upscale-arg 2 \
  --pre-upscale-arg --device --pre-upscale-arg cpu
```

The adapter also runs directly as a two-step workflow:

```sh
"$PINNED_PYTHON" -I scripts/pinned_realesrgan.py \
  --vendor-project-root "$VENDOR_PROJECT_ROOT" \
  --input ./source-512.png --output ./source-1024.png --scale 2 --device cpu
./build/core/material-lab --input ./source-1024.png \
  --output ./weathered-stone.pbrmaterial --label 'weathered stone' --preset stone
```

The one-step CLI hook retains the original input hash and upscaler receipt in the exported manifest. The two-step path derives from the provided upscaled PNG, so preserve its `.upscale.json` receipt separately if original-input provenance matters. Neither path admits a material into a game runtime.

## Verification

The adapter ran the locally pinned x2plus and x4plus weights on a synthetic 8×8 sRGB input using CPU. The x2 result was 16×16, the x4 result was 32×32, and the x2 PNG was byte-identical across repeated runs after fixed sRGB tagging. This verifies the local model invocation and encoding path on a tiny image; it is not a texture-quality or throughput qualification.

## High-resolution export (`--resolution 4096|8192`, CLI 1.4.0)

`--resolution` derives the whole material at 4096² or 8192². The maps are not resized afterwards: the albedo is enlarged with the pinned upscaler, then every map is derived at the target size from it. Height, normals, AO and the masks come from the full-size albedo, and every spatial scale follows the tile (docs/DERIVATION.md), so a 4K export describes the same surface as a 1K one.

- **Passes that land on the target.** A source more than half the target gets one 2× pass, then a high-quality (Lanczos, vImage) resample down. Otherwise the source is first resampled up, by less than 2×, to target / P, where P is the largest power of two ≤ target / source. P is then applied in 4× and 2× passes (at most three). A 1024 source reaches 4096 in one 4× pass, a 1024 source reaches 8192 in a 4× and a 2× pass, and a 192 source reaches 4096 via 256 and two 4× passes.
- **Tiling is kept.** When the recipe tiles (the default), every pass gets a wrap-padded copy (a sixteenth of the size, at least 8 px), and the result is cropped back to one period. The resamples pad by a whole number of periods' fraction so they crop on exact pixels. Without padding, the upscaler would treat the tile edges as image borders and the albedo would no longer tile.
- **Every pass reads a PNG of the decoded pixels:** oriented and converted to sRGB, exactly what Material Lab derives from.
- **The upscaler.** By default this is `scripts/pinned_realesrgan.py`, run with the vendor tree's pinned Python:
  - `--upscaler-root VENDOR_PROJECT`, or `$MATERIAL_LAB_REALESRGAN_ROOT`, names the vendor project. Its Python is `third_party/realesrgan/.venv/bin/python3.11`, overridable with `$MATERIAL_LAB_REALESRGAN_PYTHON`.
  - The adapter is found beside `material-lab`, in `share/material-lab/`, in the repository's `scripts/` (for `build/core/material-lab`), or at `$MATERIAL_LAB_REALESRGAN_ADAPTER`.
  - `--upscaler-device cpu|mps` picks the device (default `cpu`). The pass timeout is one hour unless `--pre-upscale-timeout` is given.
  - `--pre-upscale-exec` and `--pre-upscale-arg` name any other local upscaler instead; its arguments may use `{scale}` (2 or 4) as well as `{input}` and `{output}`. With `--resolution`, that tool is the resolution upscaler, not a separate pre-pass.
- **No upscaler, no bundle.** When the source is smaller than the target and no upscaler is configured or installed, the CLI fails before deriving. The message names what is missing.
- **Guides and authored maps follow the target size.** `--learned` runs MoGe-2 on the albedo (a 4096 copy for 8K; its working size is at most 2072 anyway) and finishes the guide at the target size. `--guide-normals` and `--guide-measured` images and authored maps are resampled to it. The raw `--relief-mask-r8` and `--height-override-r16le` inputs are refused; use `--height-map`.
- **Provenance.** `source.sha256` stays the original file's hash. `source.resolution` records:
  - `target_px`, `source_px` and `pre_resample_px`;
  - `upscaler` (`pinned_realesrgan`, `custom` or `none`) and `wrap`;
  - every pass (`scale`, `wrap_padding_px`, output dimensions, and the same executable, argument and receipt hashes as `pre_upscale`);
  - `resample` (`vimage_high_quality_lanczos` or `none`) and `processed_rgba8_sha256`, the hash of the albedo pixels derived from.

  The validator checks its shape and that `target_px` is the map size.

Memory: a 4096 derivation peaks at about 3.3 GB resident (measured on the dev M5 with the stone preset). 8192 needs about four times that. Run 8K exports one at a time, with the machine otherwise quiet.

Verification (17 November): the CLI tests run the 4096 path end to end with `core/tests/ResolutionStub.py`, a sips-resize stand-in, both as a custom upscaler and through the pinned-adapter lookup (fake vendor root). They check the pass plan, wrap padding, receipts, the tiling albedo seam, and the clear failure when no upscaler is installed. The real Real-ESRGAN adapter was not run through `--resolution` (CPU passes at 4K are slow, and the machine was loaded), and no 8192 derivation was run.
