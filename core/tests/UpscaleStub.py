#!/usr/bin/env python3
"""Local no-network 2x PNG resize stub for CLI argv-hook tests only."""
import argparse
import hashlib
import json
import pathlib
import struct
import sys
import time
import zlib


def chunk(kind, content):
    body = kind + content
    return struct.pack(">I", len(content)) + body + struct.pack(">I", zlib.crc32(body))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--bad-receipt", action="store_true")
    parser.add_argument("--fail", action="store_true", help="print a stdout marker and exit 3")
    parser.add_argument("--sleep", type=float, default=0, help="stall before working (timeout tests)")
    args = parser.parse_args()
    print("STUB-STDOUT-MARKER", flush=True)
    if args.fail:
        print("stub failure requested", file=sys.stderr)
        raise SystemExit(3)
    if args.sleep:
        time.sleep(args.sleep)
    source = pathlib.Path(args.input).read_bytes()
    if not source.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("stub requires PNG")
    width, height, depth, color = struct.unpack_from(">IIBB", source, 16)
    if depth != 8 or color != 6 or width != height or width > 128:
        raise ValueError("stub requires a small RGBA8 square")
    offset = 8
    compressed = bytearray()
    while offset + 12 <= len(source):
        length = struct.unpack_from(">I", source, offset)[0]
        kind = source[offset + 4:offset + 8]
        data = source[offset + 8:offset + 8 + length]
        if kind == b"IDAT":
            compressed.extend(data)
        offset += length + 12
        if kind == b"IEND":
            break
    decoded = zlib.decompress(compressed)
    rows = []
    stride = width * 4 + 1
    for y in range(height):
        row = decoded[y * stride:(y + 1) * stride]
        if row[0] != 0:
            raise ValueError("stub supports PNG filter 0 only")
        expanded = b"".join(row[1 + x * 4:1 + (x + 1) * 4] * 2 for x in range(width))
        rows.extend((b"\x00" + expanded, b"\x00" + expanded))
    doubled = width * 2
    result = bytearray(b"\x89PNG\r\n\x1a\n")
    result += chunk(b"IHDR", struct.pack(">IIBBBBB", doubled, doubled, 8, 6, 0, 0, 0))
    result += chunk(b"sRGB", b"\x00")
    result += chunk(b"IDAT", zlib.compress(b"".join(rows)))
    result += chunk(b"IEND", b"")
    pathlib.Path(args.output).write_bytes(result)
    receipt = {"schemaVersion": 1, "operation": "test-local-upscale",
               "sourceSHA256": hashlib.sha256(source).hexdigest(),
               "outputSHA256": "0" * 64 if args.bad_receipt else hashlib.sha256(result).hexdigest(),
               "model": "nearest-neighbor-test-stub"}
    pathlib.Path(args.output + ".upscale.json").write_text(json.dumps(receipt))


if __name__ == "__main__":
    main()
