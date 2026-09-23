#pragma once
#include "PBRMaterialLab.h"
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace pbrlab {
// Encodes one map in memory: RGBA8 (colour type 6) or 16-bit big-endian grayscale for R16 height.
// Albedo (RGBA8 sRGB) carries an sRGB chunk; linear maps carry gAMA 1.0. Rows use adaptive filters, zlib level 6.
bool encodePNG(const PBRLabMap& map, std::vector<uint8_t>& png, std::string& error);
// Writes bytes to a unique temporary file beside path, checks every write and close, then renames over path.
bool writeFileAtomically(const std::string& path, const std::vector<uint8_t>& bytes, std::string& error);

struct PNGInfo {
    uint32_t width = 0, height = 0;
    uint8_t bitDepth = 0, colorType = 0, interlace = 0;
    bool hasSRGB = false, hasGAMA = false;
};
// Structural decode: signature, chunk CRCs, IHDR-first/IEND-last ordering, and a full zlib inflate whose
// size and per-row filter types must match IHDR exactly. Trailing bytes after IEND are rejected.
// Supports the non-palette, non-interlaced 8/16-bit layouts Material Lab writes; others are rejected.
bool inspectPNG(const uint8_t* bytes, size_t size, PNGInfo& info, std::string& error);
}
