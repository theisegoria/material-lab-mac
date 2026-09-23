#!/usr/bin/env python3
"""End-to-end bundle contract checks with only Python's standard library."""
import base64
import hashlib
import uuid
import json
import pathlib
import struct
import subprocess
import sys
import tempfile
import zlib


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


def run(cli: str, *args: str, expect_success=True) -> subprocess.CompletedProcess:
    process = subprocess.run([cli, *args], text=True, capture_output=True)
    if (process.returncode == 0) != expect_success:
        raise AssertionError(f"unexpected CLI status: {process.returncode}\n{process.stdout}\n{process.stderr}")
    return process


def main() -> None:
    cli = sys.argv[1]
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
            "sourceSHA256": source_digest, "algorithmVersion": "1.0.0",
            "recipe": {"preset": "stone", "heightStrength": 0.22, "heightPolarity": 1,
                       "roughnessBase": 0.78, "roughnessVariation": 0.15,
                       "aoRadiusPixels": 10, "tileWrap": True, "bentNormal": False},
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
        assert any(item["path"] == str(stub) and len(item["sha256"]) == 64
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
    print("Material Lab CLI smoke tests passed")


if __name__ == "__main__":
    main()
