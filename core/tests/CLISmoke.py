#!/usr/bin/env python3
"""End-to-end bundle contract checks with only Python's standard library."""
import base64
import hashlib
import os
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
        for key in ("normal_strength", "normal_y_down", "ao_strength", "albedo_equalize", "seamless_blend"):
            legacy["recipe"].pop(key)
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
    print("Material Lab CLI smoke tests passed")


if __name__ == "__main__":
    main()
