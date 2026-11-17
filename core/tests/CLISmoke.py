#!/usr/bin/env python3
"""End-to-end bundle contract checks with only Python's standard library."""
import base64
import hashlib
import os
import uuid
import json
import math
import signal
import time
import shutil
import pathlib
import struct
import subprocess
import sys
import tempfile
import zlib


V15_RECIPE = ("mid_relief_share", "tile_metres", "roughness_albedo_limit", "substrate_relief")
V15_RELIEF = ("mid_relief_share_before", "mid_relief_share_after", "roughness_albedo_correlation_before",
              "roughness_albedo_correlation_after")

def chunk(name: bytes, content: bytes) -> bytes:
    body = name + content
    return struct.pack(">I", len(content)) + body + struct.pack(">I", zlib.crc32(body))


def sample_png(path: pathlib.Path, *, srgb: bool = True) -> None:
    width = height = 16
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            value = 160 if (x // 4 + y // 4) % 2 else 80
            rows.extend((value, value, value, 255))
    png = bytearray(b"\x89PNG\r\n\x1a\n")
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    if srgb:
        png += chunk(b"sRGB", b"\x00")
    png += chunk(b"IDAT", zlib.compress(rows))
    png += chunk(b"IEND", b"")
    path.write_bytes(png)


def sample_height_png(path: pathlib.Path) -> None:
    width = height = 16
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            rows.extend(struct.pack(">H", (x + y) * 65535 // 30))
    png = bytearray(b"\x89PNG\r\n\x1a\n")
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 16, 0, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(rows))
    png += chunk(b"IEND", b"")
    path.write_bytes(png)


def gray_png(path: pathlib.Path, values) -> None:
    """A 16x16 8-bit grayscale PNG; values(x, y) -> 0..255."""
    rows = bytearray()
    for y in range(16):
        rows.append(0)
        rows.extend(values(x, y) for x in range(16))
    png = bytearray(b"\x89PNG\r\n\x1a\n")
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", 16, 16, 8, 0, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(rows))
    png += chunk(b"IEND", b"")
    path.write_bytes(png)


def rgb_png(path: pathlib.Path, pixel) -> None:
    """A 16x16 8-bit RGB PNG; pixel(x, y) -> (r, g, b)."""
    rows = bytearray()
    for y in range(16):
        rows.append(0)
        for x in range(16):
            rows.extend(pixel(x, y))
    png = bytearray(b"\x89PNG\r\n\x1a\n")
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", 16, 16, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(rows))
    png += chunk(b"IEND", b"")
    path.write_bytes(png)


def textured_png(path: pathlib.Path, n: int = 32, tint=(1.0, 0.95, 0.9), phase: float = 0.0) -> None:
    """A tileable n x n RGBA8 sRGB texture with relief-like detail."""
    rows = bytearray()
    for y in range(n):
        rows.append(0)
        for x in range(n):
            a = 0.5 + 0.25 * math.sin(2 * math.pi * (2 * x / n + phase)) * math.cos(2 * math.pi * 3 * y / n) \
                + 0.15 * math.sin(2 * math.pi * (5 * x + 7 * y) / n)
            rows.extend(tuple(max(0, min(255, int(255 * a * t))) for t in tint) + (255,))
    png = bytearray(b"\x89PNG\r\n\x1a\n")
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", n, n, 8, 6, 0, 0, 0))
    png += chunk(b"sRGB", b"\x00")
    png += chunk(b"IDAT", zlib.compress(rows))
    png += chunk(b"IEND", b"")
    path.write_bytes(png)


def run(cli: str, *args: str, expect_success=True, cwd=None) -> subprocess.CompletedProcess:
    process = subprocess.run([cli, *args], text=True, capture_output=True, cwd=cwd)
    if (process.returncode == 0) != expect_success:
        raise AssertionError(f"unexpected CLI status: {process.returncode}\n{process.stdout}\n{process.stderr}")
    # Failures must be orderly error exits, never an uncaught NSException abort or other signal.
    if not expect_success and process.returncode != 1:
        raise AssertionError(f"expected exit status 1, got {process.returncode}\n{process.stderr}")
    return process


def read_png(path: pathlib.Path):
    """Minimal non-interlaced PNG decoder (all five filter types) returning (width, height, bpp, rows)."""
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    offset, idat, header = 8, bytearray(), None
    while offset < len(data):
        length, kind = struct.unpack_from(">I4s", data, offset)
        body = data[offset + 8:offset + 8 + length]
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat.extend(body)
        offset += length + 12
    width, height, depth, color, _, _, interlace = header
    assert interlace == 0
    bpp = {0: 1, 2: 3, 4: 2, 6: 4}[color] * depth // 8
    raw = zlib.decompress(bytes(idat))
    stride = width * bpp
    rows, prior = [], bytearray(stride)
    for y in range(height):
        kind, line = raw[y * (stride + 1)], raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)]
        row = bytearray(stride)
        for i in range(stride):
            a = row[i - bpp] if i >= bpp else 0
            b = prior[i]
            c = prior[i - bpp] if i >= bpp else 0
            if kind == 0: pred = 0
            elif kind == 1: pred = a
            elif kind == 2: pred = b
            elif kind == 3: pred = (a + b) // 2
            else:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
            row[i] = (line[i] + pred) & 255
        rows.append(bytes(row))
        prior = row
    return width, height, bpp, rows


def main() -> None:
    cli = os.path.abspath(sys.argv[1])
    with tempfile.TemporaryDirectory(prefix="material-lab-cli-") as name:
        root = pathlib.Path(name)
        image = root / "source.png"
        sample_png(image)
        out = root / "single"
        run(cli, "--input", str(image), "--output", str(out), "--label", "checker surface",
            "--preset", "stone", "--metalness", "0.2", "--bent-normal")
        bundle = root / "single.pbrmaterial"
        run(cli, "--validate", str(bundle))
        manifest = json.loads((bundle / "manifest.json").read_text())
        assert manifest["bundle_kind"] == "pbr-material-bundle"
        assert manifest["semantic_label"] == "checker surface"
        assert manifest["source"]["sha256"] == hashlib.sha256(image.read_bytes()).hexdigest()
        assert manifest["maps"]["height"]["pixel_format"] == "r16_unorm_png"
        assert manifest["maps"]["normal"]["pixel_format"] == "rgba8_linear_png"
        assert "orm" in manifest["maps"] and "bent_normal" in manifest["maps"]
        # 1.3.0: estimated height is range-normalized and the manifest records the depth it spans.
        assert manifest["algorithm_version"] == "1.5.0"
        assert manifest["recipe"]["albedo_repair"] == "off" and "albedo_repair" not in manifest
        relief = manifest["relief"]
        assert relief["height_span_tile_widths"] > 0 and relief["rms_slope"] > 0
        assert relief["learned_form_share"] == 0 and relief["detail_polarity"] == 1
        _, _, hbpp, hrows = read_png(bundle / "height.png")
        hvalues = [struct.unpack_from(">H", row, x * 2)[0] for row in hrows for x in range(16)]
        assert min(hvalues) == 0 and max(hvalues) == 65535, (min(hvalues), max(hvalues))
        normal = bundle / "normal.png"
        normal.write_bytes(normal.read_bytes() + b"tampered")
        run(cli, "--validate", str(bundle), expect_success=False)

        oversized = root / "oversized.pbrcapture"
        with oversized.open("wb") as stream:
            stream.truncate(64 * 1024 * 1024 + 1)
        run(cli, "--validate", str(oversized), expect_success=False)

        source_bytes = image.read_bytes()
        source_digest = hashlib.sha256(source_bytes).hexdigest()
        linear_png = root / "linear-map.png"
        sample_png(linear_png, srgb=False)
        linear_bytes = linear_png.read_bytes()
        linear_digest = hashlib.sha256(linear_bytes).hexdigest()
        height_png = root / "authored-height.png"
        sample_height_png(height_png)
        height_bytes = height_png.read_bytes()
        height_digest = hashlib.sha256(height_bytes).hexdigest()
        envelope = {
            "schemaVersion": 1, "bundleKind": "pbr-capture",
            "captureId": str(uuid.uuid4()), "semanticLabel": "phone checker", "category": "test",
            "sourceMime": "image/png", "sourceBase64": base64.b64encode(source_bytes).decode(),
            "sourceSHA256": source_digest, "algorithmVersion": "1.1.0",
            "recipe": {"preset": "stone", "heightStrength": 0.22, "heightPolarity": 1,
                       "roughnessBase": 0.78, "roughnessVariation": 0.15,
                       "aoRadiusPixels": 10, "tileWrap": True, "bentNormal": False,
                       "normalStrength": 1, "normalYDown": False, "aoStrength": 1,
                       "albedoEqualize": 0, "seamlessBlend": 0},
            "capture": {"capturedAt": "2026-09-23T00:00:00Z", "orientation": "up",
                        "colorProfile": "sRGB", "captureMode": "estimated-albedo-ordinary-photo",
                        "crop": {}, "imageQuality": {}, "fallbackUsed": False,
                        "constantColorCenterConfidence": 0.75,
                        "originalMime": "image/png", "originalBase64": base64.b64encode(source_bytes).decode(),
                        "originalSHA256": source_digest, "originalWidth": 16, "originalHeight": 16,
                        "fallbackOriginalMime": "image/png",
                        "fallbackOriginalBase64": base64.b64encode(source_bytes).decode(),
                        "fallbackOriginalSHA256": source_digest,
                        "fallbackOriginalWidth": 16, "fallbackOriginalHeight": 16},
            "derived": {"height": {"mime": "image/png", "base64": base64.b64encode(height_bytes).decode(),
                                    "sha256": height_digest, "width": 16, "height": 16,
                                    "pixelFormat": "r16_unorm_png", "provenance": "authored test"},
                        "albedo": {
                "mime": "image/png", "base64": base64.b64encode(source_bytes).decode(),
                "sha256": source_digest, "width": 16, "height": 16,
                "pixelFormat": "rgba8_srgb_png", "provenance": "captured test"}},
            "seamMetrics": {"heightValueDelta": 0, "heightGradientDelta": 0,
                            "albedoValueDelta": 0}, "runtimeAdmitted": False
        }
        for role in ("normal", "roughness", "ao", "cavity", "convexity", "slope", "edge"):
            envelope["derived"][role] = {
                "mime": "image/png", "base64": base64.b64encode(linear_bytes).decode(),
                "sha256": linear_digest, "width": 16, "height": 16,
                "pixelFormat": "rgba8_linear_png", "provenance": "synthetic data map"}
        capture = root / "sample.pbrcapture"
        capture.write_text(json.dumps(envelope))
        run(cli, "--validate", str(capture))
        # 1.1.0 capture recipes require the new fields with the right types and ranges.
        for key, forged in (("normalStrength", None), ("normalStrength", 17), ("aoStrength", "1"),
                            ("seamlessBlend", 0.5), ("albedoEqualize", -0.1), ("normalYDown", 0),
                            ("tileWrap", 1)):
            broken = json.loads(json.dumps(envelope))
            if forged is None:
                del broken["recipe"][key]
            else:
                broken["recipe"][key] = forged
            capture.write_text(json.dumps(broken))
            run(cli, "--validate", str(capture), expect_success=False)
        broken = json.loads(json.dumps(envelope))
        broken["schemaVersion"] = True
        capture.write_text(json.dumps(broken))
        run(cli, "--validate", str(capture), expect_success=False)
        legacy_capture = json.loads(json.dumps(envelope))
        legacy_capture["algorithmVersion"] = "1.0.0"
        for key in ("normalStrength", "normalYDown", "aoStrength", "albedoEqualize", "seamlessBlend"):
            del legacy_capture["recipe"][key]
        capture.write_text(json.dumps(legacy_capture))
        legacy_run = run(cli, "--validate", str(capture))
        assert "green-down" in legacy_run.stderr
        capture.write_text(json.dumps(envelope))
        envelope["capture"]["constantColorCenterConfidence"] = 1.5
        capture.write_text(json.dumps(envelope))
        run(cli, "--validate", str(capture), expect_success=False)
        envelope["capture"]["constantColorCenterConfidence"] = 0.75
        del envelope["derived"]["edge"]
        capture.write_text(json.dumps(envelope))
        run(cli, "--validate", str(capture), expect_success=False)
        envelope["derived"]["edge"] = envelope["derived"]["slope"].copy()
        envelope["capture"]["gpsLatitude"] = 42
        capture.write_text(json.dumps(envelope))
        run(cli, "--validate", str(capture), expect_success=False)
        del envelope["capture"]["gpsLatitude"]
        envelope["capture"]["originalSHA256"] = "0" * 64
        capture.write_text(json.dumps(envelope))
        run(cli, "--validate", str(capture), expect_success=False)
        envelope["capture"]["originalSHA256"] = source_digest
        envelope["capture"]["fallbackOriginalSHA256"] = "0" * 64
        capture.write_text(json.dumps(envelope))
        run(cli, "--validate", str(capture), expect_success=False)
        envelope["capture"]["fallbackOriginalSHA256"] = source_digest
        envelope["capture"]["fallbackOriginalWidth"] = 15
        capture.write_text(json.dumps(envelope))
        run(cli, "--validate", str(capture), expect_success=False)
        envelope["capture"]["fallbackOriginalWidth"] = 16
        envelope["derived"]["albedo"]["sha256"] = "0" * 64
        capture.write_text(json.dumps(envelope))
        run(cli, "--validate", str(capture), expect_success=False)

        upscaled = root / "upscaled"
        stub = pathlib.Path(__file__).with_name("UpscaleStub.py")
        run(cli, "--input", str(image), "--output", str(upscaled), "--preset", "stone",
            "--pre-upscale-exec", sys.executable,
            "--pre-upscale-arg", str(stub),
            "--pre-upscale-arg", "--input", "--pre-upscale-arg", "{input}",
            "--pre-upscale-arg", "--output", "--pre-upscale-arg", "{output}")
        upscaled_bundle = root / "upscaled.pbrmaterial"
        run(cli, "--validate", str(upscaled_bundle))
        scaled_manifest = json.loads((upscaled_bundle / "manifest.json").read_text())
        scaled_source = scaled_manifest["source"]
        assert scaled_source["sha256"] == source_digest
        assert scaled_source["pre_upscale"]["input_sha256"] == source_digest
        assert scaled_source["processed_sha256"] == scaled_source["pre_upscale"]["output_sha256"]
        assert scaled_source["pre_upscale"]["output_dimensions_px"] == [32, 32]
        assert len(scaled_source["pre_upscale"]["output_sha256"]) == 64
        assert len(scaled_source["pre_upscale"]["executable_sha256"]) == 64
        assert scaled_source["pre_upscale"]["receipt"]["model"] == "nearest-neighbor-test-stub"
        assert len(scaled_source["pre_upscale"]["receipt_sha256"]) == 64
        assert hashlib.sha256(base64.b64decode(scaled_source["pre_upscale"]["receipt_json_base64"])).hexdigest() == scaled_source["pre_upscale"]["receipt_sha256"]
        assert scaled_source["pre_upscale"]["executable"] == pathlib.Path(sys.executable).name
        assert scaled_source["path"] == "source.png"
        assert any(item["path"] == stub.name and len(item["sha256"]) == 64
                   for item in scaled_source["pre_upscale"]["local_argument_files"])
        assert scaled_manifest["maps"]["height"]["width"] == 32
        manifest_path = upscaled_bundle / "manifest.json"
        for key_path, forged in (
            (("source", "processed_sha256"), "0" * 64),
            (("source", "pre_upscale", "input_sha256"), "0" * 64),
            (("source", "pre_upscale", "output_sha256"), "0" * 64),
            (("source", "pre_upscale", "output_dimensions_px"), [999, 999]),
            (("source", "pre_upscale", "receipt", "sourceSHA256"), "0" * 64),
            (("source", "pre_upscale", "receipt", "outputSHA256"), "0" * 64),
            (("source", "pre_upscale", "receipt_sha256"), "0" * 64),
            (("source", "pre_upscale", "receipt_json_base64"), base64.b64encode(b"{}").decode()),
        ):
            tampered = json.loads(json.dumps(scaled_manifest))
            current = tampered
            for key in key_path[:-1]:
                current = current[key]
            current[key_path[-1]] = forged
            manifest_path.write_text(json.dumps(tampered))
            run(cli, "--validate", str(upscaled_bundle), expect_success=False)
        missing_receipt_proof = json.loads(json.dumps(scaled_manifest))
        del missing_receipt_proof["source"]["pre_upscale"]["receipt_json_base64"]
        manifest_path.write_text(json.dumps(missing_receipt_proof))
        run(cli, "--validate", str(upscaled_bundle), expect_success=False)
        manifest_path.write_text(json.dumps(scaled_manifest))
        run(cli, "--validate", str(upscaled_bundle))
        run(cli, "--input", str(image), "--output", str(root / "bad-receipt"),
            "--pre-upscale-exec", sys.executable,
            "--pre-upscale-arg", str(stub),
            "--pre-upscale-arg", "--input", "--pre-upscale-arg", "{input}",
            "--pre-upscale-arg", "--output", "--pre-upscale-arg", "{output}",
            "--pre-upscale-arg", "--bad-receipt", expect_success=False)
        run(cli, "--input", str(image), "--output", str(root / "bad-upscale"),
            "--pre-upscale-exec", sys.executable,
            "--pre-upscale-arg", str(stub), "--pre-upscale-arg", "{input}",
            expect_success=False)
        stub_args = ["--pre-upscale-exec", sys.executable, "--pre-upscale-arg", str(stub),
                     "--pre-upscale-arg", "--input", "--pre-upscale-arg", "{input}",
                     "--pre-upscale-arg", "--output", "--pre-upscale-arg", "{output}"]
        failing = run(cli, "--input", str(image), "--output", str(root / "failing-upscale"), *stub_args,
                      "--pre-upscale-arg", "--fail", expect_success=False)
        assert "STUB-STDOUT-MARKER" not in failing.stdout and "STUB-STDOUT-MARKER" in failing.stderr
        assert "status 3" in failing.stderr
        assert not (root / "failing-upscale.pbrmaterial").exists()
        slow = run(cli, "--input", str(image), "--output", str(root / "slow-upscale"), *stub_args,
                   "--pre-upscale-arg", "--sleep", "--pre-upscale-arg", "30",
                   "--pre-upscale-timeout", "1", expect_success=False)
        assert "timed out" in slow.stderr
        assert not list(root.glob("slow-upscale*"))
        ok = run(cli, "--input", str(image), "--output", str(root / "stdout-upscale"), *stub_args)
        assert ok.stdout.strip().endswith("stdout-upscale.pbrmaterial") and "MARKER" not in ok.stdout

        # Recipe flags: preset applies first regardless of position; new 1.1.0 controls are recorded.
        flagged = root / "flagged.pbrmaterial"
        run(cli, "--roughness", "0.4", "--normal-strength", "2", "--ao-strength", "1.5", "--equalize", "0.3",
            "--seamless", "0.1", "--normal-dx", "--input", str(image), "--output", str(flagged),
            "--preset", "stone")
        run(cli, "--validate", str(flagged))
        flagged_manifest = json.loads((flagged / "manifest.json").read_text())
        recipe = flagged_manifest["recipe"]
        assert recipe["preset"] == "stone" and abs(recipe["roughness_base"] - 0.4) < 1e-6
        assert abs(recipe["normal_strength"] - 2) < 1e-6 and abs(recipe["ao_strength"] - 1.5) < 1e-6
        assert abs(recipe["albedo_equalize"] - 0.3) < 1e-6 and abs(recipe["seamless_blend"] - 0.1) < 1e-6
        assert recipe["normal_y_down"] is True and flagged_manifest["normal_convention"] == "-Y"
        assert recipe["seamless_mode"] == "cut"
        blended = root / "blended.pbrmaterial"
        run(cli, "--input", str(image), "--output", str(blended), "--seamless", "0.2", "--seamless-mode", "blend")
        run(cli, "--validate", str(blended))
        assert json.loads((blended / "manifest.json").read_text())["recipe"]["seamless_mode"] == "blend"
        run(cli, "--input", str(image), "--output", str(root / "bad-mode"), "--seamless-mode", "quilt", expect_success=False)
        assert manifest["normal_convention"] == "+Y" and manifest["recipe"]["normal_y_down"] is False
        run(cli, "--input", str(image), "--output", str(root / "bad-flag"), "--seamless", "0.6", expect_success=False)

        # Normal convention: height rising toward the image bottom encodes green > 128 for +Y, < 128 for -Y.
        ramp = root / "ramp.r16"
        ramp.write_bytes(b"".join(struct.pack("<H", y * 65535 // 15) for y in range(16) for _ in range(16)))
        for name, extra, check in (("ramp-gl", [], lambda g: g > 128), ("ramp-dx", ["--normal-dx"], lambda g: g < 128)):
            run(cli, "--input", str(image), "--output", str(root / name), "--no-tile",
                "--height-override-r16le", str(ramp), *extra)
            width, height, bpp, rows = read_png(root / f"{name}.pbrmaterial" / "normal.png")
            red, green = rows[8][8 * bpp], rows[8][8 * bpp + 1]
            assert red == 128 and check(green), (name, red, green)

        # Guide normals (the learned path without a model): provenance is recorded and enforced.
        guided = root / "guided.pbrmaterial"
        run(cli, "--input", str(image), "--output", str(guided), "--guide-normals",
            str(root / "ramp-gl.pbrmaterial" / "normal.png"), "--guide-weight", "0.7", "--preset", "stone")
        run(cli, "--validate", str(guided))
        guided_manifest = json.loads((guided / "manifest.json").read_text())
        assert abs(guided_manifest["recipe"]["guide_normal_weight"] - 0.7) < 1e-6
        assert guided_manifest["guide_normals"]["contract"] == "tangent_normals_plus_y_v1"
        assert guided_manifest["maps"]["height"]["provenance"] == "estimated_from_albedo_and_learned_normals"
        assert 0 <= guided_manifest["relief"]["learned_form_share"] <= 0.7 + 1e-6
        assert -1 <= guided_manifest["relief"]["learned_detail_correlation"] <= 1
        run(cli, "--input", str(image), "--output", str(root / "save-guide"), "--guide-normals", str(image),
            "--save-guide-normals", str(root / "g.png"), expect_success=False)  # Saving needs the estimator.
        assert manifest["recipe"]["guide_normal_weight"] == 0 and "guide_normals" not in manifest
        run(cli, "--input", str(image), "--output", str(root / "no-guide"), "--guide-weight", "0.5", expect_success=False)
        run(cli, "--input", str(image), "--output", str(root / "both-guides"), "--guide-normals", str(image),
            "--learned-normals", str(image), expect_success=False)
        guided_good = guided_manifest
        def forge_guide(mutate):
            tampered = json.loads(json.dumps(guided_good))
            mutate(tampered)
            (guided / "manifest.json").write_text(json.dumps(tampered))
            run(cli, "--validate", str(guided), expect_success=False)
        forge_guide(lambda m: m.pop("guide_normals"))
        forge_guide(lambda m: m["recipe"].__setitem__("guide_normal_weight", 0))
        forge_guide(lambda m: m["recipe"].__setitem__("guide_normal_weight", 1.5))
        forge_guide(lambda m: m["guide_normals"].__setitem__("contract", "something_else"))
        (guided / "manifest.json").write_text(json.dumps(guided_good))
        run(cli, "--validate", str(guided))

        # 1.4.0 explicit albedo repair: the albedo is derived data with hashes and seam measures, and is enforced.
        repaired = root / "repaired.pbrmaterial"
        run(cli, "--input", str(image), "--output", str(repaired), "--preset", "organic", "--repair-albedo", "auto")
        run(cli, "--validate", str(repaired))
        repaired_good = json.loads((repaired / "manifest.json").read_text())
        block = repaired_good["albedo_repair"]
        assert repaired_good["recipe"]["albedo_repair"] == "auto" and block["mode"] == "auto"
        assert block["method"] in ("quilt", "blend") and abs(block["band_fraction"] - 0.12) < 1e-6
        assert block["source_sha256"] == repaired_good["source"]["sha256"]
        assert repaired_good["maps"]["albedo"]["provenance"] == "repaired_tileable_albedo_derived_from_source"
        for key in ("pixel_x", "pixel_y", "tone_x", "tone_y", "detail"):
            assert key in block["seam_before"] and key in block["seam_after"]
        run(cli, "--input", str(image), "--output", str(root / "repair-no-tile"), "--repair-albedo", "quilt", "--no-tile",
            expect_success=False)
        run(cli, "--input", str(image), "--output", str(root / "repair-bad"), "--repair-albedo", "magic", expect_success=False)
        def forge_repair(mutate):
            tampered = json.loads(json.dumps(repaired_good))
            mutate(tampered)
            (repaired / "manifest.json").write_text(json.dumps(tampered))
            run(cli, "--validate", str(repaired), expect_success=False)
        forge_repair(lambda m: m.pop("albedo_repair"))
        forge_repair(lambda m: m["albedo_repair"].update(mode="quilt"))
        forge_repair(lambda m: m["albedo_repair"].update(source_sha256="0" * 64))
        forge_repair(lambda m: m["albedo_repair"].update(repaired_rgba8_sha256="nope"))
        forge_repair(lambda m: m["albedo_repair"]["seam_after"].pop("tone_x"))
        forge_repair(lambda m: m["maps"]["albedo"].update(provenance="source_color_converted_to_srgb"))
        forge_repair(lambda m: m["recipe"].update(albedo_repair="off"))
        forge_repair(lambda m: m["recipe"].update(albedo_repair="sometimes"))
        (repaired / "manifest.json").write_text(json.dumps(repaired_good))
        run(cli, "--validate", str(repaired))

        # Bundle tools: --info (text and JSON), --contact-sheet, --diff; each validates its bundles first.
        # Fresh bundles: earlier cases tamper with theirs.
        tool_a, tool_b = root / "tool-a.pbrmaterial", root / "tool-b.pbrmaterial"
        run(cli, "--input", str(image), "--output", str(tool_a), "--preset", "stone", "--label", "tool a")
        run(cli, "--input", str(image), "--output", str(tool_b), "--preset", "stone", "--normal-dx")
        tool_manifest = json.loads((tool_a / "manifest.json").read_text())
        info = run(cli, "--info", str(tool_a)).stdout
        assert "Material Lab bundle" in info and "Recipe" in info and "Admitted" in info, info
        info_json = json.loads(run(cli, "--info", str(tool_a), "--json").stdout)
        assert info_json["algorithm_version"] == tool_manifest["algorithm_version"] and "albedo" in info_json["maps"]
        sheet = root / "sheet.png"
        run(cli, "--contact-sheet", str(tool_a), "--output", str(sheet))
        width, height, bpp, rows = read_png(sheet)
        assert width > 400 and height > 300 and bpp == 4
        # --preview: a deterministic lit render; a DirectX-normal bundle of the same recipe lights the same way.
        lit_a, lit_a2, lit_b = root / "lit-a.png", root / "lit-a2.png", root / "lit-b.png"
        run(cli, "--preview", str(tool_a), "--output", str(lit_a))
        run(cli, "--preview", str(tool_a), "--output", str(lit_a2))
        run(cli, "--preview", str(tool_b), "--output", str(lit_b))
        assert lit_a.read_bytes() == lit_a2.read_bytes()
        width, height, bpp, rows_a = read_png(lit_a)
        assert (width, height, bpp) == (1352, 688, 4)
        rows_b = read_png(lit_b)[3]
        centre = rows_a[height // 2][(24 + 320) * 4:(24 + 320) * 4 + 3]
        assert max(centre) > 40, centre  # The sphere is lit.
        worst = max(abs(x - y) for ra, rb in zip(rows_a, rows_b) for x, y in zip(ra, rb))
        assert worst <= 6, worst
        run(cli, "--preview", str(tool_a), expect_success=False)
        same = json.loads(run(cli, "--diff", str(tool_a), str(tool_a), "--json").stdout)
        assert same["identical"] is True
        changed = json.loads(run(cli, "--diff", str(tool_a), str(tool_b), "--json").stdout)
        assert changed["identical"] is False and any(c["key"] == "normal_y_down" for c in changed["recipe_changes"])
        run(cli, "--info", str(root / "missing.pbrmaterial"), expect_success=False)
        run(cli, "--info", str(tool_a), "--input", str(image), expect_success=False)  # Tools exclude derive options.

        # Exports: glTF binary, USDZ (64-byte aligned stored ZIP) and engine folders.
        exports = root / "exports"
        exports.mkdir()
        glb = exports / "m.glb"
        run(cli, "--export", str(tool_a), "--format", "glb", "--output", str(glb))
        blob = glb.read_bytes()
        assert blob[:4] == b"glTF" and struct.unpack_from("<I", blob, 8)[0] == len(blob)
        json_length = struct.unpack_from("<I", blob, 12)[0]
        gltf = json.loads(blob[20:20 + json_length])
        material = gltf["materials"][0]
        assert material["normalTexture"]["index"] == 1 and material["pbrMetallicRoughness"]["metallicFactor"] == 0
        usdz = exports / "m.usdz"
        run(cli, "--export", str(tool_a), "--format", "usdz", "--output", str(usdz))
        import zipfile
        with zipfile.ZipFile(usdz) as archive:
            names = archive.namelist()
            assert names[0].endswith(".usda") and "textures/normal.png" in names
            raw = usdz.read_bytes()
            for entry in archive.infolist():
                assert entry.compress_type == zipfile.ZIP_STORED
                # The alignment padding lives in the local header's extra field (the central copy is empty).
                name_length, extra_length = struct.unpack_from("<HH", raw, entry.header_offset + 26)
                data_offset = entry.header_offset + 30 + name_length + extra_length
                assert data_offset % 64 == 0, (entry.filename, data_offset)
        if shutil.which("usdchecker"):
            check = subprocess.run(["usdchecker", "--arkit", str(usdz)], capture_output=True, text=True)
            assert check.returncode == 0, check.stdout + check.stderr
        for fmt, expected in (("unreal", "T_ToolA_Normal.png"), ("unity-hdrp", "ToolA_MaskMap.png"),
                              ("godot", "tool_a_orm.png"), ("blender", "tool_a_roughness.png"),
                              ("unity", "ToolA_MetallicSmoothness.png"), ("substance", "ToolA_AmbientOcclusion.png"),
                              ("roblox", "ToolA_NormalMap.png"), ("materialx", "tool_a.mtlx"),
                              ("minecraft-labpbr", "assets/minecraft/textures/block/tool_a_s.png")):
            folder = exports / fmt
            run(cli, "--export", str(tool_a), "--format", fmt, "--output", str(folder))
            assert (folder / expected).exists(), sorted(p.name for p in folder.iterdir())
            assert json.loads((folder / "material-lab-export.json").read_text())["format"] == fmt
        # Unreal gets DirectX normals: green is inverted relative to the +Y bundle.
        _, _, nbpp, bundle_rows = read_png(tool_a / "normal.png")
        _, _, _, unreal_rows = read_png(exports / "unreal" / "T_ToolA_Normal.png")
        assert unreal_rows[3][1] == 255 - bundle_rows[3][1]
        # LabPBR _n: DirectX green, ambient occlusion in blue, height in alpha (never 0).
        _, _, _, lab_rows = read_png(exports / "minecraft-labpbr/assets/minecraft/textures/block/tool_a_n.png")
        _, _, _, ao_rows = read_png(tool_a / "ao.png")
        assert lab_rows[3][1] == 255 - bundle_rows[3][1] and lab_rows[3][2] == ao_rows[3][0]
        assert min(row[x] for row in lab_rows for x in range(3, len(row), 4)) >= 1
        import xml.etree.ElementTree as ET
        mtlx = ET.parse(exports / "materialx" / "tool_a.mtlx").getroot()
        assert mtlx.tag == "materialx" and mtlx.find("surfacematerial") is not None
        assert json.loads((exports / "minecraft-labpbr" / "pack.mcmeta").read_text())["pack"]["pack_format"] > 0
        run(cli, "--export", str(tool_a), "--format", "fbx", "--output", str(exports / "x"), expect_success=False)
        run(cli, "--export", str(tool_a), "--format", "glb", "--output", str(glb), expect_success=False)  # Exists.

        formats = json.loads(run(cli, "--list-formats", "--json").stdout)
        assert [f["identifier"] for f in formats][:2] == ["glb", "usdz"] and len(formats) == 11
        assert all(f["title"] and f["detail"] for f in formats)
        # Authored inputs: a hand-made albedo and artist maps replace derived ones exactly.
        authored_dir = root / "authored"
        authored_dir.mkdir()
        gray_png(authored_dir / "rough.png", lambda x, y: x * 16)
        gray_png(authored_dir / "metal.png", lambda x, y: 255 if x < 8 else 0)
        gray_png(authored_dir / "ao.png", lambda x, y: 128 + y * 8)
        rgb_png(authored_dir / "normal.png", lambda x, y: (128 + (x % 4) * 20, 128 - (y % 4) * 20, 230))
        sample_height_png(authored_dir / "height.png")
        authored_bundle = authored_dir / "hand.pbrmaterial"
        run(cli, "--input", str(image), "--output", str(authored_bundle), "--authored", "--normal-map",
            str(authored_dir / "normal.png"), "--normal-map-dx", "--roughness-map", str(authored_dir / "rough.png"),
            "--ao-map", str(authored_dir / "ao.png"), "--metalness-map", str(authored_dir / "metal.png"))
        run(cli, "--validate", str(authored_bundle))
        hand = json.loads((authored_bundle / "manifest.json").read_text())
        assert hand["source"]["source_kind"] == "authored_albedo" and hand["maps"]["albedo"]["provenance"] == "authored_albedo"
        assert hand["maps"]["normal"]["provenance"] == "authored_normal_map"
        assert hand["maps"]["height"]["provenance"] == "integrated_from_authored_normal_map"
        assert sorted(hand["authored_inputs"]) == ["ao", "metalness", "normal", "roughness"]
        assert hand["recipe"]["assigned_metalness_enabled"] is True and "orm" in hand["maps"]
        _, _, _, rough_rows = read_png(authored_bundle / "roughness.png")
        _, _, _, orm_rows = read_png(authored_bundle / "orm.png")
        _, _, _, normal_rows = read_png(authored_bundle / "normal.png")
        assert rough_rows[0][4 * 5] == 80 and orm_rows[0][4 * 2 + 2] == 255 and orm_rows[0][4 * 12 + 2] == 0
        assert normal_rows[1][1] == 255 - (128 - 20)  # DirectX input flipped to the bundle's +Y
        # The exporter carries the per-pixel metalness into Unity's metallic map.
        run(cli, "--export", str(authored_bundle), "--format", "unity", "--output", str(authored_dir / "unity"))
        _, _, _, unity_rows = read_png(authored_dir / "unity" / "Source_MetallicSmoothness.png")
        assert unity_rows[0][0] == 255 and unity_rows[0][4 * 12] == 0
        height_bundle = authored_dir / "height.pbrmaterial"
        run(cli, "--input", str(image), "--output", str(height_bundle), "--preset", "stone", "--height-map", str(authored_dir / "height.png"))
        assert json.loads((height_bundle / "manifest.json").read_text())["maps"]["height"]["provenance"] == "authored_height_override"
        run(cli, "--input", str(image), "--output", str(authored_dir / "x"), "--normal-map-dx", expect_success=False)

        # Material presets: the library is listed, recorded in manifests and saved recipes, and validated.
        listed = json.loads(run(cli, "--list-presets", "--json").stdout)
        assert len(listed) >= 30 and {"red-brick", "wood-planks", "brushed-steel"} <= {p["identifier"] for p in listed}
        steel = next(p for p in listed if p["identifier"] == "brushed-steel")
        assert steel["recipe"]["preset"] == "bare-metal" and steel["recipe"]["assigned_metalness_enabled"] is True
        preset_bundle = root / "preset-brick.pbrmaterial"
        run(cli, "--input", str(image), "--output", str(preset_bundle), "--preset", "red-brick")
        preset_manifest = json.loads((preset_bundle / "manifest.json").read_text())
        assert preset_manifest["recipe"]["material_preset"] == "red-brick" and preset_manifest["recipe"]["preset"] == "stone"
        assert abs(preset_manifest["recipe"]["roughness_base"] - 0.82) < 1e-6
        # A later prior replaces the library preset, and is not recorded as one.
        prior_bundle = root / "prior.pbrmaterial"
        run(cli, "--input", str(image), "--output", str(prior_bundle), "--preset", "red-brick", "--preset", "fabric")
        assert "material_preset" not in json.loads((prior_bundle / "manifest.json").read_text())["recipe"]
        run(cli, "--input", str(image), "--output", str(root / "bad"), "--preset", "unobtainium", expect_success=False)
        preset_manifest["recipe"]["material_preset"] = "unobtainium"
        (preset_bundle / "manifest.json").write_text(json.dumps(preset_manifest))
        run(cli, "--validate", str(preset_bundle), expect_success=False)

        # Recipes: from a bundle, from the apps' camelCase JSON, from the Mac app's saved recipes; save one.
        pipeline = root / "pipeline"
        pipeline.mkdir()
        from_bundle = pipeline / "from-bundle.pbrmaterial"
        run(cli, "--input", str(image), "--output", str(from_bundle), "--recipe", str(tool_b))
        assert json.loads((from_bundle / "manifest.json").read_text())["recipe"]["normal_y_down"] is True
        camel = pipeline / "camel.json"
        camel.write_text(json.dumps({"preset": "coatedMetal", "heightStrength": 0.31, "normalYDown": False,
                                     "seamlessMode": "blend", "albedoRepair": "quilt", "assignedMetalness": 0.4}))
        saved_out = pipeline / "saved.json"
        run(cli, "--recipe", str(camel), "--roughness", "0.2", "--save-recipe", str(saved_out))
        saved = json.loads(saved_out.read_text())
        assert saved["preset"] == "coated-metal" and abs(saved["height_strength"] - 0.31) < 1e-6
        assert abs(saved["roughness_base"] - 0.2) < 1e-6 and saved["albedo_repair"] == "quilt"
        assert saved["assigned_metalness_enabled"] is True and saved["seamless_mode"] == "blend"
        home = pipeline / "home"
        (home / "Library/Application Support/Material Lab").mkdir(parents=True)
        (home / "Library/Application Support/Material Lab/saved-recipes.json").write_text(json.dumps(
            [{"name": "Wet slate", "recipe": {"preset": "stone", "heightStrength": 0.12}}]))
        env = dict(os.environ, HOME=str(home))
        slate = subprocess.run([cli, "--saved-recipe", "wet SLATE", "--save-recipe", str(pipeline / "slate.json")],
                               env=env, capture_output=True, text=True)
        assert slate.returncode == 0, slate.stderr
        assert abs(json.loads((pipeline / "slate.json").read_text())["height_strength"] - 0.12) < 1e-6
        missing = subprocess.run([cli, "--saved-recipe", "nope", "--save-recipe", str(pipeline / "x.json")],
                                 env=env, capture_output=True, text=True)
        assert missing.returncode == 1 and "Wet slate" in missing.stderr
        run(cli, "--recipe", str(camel), "--preset", "stone", "--save-recipe", str(pipeline / "y.json"), expect_success=False)

        # --also-export and --report on a single derive.
        exported = pipeline / "exported.pbrmaterial"
        report = pipeline / "report.json"
        run(cli, "--input", str(image), "--output", str(exported), "--also-export", "glb,godot", "--report", str(report))
        assert (pipeline / "exported.glb").exists() and (pipeline / "exported-godot").is_dir()
        assert json.loads(report.read_text())["items"][0]["status"] == "derived"
        run(cli, "--input", str(image), "--output", str(pipeline / "bad"), "--also-export", "fbx", expect_success=False)

        # Parallel catalog batch with a report.
        batch_dir = pipeline / "batch"
        batch_dir.mkdir()
        for name in ("a", "b", "c"):
            shutil.copy(image, batch_dir / f"{name}.png")
        (batch_dir / "catalog.json").write_text(json.dumps({"items": [
            {"path": f"{n}.png", "label": n, "reviewed": True} for n in ("a", "b", "c")]}))
        batch_out, batch_report = pipeline / "batch-out", pipeline / "batch-report.json"
        run(cli, "--catalog", str(batch_dir / "catalog.json"), "--output", str(batch_out), "--jobs", "2",
            "--report", str(batch_report), "--preset", "stone")
        rows = json.loads(batch_report.read_text())["items"]
        assert sorted(r["status"] for r in rows) == ["derived"] * 3
        for name in ("a", "b", "c"):
            run(cli, "--validate", str(batch_out / f"{name}.pbrmaterial"))
        run(cli, "--input", str(image), "--output", str(pipeline / "j"), "--jobs", "2", expect_success=False)

        # --watch derives a dropped image, then stops cleanly on SIGINT.
        inbox, watched = pipeline / "inbox", pipeline / "watched"
        inbox.mkdir()
        watcher = subprocess.Popen([cli, "--watch", str(inbox), "--output", str(watched)], stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        try:
            time.sleep(0.5)
            shutil.copy(image, inbox / "dropped.png")
            for _ in range(100):
                if (watched / "dropped.pbrmaterial" / "manifest.json").exists():
                    break
                time.sleep(0.2)
            assert (watched / "dropped.pbrmaterial" / "manifest.json").exists(), "watch did not derive the dropped image"
        finally:
            watcher.send_signal(signal.SIGINT)
            out, err = watcher.communicate(timeout=20)
        assert "stopped watching; derived 1 of 1" in out, (out, err)
        run(cli, "--validate", str(watched / "dropped.pbrmaterial"))

        # Non-ASCII labels survive; a bare relative --output lands in the working directory.
        label = "ardoise \u00e9clat \u77f3"
        run(cli, "--input", str(image), "--output", "bare", "--label", label, cwd=root)
        assert json.loads((root / "bare.pbrmaterial" / "manifest.json").read_text(encoding="utf-8"))["semantic_label"] == label
        run(cli, "--validate", "bare.pbrmaterial", cwd=root)
        run(cli, "--input", str(image), "--output", "bare", cwd=root, expect_success=False)  # Existing output.

        # Forged manifests are rejected with an orderly error.
        good = json.loads((bundle / "manifest.json").read_text())
        forged_bundle = root / "forged.pbrmaterial"
        run(cli, "--input", str(image), "--output", str(forged_bundle), "--preset", "stone",
            "--metalness", "0.2", "--bent-normal")
        good = json.loads((forged_bundle / "manifest.json").read_text())
        run(cli, "--validate", str(forged_bundle))
        def forge(mutate):
            tampered = json.loads(json.dumps(good))
            mutate(tampered)
            (forged_bundle / "manifest.json").write_text(json.dumps(tampered))
            run(cli, "--validate", str(forged_bundle), expect_success=False)
        forge(lambda m: m.pop("runtime_admitted"))
        forge(lambda m: m.update(runtime_admitted="no"))
        forge(lambda m: m.update(runtime_admitted=0))
        forge(lambda m: m.update(runtime_admitted=True))
        forge(lambda m: m.update(schema_version=True))
        forge(lambda m: m.update(material_id=5))
        forge(lambda m: m.update(semantic_label=["x"]))
        forge(lambda m: m.update(algorithm_version="9.9.9"))
        forge(lambda m: m.pop("normal_convention"))
        forge(lambda m: m.update(normal_convention="-Y"))
        forge(lambda m: m["recipe"].update(height_strength="0.2"))
        forge(lambda m: m["recipe"].update(normal_strength=20))
        forge(lambda m: m["recipe"].update(tile_wrap=1))
        forge(lambda m: m["recipe"].pop("seamless_blend"))
        forge(lambda m: m["recipe"].update(assigned_metalness_enabled=False))  # ORM present without flag.
        forge(lambda m: m["recipe"].update(bent_normal_enabled=False))
        forge(lambda m: m["maps"].pop("cavity"))
        forge(lambda m: m["maps"].update(extra=m["maps"]["edge"]))
        forge(lambda m: m["maps"]["albedo"].update(sha256=5))
        forge(lambda m: m["maps"]["albedo"].update(width="16"))
        forge(lambda m: m["maps"].update(roughness=dict(m["maps"]["ao"], pixel_format="rgba8_linear_png")))  # File swap.
        forge(lambda m: m["source"].update(sha256=None))
        forge(lambda m: m.update(maps=[]))
        forge(lambda m: m.pop("relief"))
        forge(lambda m: m["relief"].update(height_span_tile_widths=-1))
        forge(lambda m: m["relief"].update(detail_polarity=0))
        forge(lambda m: m["relief"].update(learned_form_share=2))
        forge(lambda m: m["relief"].pop("height_wrap_seam_ratio"))
        # 1.5.0 fields: range-checked, all-or-none in relief, and only from 1.5.0 on.
        assert all(key in good["recipe"] for key in V15_RECIPE) and all(key in good["relief"] for key in V15_RELIEF)
        forge(lambda m: m["recipe"].update(mid_relief_share=.95))
        forge(lambda m: m["recipe"].update(roughness_albedo_limit=-.1))
        forge(lambda m: m["recipe"].update(tile_metres=float("nan")))
        forge(lambda m: m["relief"].pop("mid_relief_share_after"))
        forge(lambda m: m["relief"].update(roughness_albedo_correlation_after=1.5))
        forge(lambda m: m.update(algorithm_version="1.4.0"))
        app_style = json.loads(json.dumps(good))  # Absent 1.5.0 fields mean the preset defaults.
        for key in V15_RECIPE:
            app_style["recipe"].pop(key)
        for key in V15_RELIEF:
            app_style["relief"].pop(key)
        (forged_bundle / "manifest.json").write_text(json.dumps(app_style))
        run(cli, "--validate", str(forged_bundle))
        (forged_bundle / "manifest.json").write_text("[1, 2]")
        run(cli, "--validate", str(forged_bundle), expect_success=False)
        upper = json.loads(json.dumps(good))
        upper["maps"]["albedo"]["sha256"] = upper["maps"]["albedo"]["sha256"].upper()
        (forged_bundle / "manifest.json").write_text(json.dumps(upper))
        run(cli, "--validate", str(forged_bundle))  # Hash comparison is case-insensitive.
        # Legacy 1.0.0 bundles lack the new fields and are accepted with a green-down warning.
        legacy = json.loads(json.dumps(good))
        legacy["algorithm_version"] = "1.0.0"
        legacy.pop("normal_convention")
        for key in ("normal_strength", "normal_y_down", "ao_strength", "albedo_equalize", "seamless_blend") + V15_RECIPE:
            legacy["recipe"].pop(key)
        for key in V15_RELIEF:
            legacy["relief"].pop(key)
        (forged_bundle / "manifest.json").write_text(json.dumps(legacy))
        legacy_result = run(cli, "--validate", str(forged_bundle))
        assert "green-down" in legacy_result.stderr
        (forged_bundle / "manifest.json").write_text(json.dumps(good))
        (forged_bundle / "roughness.png").write_bytes((forged_bundle / "ao.png").read_bytes())
        run(cli, "--validate", str(forged_bundle), expect_success=False)

        catalog = root / "catalog.json"
        catalog.write_text(json.dumps({"items": [
            {"id": "checked_surface", "path": "source.png", "label": "checked surface", "reviewed": True}]}))
        run(cli, "--catalog", str(catalog), "--output", str(root / "batch"), "--preset", "fabric")
        run(cli, "--validate", str(root / "batch" / "checked_surface.pbrmaterial"))
        catalog.write_text(json.dumps({"assets": [
            {"id": "asset_surface", "path": "source.png", "label": "asset surface", "review_status": "approved"}]}))
        run(cli, "--catalog", str(catalog), "--output", str(root / "asset_batch"), "--preset", "fabric")
        run(cli, "--validate", str(root / "asset_batch" / "asset_surface.pbrmaterial"))
        catalog.write_text(json.dumps({"items": [
            {"id": "candidate", "path": "source.png", "label": "candidate", "reviewed": False}]}))
        run(cli, "--catalog", str(catalog), "--output", str(root / "unreviewed"), expect_success=False)
        run(cli, "--catalog", str(catalog), "--output", str(root / "opted_in"),
            "--include-unreviewed")
        opted = json.loads((root / "opted_in" / "candidate.pbrmaterial" / "manifest.json").read_text())
        assert opted["source_review_status"] == "unreviewed" and opted["included_by_opt_in"] is True
        reviewed_manifest = json.loads((root / "batch" / "checked_surface.pbrmaterial" / "manifest.json").read_text())
        assert reviewed_manifest["source_review_status"] == "reviewed" and reviewed_manifest["included_by_opt_in"] is False

        # Catalog path containment: symlinks and ".." components are rejected; "foo..v2.png" is a name.
        catalog_root = root / "catalog_root"
        (catalog_root / "textures").mkdir(parents=True)
        outside = root / "outside"
        outside.mkdir()
        sample_png(outside / "secret.png")
        sample_png(catalog_root / "foo..v2.png")
        os.symlink(outside / "secret.png", catalog_root / "link.png")
        os.symlink(outside, catalog_root / "linked_dir")
        sample_png(catalog_root / "textures" / "wall.png")
        nested = catalog_root / "catalog.json"
        def catalog_run(items, *extra, expect_success=True, output="out"):
            nested.write_text(json.dumps({"items": items}, ensure_ascii=False))
            return run(cli, "--catalog", str(nested), "--output", str(catalog_root / output), *extra,
                       expect_success=expect_success)
        catalog_run([{"id": "dots", "path": "foo..v2.png", "reviewed": True, "label": "\u77f3\u306e\u58c1"}], output="dots")
        dots = json.loads((catalog_root / "dots" / "dots.pbrmaterial" / "manifest.json").read_text(encoding="utf-8"))
        assert dots["semantic_label"] == "\u77f3\u306e\u58c1" and dots["source"]["path"] == "foo..v2.png"
        for escape in ("link.png", "linked_dir/secret.png", "../outside/secret.png", "textures/../../outside/secret.png",
                       str(outside / "secret.png")):
            catalog_run([{"id": "escape", "path": escape, "reviewed": True}], expect_success=False, output="escape")
            assert not (catalog_root / "escape").exists()
        catalog_run([{"id": "same", "path": "textures/wall.png", "reviewed": True},
                     {"id": "same", "path": "foo..v2.png", "reviewed": True}], expect_success=False, output="dupes")
        assert not (catalog_root / "dupes").exists()  # Duplicates fail before any derivation.
        catalog_run([{"id": 7, "path": "textures/wall.png", "reviewed": True}], expect_success=False, output="badid")
        catalog_run([{"id": "x", "path": ["textures/wall.png"], "reviewed": True}], expect_success=False, output="badpath")
        catalog_run([{"id": "x", "path": "textures/wall.png", "reviewed": 1}], expect_success=False, output="numflag")
        # Per-item failure: stop by default; --keep-going derives the rest and reports a summary.
        mixed = [{"id": "broken", "path": "textures/wall.png", "reviewed": True},
                 {"id": "fine", "path": "foo..v2.png", "reviewed": True}]
        (catalog_root / "textures" / "wall.png").write_bytes(b"not an image")
        catalog_run(mixed, expect_success=False, output="stop")
        assert not (catalog_root / "stop" / "fine.pbrmaterial").exists()
        going = catalog_run(mixed, "--keep-going", expect_success=False, output="going")
        assert (catalog_root / "going" / "fine.pbrmaterial").is_dir()
        assert "derived 1 material bundles, 1 failed" in going.stdout

        # Composed bundles (CLI 1.4.0): layers, variants and larger tiles, validated and traceable to their sources.
        compose = root / "compose"
        compose.mkdir()
        textured_png(compose / "stone.png")
        textured_png(compose / "moss.png", tint=(0.45, 0.8, 0.35), phase=0.3)
        run(cli, "--input", str(compose / "stone.png"), "--output", str(compose / "stone"), "--preset", "stone")
        run(cli, "--input", str(compose / "moss.png"), "--output", str(compose / "moss"), "--preset", "organic", "--metalness", "0.3")
        base, top = compose / "stone.pbrmaterial", compose / "moss.pbrmaterial"
        def composed(path):
            run(cli, "--validate", str(path))
            return json.loads((path / "manifest.json").read_text())
        printed = run(cli, "layer", "--base", str(base), "--top", str(top), "--mask", "height", "--invert",
                      "--output", str(compose / "mossy"), "--label", "mossy stone").stdout.strip()
        assert printed == str(compose / "mossy.pbrmaterial")
        layered = composed(compose / "mossy.pbrmaterial")
        assert layered["source"]["source_kind"] == "derived_bundle" and layered["semantic_label"] == "mossy stone"
        assert layered["source"]["sha256"] == hashlib.sha256((base / "manifest.json").read_bytes()).hexdigest()
        assert layered["layers"]["top"]["manifest_sha256"] == hashlib.sha256((top / "manifest.json").read_bytes()).hexdigest()
        assert layered["layers"]["mask"] == {"type": "height", "threshold": 0.5, "softness": layered["layers"]["mask"]["softness"], "invert": True}
        assert layered["recipe"]["assigned_metalness_enabled"] and "orm" in layered["maps"]
        assert layered["maps"]["albedo"]["provenance"] == "layer_blend_albedo"
        assert layered["maps"]["normal"]["provenance"] == "derived_from_composed_height"
        for name in ("noise-a", "noise-b"):
            run(cli, "layer", "--base", str(base), "--top", str(top), "--mask", "noise", "--seed", "4", "--scale", "2",
                "--output", str(compose / name))
        assert (compose / "noise-a.pbrmaterial" / "albedo.png").read_bytes() == (compose / "noise-b.pbrmaterial" / "albedo.png").read_bytes()
        gray_png(compose / "paint.png", lambda x, y: 255 if x < 8 else 0)
        painted = run(cli, "layer", "--base", str(base), "--top", str(top), "--mask", str(compose / "paint.png"),
                      "--normal-blend", "reoriented", "--output", str(compose / "painted")).stdout.strip()
        painted_manifest = composed(pathlib.Path(painted))
        assert painted_manifest["layers"]["mask"]["sha256"] == hashlib.sha256((compose / "paint.png").read_bytes()).hexdigest()
        # A 16 px painted mask over 32 px maps: the mask is resampled, the top (same size) is not.
        assert painted_manifest["layers"]["top_resampled"] is False and painted_manifest["layers"]["mask"]["size_px"] == 16
        run(cli, "layer", "--base", str(base), "--top", str(top), "--mask", "slope", "--output", str(compose / "mossy"),
            expect_success=False)  # never overwrites
        run(cli, "layer", "--base", str(base), "--top", str(top), "--mask", "cloudy", "--output", str(compose / "x"),
            expect_success=False)
        run(cli, "layer", "--base", str(base), "--top", str(compose / "missing.pbrmaterial"), "--mask", "slope",
            "--output", str(compose / "x"), expect_success=False)
        # Variants: deterministic per seed, different across seeds; the drawn shifts are recorded.
        for name, seed in (("v7", "7"), ("v7b", "7"), ("v8", "8")):
            run(cli, "--input", str(base), "--variant", seed, "--output", str(compose / name))
        assert (compose / "v7.pbrmaterial" / "normal.png").read_bytes() == (compose / "v7b.pbrmaterial" / "normal.png").read_bytes()
        assert (compose / "v7.pbrmaterial" / "albedo.png").read_bytes() != (compose / "v8.pbrmaterial" / "albedo.png").read_bytes()
        variant = composed(compose / "v7.pbrmaterial")
        assert variant["variant"]["seed"] == 7 and abs(variant["variant"]["drawn"]["hue_degrees"]) <= 6
        # From a photo: derive, vary, then a 2 x 2 tile; only the final bundle remains and the chain is recorded.
        run(cli, "--input", str(compose / "stone.png"), "--preset", "stone", "--variant", "3", "--large-tile", "2",
            "--output", str(compose / "big"))
        big = composed(compose / "big.pbrmaterial")
        assert big["maps"]["albedo"]["width"] == 64 and big["large_tile"]["tiles"] == 2
        assert big["source"]["path"] == "intermediate" and big["large_tile"]["source"]["variant"]["seed"] == 3
        assert big["large_tile"]["source"]["variant"]["source"]["source"]["path"] == "stone.png"
        assert not [p for p in compose.iterdir() if ".stage-" in p.name]
        run(cli, "--input", str(base), "--large-tile", "3", "--output", str(compose / "bad"), expect_success=False)
        run(cli, "--input", str(compose / "stone.png"), "--no-tile", "--large-tile", "2", "--output", str(compose / "bad"),
            expect_success=False)
        run(cli, "--input", str(base), "--output", str(compose / "bad"), expect_success=False)  # a bundle input needs an operation
        tampered = json.loads((compose / "v8.pbrmaterial" / "manifest.json").read_text())
        tampered["layers"] = layered["layers"]
        (compose / "v8.pbrmaterial" / "manifest.json").write_text(json.dumps(tampered))
        run(cli, "--validate", str(compose / "v8.pbrmaterial"), expect_success=False)
    print("Material Lab CLI smoke tests passed")


if __name__ == "__main__":
    main()
