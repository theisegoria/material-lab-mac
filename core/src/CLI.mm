#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CommonCrypto/CommonDigest.h>
#include "PBRMaterialLab.h"
#include "PNGWriter.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <iostream>
#include <map>
#include <memory>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

namespace fs = std::filesystem;
namespace {
NSString* ns(const std::string& s) { return [NSString stringWithUTF8String:s.c_str()]; }
std::string str(NSString* s) { return s ? std::string([s UTF8String]) : std::string(); }
std::string hash(NSData* data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, static_cast<CC_LONG>(data.length), digest);
    const char* hex = "0123456789abcdef";
    std::string out; out.reserve(64);
    for (auto c : digest) { out.push_back(hex[c >> 4]); out.push_back(hex[c & 15]); }
    return out;
}
NSData* dataAt(const fs::path& path) { return [NSData dataWithContentsOfFile:ns(path.string())]; }
std::string sanitized(std::string raw) {
    for (char& c : raw) if (!(std::isalnum(static_cast<unsigned char>(c)) || c == '-' || c == '_')) c = '_';
    while (!raw.empty() && raw.front() == '_') raw.erase(raw.begin());
    return raw.empty() ? "material" : raw;
}
struct Image { std::vector<uint8_t> pixels; uint32_t width = 0, height = 0; };
Image decodeSRGB(const fs::path& path) {
    NSData* bytes = dataAt(path);
    if (!bytes) throw std::runtime_error("cannot read input image: " + path.string());
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)bytes, nullptr);
    if (!source) throw std::runtime_error("ImageIO cannot open input image");
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, nullptr);
    CFRelease(source);
    if (!image) throw std::runtime_error("ImageIO cannot decode input image");
    Image out;
    out.width = static_cast<uint32_t>(CGImageGetWidth(image));
    out.height = static_cast<uint32_t>(CGImageGetHeight(image));
    if (out.width < 2 || out.width > 4096 || out.height != out.width) {
        CGImageRelease(image); throw std::runtime_error("input must be square and 2..4096 pixels");
    }
    out.pixels.resize(static_cast<size_t>(out.width) * out.height * 4);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGBitmapInfo info = static_cast<CGBitmapInfo>(static_cast<uint32_t>(kCGImageAlphaPremultipliedLast) | static_cast<uint32_t>(kCGBitmapByteOrder32Big));
    CGContextRef context = CGBitmapContextCreate(out.pixels.data(), out.width, out.height,
                                                 8, static_cast<size_t>(out.width) * 4, space, info);
    CGColorSpaceRelease(space);
    if (!context) { CGImageRelease(image); throw std::runtime_error("cannot allocate sRGB conversion context"); }
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextDrawImage(context, CGRectMake(0, 0, out.width, out.height), image);
    CGContextRelease(context);
    CGImageRelease(image);
    // CoreGraphics stores premultiplied RGBA; the core accepts straight RGBA.
    for (size_t i = 0; i < out.pixels.size(); i += 4) {
        unsigned alpha = out.pixels[i + 3];
        if (alpha == 0) { out.pixels[i] = out.pixels[i + 1] = out.pixels[i + 2] = 0; continue; }
        if (alpha < 255) for (int c = 0; c < 3; ++c)
            out.pixels[i + c] = static_cast<uint8_t>(std::min(255u, (out.pixels[i + c] * 255u + alpha / 2) / alpha));
    }
    return out;
}
std::vector<uint8_t> rawFile(const fs::path& path, size_t expected) {
    NSData* data = dataAt(path);
    if (!data || data.length != expected) throw std::runtime_error("raw mask/height file has wrong byte length: " + path.string());
    return std::vector<uint8_t>(static_cast<const uint8_t*>(data.bytes),
                                static_cast<const uint8_t*>(data.bytes) + data.length);
}
struct Options {
    fs::path input, output, catalog, validate, mask, heightOverride;
    std::string label, id;
    PBRLabRecipe recipe = PBRLabDefaultRecipe(PBRLabPresetFlat);
    bool includeUnreviewed = false;
};
PBRLabPreset parsePreset(const std::string& s) {
    if (s == "flat") return PBRLabPresetFlat;
    if (s == "stone") return PBRLabPresetStone;
    if (s == "fabric") return PBRLabPresetFabric;
    if (s == "organic") return PBRLabPresetOrganic;
    if (s == "coated-metal") return PBRLabPresetCoatedMetal;
    if (s == "bare-metal") return PBRLabPresetBareMetal;
    throw std::runtime_error("unknown preset: " + s);
}
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
float number(const std::string& s) {
    size_t parsed = 0;
    float n = std::stof(s, &parsed);
    if (parsed != s.size() || !std::isfinite(n)) throw std::runtime_error("invalid number: " + s);
    return n;
}
Options parse(int argc, const char** argv) {
    Options o;
    for (int i = 1; i < argc; ++i) {
        std::string flag = argv[i];
        auto value = [&]() -> std::string { if (++i >= argc) throw std::runtime_error("missing value for " + flag); return argv[i]; };
        if (flag == "--input") o.input = value();
        else if (flag == "--output") o.output = value();
        else if (flag == "--catalog") o.catalog = value();
        else if (flag == "--validate") o.validate = value();
        else if (flag == "--id") o.id = value();
        else if (flag == "--label") o.label = value();
        else if (flag == "--preset") o.recipe = PBRLabDefaultRecipe(parsePreset(value()));
        else if (flag == "--height-strength") o.recipe.height_strength = number(value());
        else if (flag == "--polarity") o.recipe.height_polarity = static_cast<int32_t>(number(value()));
        else if (flag == "--roughness") o.recipe.roughness_base = number(value());
        else if (flag == "--roughness-variation") o.recipe.roughness_variation = number(value());
        else if (flag == "--ao-radius") o.recipe.ao_radius_pixels = number(value());
        else if (flag == "--no-tile") o.recipe.tile_wrap = 0;
        else if (flag == "--bent-normal") o.recipe.bent_normal_enabled = 1;
        else if (flag == "--metalness") { o.recipe.assigned_metalness_enabled = 1; o.recipe.assigned_metalness = number(value()); }
        else if (flag == "--relief-mask-r8") o.mask = value();
        else if (flag == "--height-override-r16le") o.heightOverride = value();
        else if (flag == "--include-unreviewed") o.includeUnreviewed = true;
        else if (flag == "--help") {
            std::cout << "material-lab --input IMAGE --output BUNDLE_DIR [--label TEXT --id ID --preset flat|stone|fabric|organic|coated-metal|bare-metal] [--height-strength 0..0.5 --polarity -1|1 --roughness 0..1 --roughness-variation 0..1 --ao-radius 0..64 --no-tile --bent-normal --metalness 0..1 --relief-mask-r8 RAW --height-override-r16le RAW]\n"
                         "material-lab --catalog CATALOG_JSON --output DIR [recipe flags] [--include-unreviewed]\n"
                         "material-lab --validate BUNDLE_DIR\n";
            std::exit(0);
        } else throw std::runtime_error("unknown option: " + flag);
    }
    if (!o.validate.empty()) {
        if (!o.input.empty() || !o.catalog.empty() || !o.output.empty()) throw std::runtime_error("--validate cannot be combined with derive options");
    } else if (o.output.empty() || (o.input.empty() == o.catalog.empty()))
        throw std::runtime_error("provide exactly one of --input or --catalog, plus --output");
    return o;
}
NSArray<NSDictionary*>* mapDefinitions() {
    return @[
        @{@"kind": @(PBRLabMapAlbedo), @"name": @"albedo", @"provenance": @"source_color_converted_to_srgb"},
        @{@"kind": @(PBRLabMapHeight), @"name": @"height", @"provenance": @"estimated_or_authored_height"},
        @{@"kind": @(PBRLabMapNormal), @"name": @"normal", @"provenance": @"derived_from_pseudo_height"},
        @{@"kind": @(PBRLabMapRoughness), @"name": @"roughness", @"provenance": @"artist_prior_with_optional_height_variation"},
        @{@"kind": @(PBRLabMapAO), @"name": @"ao", @"provenance": @"heightfield_horizon_estimate"},
        @{@"kind": @(PBRLabMapCavity), @"name": @"cavity", @"provenance": @"heightfield_diagnostic"},
        @{@"kind": @(PBRLabMapConvexity), @"name": @"convexity", @"provenance": @"heightfield_diagnostic"},
        @{@"kind": @(PBRLabMapSlope), @"name": @"slope", @"provenance": @"heightfield_diagnostic"},
        @{@"kind": @(PBRLabMapEdge), @"name": @"edge", @"provenance": @"heightfield_diagnostic"},
        @{@"kind": @(PBRLabMapBentNormal), @"name": @"bent_normal", @"provenance": @"heightfield_horizon_estimate"},
        @{@"kind": @(PBRLabMapORM), @"name": @"orm", @"provenance": @"estimated_ao_artist_roughness_artist_assigned_metalness"}
    ];
}
void deriveOne(const fs::path& inputPath, const fs::path& outputPath, const std::string& id,
               const std::string& label, const Options& options, NSString* reviewStatus = nil) {
    Image image = decodeSRGB(inputPath);
    const size_t count = static_cast<size_t>(image.width) * image.height;
    auto mask = options.mask.empty() ? std::vector<uint8_t>{} : rawFile(options.mask, count);
    auto authored = options.heightOverride.empty() ? std::vector<uint8_t>{} : rawFile(options.heightOverride, count * 2);
    PBRLabInput input{image.pixels.data(), static_cast<size_t>(image.width) * 4,
                      mask.empty() ? nullptr : mask.data(), mask.empty() ? 0 : image.width,
                      authored.empty() ? nullptr : authored.data(), authored.empty() ? 0 : static_cast<size_t>(image.width) * 2,
                      image.width, image.height};
    char error[256]{};
    std::unique_ptr<PBRLabResult, decltype(&PBRLabFreeResult)> result(
        PBRLabDerive(&input, &options.recipe, nullptr, nullptr, error, sizeof(error)), &PBRLabFreeResult);
    if (!result) throw std::runtime_error(std::string("derivation failed: ") + error);
    if (fs::exists(outputPath)) throw std::runtime_error("bundle output already exists: " + outputPath.string());
    fs::create_directories(outputPath.parent_path());
    fs::path temp = outputPath;
    temp += ".tmp-" + str([[NSUUID UUID] UUIDString]);
    fs::create_directory(temp);
    try {
        NSMutableDictionary* maps = [NSMutableDictionary dictionary];
        for (NSDictionary* definition in mapDefinitions()) {
            auto kind = static_cast<PBRLabMapKind>([definition[@"kind"] intValue]);
            PBRLabMap map{};
            if (!PBRLabGetMap(result.get(), kind, &map)) continue;
            NSString* name = definition[@"name"];
            NSString* filename = [name stringByAppendingString:@".png"];
            fs::path file = temp / str(filename);
            std::string pngError;
            if (!pbrlab::writePNG(file.string(), map, pngError)) throw std::runtime_error(pngError);
            NSData* bytes = dataAt(file);
            NSString* format = map.format == PBRLabPixelFormatR16UNormLE ? @"r16_unorm_png" :
                               map.format == PBRLabPixelFormatRGBA8SRGB ? @"rgba8_srgb_png" : @"rgba8_linear_png";
            NSString* provenance = definition[@"provenance"];
            if (kind == PBRLabMapHeight) provenance = !authored.empty() ? @"authored_height_override" :
                options.recipe.preset == PBRLabPresetFlat ? @"flat_prior" : @"estimated_from_albedo";
            maps[name] = @{@"file": filename, @"sha256": ns(hash(bytes)), @"width": @(map.width),
                           @"height": @(map.height), @"pixel_format": format, @"provenance": provenance};
        }
        NSData* sourceData = dataAt(inputPath);
        PBRLabSeamMetrics seam = PBRLabGetSeamMetrics(result.get());
        NSDictionary* recipe = @{
            @"preset": ns(presetName(options.recipe.preset)),
            @"height_strength": @(options.recipe.height_strength),
            @"height_polarity": @(options.recipe.height_polarity),
            @"roughness_base": @(options.recipe.roughness_base),
            @"roughness_variation": @(options.recipe.roughness_variation),
            @"ao_radius_pixels": @(options.recipe.ao_radius_pixels),
            @"tile_wrap": @(options.recipe.tile_wrap != 0),
            @"assigned_metalness_enabled": @(options.recipe.assigned_metalness_enabled != 0),
            @"assigned_metalness": @(options.recipe.assigned_metalness),
            @"bent_normal_enabled": @(options.recipe.bent_normal_enabled != 0)
        };
        NSMutableDictionary* manifest = [@{
            @"schema_version": @1,
            @"bundle_kind": @"pbr-material-bundle",
            @"algorithm_version": ns(PBRLabVersion()),
            @"material_id": ns(id),
            @"semantic_label": ns(label),
            @"source": @{@"path": ns(inputPath.string()), @"sha256": ns(hash(sourceData)),
                          @"color_space": @"converted_to_sRGB", @"source_kind": @"user_supplied_image"},
            @"recipe": recipe,
            @"maps": maps,
            @"seam_metrics": @{@"height_value_delta": @(seam.height_value_delta),
                                @"height_gradient_delta": @(seam.height_gradient_delta),
                                @"albedo_value_delta": @(seam.albedo_value_delta)},
            @"runtime_admitted": @NO
        } mutableCopy];
        if (reviewStatus) manifest[@"source_review_status"] = reviewStatus;
        NSError* jsonError = nil;
        NSData* json = [NSJSONSerialization dataWithJSONObject:manifest
            options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&jsonError];
        if (!json || ![json writeToFile:ns((temp / "manifest.json").string()) atomically:YES])
            throw std::runtime_error("cannot write material manifest");
        fs::rename(temp, outputPath);
    } catch (...) { fs::remove_all(temp); throw; }
    std::cout << outputPath.string() << '\n';
}
uint32_t readBE32(const uint8_t* p) {
    return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | p[3];
}
void validate(const fs::path& bundle) {
    if (!fs::is_directory(bundle) || fs::is_symlink(bundle / "manifest.json") ||
        !fs::exists(bundle / "manifest.json") || fs::file_size(bundle / "manifest.json") > 4 * 1024 * 1024)
        throw std::runtime_error("bundle manifest missing, linked, or oversized");
    NSData* data = dataAt(bundle / "manifest.json");
    if (!data) throw std::runtime_error("manifest.json missing");
    NSError* jsonError = nil;
    NSDictionary* manifest = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (![manifest isKindOfClass:[NSDictionary class]] || ![manifest[@"schema_version"] isEqual:@1] ||
        ![manifest[@"bundle_kind"] isEqual:@"pbr-material-bundle"] ||
        ![manifest[@"maps"] isKindOfClass:[NSDictionary class]] ||
        ![manifest[@"recipe"] isKindOfClass:[NSDictionary class]] ||
        ![manifest[@"source"] isKindOfClass:[NSDictionary class]] ||
        ![manifest[@"material_id"] isKindOfClass:[NSString class]] ||
        ![manifest[@"semantic_label"] isKindOfClass:[NSString class]] ||
        ![manifest[@"algorithm_version"] isKindOfClass:[NSString class]] ||
        [manifest[@"runtime_admitted"] boolValue])
        throw std::runtime_error("invalid material bundle manifest");
    NSString* sourceHash = manifest[@"source"][@"sha256"];
    if (![sourceHash isKindOfClass:[NSString class]] || sourceHash.length != 64 ||
        ![manifest[@"source"][@"color_space"] isKindOfClass:[NSString class]] ||
        ![manifest[@"seam_metrics"] isKindOfClass:[NSDictionary class]] ||
        [manifest[@"material_id"] length] == 0 ||
        [manifest[@"semantic_label"] length] == 0 || [manifest[@"algorithm_version"] length] == 0)
        throw std::runtime_error("manifest identity or source hash is invalid");
    NSDictionary* recipe = manifest[@"recipe"];
    for (NSString* key in @[@"preset", @"height_strength", @"height_polarity", @"roughness_base",
                          @"roughness_variation", @"ao_radius_pixels", @"tile_wrap",
                          @"assigned_metalness_enabled", @"assigned_metalness", @"bent_normal_enabled"])
        if (!recipe[key]) throw std::runtime_error("manifest recipe parameter missing: " + str(key));
    NSDictionary* maps = manifest[@"maps"];
    uint32_t bundleWidth = 0, bundleHeight = 0;
    for (NSString* required in @[@"albedo", @"height", @"normal", @"roughness", @"ao"])
        if (![maps[required] isKindOfClass:[NSDictionary class]]) throw std::runtime_error("required map missing: " + str(required));
    for (NSString* name in maps) {
        NSDictionary* record = maps[name];
        if (![record isKindOfClass:[NSDictionary class]] ||
            ![record[@"sha256"] isKindOfClass:[NSString class]] || [record[@"sha256"] length] != 64 ||
            ![record[@"width"] isKindOfClass:[NSNumber class]] ||
            ![record[@"height"] isKindOfClass:[NSNumber class]] ||
            ![record[@"pixel_format"] isKindOfClass:[NSString class]] ||
            ![record[@"provenance"] isKindOfClass:[NSString class]])
            throw std::runtime_error("malformed map record: " + str(name));
        NSString* filename = record[@"file"];
        if (![filename isKindOfClass:[NSString class]] || [filename containsString:@"/"] || [filename containsString:@".."])
            throw std::runtime_error("unsafe map filename");
        fs::path mapPath = bundle / str(filename);
        if (!fs::is_regular_file(mapPath) || fs::is_symlink(mapPath) || fs::file_size(mapPath) > 128 * 1024 * 1024)
            throw std::runtime_error("map file missing, linked, or oversized: " + str(filename));
        NSData* file = dataAt(mapPath);
        if (!file || file.length < 33) throw std::runtime_error("map file missing or too short: " + str(filename));
        if (![ns(hash(file)) isEqualToString:record[@"sha256"]]) throw std::runtime_error("map SHA-256 mismatch: " + str(filename));
        auto* p = static_cast<const uint8_t*>(file.bytes);
        constexpr uint8_t signature[8] = {137,80,78,71,13,10,26,10};
        if (std::memcmp(p, signature, 8) || std::memcmp(p + 12, "IHDR", 4))
            throw std::runtime_error("invalid PNG header: " + str(filename));
        if (readBE32(p + 16) != [record[@"width"] unsignedIntValue] ||
            readBE32(p + 20) != [record[@"height"] unsignedIntValue])
            throw std::runtime_error("PNG dimensions do not match manifest: " + str(filename));
        bool height = [name isEqual:@"height"];
        NSString* expectedFormat = height ? @"r16_unorm_png" :
            [name isEqual:@"albedo"] ? @"rgba8_srgb_png" : @"rgba8_linear_png";
        if (p[24] != (height ? 16 : 8) || p[25] != (height ? 0 : 6) ||
            ![record[@"pixel_format"] isEqualToString:expectedFormat])
            throw std::runtime_error("PNG channel format does not match map role: " + str(filename));
        uint32_t width = readBE32(p + 16), heightPixels = readBE32(p + 20);
        if (!width || width > 4096 || heightPixels != width ||
            (bundleWidth && (width != bundleWidth || heightPixels != bundleHeight)))
            throw std::runtime_error("map dimensions are inconsistent or out of range");
        bundleWidth = width; bundleHeight = heightPixels;
        CGImageSourceRef imageSource = CGImageSourceCreateWithData((__bridge CFDataRef)file, nullptr);
        if (!imageSource || CGImageSourceGetStatus(imageSource) != kCGImageStatusComplete) {
            if (imageSource) CFRelease(imageSource);
            throw std::runtime_error("PNG decode failed: " + str(filename));
        }
        CFRelease(imageSource);
    }
    std::cout << "valid: " << bundle.string() << " (" << maps.count << " maps)\n";
}
bool hasLocationKey(id value) {
    if ([value isKindOfClass:[NSDictionary class]]) {
        for (NSString* key in (NSDictionary*)value) {
            NSString* lower = [key lowercaseString];
            if ([lower containsString:@"gps"] || [lower containsString:@"location"] ||
                [lower containsString:@"latitude"] || [lower containsString:@"longitude"]) return true;
            if (hasLocationKey(((NSDictionary*)value)[key])) return true;
        }
    } else if ([value isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray*)value) if (hasLocationKey(item)) return true;
    }
    return false;
}
void verifyDigest(NSData* bytes, NSString* expected, const std::string& label) {
    if (!bytes || ![expected isKindOfClass:[NSString class]] || expected.length != 64 ||
        [ns(hash(bytes)) caseInsensitiveCompare:expected] != NSOrderedSame)
        throw std::runtime_error(label + " SHA-256 mismatch");
}
struct DecodedSize { uint32_t width, height; int bits; };
DecodedSize inspectEncoded(NSData* bytes, const std::string& label, uint32_t maxSide,
                           bool square, NSString* mime) {
    if (!bytes || !bytes.length || bytes.length > 64 * 1024 * 1024)
        throw std::runtime_error(label + " encoded image is missing or oversized");
    auto* p = static_cast<const uint8_t*>(bytes.bytes);
    if ([mime isEqual:@"image/png"]) {
        constexpr uint8_t signature[8] = {137,80,78,71,13,10,26,10};
        if (bytes.length < 33 || std::memcmp(p, signature, 8) || std::memcmp(p + 12, "IHDR", 4))
            throw std::runtime_error(label + " is not PNG");
    } else if (!([mime isEqual:@"image/jpeg"] || [mime isEqual:@"image/heic"]))
        throw std::runtime_error(label + " has unsupported MIME type");
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)bytes, nullptr);
    if (!source || CGImageSourceGetStatus(source) != kCGImageStatusComplete ||
        CGImageSourceGetCount(source) != 1) {
        if (source) CFRelease(source);
        throw std::runtime_error(label + " image decode failed");
    }
    CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr);
    bool metadataHasLocation = properties && hasLocationKey((__bridge id)properties);
    if (properties) CFRelease(properties);
    if (metadataHasLocation) { CFRelease(source); throw std::runtime_error(label + " contains embedded location metadata"); }
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, nullptr);
    CFRelease(source);
    if (!image) throw std::runtime_error(label + " image decode failed");
    DecodedSize result{static_cast<uint32_t>(CGImageGetWidth(image)),
                       static_cast<uint32_t>(CGImageGetHeight(image)),
                       static_cast<int>(CGImageGetBitsPerComponent(image))};
    CGImageRelease(image);
    if (result.width < 2 || result.height < 2 || result.width > maxSide || result.height > maxSide ||
        (square && result.width != result.height))
        throw std::runtime_error(label + " dimensions are out of range");
    return result;
}
void validateCapture(const fs::path& capturePath) {
    constexpr uintmax_t maximumBytes = 64ull * 1024 * 1024;
    if (!fs::is_regular_file(capturePath) || fs::is_symlink(capturePath) ||
        fs::file_size(capturePath) == 0 || fs::file_size(capturePath) > maximumBytes)
        throw std::runtime_error("capture envelope missing, linked, or larger than 64 MiB");
    NSData* file = dataAt(capturePath);
    NSError* jsonError = nil;
    NSDictionary* capture = [NSJSONSerialization JSONObjectWithData:file options:0 error:&jsonError];
    if (![capture isKindOfClass:[NSDictionary class]] ||
        ![capture[@"schemaVersion"] isEqual:@1] ||
        ![capture[@"bundleKind"] isEqual:@"pbr-capture"] ||
        ![capture[@"runtimeAdmitted"] isKindOfClass:[NSNumber class]] ||
        [capture[@"runtimeAdmitted"] boolValue] ||
        ![capture[@"captureId"] isKindOfClass:[NSString class]] ||
        ![[NSUUID alloc] initWithUUIDString:capture[@"captureId"]] ||
        ![capture[@"semanticLabel"] isKindOfClass:[NSString class]] ||
        [capture[@"semanticLabel"] length] == 0 || [capture[@"semanticLabel"] length] > 240 ||
        ![capture[@"sourceMime"] isEqual:@"image/png"] ||
        ![capture[@"sourceBase64"] isKindOfClass:[NSString class]] ||
        ![capture[@"algorithmVersion"] isKindOfClass:[NSString class]] ||
        ![capture[@"recipe"] isKindOfClass:[NSDictionary class]] ||
        ![capture[@"capture"] isKindOfClass:[NSDictionary class]] ||
        ![capture[@"seamMetrics"] isKindOfClass:[NSDictionary class]])
        throw std::runtime_error("invalid capture envelope fields");
    if (hasLocationKey(capture)) throw std::runtime_error("capture contains GPS or location metadata");
    NSData* source = [[NSData alloc] initWithBase64EncodedString:capture[@"sourceBase64"] options:0];
    verifyDigest(source, capture[@"sourceSHA256"], "source");
    DecodedSize sourceSize = inspectEncoded(source, "source", 4096, true, @"image/png");
    NSDictionary* metadata = capture[@"capture"];
    NSArray* originalFields = @[@"originalMime", @"originalBase64", @"originalSHA256",
                                @"originalWidth", @"originalHeight"];
    bool hasOriginal = false;
    for (NSString* key in originalFields) if (metadata[key] && metadata[key] != [NSNull null]) hasOriginal = true;
    if (hasOriginal) {
        NSString* mime = metadata[@"originalMime"];
        NSString* base64 = metadata[@"originalBase64"];
        if (![mime isKindOfClass:[NSString class]] || ![base64 isKindOfClass:[NSString class]] ||
            ![metadata[@"originalWidth"] isKindOfClass:[NSNumber class]] ||
            ![metadata[@"originalHeight"] isKindOfClass:[NSNumber class]])
            throw std::runtime_error("original capture fields are incomplete");
        NSData* original = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
        verifyDigest(original, metadata[@"originalSHA256"], "original");
        auto originalSize = inspectEncoded(original, "original", 8192, false, mime);
        if (originalSize.width != [metadata[@"originalWidth"] unsignedIntValue] ||
            originalSize.height != [metadata[@"originalHeight"] unsignedIntValue] ||
            static_cast<uint64_t>(originalSize.width) * originalSize.height > 50000000)
            throw std::runtime_error("original capture dimensions mismatch");
    }
    id derivedRaw = capture[@"derived"];
    if (derivedRaw && derivedRaw != [NSNull null] && ![derivedRaw isKindOfClass:[NSDictionary class]])
        throw std::runtime_error("derived maps must be an object");
    NSDictionary* derived = [derivedRaw isKindOfClass:[NSDictionary class]] ? derivedRaw : @{};
    NSSet* allowed = [NSSet setWithArray:@[@"albedo", @"height", @"normal", @"roughness", @"ao",
                                        @"cavity", @"convexity", @"slope", @"edge", @"bent_normal", @"orm"]];
    for (NSString* kind in derived) {
        NSDictionary* record = derived[kind];
        if (![allowed containsObject:kind] || ![record isKindOfClass:[NSDictionary class]] ||
            ![record[@"mime"] isEqual:@"image/png"] ||
            ![record[@"base64"] isKindOfClass:[NSString class]] ||
            ![record[@"width"] isKindOfClass:[NSNumber class]] ||
            ![record[@"height"] isKindOfClass:[NSNumber class]] ||
            ![record[@"pixelFormat"] isKindOfClass:[NSString class]] ||
            ![record[@"provenance"] isKindOfClass:[NSString class]])
            throw std::runtime_error("invalid derived map record: " + str(kind));
        NSData* bytes = [[NSData alloc] initWithBase64EncodedString:record[@"base64"] options:0];
        verifyDigest(bytes, record[@"sha256"], str(kind));
        auto size = inspectEncoded(bytes, str(kind), 4096, true, @"image/png");
        if (size.width != sourceSize.width || size.height != sourceSize.height ||
            size.width != [record[@"width"] unsignedIntValue] ||
            size.height != [record[@"height"] unsignedIntValue])
            throw std::runtime_error("derived map dimensions mismatch: " + str(kind));
        auto* png = static_cast<const uint8_t*>(bytes.bytes);
        bool height = [kind isEqual:@"height"];
        NSString* expectedFormat = height ? @"r16_unorm_png" :
            [kind isEqual:@"albedo"] ? @"rgba8_srgb_png" : @"rgba8_linear_png";
        if (![record[@"pixelFormat"] isEqualToString:expectedFormat] ||
            png[24] != (height ? 16 : 8) || png[25] != (height ? 0 : 6))
            throw std::runtime_error("derived map pixel format mismatch: " + str(kind));
    }
    std::cout << "valid capture: " << capturePath.string() << " (" << derived.count << " derived maps)\n";
}
void batch(const Options& options) {
    NSData* data = dataAt(options.catalog);
    if (!data) throw std::runtime_error("cannot read catalog");
    NSError* error = nil;
    NSDictionary* catalog = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![catalog isKindOfClass:[NSDictionary class]]) throw std::runtime_error("catalog root must be an object");
    NSArray* materials = catalog[@"items"] ?: catalog[@"materials"];
    if (![materials isKindOfClass:[NSArray class]]) throw std::runtime_error("catalog has no items or materials array");
    fs::create_directories(options.output);
    std::set<std::string> ids;
    size_t made = 0;
    for (NSDictionary* material in materials) {
        if (![material isKindOfClass:[NSDictionary class]]) throw std::runtime_error("invalid catalog record");
        NSString* status = [material[@"review_status"] isKindOfClass:[NSString class]] ? material[@"review_status"] : nil;
        NSNumber* reviewedFlag = [material[@"reviewed"] isKindOfClass:[NSNumber class]] ? material[@"reviewed"] : nil;
        bool reviewed = reviewedFlag.boolValue || [status isEqualToString:@"approved"] || [status isEqualToString:@"reviewed"];
        if (!reviewed && !options.includeUnreviewed) continue;
        NSString* relative = material[@"path"] ?: material[@"relative_path"];
        NSString* identity = material[@"id"];
        if (![relative isKindOfClass:[NSString class]])
            throw std::runtime_error("catalog entry missing path");
        fs::path rel = str(relative);
        if (rel.is_absolute() || rel.string().find("..") != std::string::npos) throw std::runtime_error("unsafe catalog relative path");
        std::string id = sanitized(identity ? str(identity) : rel.stem().string());
        if (!ids.insert(id).second) throw std::runtime_error("duplicate material ID: " + id);
        fs::path source = options.catalog.parent_path() / rel;
        NSString* label = [material[@"label"] isKindOfClass:[NSString class]] ? material[@"label"] :
            [material[@"material_label"] isKindOfClass:[NSString class]] ? material[@"material_label"] : nil;
        deriveOne(source, options.output / (id + ".pbrmaterial"), id, label ? str(label) : id, options, status);
        ++made;
    }
    if (!made) throw std::runtime_error("no reviewed materials in catalog; use --include-unreviewed to opt in to candidates");
    std::cout << "derived " << made << " material bundles\n";
}
} // namespace
int main(int argc, const char** argv) {
    @autoreleasepool {
        try {
            Options options = parse(argc, argv);
            if (!options.validate.empty()) {
                if (fs::is_directory(options.validate)) validate(options.validate);
                else validateCapture(options.validate);
            }
            else if (!options.catalog.empty()) batch(options);
            else {
                std::string id = options.id.empty() ? sanitized(options.input.stem().string()) : sanitized(options.id);
                std::string label = options.label.empty() ? id : options.label;
                fs::path destination = options.output;
                if (destination.extension() != ".pbrmaterial") destination += ".pbrmaterial";
                deriveOne(options.input, destination, id, label, options);
            }
            return 0;
        } catch (const std::exception& e) {
            std::cerr << "material-lab: " << e.what() << '\n';
            return 1;
        }
    }
}
