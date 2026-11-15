#pragma once
// Bundle tools for the material-lab CLI: inspection, comparison and export. Every entry point receives a bundle
// that CLI.mm has already validated (manifest, hashes, PNG structure), so the tools trust its layout.
#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace mltools {
namespace fs = std::filesystem;

// A decoded map with no colour management: 8-bit samples, or 16-bit samples stored big-endian as in the PNG.
struct Raster {
    uint32_t width = 0, height = 0;
    int channels = 0;  // 1 (height) or 4 (RGBA)
    int bits = 8;      // 8 or 16
    std::vector<uint8_t> bytes;
    // Sample in [0, 1].
    float at(uint32_t x, uint32_t y, int c) const;
};

// --info: provenance, recipe, maps, seams and relief of a bundle. `json` prints a machine-readable object.
int info(const fs::path& bundle, bool json);
// --contact-sheet: one labelled PNG of every map (height and data maps shown as encoded).
int contactSheet(const fs::path& bundle, const fs::path& output);
// --preview: a lit render (a sphere and a flat 2 x 2 tiling) from the bundle's maps; CPU, deterministic.
int preview(const fs::path& bundle, const fs::path& output);
// --diff: per-map mean and max absolute difference and PSNR, plus recipe differences.
int diff(const fs::path& a, const fs::path& b, bool json);
// --export: one of exportFormats(), written to `output` (a file or folder per format).
// `announce` prints the written path (off for the CLI's own --also-export follow-ups).
int exportBundle(const fs::path& bundle, const std::string& format, const fs::path& output, bool announce = true);
// Every --export format, in display order.
const std::vector<std::string>& exportFormats();

// Shared helpers.
Raster loadMap(const fs::path& bundle, const std::string& name);  // throws on a missing or undecodable map
std::vector<uint8_t> readFile(const fs::path& path);
void writeFile(const fs::path& path, const std::vector<uint8_t>& bytes);
// PNG encoders (same encoder as bundle maps): RGBA8 sRGB-tagged or linear, and 16-bit grayscale.
std::vector<uint8_t> encodeRGBA8(uint32_t width, uint32_t height, const std::vector<uint8_t>& rgba, bool srgb);
std::vector<uint8_t> encodeGray16(uint32_t width, uint32_t height, const std::vector<uint8_t>& bigEndianSamples);
}
