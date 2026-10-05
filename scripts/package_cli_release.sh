#!/usr/bin/env bash
# Build, sign and package the material-lab CLI as a binary release:
#   material-lab-VERSION-macos-arm64.tar.gz  (bin/, share/ with the learned model, man page and completions)
# Usage: scripts/package_cli_release.sh VERSION [SIGNING_IDENTITY]
# Needs third_party/moge/build/MoGe2Normals.mlpackage (see docs/LEARNED_NORMALS.md) to bundle the model.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:?usage: package_cli_release.sh VERSION [IDENTITY]}"
identity="${2:-Developer ID Application}"
build="$repo_root/build/cli-release"
dist="$repo_root/build/dist"
name="material-lab-$version-macos-arm64"
stage="$dist/$name"
model="$repo_root/third_party/moge/build/MoGe2Normals.mlpackage"
packaging="$repo_root/packaging/cli"

rm -rf "$build" "$stage" "$dist/$name.tar.gz" "$dist/$name.tar.gz.sha256"
mkdir -p "$dist"
cmake -S "$repo_root/core" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
cmake --build "$build" --target material-lab
built_version="$("$build/material-lab" --version)"
[[ "$built_version" == "material-lab $version "* ]] || { echo "binary reports '$built_version', expected $version" >&2; exit 1; }

mkdir -p "$stage/bin" "$stage/share/material-lab" "$stage/share/man/man1" "$stage/share/zsh/site-functions" \
         "$stage/share/bash-completion/completions" "$stage/share/fish/vendor_completions.d"
cp "$build/material-lab" "$stage/bin/material-lab"
codesign --force --options runtime --timestamp --identifier io.materiallab.cli --sign "$identity" "$stage/bin/material-lab"
codesign --verify --strict --verbose=1 "$stage/bin/material-lab"
if [[ -e "$model" ]]; then
  xcrun coremlcompiler compile "$model" "$stage/share/material-lab" >/dev/null
else
  echo "warning: no learned model at $model; --learned will need the Material Lab app or MATERIAL_LAB_MODEL" >&2
fi
cp "$packaging/material-lab.1" "$stage/share/man/man1/"
cp "$packaging/completions/_material-lab" "$stage/share/zsh/site-functions/"
cp "$packaging/completions/material-lab.bash" "$stage/share/bash-completion/completions/material-lab"
cp "$packaging/completions/material-lab.fish" "$stage/share/fish/vendor_completions.d/"
cp "$packaging/README.md" "$packaging/LICENSE" "$packaging/THIRD_PARTY_NOTICES.md" "$stage/"

# Smoke test the packaged layout: version, and a learned derivation that finds the bundled model by itself.
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
"$stage/bin/material-lab" --version
python3 - "$scratch/in.png" <<'PY'
import struct, sys, zlib
w = h = 64
rows = b"".join(b"\x00" + bytes(v for x in range(w) for v in ((x * 7 + y * 3) % 256, (x * 5) % 256, (y * 9) % 256))
                for y in range(h))
def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + \
      chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")
open(sys.argv[1], "wb").write(png)
PY
learned_flag=()
[[ -d "$stage/share/material-lab/MoGe2Normals.mlmodelc" ]] && learned_flag=(--learned)
# Run it as Homebrew does: a bin/ symlink found on $PATH by bare name, from an unrelated directory.
mkdir -p "$scratch/brew/bin" "$scratch/elsewhere"
ln -s "$stage/bin/material-lab" "$scratch/brew/bin/material-lab"
(cd "$scratch/elsewhere" && HOME=/nonexistent PATH="$scratch/brew/bin:/usr/bin:/bin" material-lab \
  --input "$scratch/in.png" --output "$scratch/out" --preset stone "${learned_flag[@]}" --also-export glb >/dev/null)
"$stage/bin/material-lab" --validate "$scratch/out.pbrmaterial" >/dev/null
"$stage/bin/material-lab" --info "$scratch/out.pbrmaterial" | grep -q "Material Lab bundle"

tar -C "$dist" -czf "$dist/$name.tar.gz" "$name"
(cd "$dist" && shasum -a 256 "$name.tar.gz" | tee "$name.tar.gz.sha256")
echo "$dist/$name.tar.gz"
