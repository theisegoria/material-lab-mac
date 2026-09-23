#include "PNGWriter.hpp"
#include <algorithm>
#include <array>
#include <cstdint>
#include <fstream>
#include <limits>
#include <vector>
#include <zlib.h>

namespace pbrlab {
namespace {
void be32(std::vector<uint8_t>& out, uint32_t n) {
    out.push_back(static_cast<uint8_t>(n >> 24));
    out.push_back(static_cast<uint8_t>(n >> 16));
    out.push_back(static_cast<uint8_t>(n >> 8));
    out.push_back(static_cast<uint8_t>(n));
}
void chunk(std::vector<uint8_t>& out, const char name[4], const std::vector<uint8_t>& data) {
    be32(out, static_cast<uint32_t>(data.size()));
    const size_t begin = out.size();
    out.insert(out.end(), name, name + 4);
    out.insert(out.end(), data.begin(), data.end());
    uLong crc = crc32(0, nullptr, 0);
    crc = crc32(crc, out.data() + begin, static_cast<uInt>(out.size() - begin));
    be32(out, static_cast<uint32_t>(crc));
}
} // namespace
bool writePNG(const std::string& path, const PBRLabMap& map, std::string& error) {
    const bool height = map.format == PBRLabPixelFormatR16UNormLE;
    const size_t channels = height ? 2 : 4;
    const size_t widthBytes = static_cast<size_t>(map.width) * channels;
    if (!map.pixels || !map.width || !map.height || map.row_bytes < widthBytes ||
        map.byte_count < map.row_bytes * map.height || map.width > 4096 || map.height > 4096) {
        error = "invalid map layout"; return false;
    }
    std::vector<uint8_t> raw;
    raw.reserve((widthBytes + 1) * map.height);
    for (uint32_t y = 0; y < map.height; ++y) {
        raw.push_back(0); // PNG filter: none.
        const auto* row = map.pixels + static_cast<size_t>(y) * map.row_bytes;
        if (height) {
            for (uint32_t x = 0; x < map.width; ++x) {
                raw.push_back(row[x * 2 + 1]); // PNG is network byte order.
                raw.push_back(row[x * 2]);
            }
        } else raw.insert(raw.end(), row, row + widthBytes);
    }
    uLongf compressedSize = compressBound(static_cast<uLong>(raw.size()));
    std::vector<uint8_t> compressed(compressedSize);
    if (compress2(compressed.data(), &compressedSize, raw.data(), static_cast<uLong>(raw.size()), Z_BEST_SPEED) != Z_OK) {
        error = "zlib compression failed"; return false;
    }
    compressed.resize(compressedSize);
    std::vector<uint8_t> png{137,80,78,71,13,10,26,10};
    std::vector<uint8_t> ihdr;
    be32(ihdr, map.width); be32(ihdr, map.height);
    ihdr.push_back(height ? 16 : 8);
    ihdr.push_back(height ? 0 : 6); // Grayscale height or RGBA.
    ihdr.insert(ihdr.end(), {0,0,0});
    chunk(png, "IHDR", ihdr);
    if (map.format == PBRLabPixelFormatRGBA8SRGB) chunk(png, "sRGB", {0});
    else { std::vector<uint8_t> gamma; be32(gamma, 100000); chunk(png, "gAMA", gamma); }
    chunk(png, "IDAT", compressed);
    chunk(png, "IEND", {});
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    if (!out) { error = "cannot open PNG output"; return false; }
    out.write(reinterpret_cast<const char*>(png.data()), static_cast<std::streamsize>(png.size()));
    if (!out) { error = "cannot write PNG output"; return false; }
    return true;
}
} // namespace pbrlab
