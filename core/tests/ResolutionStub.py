#!/usr/bin/env python3
"""Local no-network stand-in for the pinned Real-ESRGAN adapter in --resolution tests: enlarges a square PNG by
--scale with macOS sips (no learned detail) and writes a receipt. Takes the adapter's command line. Tests only."""
import argparse
import hashlib
import json
import pathlib
import struct
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--scale", type=int, choices=(2, 4), required=True)
    parser.add_argument("--no-op", action="store_true", help="copy the input unchanged (a broken upscaler)")
    # Accepted and ignored, so the stub can stand in for scripts/pinned_realesrgan.py's command line.
    parser.add_argument("--vendor-project-root")
    parser.add_argument("--device", choices=("cpu", "mps"))
    args = parser.parse_args()
    source = pathlib.Path(args.input).read_bytes()
    if not source.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("stub requires PNG")
    width, height = struct.unpack_from(">II", source, 16)
    if width != height:
        raise ValueError("stub requires a square image")
    if args.no_op:
        pathlib.Path(args.output).write_bytes(source)
    else:
        size = str(width * args.scale)
        subprocess.run(["/usr/bin/sips", "-z", size, size, args.input, "--out", args.output],
                       check=True, capture_output=True)
    result = pathlib.Path(args.output).read_bytes()
    receipt = {"schemaVersion": 1, "operation": "test-local-resolution-upscale",
               "sourceSHA256": hashlib.sha256(source).hexdigest(),
               "outputSHA256": hashlib.sha256(result).hexdigest(),
               "outputSize": [width * args.scale, width * args.scale] if not args.no_op else [width, width],
               "model": "sips-resize-test-stub", "scale": args.scale}
    pathlib.Path(args.output + ".upscale.json").write_text(json.dumps(receipt))


if __name__ == "__main__":
    main()
