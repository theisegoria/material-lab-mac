// Bundle operations on derived materials: layering, seeded variants and larger tiles (docs/BUNDLE_FORMAT.md,
// "Composed bundles"). Each reads one or two bundles, runs the core operation (MaterialOps.cpp) and writes a new bundle
// whose manifest records the operation and its sources. Shared by the CLI (material-lab layer, --variant,
// --large-tile), the MCP server and both apps (PBRLabExport.h).
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CommonCrypto/CommonDigest.h>
#include "Tools.hpp"
#include "PBRLabExport.h"
#include "../PNGWriter.hpp"
#include <array>
#include <cmath>
#include <cstring>
#include <memory>
#include <stdexcept>

namespace mltools {
namespace {

NSString* ns(const std::string& s) { return [NSString stringWithUTF8String:s.c_str()] ?: @""; }
std::string sha256(const void* bytes, size_t length) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes, static_cast<CC_LONG>(length), digest);
    char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) snprintf(hex + i * 2, 3, "%02x", digest[i]);
    return hex;
}
std::string sha256(const std::vector<uint8_t>& bytes) { return sha256(bytes.data(), bytes.size()); }

// A bundle decoded into the buffers a PBRLabMaterialMaps points at.
struct LoadedBundle {
    fs::path path;
    NSDictionary* manifest = nil;
    std::string manifestHash;
    std::vector<uint8_t> albedo, height, roughness, metalness, normal;
    uint32_t size = 0;
    PBRLabRecipe recipe{};
    PBRLabMaterialMaps maps{};
};

NSNumber* number(NSDictionary* d, NSString* key) {
    id v = d[key];
    return [v isKindOfClass:[NSNumber class]] ? v : nil;
}

// The bundle's derivation recipe (snake_case, as validated); absent optional fields keep the preset defaults.
PBRLabRecipe recipeOf(NSDictionary* r) {
    NSString* presetText = [r[@"preset"] isKindOfClass:[NSString class]] ? r[@"preset"] : @"flat";
    PBRLabPreset preset = PBRLabPresetFlat;
    for (int p = PBRLabPresetFlat; p <= PBRLabPresetBareMetal; ++p)
        if ([presetText isEqualToString:ns(presetName(static_cast<PBRLabPreset>(p)))]) preset = static_cast<PBRLabPreset>(p);
    PBRLabRecipe recipe = PBRLabDefaultRecipe(preset);
    auto num = [&](NSString* key, float& target) { if (NSNumber* n = number(r, key)) target = n.floatValue; };
    auto flag = [&](NSString* key, uint32_t& target) { if (NSNumber* n = number(r, key)) target = n.boolValue ? 1 : 0; };
    num(@"height_strength", recipe.height_strength);
    if (NSNumber* n = number(r, @"height_polarity")) recipe.height_polarity = n.intValue < 0 ? -1 : 1;
    num(@"roughness_base", recipe.roughness_base);
    num(@"roughness_variation", recipe.roughness_variation);
    num(@"ao_radius_pixels", recipe.ao_radius_pixels);
    flag(@"tile_wrap", recipe.tile_wrap);
    flag(@"assigned_metalness_enabled", recipe.assigned_metalness_enabled);
    num(@"assigned_metalness", recipe.assigned_metalness);
    flag(@"bent_normal_enabled", recipe.bent_normal_enabled);
    num(@"normal_strength", recipe.normal_strength);
    flag(@"normal_y_down", recipe.normal_y_down);
    num(@"ao_strength", recipe.ao_strength);
    num(@"albedo_equalize", recipe.albedo_equalize);
    num(@"seamless_blend", recipe.seamless_blend);
    num(@"guide_normal_weight", recipe.guide_normal_weight);
    num(@"mid_relief_share", recipe.mid_relief_share);
    num(@"tile_metres", recipe.tile_metres);
    num(@"roughness_albedo_limit", recipe.roughness_albedo_limit);
    num(@"substrate_relief", recipe.substrate_relief);
    if ([r[@"seamless_mode"] isKindOfClass:[NSString class]]) recipe.seamless_mode = [r[@"seamless_mode"] isEqualToString:@"cut"] ? 1 : 0;
    if ([r[@"albedo_repair"] isKindOfClass:[NSString class]]) {
        NSUInteger index = [@[@"off", @"blend", @"quilt", @"auto"] indexOfObject:r[@"albedo_repair"]];
        recipe.albedo_repair = index == NSNotFound ? 0 : static_cast<uint32_t>(index);
    }
    return recipe;
}

std::unique_ptr<LoadedBundle> loadBundle(const fs::path& path) {
    auto b = std::make_unique<LoadedBundle>();
    b->path = path;
    const auto manifestBytes = readFile(path / "manifest.json");
    b->manifestHash = sha256(manifestBytes);
    NSData* data = [NSData dataWithBytes:manifestBytes.data() length:manifestBytes.size()];
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![root isKindOfClass:[NSDictionary class]]) throw std::runtime_error("bundle manifest is not a JSON object: " + path.string());
    b->manifest = root;
    NSDictionary* relief = [root[@"relief"] isKindOfClass:[NSDictionary class]] ? root[@"relief"] : nil;
    NSNumber* span = relief ? number(relief, @"height_span_tile_widths") : nil;
    if (!span) throw std::runtime_error("bundle records no relief height span (re-derive it with algorithm 1.3.0 or later): " + path.string());
    NSDictionary* recipe = [root[@"recipe"] isKindOfClass:[NSDictionary class]] ? root[@"recipe"] : @{};
    b->recipe = recipeOf(recipe);
    const Raster albedo = loadMap(path, "albedo"), height = loadMap(path, "height"), roughness = loadMap(path, "roughness");
    if (albedo.channels != 4 || albedo.bits != 8 || height.channels != 1 || height.bits != 16 || roughness.channels != 4 ||
        albedo.width != albedo.height || height.width != albedo.width || roughness.width != albedo.width)
        throw std::runtime_error("bundle maps have unexpected formats or sizes: " + path.string());
    b->size = albedo.width;
    const size_t count = static_cast<size_t>(b->size) * b->size;
    b->albedo = albedo.bytes;
    b->height.resize(count * 2);
    for (size_t i = 0; i < count; ++i) { b->height[i * 2] = height.bytes[i * 2 + 1]; b->height[i * 2 + 1] = height.bytes[i * 2]; }
    b->roughness.resize(count);
    for (size_t i = 0; i < count; ++i) b->roughness[i] = roughness.bytes[i * 4];
    NSDictionary* maps = [root[@"maps"] isKindOfClass:[NSDictionary class]] ? root[@"maps"] : @{};
    if (maps[@"orm"]) {
        const Raster orm = loadMap(path, "orm");
        if (orm.channels != 4 || orm.width != b->size) throw std::runtime_error("orm.png has an unexpected format: " + path.string());
        b->metalness.resize(count);
        for (size_t i = 0; i < count; ++i) b->metalness[i] = orm.bytes[i * 4 + 2];
    }
    const Raster normal = loadMap(path, "normal");
    if (normal.channels != 4 || normal.width != b->size) throw std::runtime_error("normal.png has an unexpected format: " + path.string());
    b->normal = normal.bytes;
    const size_t n = b->size;
    b->maps = {b->albedo.data(), n * 4, b->height.data(), n * 2, b->roughness.data(), n,
               b->metalness.empty() ? nullptr : b->metalness.data(), b->metalness.empty() ? 0 : n,
               b->normal.data(), n * 4, b->size, b->recipe.normal_y_down, span.floatValue};
    return b;
}

// The CLI chains operations through hidden stage bundles that it removes afterwards (".<name>.stage-<uuid>").
bool isStage(const fs::path& path) {
    const std::string name = path.filename().string();
    return !name.empty() && name.front() == '.' && name.find(".stage-") != std::string::npos;
}
std::string sourceName(const LoadedBundle& b) { return isStage(b.path) ? "intermediate" : b.path.filename().string(); }
// How a composed bundle names its sources: enough to find and verify them, with their own provenance (their source
// and, for a composed source, its operation), so a chain stays traceable when an intermediate is not kept.
NSDictionary* sourceRecord(const LoadedBundle& b) {
    NSMutableDictionary* record = [@{@"path": ns(sourceName(b)), @"manifest_sha256": ns(b.manifestHash)} mutableCopy];
    if (isStage(b.path)) record[@"intermediate"] = @YES;
    for (NSString* key in @[@"source", @"layers", @"variant", @"large_tile"])
        if ([b.manifest[key] isKindOfClass:[NSDictionary class]]) record[key] = b.manifest[key];
    for (NSString* key in @[@"material_id", @"semantic_label", @"algorithm_version"])
        if ([b.manifest[key] isKindOfClass:[NSString class]]) record[key] = b.manifest[key];
    if (NSDictionary* recipe = [b.manifest[@"recipe"] isKindOfClass:[NSDictionary class]] ? b.manifest[@"recipe"] : nil) record[@"recipe"] = recipe;
    return record;
}

struct MapRole { PBRLabMapKind kind; const char* name; const char* provenance; const char* format; };
constexpr std::array<MapRole, 11> kRoles{{
    {PBRLabMapAlbedo, "albedo", nullptr, "rgba8_srgb_png"},
    {PBRLabMapHeight, "height", nullptr, "r16_unorm_png"},
    {PBRLabMapNormal, "normal", "derived_from_composed_height", "rgba8_linear_png"},
    {PBRLabMapRoughness, "roughness", nullptr, "rgba8_linear_png"},
    {PBRLabMapAO, "ao", "heightfield_horizon_estimate", "rgba8_linear_png"},
    {PBRLabMapCavity, "cavity", "heightfield_diagnostic", "rgba8_linear_png"},
    {PBRLabMapConvexity, "convexity", "heightfield_diagnostic", "rgba8_linear_png"},
    {PBRLabMapSlope, "slope", "heightfield_diagnostic", "rgba8_linear_png"},
    {PBRLabMapEdge, "edge", "heightfield_diagnostic", "rgba8_linear_png"},
    {PBRLabMapBentNormal, "bent_normal", "heightfield_horizon_estimate", "rgba8_linear_png"},
    {PBRLabMapORM, "orm", "estimated_ao_composed_roughness_composed_metalness", "rgba8_linear_png"},
}};

// Writes a derived result as a bundle at `output` (which must not exist), through a temporary directory.
// `operation` is the provenance of the composed maps ("layer_blend", ...); `section` is added under `sectionKey`.
void writeComposed(const PBRLabResult* result, const PBRLabRecipe& recipe, const LoadedBundle& primary,
                   const fs::path& output, const std::string& label, const std::string& id, NSString* operation,
                   NSString* sectionKey, NSDictionary* section, NSString* normalProvenance = nil) {
    std::error_code ec;
    if (fs::exists(fs::symlink_status(output, ec))) throw std::runtime_error("bundle output already exists: " + output.string());
    if (!output.parent_path().empty()) fs::create_directories(output.parent_path());
    fs::path temp = output;
    temp += ".tmp-" + std::string([[[NSUUID UUID] UUIDString] UTF8String]);
    fs::create_directory(temp);
    try {
        NSMutableDictionary* maps = [NSMutableDictionary dictionary];
        for (const auto& role : kRoles) {
            PBRLabMap map{};
            if (!PBRLabGetMap(result, role.kind, &map)) continue;
            std::vector<uint8_t> png;
            std::string error;
            if (!pbrlab::encodePNG(map, png, error)) throw std::runtime_error(error);
            const std::string file = std::string(role.name) + ".png";
            writeFile(temp / file, png);
            NSString* provenance = role.provenance ? @(role.provenance) : [operation stringByAppendingFormat:@"_%s", role.name];
            if (role.kind == PBRLabMapNormal && normalProvenance) provenance = normalProvenance;
            maps[@(role.name)] = @{@"file": ns(file), @"sha256": ns(sha256(png)), @"width": @(map.width), @"height": @(map.height),
                                   @"pixel_format": @(role.format), @"provenance": provenance};
        }
        NSMutableDictionary* recipeJSON = [recipeDictionary(recipe) mutableCopy];
        if (NSString* preset = [primary.manifest[@"recipe"] isKindOfClass:[NSDictionary class]] ? primary.manifest[@"recipe"][@"material_preset"] : nil)
            if ([preset isKindOfClass:[NSString class]]) recipeJSON[@"material_preset"] = preset;
        const PBRLabSeamMetrics seam = PBRLabGetSeamMetrics(result);
        const PBRLabDerivationInfo info = PBRLabGetDerivationInfo(result);
        NSMutableDictionary* manifest = [@{
            @"schema_version": @1,
            @"bundle_kind": @"pbr-material-bundle",
            @"algorithm_version": @(PBRLabVersion()),
            @"material_id": ns(id),
            @"semantic_label": ns(label),
            @"source": @{@"path": ns(sourceName(primary)), @"sha256": ns(primary.manifestHash),
                         @"color_space": @"converted_to_sRGB", @"source_kind": @"derived_bundle"},
            @"recipe": recipeJSON,
            @"normal_convention": recipe.normal_y_down ? @"-Y" : @"+Y",
            @"maps": maps,
            @"seam_metrics": @{@"height_value_delta": @(seam.height_value_delta),
                               @"height_gradient_delta": @(seam.height_gradient_delta),
                               @"albedo_value_delta": @(seam.albedo_value_delta)},
            @"relief": @{@"height_span_tile_widths": @(info.height_span_tile_widths), @"rms_slope": @(info.rms_slope),
                         @"learned_form_share": @(info.learned_form_share),
                         @"learned_detail_correlation": @(info.learned_detail_correlation),
                         @"detail_polarity": @(info.detail_polarity), @"height_wrap_seam_ratio": @(info.height_wrap_seam_ratio)},
            @"runtime_admitted": @NO
        } mutableCopy];
        manifest[sectionKey] = section;
        NSData* json = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
        if (!json) throw std::runtime_error("cannot encode the bundle manifest");
        writeFile(temp / "manifest.json", std::vector<uint8_t>(static_cast<const uint8_t*>(json.bytes), static_cast<const uint8_t*>(json.bytes) + json.length));
        if (fs::exists(fs::symlink_status(output, ec))) throw std::runtime_error("bundle output appeared meanwhile: " + output.string());
        fs::rename(temp, output);
    } catch (...) { std::error_code ignored; fs::remove_all(temp, ignored); throw; }
}

using ResultPtr = std::unique_ptr<PBRLabResult, decltype(&PBRLabFreeResult)>;
ResultPtr check(PBRLabResult* result, const char* error) {
    if (!result) throw std::runtime_error(error);
    return ResultPtr(result, &PBRLabFreeResult);
}

std::string defaultID(const fs::path& output) {
    std::string raw = output.stem().string();
    for (char& c : raw) if (!(std::isalnum(static_cast<unsigned char>(c)) || c == '-' || c == '_')) c = '_';
    while (!raw.empty() && raw.front() == '_') raw.erase(raw.begin());
    return raw.empty() ? "material" : raw;
}
std::string labelOf(const LoadedBundle& b) {
    NSString* label = [b.manifest[@"semantic_label"] isKindOfClass:[NSString class]] ? b.manifest[@"semantic_label"] : @"material";
    return label.UTF8String;
}

} // namespace

const char* layerMaskName(PBRLabLayerMaskKind kind) {
    switch (kind) {
    case PBRLabLayerMaskHeight: return "height";
    case PBRLabLayerMaskSlope: return "slope";
    case PBRLabLayerMaskNoise: return "noise";
    default: return "image";
    }
}

std::vector<uint8_t> loadMaskImage(const fs::path& path, uint32_t& size) {
    NSData* data = [NSData dataWithContentsOfFile:ns(path.string())];
    if (!data || data.length > 256ull * 1024 * 1024) throw std::runtime_error("cannot read mask image: " + path.string());
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr);
    CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, nullptr) : nullptr;
    if (source) CFRelease(source);
    if (!image) throw std::runtime_error("cannot decode mask image: " + path.string());
    const size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    if (w != h || w < 2 || w > 8192) { CGImageRelease(image); throw std::runtime_error("mask image must be square, 2..8192 pixels"); }
    size = static_cast<uint32_t>(w);
    std::vector<uint8_t> out(w * w);
    // A painted mask is data: grey values without colour management.
    CGColorSpaceRef space = CGColorSpaceCreateDeviceGray();
    CGContextRef context = CGBitmapContextCreate(out.data(), w, w, 8, w, space, static_cast<CGBitmapInfo>(kCGImageAlphaNone));
    CGColorSpaceRelease(space);
    if (!context) { CGImageRelease(image); throw std::runtime_error("cannot allocate the mask buffer"); }
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextDrawImage(context, CGRectMake(0, 0, w, w), image);
    CGContextRelease(context);
    CGImageRelease(image);
    return out;
}

void layerBundles(const fs::path& basePath, const fs::path& topPath, PBRLabLayerParams params, const fs::path& maskImage,
                  const fs::path& output, std::string label, std::string id) {
    const auto base = loadBundle(basePath), top = loadBundle(topPath);
    std::vector<uint8_t> painted;
    NSMutableDictionary* mask = [@{@"type": @(layerMaskName(params.mask)), @"threshold": @(params.threshold),
                                   @"softness": @(params.softness), @"invert": @(params.invert != 0)} mutableCopy];
    if (params.mask == PBRLabLayerMaskImage) {
        if (maskImage.empty()) throw std::runtime_error("an image mask needs a mask file");
        uint32_t size = 0;
        painted = loadMaskImage(maskImage, size);
        params.mask_r8 = painted.data();
        params.mask_row_bytes = size;
        params.mask_size = size;
        mask[@"file"] = ns(maskImage.filename().string());
        mask[@"sha256"] = ns(sha256(readFile(maskImage)));
        mask[@"size_px"] = @(size);
    } else if (params.mask == PBRLabLayerMaskNoise) {
        mask[@"seed"] = @(params.seed);
        mask[@"scale"] = @(std::lround(params.noise_scale));
        mask[@"contrast"] = @(params.noise_contrast);
    }
    char error[256]{};
    std::vector<uint8_t> weights(static_cast<size_t>(base->size) * base->size);
    if (!PBRLabLayerWeights(&base->maps, &top->maps, &params, weights.data(), base->size, error, sizeof(error)))
        throw std::runtime_error(std::string("layer mask failed: ") + error);
    PBRLabRecipe used{};
    auto result = check(PBRLabLayerMaterials(&base->maps, &top->maps, &params, &base->recipe, &used, error, sizeof(error)), error);
    NSDictionary* section = @{@"base": sourceRecord(*base), @"top": sourceRecord(*top), @"mask": mask,
                              @"height_blend": @(params.height_blend),
                              @"normal_blend": params.normal_blend ? @"reoriented" : @"height",
                              @"top_resampled": @(top->size != base->size),
                              @"weights_sha256": ns(sha256(weights)), @"method": @"material_lab_layer_v1"};
    if (id.empty()) id = defaultID(output);
    if (label.empty()) label = labelOf(*top) + " over " + labelOf(*base);
    writeComposed(result.get(), used, *base, output, label, id, @"layer_blend", @"layers", section,
                  params.normal_blend ? @"reoriented_normal_blend" : nil);
}

void variantBundle(const fs::path& sourcePath, const PBRLabVariantParams& params, const fs::path& output,
                   std::string label, std::string id) {
    const auto source = loadBundle(sourcePath);
    char error[256]{};
    PBRLabRecipe used{};
    PBRLabVariantInfo info{};
    auto result = check(PBRLabMakeVariant(&source->maps, &params, &source->recipe, &info, &used, error, sizeof(error)), error);
    NSDictionary* section = @{
        @"source": sourceRecord(*source), @"seed": @(params.seed), @"method": @"material_lab_variant_v1",
        @"amounts": @{@"hue_degrees": @(params.hue_degrees), @"saturation": @(params.saturation), @"value": @(params.value),
                      @"roughness": @(params.roughness), @"relief": @(params.relief), @"offset": @(params.offset != 0),
                      @"rotation": @(params.rotation != 0)},
        @"drawn": @{@"hue_degrees": @(info.hue_degrees), @"saturation_scale": @(info.saturation_scale),
                    @"value_scale": @(info.value_scale), @"roughness_offset": @(info.roughness_offset),
                    @"relief_scale": @(info.relief_scale), @"offset_px": @[@(info.offset_x), @(info.offset_y)],
                    @"quarter_turns": @(info.quarter_turns), @"mirrored": @(info.mirrored != 0)}};
    if (id.empty()) id = defaultID(output);
    if (label.empty()) label = labelOf(*source) + " (variant " + std::to_string(params.seed) + ")";
    writeComposed(result.get(), used, *source, output, label, id, @"variant", @"variant", section);
}

void largeTileBundle(const fs::path& sourcePath, const PBRLabLargeTileParams& params, const fs::path& output,
                     std::string label, std::string id) {
    const auto source = loadBundle(sourcePath);
    char error[256]{};
    PBRLabRecipe used{};
    auto result = check(PBRLabMakeLargeTile(&source->maps, &params, &source->recipe, &used, error, sizeof(error)), error);
    NSDictionary* section = @{@"source": sourceRecord(*source), @"tiles": @(params.tiles), @"seed": @(params.seed),
                              @"patch": @(params.patch), @"sharpness": @(params.sharpness),
                              @"source_size_px": @(source->size), @"method": @"histogram_preserving_tiling_and_blending_v1"};
    if (id.empty()) id = defaultID(output);
    if (label.empty()) label = labelOf(*source) + " (" + std::to_string(params.tiles) + "x" + std::to_string(params.tiles) + " tile)";
    writeComposed(result.get(), used, *source, output, label, id, @"large_tile", @"large_tile", section);
}

} // namespace mltools

// ---------------------------------------------------------------------------------------------------------------------
// C API for the apps (PBRLabExport.h).
namespace {
void setError(char* error, size_t capacity, const std::string& message) {
    if (!error || capacity == 0) return;
    std::strncpy(error, message.c_str(), capacity - 1);
    error[capacity - 1] = '\0';
}
template <typename F> int guardedCall(char* error, size_t capacity, F&& body) {
    setError(error, capacity, "");
    @autoreleasepool {
        try { body(); return 1; }
        catch (const std::exception& e) { setError(error, capacity, e.what()); return 0; }
    }
}
std::string text(const char* s) { return s ? s : ""; }
} // namespace

extern "C" int PBRLabLayerBundles(const char* base_dir, const char* top_dir, const PBRLabLayerParams* params,
                                  const char* mask_image_path, const char* output_dir, const char* label,
                                  const char* material_id, char* error, size_t error_capacity) {
    return guardedCall(error, error_capacity, [&] {
        if (!base_dir || !top_dir || !params || !output_dir) throw std::runtime_error("base, top, parameters and output are required");
        mltools::layerBundles(base_dir, top_dir, *params, text(mask_image_path), output_dir, text(label), text(material_id));
    });
}

extern "C" int PBRLabVariantBundle(const char* bundle_dir, const PBRLabVariantParams* params, const char* output_dir,
                                   const char* label, const char* material_id, char* error, size_t error_capacity) {
    return guardedCall(error, error_capacity, [&] {
        if (!bundle_dir || !params || !output_dir) throw std::runtime_error("bundle, parameters and output are required");
        mltools::variantBundle(bundle_dir, *params, output_dir, text(label), text(material_id));
    });
}

extern "C" int PBRLabLargeTileBundle(const char* bundle_dir, const PBRLabLargeTileParams* params, const char* output_dir,
                                     const char* label, const char* material_id, char* error, size_t error_capacity) {
    return guardedCall(error, error_capacity, [&] {
        if (!bundle_dir || !params || !output_dir) throw std::runtime_error("bundle, parameters and output are required");
        mltools::largeTileBundle(bundle_dir, *params, output_dir, text(label), text(material_id));
    });
}
