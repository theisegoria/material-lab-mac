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
