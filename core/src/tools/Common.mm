#import <Foundation/Foundation.h>
#include "Tools.hpp"
#include "../PNGWriter.hpp"
#include <fstream>
#include <stdexcept>

namespace mltools {

float Raster::at(uint32_t x, uint32_t y, int c) const {
    const size_t index = (static_cast<size_t>(y) * width + x) * channels + c;
    if (bits == 16) return static_cast<float>((bytes[index * 2] << 8) | bytes[index * 2 + 1]) / 65535.0f;
    return static_cast<float>(bytes[index]) / 255.0f;
}

std::vector<uint8_t> readFile(const fs::path& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) throw std::runtime_error("cannot read " + path.string());
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
}

void writeFile(const fs::path& path, const std::vector<uint8_t>& bytes) {
    if (!path.parent_path().empty()) fs::create_directories(path.parent_path());
    std::string error;
    if (!pbrlab::writeFileAtomically(path.string(), bytes, error)) throw std::runtime_error(error);
}

Raster loadMap(const fs::path& bundle, const std::string& name) {
    const auto bytes = readFile(bundle / (name + ".png"));
    pbrlab::PNGInfo info;
    std::string error;
    Raster raster;
    if (!pbrlab::inspectPNG(bytes.data(), bytes.size(), info, error, &raster.bytes))
        throw std::runtime_error(name + ".png: " + error);
    if (info.colorType != 0 && info.colorType != 6) throw std::runtime_error(name + ".png: unexpected colour type");
    raster.width = info.width;
    raster.height = info.height;
    raster.channels = info.colorType == 0 ? 1 : 4;
    raster.bits = info.bitDepth;
    return raster;
}

std::vector<uint8_t> encodeRGBA8(uint32_t width, uint32_t height, const std::vector<uint8_t>& rgba, bool srgb) {
    PBRLabMap map{rgba.data(), width, height, static_cast<size_t>(width) * 4, rgba.size(),
                  srgb ? PBRLabPixelFormatRGBA8SRGB : PBRLabPixelFormatRGBA8Linear};
    std::vector<uint8_t> png;
    std::string error;
    if (!pbrlab::encodePNG(map, png, error)) throw std::runtime_error("PNG encode failed: " + error);
    return png;
}

std::vector<uint8_t> encodeGray16(uint32_t width, uint32_t height, const std::vector<uint8_t>& bigEndian) {
    std::vector<uint8_t> little(bigEndian.size());
    for (size_t i = 0; i + 1 < bigEndian.size(); i += 2) { little[i] = bigEndian[i + 1]; little[i + 1] = bigEndian[i]; }
    PBRLabMap map{little.data(), width, height, static_cast<size_t>(width) * 2, little.size(), PBRLabPixelFormatR16UNormLE};
    std::vector<uint8_t> png;
    std::string error;
    if (!pbrlab::encodePNG(map, png, error)) throw std::runtime_error("PNG encode failed: " + error);
    return png;
}

} // namespace mltools
