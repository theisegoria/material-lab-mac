#!/usr/bin/env python3
"""Optional offline Real-ESRGAN image adapter for a separately pinned vendor tree.

Run this with that vendor tree's pinned virtualenv. Nothing is downloaded or
installed. Material Lab's generic CLI upscaler hook can invoke this executable.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def vendor_module(project: Path):
    script = project / "script" / "vendor_realesrgan.py"
    if not script.is_file():
        raise RuntimeError("vendor project has no script/vendor_realesrgan.py")
    spec = importlib.util.spec_from_file_location("material_lab_pinned_vendor", script)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load pinned vendor manifest")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    expected = project / "third_party" / "realesrgan"
    if module.ROOT.resolve() != expected.resolve():
        raise RuntimeError("vendor manifest resolved a different dependency root")
    module.verify()
    return module


def source_pixels(path: Path):
    from PIL import Image, ImageCms, ImageOps
    import numpy as np

    with Image.open(path) as opened:
        image = ImageOps.exif_transpose(opened)
        alpha = image.getchannel("A") if "A" in image.getbands() else None
        source_profile = image.info.get("icc_profile")
        if source_profile:
            profile = ImageCms.ImageCmsProfile(io.BytesIO(source_profile))
            target = ImageCms.createProfile("sRGB")
            rgb = ImageCms.profileToProfile(image, profile, target, outputMode="RGB")
            conversion = "embedded ICC to sRGB"
        else:
            rgb = image.convert("RGB")
            conversion = "untagged input assumed sRGB"
        return np.asarray(rgb, dtype=np.uint8), alpha, conversion


def upscale(array, model, scale: int, device: str, tile: int, pad: int):
    import numpy as np
    import torch

    height, width, _ = array.shape
    result = np.empty((height * scale, width * scale, 3), dtype=np.uint8)
    count = ((height + tile - 1) // tile) * ((width + tile - 1) // tile)
    completed = 0
    with torch.inference_mode():
        for y in range(0, height, tile):
            for x in range(0, width, tile):
                core_h, core_w = min(tile, height - y), min(tile, width - x)
                top, left = max(0, y - pad), max(0, x - pad)
                bottom, right = min(height, y + core_h + pad), min(width, x + core_w + pad)
                patch = array[top:bottom, left:right]
                patch_h, patch_w = patch.shape[:2]
                if scale == 2:
                    patch = np.pad(patch, ((0, patch_h % 2), (0, patch_w % 2), (0, 0)), mode="edge")
                tensor = torch.from_numpy(patch.copy()).permute(2, 0, 1).unsqueeze(0)
                tensor = tensor.to(device=device, dtype=torch.float32).div_(255.0)
                enhanced = model(tensor).clamp_(0, 1)
                if not bool(torch.isfinite(enhanced).all().item()):
                    raise RuntimeError("model produced a non-finite pixel")
                pixels = enhanced[0].permute(1, 2, 0).mul(255).round().byte().cpu().numpy()
                crop_y, crop_x = (y - top) * scale, (x - left) * scale
                result[y * scale:(y + core_h) * scale, x * scale:(x + core_w) * scale] = \
                    pixels[crop_y:crop_y + core_h * scale, crop_x:crop_x + core_w * scale]
                completed += 1
                print(f"Real-ESRGAN tiles {completed}/{count}", file=sys.stderr, flush=True)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vendor-project-root", type=Path, required=True,
                        help="Local project containing the pinned script and third_party/realesrgan")
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--scale", type=int, choices=(2, 4), default=2)
    parser.add_argument("--device", choices=("cpu", "mps"), default="cpu")
    parser.add_argument("--tile", type=int, default=128)
    parser.add_argument("--pad", type=int, default=48)
    args = parser.parse_args()
    if args.tile < 16 or args.tile > 1024 or args.pad < 0 or args.pad > 256:
        parser.error("tile must be 16..1024 and pad must be 0..256")
    if args.scale == 2 and (args.tile % 2 or args.pad % 2):
        parser.error("x2 model requires even tile and pad values to preserve pixel-unshuffle phase")
    if not sys.flags.isolated:
        parser.error("run the pinned Python interpreter with -I to isolate imports from PYTHONPATH")
    if not args.input.is_file() or args.input.is_symlink():
        parser.error("input must be a regular local image")
    if args.output.suffix.lower() != ".png" or args.output.resolve() == args.input.resolve():
        parser.error("output must be a distinct .png path")
    args.output.parent.mkdir(parents=True, exist_ok=True)

    sys.dont_write_bytecode = True
    vendor = vendor_module(args.vendor_project_root.resolve())
    pinned_env = (vendor.ROOT / ".venv").resolve()
    if Path(sys.prefix).resolve() != pinned_env:
        raise RuntimeError(f"run with the pinned Python environment: {pinned_env / 'bin/python3.11'}")
    for wheel in json.loads((vendor.ROOT / "wheelhouse.lock.json").read_text())["wheels"]:
        if importlib.metadata.version(wheel["name"]) != wheel["version"]:
            raise RuntimeError("installed dependency version differs from pinned lock: " + wheel["name"])

    import numpy as np
    import torch
    from PIL import Image, PngImagePlugin

    if args.device == "mps" and not torch.backends.mps.is_available():
        raise RuntimeError("MPS unavailable; select CPU explicitly")
    torch.set_num_threads(2)
    if args.device == "cpu":
        torch.use_deterministic_algorithms(True)
    pixels, alpha, color_conversion = source_pixels(args.input)
    height, width = pixels.shape[:2]
    if min(height, width) < 2 or max(height, width) * args.scale > 4096:
        raise RuntimeError("upscaled dimensions must remain within the 2..4096 pixel Material Lab input limit")

    model_name = f"RealESRGAN_x{args.scale}plus"
    weight = vendor.ROOT / "weights" / f"{model_name}.pth"
    network = vendor.rrdb_type()(num_in_ch=3, num_out_ch=3, num_feat=64,
                                 num_block=23, num_grow_ch=32, scale=args.scale)
    checkpoint = torch.load(weight, map_location="cpu", weights_only=True)
    network.load_state_dict(checkpoint.get("params_ema", checkpoint.get("params")), strict=True)
    network.eval().to(args.device)
    enhanced = upscale(pixels, network, args.scale, args.device, args.tile, args.pad)
    result = Image.fromarray(enhanced, "RGB")
    if alpha is not None:
        result = result.convert("RGBA")
        result.putalpha(alpha.resize(result.size, Image.Resampling.BICUBIC))
    png_info = PngImagePlugin.PngInfo()
    png_info.add(b"sRGB", bytes([0]))  # Perceptual sRGB rendering intent, fixed bytes.
    descriptor = None
    try:
        with tempfile.NamedTemporaryFile(dir=args.output.parent, suffix=".png", delete=False) as temporary:
            descriptor = Path(temporary.name)
        result.save(descriptor, format="PNG", pnginfo=png_info)
        os.replace(descriptor, args.output)
        descriptor = None
    finally:
        if descriptor is not None:
            descriptor.unlink(missing_ok=True)
    receipt = {
        "schemaVersion": 1, "operation": "local-offline-upscale",
        "sourceSHA256": digest(args.input), "outputSHA256": digest(args.output),
        "sourceSize": [width, height], "outputSize": [width * args.scale, height * args.scale],
        "model": model_name, "modelSHA256": digest(weight),
        "pinnedSourceCommit": vendor.COMMIT, "device": args.device,
        "python": sys.version.split()[0], "torch": torch.__version__,
        "tile": args.tile, "pad": args.pad, "colorConversion": color_conversion,
        "alpha": "source alpha resized; not inferred" if alpha is not None else "none",
    }
    receipt_path = args.output.with_name(args.output.name + ".upscale.json")
    receipt_temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=args.output.parent, suffix=".json", delete=False) as temporary:
            receipt_temporary = Path(temporary.name)
            temporary.write((json.dumps(receipt, sort_keys=True, indent=2) + "\n").encode("utf-8"))
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(receipt_temporary, receipt_path)  # Replaces a symlink itself; never follows it.
        receipt_temporary = None
    finally:
        if receipt_temporary is not None:
            receipt_temporary.unlink(missing_ok=True)
    print(json.dumps({"output": str(args.output), "receipt": str(receipt_path),
                      "outputSHA256": receipt["outputSHA256"]}))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"pinned Real-ESRGAN upscale failed: {error}", file=sys.stderr)
        raise SystemExit(1)
