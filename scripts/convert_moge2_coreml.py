#!/usr/bin/env python3
"""Convert MoGe-2 ViT-S (normal head) to a Core ML tangent-normal estimator for Material Lab.

Offline and explicit: this script never downloads anything. It expects a local MoGe source checkout
and the pinned weights (see docs/LEARNED_NORMALS.md for the pinned commit and SHA-256).

Output model contract (MoGe2Normals.mlpackage):
  input  "image"   : RGB image, 518x518, values scaled to [0, 1]
  output "normals" : float16 (1, 3, 518, 518), unit tangent-space normals, +X right, +Y up, +Z toward viewer

MoGe predicts normals in OpenCV camera coordinates (x right, y down, z forward), so for a photo taken
facing the surface the tangent normal is (nx, -ny, -nz).
"""
import argparse
import hashlib
import json
import sys
from pathlib import Path

TILE = 518                     # 37 x 37 DINOv2 patches of 14 px
NUM_TOKENS = (TILE // 14) ** 2  # 1369, inside MoGe-2's recommended 1200..2500 range
PINNED_WEIGHTS_SHA256 = "79a16621928c2bf0ed04659218c55c01075e950507f40bb3332fb4c873d3e1dc"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--moge-src", required=True, type=Path, help="local microsoft/MoGe checkout")
    parser.add_argument("--weights", required=True, type=Path, help="moge-2-vits-normal model.pt")
    parser.add_argument("--output", required=True, type=Path, help="destination .mlpackage")
    parser.add_argument("--verify-image", type=Path, help="optional image to compare Core ML against PyTorch")
    args = parser.parse_args()

    weights_hash = sha256(args.weights)
    if weights_hash != PINNED_WEIGHTS_SHA256:
        print(f"weights SHA-256 {weights_hash} does not match the pinned {PINNED_WEIGHTS_SHA256}", file=sys.stderr)
        return 2
    sys.path.insert(0, str(args.moge_src.resolve()))

    import numpy as np
    import torch
    import coremltools as ct
    import moge.model.v2 as moge_v2
    from moge.model.v2 import MoGeModel

    # View-plane UV grids depend only on the fixed tile size; precompute them so no meshgrid is traced.
    original_uv = moge_v2.normalized_view_plane_uv
    uv_cache = {}

    def constant_uv(width, height, aspect_ratio=None, dtype=None, device=None):
        key = (int(width), int(height), float(aspect_ratio) if aspect_ratio is not None else None)
        if key not in uv_cache:
            uv_cache[key] = original_uv(int(width), int(height), aspect_ratio=aspect_ratio).detach()
        return uv_cache[key].to(dtype=dtype or torch.float32)

    moge_v2.normalized_view_plane_uv = constant_uv
    base = TILE // 14
    for level in range(5):  # Populate before tracing so the grids enter the graph as constants.
        constant_uv(base * 2 ** level, base * 2 ** level, aspect_ratio=1.0)

    model = MoGeModel.from_pretrained(str(args.weights)).eval()
    # The tile size is fixed, so DINOv2's bicubic positional-embedding resize (unsupported by Core ML) is
    # evaluated once in eager mode with the model's exact default settings and baked in as a constant.
    for module in model.modules():
        if hasattr(module, "interpolate_pos_encoding") and hasattr(module, "pos_embed"):
            with torch.no_grad():
                tokens = torch.zeros(1, NUM_TOKENS + 1, module.pos_embed.shape[-1])
                baked = module.interpolate_pos_encoding(tokens, TILE, TILE).detach().clone()
            module.interpolate_pos_encoding = (lambda constant: (lambda x, h, w: constant.to(x.dtype)))(baked)
    model.onnx_compatible_mode = True  # Avoids antialiased resizes and data-dependent ops that do not trace.

    class TangentNormals(torch.nn.Module):
        def __init__(self, inner):
            super().__init__()
            self.inner = inner

        def forward(self, image):
            normal = self.inner(image, num_tokens=NUM_TOKENS)["normal"]  # (1, H, W, 3), OpenCV camera space
            tangent = torch.stack([normal[..., 0], -normal[..., 1], -normal[..., 2]], dim=1)
            return tangent

    wrapper = TangentNormals(model).eval()
    example = torch.rand(1, 3, TILE, TILE)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example, check_trace=False)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, TILE, TILE), scale=1.0 / 255.0,
                             color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="normals")],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS15,
        convert_to="mlprogram",
    )
    commit_file = args.moge_src / ".." / "PINNED_COMMIT"
    commit = commit_file.read_text().strip() if commit_file.exists() else "unknown"
    mlmodel.author = "Material Lab conversion of Microsoft MoGe-2 ViT-S normal (MIT)"
    mlmodel.license = "MIT (MoGe); DINOv2 modules Apache-2.0"
    mlmodel.short_description = "Tangent-space normals (+Y up) from a 518x518 RGB image."
    mlmodel.version = "moge-2-vits-normal"
    mlmodel.user_defined_metadata.update({
        "materiallab.contract": "tangent_normals_plus_y_v1",
        "materiallab.tile": str(TILE),
        "materiallab.num_tokens": str(NUM_TOKENS),
        "materiallab.weights_sha256": weights_hash,
        "materiallab.moge_commit": commit,
    })
    mlmodel.save(str(args.output))
    print(json.dumps({"output": str(args.output), "weights_sha256": weights_hash, "moge_commit": commit}))

    if args.verify_image:
        from PIL import Image
        image = Image.open(args.verify_image).convert("RGB").resize((TILE, TILE), Image.LANCZOS)
        tensor = torch.from_numpy(np.asarray(image).astype(np.float32) / 255.0).permute(2, 0, 1)[None]
        with torch.no_grad():
            reference = wrapper(tensor)[0].numpy()
        predicted = np.asarray(mlmodel.predict({"image": image})["normals"], dtype=np.float32)[0]
        predicted /= np.linalg.norm(predicted, axis=0, keepdims=True) + 1e-8
        cosine = np.clip((reference * predicted).sum(0), -1, 1)
        angle = np.degrees(np.arccos(cosine))
        print(json.dumps({
            "verify_image": str(args.verify_image),
            "mean_angle_deg": float(angle.mean()),
            "p99_angle_deg": float(np.percentile(angle, 99)),
            "mean_tangent_normal": [float(v) for v in reference.reshape(3, -1).mean(1)],
        }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
