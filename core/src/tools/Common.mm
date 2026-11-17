#import <Foundation/Foundation.h>
#include "Tools.hpp"
#include "../PNGWriter.hpp"
#include <fstream>
#include <stdexcept>

namespace mltools {

std::string presetName(PBRLabPreset p) {
    switch (p) {
    case PBRLabPresetStone: return "stone";
    case PBRLabPresetFabric: return "fabric";
    case PBRLabPresetOrganic: return "organic";
    case PBRLabPresetCoatedMetal: return "coated-metal";
    case PBRLabPresetBareMetal: return "bare-metal";
    default: return "flat";
    }
}

// The recipe as written into bundle manifests and by --save-recipe (snake_case).
NSDictionary* recipeDictionary(const PBRLabRecipe& r) {
    return @{
        @"preset": @(presetName(r.preset).c_str()),
        @"height_strength": @(r.height_strength),
        @"height_polarity": @(r.height_polarity),
        @"roughness_base": @(r.roughness_base),
        @"roughness_variation": @(r.roughness_variation),
        @"ao_radius_pixels": @(r.ao_radius_pixels),
        @"tile_wrap": @(r.tile_wrap != 0),
        @"assigned_metalness_enabled": @(r.assigned_metalness_enabled != 0),
        @"assigned_metalness": @(r.assigned_metalness),
        @"bent_normal_enabled": @(r.bent_normal_enabled != 0),
        @"normal_strength": @(r.normal_strength),
        @"normal_y_down": @(r.normal_y_down != 0),
        @"ao_strength": @(r.ao_strength),
        @"albedo_equalize": @(r.albedo_equalize),
        @"seamless_blend": @(r.seamless_blend),
        @"guide_normal_weight": @(r.guide_normal_weight),
        @"mid_relief_share": @(r.mid_relief_share),
        @"tile_metres": @(r.tile_metres),
        @"roughness_albedo_limit": @(r.roughness_albedo_limit),
        @"substrate_relief": @(r.substrate_relief),
        @"seamless_mode": r.seamless_mode == 1 ? @"cut" : @"blend",
        @"albedo_repair": @[@"off", @"blend", @"quilt", @"auto"][r.albedo_repair]
    };
}

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
