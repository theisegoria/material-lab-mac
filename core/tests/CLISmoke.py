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


def sample_png(path: pathlib.Path) -> None:
    width = height = 16
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            value = 160 if (x // 4 + y // 4) % 2 else 80
            rows.extend((value, value, value, 255))
    png = bytearray(b"\x89PNG\r\n\x1a\n")
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
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
        height_png = root / "authored-height.png"
        sample_height_png(height_png)
        height_bytes = height_png.read_bytes()
        height_digest = hashlib.sha256(height_bytes).hexdigest()
        envelope = {
            "schemaVersion": 1, "bundleKind": "pbr-capture",
            "captureId": str(uuid.uuid4()), "semanticLabel": "phone checker", "category": "test",
            "sourceMime": "image/png", "sourceBase64": base64.b64encode(source_bytes).decode(),
            "sourceSHA256": source_digest, "algorithmVersion": "1.0.0", "recipe": {},
            "capture": {"originalMime": "image/png", "originalBase64": base64.b64encode(source_bytes).decode(),
                        "originalSHA256": source_digest, "originalWidth": 16, "originalHeight": 16},
            "derived": {"height": {"mime": "image/png", "base64": base64.b64encode(height_bytes).decode(),
                                    "sha256": height_digest, "width": 16, "height": 16,
                                    "pixelFormat": "r16_unorm_png", "provenance": "authored test"},
                        "albedo": {
                "mime": "image/png", "base64": base64.b64encode(source_bytes).decode(),
                "sha256": source_digest, "width": 16, "height": 16,
                "pixelFormat": "rgba8_srgb_png", "provenance": "captured test"}},
            "seamMetrics": {}, "runtimeAdmitted": False
        }
        capture = root / "sample.pbrcapture"
        capture.write_text(json.dumps(envelope))
        run(cli, "--validate", str(capture))
        envelope["capture"]["gpsLatitude"] = 42
        capture.write_text(json.dumps(envelope))
        run(cli, "--validate", str(capture), expect_success=False)
        del envelope["capture"]["gpsLatitude"]
        envelope["capture"]["originalSHA256"] = "0" * 64
        capture.write_text(json.dumps(envelope))
        run(cli, "--validate", str(capture), expect_success=False)
        envelope["capture"]["originalSHA256"] = source_digest
        envelope["derived"]["albedo"]["sha256"] = "0" * 64
        capture.write_text(json.dumps(envelope))
        run(cli, "--validate", str(capture), expect_success=False)

        catalog = root / "catalog.json"
        catalog.write_text(json.dumps({"items": [
            {"id": "checked_surface", "path": "source.png", "label": "checked surface", "reviewed": True}]}))
        run(cli, "--catalog", str(catalog), "--output", str(root / "batch"), "--preset", "fabric")
        run(cli, "--validate", str(root / "batch" / "checked_surface.pbrmaterial"))
        catalog.write_text(json.dumps({"items": [
            {"id": "candidate", "path": "source.png", "label": "candidate", "reviewed": False}]}))
        run(cli, "--catalog", str(catalog), "--output", str(root / "unreviewed"), expect_success=False)
        run(cli, "--catalog", str(catalog), "--output", str(root / "opted_in"),
            "--include-unreviewed")
    print("Material Lab CLI smoke tests passed")


if __name__ == "__main__":
    main()
