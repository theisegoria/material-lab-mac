#import <Foundation/Foundation.h>
#include "Tools.hpp"
#include <zlib.h>
#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstring>
#include <iostream>
#include <stdexcept>

// Exports a validated bundle to formats other tools import directly. The canonical .pbrmaterial bundle is
// never modified; every export is derived from its maps and recorded alongside (material-lab-export.json).
namespace mltools {
namespace {

struct Material {
    std::string label, slug, titleCase, convention;
    bool metalAssigned = false;
    float metal = 0;
    Raster albedo, normal, roughness, ao, height;
    uint32_t size() const { return albedo.width; }
};

NSDictionary* loadManifestObject(const fs::path& bundle) {
    const auto bytes = readFile(bundle / "manifest.json");
    id root = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes.data() length:bytes.size()] options:0 error:nil];
    if (![root isKindOfClass:[NSDictionary class]]) throw std::runtime_error("manifest is not a JSON object");
    return root;
}

std::string words(const std::string& label, bool titleCase) {
    std::string out;
    bool upper = true;
    for (unsigned char c : label) {
        if (std::isalnum(c)) {
            if (titleCase) out += upper ? static_cast<char>(std::toupper(c)) : static_cast<char>(c);
            else out += static_cast<char>(std::tolower(c));
            upper = false;
        } else {
            if (!titleCase && !out.empty() && out.back() != '_') out += '_';
            upper = true;
        }
    }
    while (!out.empty() && out.back() == '_') out.pop_back();
    return out.empty() ? (titleCase ? "Material" : "material") : out;
}

Material load(const fs::path& bundle) {
    NSDictionary* m = loadManifestObject(bundle);
    NSDictionary* recipe = [m[@"recipe"] isKindOfClass:[NSDictionary class]] ? m[@"recipe"] : @{};
    Material material;
    material.label = [m[@"semantic_label"] isKindOfClass:[NSString class]] ? [m[@"semantic_label"] UTF8String] : "material";
    material.slug = words(material.label, false);
    material.titleCase = words(material.label, true);
    material.convention = [m[@"normal_convention"] isEqual:@"-Y"] ? "-Y" : "+Y";
    material.metalAssigned = [recipe[@"assigned_metalness_enabled"] boolValue];
    material.metal = material.metalAssigned ? [recipe[@"assigned_metalness"] floatValue] : 0;
    material.albedo = loadMap(bundle, "albedo");
    material.normal = loadMap(bundle, "normal");
    material.roughness = loadMap(bundle, "roughness");
    material.ao = loadMap(bundle, "ao");
    material.height = loadMap(bundle, "height");
    return material;
}

uint8_t byteAt(const Raster& r, size_t pixel, int channel) { return r.bytes[pixel * 4 + channel]; }

// Tangent normals in the requested convention (the bundle records which one it holds).
std::vector<uint8_t> normalRGBA(const Material& m, const std::string& convention) {
    std::vector<uint8_t> out = m.normal.bytes;
    if (convention != m.convention)
        for (size_t i = 1; i < out.size(); i += 4) out[i] = static_cast<uint8_t>(255 - out[i]);
    return out;
}

// glTF / Unreal / Godot packing: R = occlusion, G = roughness, B = metalness.
std::vector<uint8_t> ormRGBA(const Material& m) {
    const size_t pixels = static_cast<size_t>(m.size()) * m.size();
    std::vector<uint8_t> out(pixels * 4, 255);
    const uint8_t metal = static_cast<uint8_t>(std::lround(m.metal * 255));
    for (size_t i = 0; i < pixels; ++i) {
        out[i * 4] = byteAt(m.ao, i, 0);
        out[i * 4 + 1] = byteAt(m.roughness, i, 0);
        out[i * 4 + 2] = metal;
    }
    return out;
}

// Unity HDRP mask map: R = metallic, G = occlusion, B = detail mask (unused, 0), A = smoothness.
std::vector<uint8_t> hdrpMaskRGBA(const Material& m) {
    const size_t pixels = static_cast<size_t>(m.size()) * m.size();
    std::vector<uint8_t> out(pixels * 4);
    const uint8_t metal = static_cast<uint8_t>(std::lround(m.metal * 255));
    for (size_t i = 0; i < pixels; ++i) {
        out[i * 4] = metal;
        out[i * 4 + 1] = byteAt(m.ao, i, 0);
        out[i * 4 + 2] = 0;
        out[i * 4 + 3] = static_cast<uint8_t>(255 - byteAt(m.roughness, i, 0));
    }
    return out;
}

// Unity URP / Built-in Standard metallic map: R = metallic, G and B unused (0), A = smoothness.
std::vector<uint8_t> unityMetallicRGBA(const Material& m) {
    const size_t pixels = static_cast<size_t>(m.size()) * m.size();
    std::vector<uint8_t> out(pixels * 4, 0);
    const uint8_t metal = static_cast<uint8_t>(std::lround(m.metal * 255));
    for (size_t i = 0; i < pixels; ++i) {
        out[i * 4] = metal;
        out[i * 4 + 3] = static_cast<uint8_t>(255 - byteAt(m.roughness, i, 0));
    }
    return out;
}

// LabPBR 1.3 (shaderLABS): _n = R,G DirectX normal XY, B ambient occlusion (0 = fully occluded), A height (>= 1);
// _s = R perceptual smoothness, G F0 (10 ~ 0.04 for dielectrics; 255 = use albedo as F0, i.e. metal), B porosity
// (0), A emission (255 = none).
std::vector<uint8_t> labNormalRGBA(const Material& m) {
    std::vector<uint8_t> out = normalRGBA(m, "-Y");
    const size_t pixels = static_cast<size_t>(m.size()) * m.size();
    for (size_t i = 0; i < pixels; ++i) {
        out[i * 4 + 2] = byteAt(m.ao, i, 0);
        out[i * 4 + 3] = std::max<uint8_t>(1, m.height.bytes[i * 2]);  // high byte of 16-bit big-endian height
    }
    return out;
}
std::vector<uint8_t> labSpecularRGBA(const Material& m) {
    const size_t pixels = static_cast<size_t>(m.size()) * m.size();
    std::vector<uint8_t> out(pixels * 4);
    const uint8_t f0 = m.metalAssigned && m.metal >= .5f ? 255 : 10;
    for (size_t i = 0; i < pixels; ++i) {
        out[i * 4] = static_cast<uint8_t>(255 - byteAt(m.roughness, i, 0));
        out[i * 4 + 1] = f0;
        out[i * 4 + 2] = 0;
        out[i * 4 + 3] = 255;
    }
    return out;
}

// Box-filters RGBA8 by an integer factor (sizes are powers of two in practice). `normals` renormalizes RGB as
// tangent vectors after averaging.
std::vector<uint8_t> shrinkRGBA(const std::vector<uint8_t>& in, uint32_t size, uint32_t factor, bool normals) {
    if (factor <= 1) return in;
    const uint32_t out = size / factor;
    std::vector<uint8_t> result(static_cast<size_t>(out) * out * 4);
    for (uint32_t y = 0; y < out; ++y)
        for (uint32_t x = 0; x < out; ++x) {
            float sum[4] = {0, 0, 0, 0};
            for (uint32_t dy = 0; dy < factor; ++dy)
                for (uint32_t dx = 0; dx < factor; ++dx) {
                    const size_t i = (static_cast<size_t>(y * factor + dy) * size + x * factor + dx) * 4;
                    for (int c = 0; c < 4; ++c) sum[c] += in[i + c];
                }
            const float n = static_cast<float>(factor * factor);
            float v[4];
            for (int c = 0; c < 4; ++c) v[c] = sum[c] / n;
            if (normals) {
                float vx = v[0] / 127.5f - 1, vy = v[1] / 127.5f - 1, vz = v[2] / 127.5f - 1;
                const float length = std::max(1e-6f, std::sqrt(vx * vx + vy * vy + vz * vz));
                v[0] = (vx / length + 1) * 127.5f; v[1] = (vy / length + 1) * 127.5f; v[2] = (vz / length + 1) * 127.5f;
            }
            const size_t o = (static_cast<size_t>(y) * out + x) * 4;
            for (int c = 0; c < 4; ++c) result[o + c] = static_cast<uint8_t>(std::clamp(std::lround(v[c]), 0L, 255L));
        }
    return result;
}

std::vector<uint8_t> grayRGBA(const Raster& r) {
    std::vector<uint8_t> out = r.bytes;
    for (size_t i = 3; i < out.size(); i += 4) out[i] = 255;
    return out;
}

std::vector<uint8_t> constantGray(uint32_t size, uint8_t value) {
    std::vector<uint8_t> out(static_cast<size_t>(size) * size * 4, value);
    for (size_t i = 3; i < out.size(); i += 4) out[i] = 255;
    return out;
}

bool hasTransparency(const Material& m) {
    for (size_t i = 3; i < m.albedo.bytes.size(); i += 4) if (m.albedo.bytes[i] < 255) return true;
    return false;
}

std::vector<uint8_t> albedoPNG(const Material& m) { return encodeRGBA8(m.size(), m.size(), m.albedo.bytes, true); }
std::vector<uint8_t> heightPNG(const Material& m) { return encodeGray16(m.size(), m.size(), m.height.bytes); }

void writeNote(const fs::path& folder, const fs::path& bundle, const std::string& format, NSDictionary* files) {
    NSDictionary* note = @{@"exporter": @"material-lab", @"format": @(format.c_str()),
                           @"source_bundle": @(bundle.filename().string().c_str()), @"files": files,
                           @"note": @"Derived from the bundle's maps; the bundle's manifest.json holds the provenance."};
    NSData* data = [NSJSONSerialization dataWithJSONObject:note options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    writeFile(folder / "material-lab-export.json", std::vector<uint8_t>(static_cast<const uint8_t*>(data.bytes),
                                                                    static_cast<const uint8_t*>(data.bytes) + data.length));
}

// ---- MaterialX -------------------------------------------------------------------------------------------

std::string xmlEscape(const std::string& text) {
    std::string out;
    for (char c : text) {
        switch (c) {
        case '&': out += "&amp;"; break;
        case '<': out += "&lt;"; break;
        case '>': out += "&gt;"; break;
        case '"': out += "&quot;"; break;
        default: out += c;
        }
    }
    return out;
}

// A standard_surface material reading the folder's textures (Houdini/Karma, Maya/Arnold, Blender, USD, Omniverse).
std::vector<uint8_t> materialXDocument(const Material& m) {
    const std::string n = m.titleCase, s = m.slug;
    char metal[32];
    snprintf(metal, sizeof metal, "%.4g", m.metal);
    std::string xml =
        "<?xml version=\"1.0\"?>\n"
        "<!-- " + xmlEscape(m.label) + ": exported by Material Lab. Maps are estimates derived from one photograph. -->\n"
        "<materialx version=\"1.38\" colorspace=\"lin_rec709\">\n"
        "  <nodegraph name=\"NG_" + n + "\">\n"
        "    <image name=\"base_color_image\" type=\"color3\">\n"
        "      <input name=\"file\" type=\"filename\" value=\"" + s + "_base_color.png\" colorspace=\"srgb_texture\" />\n"
        "    </image>\n"
        "    <image name=\"roughness_image\" type=\"float\">\n"
        "      <input name=\"file\" type=\"filename\" value=\"" + s + "_roughness.png\" />\n"
        "    </image>\n"
        "    <image name=\"normal_image\" type=\"vector3\">\n"
        "      <input name=\"file\" type=\"filename\" value=\"" + s + "_normal.png\" />\n"
        "    </image>\n"
        "    <normalmap name=\"normal_map\" type=\"vector3\">\n"
        "      <input name=\"in\" type=\"vector3\" nodename=\"normal_image\" />\n"
        "    </normalmap>\n"
        "    <output name=\"base_color_output\" type=\"color3\" nodename=\"base_color_image\" />\n"
        "    <output name=\"roughness_output\" type=\"float\" nodename=\"roughness_image\" />\n"
        "    <output name=\"normal_output\" type=\"vector3\" nodename=\"normal_map\" />\n"
        "  </nodegraph>\n"
        "  <standard_surface name=\"SR_" + n + "\" type=\"surfaceshader\">\n"
        "    <input name=\"base\" type=\"float\" value=\"1.0\" />\n"
        "    <input name=\"base_color\" type=\"color3\" nodegraph=\"NG_" + n + "\" output=\"base_color_output\" />\n"
        "    <input name=\"metalness\" type=\"float\" value=\"" + metal + "\" />\n"
        "    <input name=\"specular_roughness\" type=\"float\" nodegraph=\"NG_" + n + "\" output=\"roughness_output\" />\n"
        "    <input name=\"normal\" type=\"vector3\" nodegraph=\"NG_" + n + "\" output=\"normal_output\" />\n"
        "  </standard_surface>\n"
        "  <surfacematerial name=\"M_" + n + "\" type=\"material\">\n"
        "    <input name=\"surfaceshader\" type=\"surfaceshader\" nodename=\"SR_" + n + "\" />\n"
        "  </surfacematerial>\n"
        "</materialx>\n";
    return std::vector<uint8_t>(xml.begin(), xml.end());
}

// ---- Engine folders -------------------------------------------------------------------------------------

void exportFolder(const fs::path& bundle, const Material& m, const std::string& format, const fs::path& folder) {
    fs::create_directories(folder);
    const uint32_t n = m.size();
    NSMutableDictionary* files = [NSMutableDictionary dictionary];
    auto put = [&](const std::string& name, const std::vector<uint8_t>& png, NSString* role) {
        writeFile(folder / name, png);
        files[@(name.c_str())] = role;
    };
    if (format == "unreal") {
        const std::string base = "T_" + m.titleCase + "_";
        put(base + "BaseColor.png", albedoPNG(m), @"Base Color (sRGB on)");
        put(base + "Normal.png", encodeRGBA8(n, n, normalRGBA(m, "-Y"), false), @"Normal (DirectX, compression: Normalmap)");
        put(base + "ORM.png", encodeRGBA8(n, n, ormRGBA(m), false), @"R occlusion, G roughness, B metallic (sRGB off, Masks)");
        put(base + "Height.png", heightPNG(m), @"Height, 16-bit (sRGB off)");
    } else if (format == "unity-hdrp") {
        put(m.titleCase + "_BaseColor.png", albedoPNG(m), @"Base Map (sRGB)");
        put(m.titleCase + "_Normal.png", encodeRGBA8(n, n, normalRGBA(m, "+Y"), false), @"Normal Map (Texture Type: Normal map)");
        put(m.titleCase + "_MaskMap.png", encodeRGBA8(n, n, hdrpMaskRGBA(m), false),
            @"Mask Map: R metallic, G occlusion, B detail mask (0), A smoothness (sRGB off)");
        put(m.titleCase + "_Height.png", heightPNG(m), @"Height Map, 16-bit (sRGB off)");
    } else if (format == "godot") {
        put(m.slug + "_albedo.png", albedoPNG(m), @"Albedo");
        put(m.slug + "_normal.png", encodeRGBA8(n, n, normalRGBA(m, "+Y"), false), @"Normal Map (OpenGL)");
        put(m.slug + "_orm.png", encodeRGBA8(n, n, ormRGBA(m), false), @"ORMMaterial3D: R occlusion, G roughness, B metallic");
        put(m.slug + "_height.png", heightPNG(m), @"Height (heightmap / parallax), 16-bit");
    } else if (format == "unity") {
        put(m.titleCase + "_BaseMap.png", albedoPNG(m), @"Base Map (sRGB)");
        put(m.titleCase + "_Normal.png", encodeRGBA8(n, n, normalRGBA(m, "+Y"), false), @"Normal Map (Texture Type: Normal map)");
        put(m.titleCase + "_MetallicSmoothness.png", encodeRGBA8(n, n, unityMetallicRGBA(m), false),
            @"Metallic Map: R metallic, A smoothness (Smoothness Source: Metallic Alpha, sRGB off)");
        put(m.titleCase + "_Occlusion.png", encodeRGBA8(n, n, grayRGBA(m.ao), false), @"Occlusion Map (sRGB off)");
        put(m.titleCase + "_Height.png", heightPNG(m), @"Height Map / parallax, 16-bit (sRGB off)");
    } else if (format == "substance") {
        put(m.titleCase + "_BaseColor.png", albedoPNG(m), @"Base Color (sRGB)");
        put(m.titleCase + "_Normal.png", encodeRGBA8(n, n, normalRGBA(m, "+Y"), false), @"Normal (OpenGL)");
        put(m.titleCase + "_Roughness.png", encodeRGBA8(n, n, grayRGBA(m.roughness), false), @"Roughness");
        put(m.titleCase + "_Metallic.png", encodeRGBA8(n, n, constantGray(n, static_cast<uint8_t>(std::lround(m.metal * 255))), false),
            @"Metallic");
        put(m.titleCase + "_AmbientOcclusion.png", encodeRGBA8(n, n, grayRGBA(m.ao), false), @"Ambient Occlusion");
        put(m.titleCase + "_Height.png", heightPNG(m), @"Height, 16-bit");
    } else if (format == "roblox") {
        // SurfaceAppearance takes at most 1024 x 1024 and OpenGL (+Y) tangent normals.
        const uint32_t factor = n > 1024 ? n / 1024 : 1, r = n / factor;
        put(m.titleCase + "_ColorMap.png", encodeRGBA8(r, r, shrinkRGBA(m.albedo.bytes, n, factor, false), true),
            @"ColorMap (alpha is ignored unless AlphaMode is set)");
        put(m.titleCase + "_NormalMap.png", encodeRGBA8(r, r, shrinkRGBA(normalRGBA(m, "+Y"), n, factor, true), false), @"NormalMap");
        put(m.titleCase + "_RoughnessMap.png", encodeRGBA8(r, r, shrinkRGBA(grayRGBA(m.roughness), n, factor, false), false),
            @"RoughnessMap");
        put(m.titleCase + "_MetalnessMap.png", encodeRGBA8(r, r, constantGray(r, static_cast<uint8_t>(std::lround(m.metal * 255))), false),
            @"MetalnessMap");
    } else if (format == "minecraft-labpbr") {
        // A resource pack: the colour, _n and _s textures replace a block texture of the same name (rename to the
        // block you want, e.g. bricks.png). Needs a LabPBR shader pack (Iris or OptiFine).
        const fs::path blocks = folder / "assets/minecraft/textures/block";
        fs::create_directories(blocks);
        const std::string base = "assets/minecraft/textures/block/" + m.slug;
        put(base + ".png", albedoPNG(m), @"Colour texture (rename to the block it should replace)");
        put(base + "_n.png", encodeRGBA8(n, n, labNormalRGBA(m), false),
            @"LabPBR _n: RG DirectX normal, B ambient occlusion, A height");
        put(base + "_s.png", encodeRGBA8(n, n, labSpecularRGBA(m), false),
            @"LabPBR _s: R perceptual smoothness, G F0 (255 = metal), B porosity 0, A no emission");
        NSDictionary* meta = @{@"pack": @{@"pack_format": @46,
                                          @"description": [NSString stringWithFormat:@"%s (Material Lab, LabPBR 1.3)", m.label.c_str()]}};
        NSData* json = [NSJSONSerialization dataWithJSONObject:meta options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
        put("pack.mcmeta", std::vector<uint8_t>(static_cast<const uint8_t*>(json.bytes), static_cast<const uint8_t*>(json.bytes) + json.length),
            @"Resource pack metadata (pack_format 46 = Minecraft 1.21.4; edit for other versions)");
    } else if (format == "materialx") {
        put(m.slug + "_base_color.png", albedoPNG(m), @"base_color (srgb_texture)");
        put(m.slug + "_normal.png", encodeRGBA8(n, n, normalRGBA(m, "+Y"), false), @"normal via normalmap (OpenGL tangent space)");
        put(m.slug + "_roughness.png", encodeRGBA8(n, n, grayRGBA(m.roughness), false), @"specular_roughness");
        put(m.slug + "_ao.png", encodeRGBA8(n, n, grayRGBA(m.ao), false), @"Ambient occlusion (not wired; standard_surface has no input)");
        put(m.slug + "_height.png", heightPNG(m), @"Height, 16-bit (wire to displacement if wanted)");
        put(m.slug + ".mtlx", materialXDocument(m), @"MaterialX 1.38 standard_surface material");
    } else {  // blender
        put(m.slug + "_base_color.png", albedoPNG(m), @"Base Color (sRGB)");
        put(m.slug + "_normal.png", encodeRGBA8(n, n, normalRGBA(m, "+Y"), false), @"Normal Map node (Non-Color, OpenGL)");
        put(m.slug + "_roughness.png", encodeRGBA8(n, n, grayRGBA(m.roughness), false), @"Roughness (Non-Color)");
        put(m.slug + "_ao.png", encodeRGBA8(n, n, grayRGBA(m.ao), false), @"Ambient occlusion (Non-Color)");
        if (m.metalAssigned)
            put(m.slug + "_metallic.png", encodeRGBA8(n, n, constantGray(n, static_cast<uint8_t>(std::lround(m.metal * 255))), false),
                @"Metallic (Non-Color)");
        put(m.slug + "_height.png", heightPNG(m), @"Displacement height, 16-bit (Non-Color)");
    }
    writeNote(folder, bundle, format, files);
}

// ---- glTF 2.0 binary ------------------------------------------------------------------------------------

void append(std::vector<uint8_t>& out, const void* data, size_t size) {
    const auto* p = static_cast<const uint8_t*>(data);
    out.insert(out.end(), p, p + size);
}
void align4(std::vector<uint8_t>& out, uint8_t fill) { while (out.size() % 4) out.push_back(fill); }
void put32(std::vector<uint8_t>& out, uint32_t v) { append(out, &v, 4); }  // GLB is little-endian, as is arm64.

void exportGLB(const Material& m, const fs::path& output) {
    // A 1 m plane facing +Z (glTF is Y-up), UV origin top-left as glTF specifies.
    const float positions[] = {-0.5f, 0.5f, 0, 0.5f, 0.5f, 0, 0.5f, -0.5f, 0, -0.5f, -0.5f, 0};
    const float normals[] = {0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1};
    const float tangents[] = {1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1};
    const float uvs[] = {0, 0, 1, 0, 1, 1, 0, 1};
    const uint16_t indices[] = {0, 3, 2, 0, 2, 1};
    const uint32_t n = m.size();
    const std::vector<std::vector<uint8_t>> images = {
        albedoPNG(m), encodeRGBA8(n, n, normalRGBA(m, "+Y"), false), encodeRGBA8(n, n, ormRGBA(m), false)};
    std::vector<uint8_t> bin;
    NSMutableArray* views = [NSMutableArray array];
    auto view = [&](const void* data, size_t size, NSNumber* target) {
        align4(bin, 0);
        NSMutableDictionary* v = [@{@"buffer": @0, @"byteOffset": @(bin.size()), @"byteLength": @(size)} mutableCopy];
        if (target) v[@"target"] = target;
        append(bin, data, size);
        [views addObject:v];
        return static_cast<NSUInteger>(views.count - 1);
    };
    const NSUInteger pv = view(positions, sizeof positions, @34962), nv = view(normals, sizeof normals, @34962),
                     tv = view(tangents, sizeof tangents, @34962), uv = view(uvs, sizeof uvs, @34962),
                     iv = view(indices, sizeof indices, @34963);
    NSMutableArray* imageObjects = [NSMutableArray array];
    for (const auto& png : images) [imageObjects addObject:@{@"bufferView": @(view(png.data(), png.size(), nil)), @"mimeType": @"image/png"}];
    align4(bin, 0);
    NSMutableDictionary* pbr = [@{@"baseColorTexture": @{@"index": @0}, @"metallicRoughnessTexture": @{@"index": @2},
                                  @"metallicFactor": @(m.metalAssigned ? 1.0 : 0.0), @"roughnessFactor": @1.0} mutableCopy];
    NSMutableDictionary* material = [@{@"name": @(m.label.c_str()), @"pbrMetallicRoughness": pbr,
                                       @"normalTexture": @{@"index": @1}, @"occlusionTexture": @{@"index": @2}} mutableCopy];
    if (hasTransparency(m)) { material[@"alphaMode"] = @"MASK"; material[@"alphaCutoff"] = @0.5; }
    NSDictionary* gltf = @{
        @"asset": @{@"version": @"2.0", @"generator": @"Material Lab"},
        @"scene": @0, @"scenes": @[@{@"nodes": @[@0]}],
        @"nodes": @[@{@"mesh": @0, @"name": @(m.titleCase.c_str())}],
        @"meshes": @[@{@"name": @"Plane", @"primitives": @[@{
            @"attributes": @{@"POSITION": @0, @"NORMAL": @1, @"TANGENT": @2, @"TEXCOORD_0": @3},
            @"indices": @4, @"material": @0}]}],
        @"accessors": @[
            @{@"bufferView": @(pv), @"componentType": @5126, @"count": @4, @"type": @"VEC3", @"min": @[@-0.5, @-0.5, @0], @"max": @[@0.5, @0.5, @0]},
            @{@"bufferView": @(nv), @"componentType": @5126, @"count": @4, @"type": @"VEC3"},
            @{@"bufferView": @(tv), @"componentType": @5126, @"count": @4, @"type": @"VEC4"},
            @{@"bufferView": @(uv), @"componentType": @5126, @"count": @4, @"type": @"VEC2"},
            @{@"bufferView": @(iv), @"componentType": @5123, @"count": @6, @"type": @"SCALAR"}],
        @"bufferViews": views,
        @"buffers": @[@{@"byteLength": @(bin.size())}],
        @"materials": @[material],
        @"textures": @[@{@"source": @0, @"sampler": @0}, @{@"source": @1, @"sampler": @0}, @{@"source": @2, @"sampler": @0}],
        @"images": imageObjects,
        @"samplers": @[@{@"magFilter": @9729, @"minFilter": @9987, @"wrapS": @10497, @"wrapT": @10497}]};
    NSData* jsonData = [NSJSONSerialization dataWithJSONObject:gltf options:NSJSONWritingSortedKeys error:nil];
    std::vector<uint8_t> json(static_cast<const uint8_t*>(jsonData.bytes), static_cast<const uint8_t*>(jsonData.bytes) + jsonData.length);
    align4(json, ' ');
    std::vector<uint8_t> glb;
    put32(glb, 0x46546C67);  // "glTF"
    put32(glb, 2);
    put32(glb, static_cast<uint32_t>(12 + 8 + json.size() + 8 + bin.size()));
    put32(glb, static_cast<uint32_t>(json.size())); put32(glb, 0x4E4F534A);  // "JSON"
    append(glb, json.data(), json.size());
    put32(glb, static_cast<uint32_t>(bin.size())); put32(glb, 0x004E4942);   // "BIN\0"
    append(glb, bin.data(), bin.size());
    writeFile(output, glb);
}

// ---- USDZ -----------------------------------------------------------------------------------------------

// A stored (uncompressed) ZIP whose file data starts on 64-byte boundaries, as USDZ requires.
std::vector<uint8_t> usdzArchive(const std::vector<std::pair<std::string, std::vector<uint8_t>>>& files) {
    std::vector<uint8_t> zip, central;
    auto put16 = [](std::vector<uint8_t>& v, uint16_t x) { v.push_back(x & 255); v.push_back(x >> 8); };
    auto put32le = [](std::vector<uint8_t>& v, uint32_t x) { for (int i = 0; i < 4; ++i) v.push_back((x >> (8 * i)) & 255); };
    for (const auto& [name, data] : files) {
        const uint32_t offset = static_cast<uint32_t>(zip.size());
        const uint32_t crc = static_cast<uint32_t>(crc32(0, data.data(), static_cast<uInt>(data.size())));
        const size_t padding = (64 - (offset + 30 + name.size() + 4) % 64) % 64;
        const uint16_t extraLength = static_cast<uint16_t>(4 + padding);
        put32le(zip, 0x04034b50); put16(zip, 20); put16(zip, 0); put16(zip, 0); put16(zip, 0); put16(zip, 0);
        put32le(zip, crc); put32le(zip, static_cast<uint32_t>(data.size())); put32le(zip, static_cast<uint32_t>(data.size()));
        put16(zip, static_cast<uint16_t>(name.size())); put16(zip, extraLength);
        append(zip, name.data(), name.size());
        put16(zip, 0x1986); put16(zip, static_cast<uint16_t>(padding));  // Padding extra field.
        zip.insert(zip.end(), padding, 0);
        if (zip.size() % 64) throw std::runtime_error("USDZ alignment failed");
        append(zip, data.data(), data.size());
        put32le(central, 0x02014b50); put16(central, 20); put16(central, 20); put16(central, 0); put16(central, 0);
        put16(central, 0); put16(central, 0); put32le(central, crc);
        put32le(central, static_cast<uint32_t>(data.size())); put32le(central, static_cast<uint32_t>(data.size()));
        put16(central, static_cast<uint16_t>(name.size())); put16(central, 0); put16(central, 0); put16(central, 0);
        put16(central, 0); put32le(central, 0); put32le(central, offset);
        append(central, name.data(), name.size());
    }
    const uint32_t centralOffset = static_cast<uint32_t>(zip.size());
    append(zip, central.data(), central.size());
    put32le(zip, 0x06054b50); put16(zip, 0); put16(zip, 0);
    put16(zip, static_cast<uint16_t>(files.size())); put16(zip, static_cast<uint16_t>(files.size()));
    put32le(zip, static_cast<uint32_t>(central.size())); put32le(zip, centralOffset); put16(zip, 0);
    return zip;
}

void exportUSDZ(const Material& m, const fs::path& output) {
    const uint32_t n = m.size();
    // UsdPreviewSurface on a 1 m plane facing +Z; st origin is the image's bottom-left, as USD specifies.
    const std::string usda = R"(#usda 1.0
(
    defaultPrim = "Material_Lab"
    metersPerUnit = 1
    upAxis = "Y"
)

def Xform "Material_Lab" (
    kind = "component"
)
{
    def Mesh "Plane" (
        prepend apiSchemas = ["MaterialBindingAPI"]
    )
    {
        float3[] extent = [(-0.5, -0.5, 0), (0.5, 0.5, 0)]
        int[] faceVertexCounts = [4]
        int[] faceVertexIndices = [0, 1, 2, 3]
        rel material:binding = </Material_Lab/Materials/Surface>
        normal3f[] normals = [(0, 0, 1), (0, 0, 1), (0, 0, 1), (0, 0, 1)] (
            interpolation = "vertex"
        )
        point3f[] points = [(-0.5, -0.5, 0), (0.5, -0.5, 0), (0.5, 0.5, 0), (-0.5, 0.5, 0)]
        texCoord2f[] primvars:st = [(0, 0), (1, 0), (1, 1), (0, 1)] (
            interpolation = "vertex"
        )
        uniform token subdivisionScheme = "none"
    }

    def Scope "Materials"
    {
        def Material "Surface"
        {
            token outputs:surface.connect = </Material_Lab/Materials/Surface/PreviewSurface.outputs:surface>

            def Shader "PreviewSurface"
            {
                uniform token info:id = "UsdPreviewSurface"
                color3f inputs:diffuseColor.connect = </Material_Lab/Materials/Surface/Albedo.outputs:rgb>
                float inputs:roughness.connect = </Material_Lab/Materials/Surface/ORM.outputs:g>
                float inputs:metallic.connect = </Material_Lab/Materials/Surface/ORM.outputs:b>
                float inputs:occlusion.connect = </Material_Lab/Materials/Surface/ORM.outputs:r>
                normal3f inputs:normal.connect = </Material_Lab/Materials/Surface/Normal.outputs:rgb>
                token outputs:surface
            }

            def Shader "PrimvarReader"
            {
                uniform token info:id = "UsdPrimvarReader_float2"
                string inputs:varname = "st"
                float2 outputs:result
            }

            def Shader "Albedo"
            {
                uniform token info:id = "UsdUVTexture"
                asset inputs:file = @textures/albedo.png@
                token inputs:sourceColorSpace = "sRGB"
                float2 inputs:st.connect = </Material_Lab/Materials/Surface/PrimvarReader.outputs:result>
                token inputs:wrapS = "repeat"
                token inputs:wrapT = "repeat"
                float3 outputs:rgb
            }

            def Shader "Normal"
            {
                uniform token info:id = "UsdUVTexture"
                asset inputs:file = @textures/normal.png@
                token inputs:sourceColorSpace = "raw"
                float4 inputs:scale = (2, 2, 2, 1)
                float4 inputs:bias = (-1, -1, -1, 0)
                float2 inputs:st.connect = </Material_Lab/Materials/Surface/PrimvarReader.outputs:result>
                token inputs:wrapS = "repeat"
                token inputs:wrapT = "repeat"
                float3 outputs:rgb
            }

            def Shader "ORM"
            {
                uniform token info:id = "UsdUVTexture"
                asset inputs:file = @textures/orm.png@
                token inputs:sourceColorSpace = "raw"
                float2 inputs:st.connect = </Material_Lab/Materials/Surface/PrimvarReader.outputs:result>
                token inputs:wrapS = "repeat"
                token inputs:wrapT = "repeat"
                float outputs:r
                float outputs:g
                float outputs:b
            }
        }
    }
}
)";
    const std::vector<std::pair<std::string, std::vector<uint8_t>>> files = {
        {"Material_Lab.usda", std::vector<uint8_t>(usda.begin(), usda.end())},
        {"textures/albedo.png", albedoPNG(m)},
        {"textures/normal.png", encodeRGBA8(n, n, normalRGBA(m, "+Y"), false)},
        {"textures/orm.png", encodeRGBA8(n, n, ormRGBA(m), false)}};
    writeFile(output, usdzArchive(files));
}

} // namespace

const std::vector<std::string>& exportFormats() {
    static const std::vector<std::string> formats = {"glb", "usdz", "materialx", "unreal", "unity", "unity-hdrp", "godot",
                                                     "blender", "substance", "roblox", "minecraft-labpbr"};
    return formats;
}

int exportBundle(const fs::path& bundle, const std::string& format, const fs::path& output, bool announce) {
    if (std::find(exportFormats().begin(), exportFormats().end(), format) == exportFormats().end()) {
        std::string list;
        for (const auto& f : exportFormats()) list += (list.empty() ? "" : ", ") + f;
        throw std::runtime_error("unknown export format: " + format + " (use " + list + ")");
    }
    if (fs::exists(fs::symlink_status(output))) throw std::runtime_error("export output already exists: " + output.string());
    const Material material = load(bundle);
    if (format == "glb") exportGLB(material, output);
    else if (format == "usdz") exportUSDZ(material, output);
    else exportFolder(bundle, material, format, output);
    if (announce) std::cout << output.string() << '\n';
    return 0;
}

} // namespace mltools
