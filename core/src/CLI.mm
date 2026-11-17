#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CommonCrypto/CommonDigest.h>
#import <Accelerate/Accelerate.h>
#import <CoreML/CoreML.h>
#import <CoreVideo/CoreVideo.h>
#include <dispatch/dispatch.h>
#include <mach-o/dyld.h>
#include "PBRMaterialLab.h"
#include "PNGWriter.hpp"
#include "tools/Tools.hpp"
#include "tools/MCPServer.hpp"
#include "PBRLabExport.h"
#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <functional>
#include <iostream>
#include <map>
#include <mutex>
#include <thread>
#include <atomic>
#include <memory>
#include <numeric>
#include <optional>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
#include <fcntl.h>
#include <spawn.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;
namespace fs = std::filesystem;
namespace {

// ---------------------------------------------------------------------------------------------
// Signals: SIGINT/SIGTERM set a flag that derivation, batch and the pre-upscale wait loop honour, so
// temporary directories are removed by normal unwinding. A second signal restores the default action.
volatile sig_atomic_t gInterrupted = 0;
volatile sig_atomic_t gChildGroup = 0;
void onSignal(int signal) {
    if (gInterrupted) { ::signal(signal, SIG_DFL); ::raise(signal); return; }
    gInterrupted = signal;
    if (gChildGroup > 0) ::kill(-static_cast<pid_t>(gChildGroup), signal);
}
void installSignalHandlers() {
    struct sigaction action{};
    action.sa_handler = onSignal;
    sigemptyset(&action.sa_mask);
    sigaction(SIGINT, &action, nullptr);
    sigaction(SIGTERM, &action, nullptr);
}
struct Interrupted : std::runtime_error { using std::runtime_error::runtime_error; };
void checkInterrupted() { if (gInterrupted) throw Interrupted("interrupted by signal"); }

// ---------------------------------------------------------------------------------------------
// Conversions and JSON type checks. Every JSON value is type-checked before any message send.
NSString* ns(const std::string& s) {
    NSString* value = [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];
    if (!value) throw std::runtime_error("text is not valid UTF-8");
    return value;
}
std::string str(NSString* s) {
    if (!s) return std::string();
    const char* utf8 = [s UTF8String];
    return utf8 ? std::string(utf8) : std::string();
}
NSString* asString(id value) { return [value isKindOfClass:[NSString class]] ? value : nil; }
NSDictionary* asDictionary(id value) { return [value isKindOfClass:[NSDictionary class]] ? value : nil; }
NSArray* asArray(id value) { return [value isKindOfClass:[NSArray class]] ? value : nil; }
bool isBoolean(id value) {
    return [value isKindOfClass:[NSNumber class]] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}
NSNumber* asNumber(id value) { // Numeric JSON value that is not a boolean.
    return [value isKindOfClass:[NSNumber class]] && !isBoolean(value) ? value : nil;
}
bool finiteNumber(id value, double minimum, double maximum) {
    NSNumber* number = asNumber(value);
    if (!number) return false;
    double n = number.doubleValue;
    return std::isfinite(n) && n >= minimum && n <= maximum;
}
bool exactNumber(id value, double expected) { return finiteNumber(value, expected, expected); }
bool unitPolarity(id value) {
    NSNumber* number = asNumber(value);
    return number && (number.doubleValue == 1.0 || number.doubleValue == -1.0);
}
bool nonemptyString(id value, NSUInteger maximum) {
    NSString* s = asString(value);
    if (!s) return false;
    NSString* trimmed = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length > 0 && s.length <= maximum;
}
std::string hash(const void* bytes, size_t length) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes, static_cast<CC_LONG>(length), digest);
    const char* hex = "0123456789abcdef";
    std::string out; out.reserve(64);
    for (auto c : digest) { out.push_back(hex[c >> 4]); out.push_back(hex[c & 15]); }
    return out;
}
std::string hash(NSData* data) { return hash(data.bytes, data.length); }
bool validSHA256String(id value) {
    NSString* digest = asString(value);
    if (!digest || digest.length != 64) return false;
    for (NSUInteger i = 0; i < digest.length; ++i) {
        unichar c = [digest characterAtIndex:i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) return false;
    }
    return true;
}
bool sameDigest(id a, id b) { // Case-insensitive; both must be well-formed.
    return validSHA256String(a) && validSHA256String(b) &&
           [(NSString*)a caseInsensitiveCompare:(NSString*)b] == NSOrderedSame;
}
NSData* dataAt(const fs::path& path) { return [NSData dataWithContentsOfFile:ns(path.string())]; }
NSData* boundedDataAt(const fs::path& path, uintmax_t maximum) {
    std::error_code ec;
    if (fs::is_symlink(path, ec) || !fs::is_regular_file(path, ec) || fs::file_size(path, ec) > maximum || ec) return nil;
    return dataAt(path);
}
std::string sanitized(std::string raw) {
    for (char& c : raw) if (!(std::isalnum(static_cast<unsigned char>(c)) || c == '-' || c == '_')) c = '_';
    while (!raw.empty() && raw.front() == '_') raw.erase(raw.begin());
    return raw.empty() ? "material" : raw;
}
void warn(const std::string& message) { std::cerr << "material-lab: warning: " << message << '\n'; }

// ---------------------------------------------------------------------------------------------
// Decoding. Orientation (EXIF/TIFF 1..8) is applied so the CLI matches PIL exif_transpose. Pixels are
// decoded unpremultiplied through vImage; the premultiplied CoreGraphics path is only a fallback.
struct Image { std::vector<uint8_t> pixels; uint32_t width = 0, height = 0; };
std::vector<uint8_t> orient(const std::vector<uint8_t>& in, uint32_t w, uint32_t h, int orientation,
                            uint32_t& outW, uint32_t& outH) {
    const bool swap = orientation >= 5 && orientation <= 8;
    outW = swap ? h : w; outH = swap ? w : h;
    if (orientation <= 1 || orientation > 8) return in;
    std::vector<uint8_t> out(in.size());
    for (uint32_t y = 0; y < outH; ++y) for (uint32_t x = 0; x < outW; ++x) {
        uint32_t sx = x, sy = y; // Source pixel displayed at (x, y).
        switch (orientation) {
        case 2: sx = w - 1 - x; sy = y; break;
        case 3: sx = w - 1 - x; sy = h - 1 - y; break;
        case 4: sx = x; sy = h - 1 - y; break;
        case 5: sx = y; sy = x; break;
        case 6: sx = y; sy = h - 1 - x; break;
        case 7: sx = w - 1 - y; sy = h - 1 - x; break;
        case 8: sx = w - 1 - y; sy = x; break;
        default: break;
        }
        std::memcpy(&out[(static_cast<size_t>(y) * outW + x) * 4], &in[(static_cast<size_t>(sy) * w + sx) * 4], 4);
    }
    return out;
}
Image decodeSRGB(NSData* bytes, uint32_t maxSide = 4096) {
    if (!bytes.length) throw std::runtime_error("input image is empty or unreadable");
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)bytes, nullptr);
    if (!source) throw std::runtime_error("ImageIO cannot open input image");
    int orientation = 1;
    if (CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr)) {
        NSNumber* value = asNumber(((__bridge NSDictionary*)properties)[(__bridge NSString*)kCGImagePropertyOrientation]);
        if (value && value.intValue >= 1 && value.intValue <= 8) orientation = value.intValue;
        CFRelease(properties);
    }
    NSDictionary* options = @{(__bridge NSString*)kCGImageSourceShouldCacheImmediately: @YES};
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!image) throw std::runtime_error("ImageIO cannot decode input image");
    const uint32_t w = static_cast<uint32_t>(CGImageGetWidth(image)), h = static_cast<uint32_t>(CGImageGetHeight(image));
    if (w < 2 || w > maxSide || h != w) {
        CGImageRelease(image); throw std::runtime_error("input must be square and 2.." + std::to_string(maxSide) + " pixels");
    }
    std::vector<uint8_t> pixels(static_cast<size_t>(w) * h * 4);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    vImage_CGImageFormat format{};
    format.bitsPerComponent = 8; format.bitsPerPixel = 32; format.colorSpace = space;
    format.bitmapInfo = static_cast<CGBitmapInfo>(static_cast<uint32_t>(kCGImageAlphaLast) |
                                                  static_cast<uint32_t>(kCGBitmapByteOrderDefault));
    format.renderingIntent = kCGRenderingIntentDefault;
    vImage_Buffer buffer{pixels.data(), h, w, static_cast<size_t>(w) * 4};
    vImage_Error decoded = vImageBuffer_InitWithCGImage(&buffer, &format, nullptr, image, kvImageNoAllocate);
    if (decoded != kvImageNoError) {
        // Fallback: premultiplied CoreGraphics draw, then unpremultiply (loses colour under alpha 0).
        CGBitmapInfo info = static_cast<CGBitmapInfo>(static_cast<uint32_t>(kCGImageAlphaPremultipliedLast) |
                                                      static_cast<uint32_t>(kCGBitmapByteOrder32Big));
        CGContextRef context = CGBitmapContextCreate(pixels.data(), w, h, 8, static_cast<size_t>(w) * 4, space, info);
        if (!context) { CGColorSpaceRelease(space); CGImageRelease(image); throw std::runtime_error("cannot allocate sRGB conversion context"); }
        CGContextSetBlendMode(context, kCGBlendModeCopy);
        CGContextDrawImage(context, CGRectMake(0, 0, w, h), image);
        CGContextRelease(context);
        for (size_t i = 0; i < pixels.size(); i += 4) {
            unsigned alpha = pixels[i + 3];
            if (alpha == 0) { pixels[i] = pixels[i + 1] = pixels[i + 2] = 0; continue; }
            if (alpha < 255) for (int c = 0; c < 3; ++c)
                pixels[i + c] = static_cast<uint8_t>(std::min(255u, (pixels[i + c] * 255u + alpha / 2) / alpha));
        }
    }
    CGColorSpaceRelease(space);
    CGImageRelease(image);
    Image out;
    out.pixels = orient(pixels, w, h, orientation, out.width, out.height);
    return out;
}
std::vector<uint8_t> rawFile(const fs::path& path, size_t expected) {
    NSData* data = boundedDataAt(path, expected);
    if (!data || data.length != expected) throw std::runtime_error("raw mask/height file has wrong byte length: " + path.string());
    return std::vector<uint8_t>(static_cast<const uint8_t*>(data.bytes),
                                static_cast<const uint8_t*>(data.bytes) + data.length);
}

// ---------------------------------------------------------------------------------------------
// Options. --preset is applied first regardless of position; every other recipe flag overrides it.
struct Options {
    fs::path input, output, catalog, validate, mask, heightOverride, preUpscaleExec;
    std::vector<std::string> preUpscaleArgs;
    std::string label, id;
    PBRLabRecipe recipe = PBRLabDefaultRecipe(PBRLabPresetFlat);
    fs::path learnedModel, guideNormals, saveGuideNormals;
    // A measured guide from another scanner (docs/DERIVATION.md, "Measured form"): a tangent normal map, or a depth
    // map (grey; white = near) spanning measuredDepthMM, converted with the recipe's tile_metres.
    fs::path measuredGuide;
    float measuredDepthMM = 0;
    bool measuredGuideDX = false;
    // Authored inputs: the source is an artist-made albedo, and/or artist-made maps replace derived ones.
    bool authoredAlbedo = false, normalMapDX = false;
    fs::path heightMap, normalMap, roughnessMap, aoMap, metalnessMap;
    bool learnedCpuOnly = false, guideWeightSet = false;
    bool includeUnreviewed = false, keepGoing = false;
    double preUpscaleTimeout = 600;
    bool preUpscaleTimeoutSet = false;
    // High-resolution export (docs/UPSCALE.md): derive at 4096 or 8192, enlarging the source with the pinned
    // Real-ESRGAN adapter (or the --pre-upscale-exec tool, which may use {scale}) when it is smaller.
    uint32_t resolution = 0;
    fs::path upscalerRoot;
    std::string upscalerDevice = "cpu";
    // Bundle tools (src/tools): each takes validated bundles.
    fs::path infoBundle, contactSheetBundle, exportBundle, previewBundle;
    std::vector<fs::path> diffBundles;
    std::string exportFormat;
    bool json = false, listPresets = false, listFormats = false;
    // Pipeline.
    fs::path recipeFile, saveRecipe, report, watch;
    std::string savedRecipe;
    // A material-library preset (PBRLabFindMaterialPreset) the recipe started from; recorded in manifests.
    std::string materialPreset;
    std::vector<std::string> alsoExport;
    int jobs = 1;
    // Post-derivation operations (Compose.mm): a seeded variant, then a larger tile. --input may then be a bundle.
    std::optional<uint32_t> variantSeed;
    float variantStrength = 1;
    bool variantRotate = false;
    uint32_t largeTile = 0, largeTileSeed = 1;
    float largeTilePatch = 0.5f;
    bool composes() const { return variantSeed.has_value() || largeTile != 0; }
    bool usesTool() const { return !infoBundle.empty() || !contactSheetBundle.empty() || !exportBundle.empty() || !diffBundles.empty() || !previewBundle.empty(); }
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
using mltools::presetName;
float number(const std::string& s) {
    size_t parsed = 0;
    float n = 0;
    try { n = std::stof(s, &parsed); } catch (const std::exception&) { throw std::runtime_error("invalid number: " + s); }
    if (parsed != s.size() || !std::isfinite(n)) throw std::runtime_error("invalid number: " + s);
    return n;
}
constexpr const char* kCLIVersion = "1.4.0";

// --learned: the model shipped beside the binary (<prefix>/share/material-lab), the one the Mac app installs,
// or MATERIAL_LAB_MODEL. Returns an empty path when none is found.
uint32_t wholeNumber(const std::string& s, const std::string& flag) {
    const float n = number(s);
    if (n < 0 || n > 4294967295.0f || n != std::floor(n)) throw std::runtime_error(flag + " must be a whole number 0..4294967295");
    return static_cast<uint32_t>(n);
}
fs::path findLearnedModel(const char* argv0) {
    std::vector<fs::path> candidates;
    if (const char* env = getenv("MATERIAL_LAB_MODEL")) candidates.emplace_back(env);
    std::error_code ec;
    // argv[0] is a bare name when the tool runs from $PATH (e.g. Homebrew's bin symlink); ask dyld for the real path.
    fs::path executable;
    uint32_t size = 0;
    _NSGetExecutablePath(nullptr, &size);
    std::string buffer(size, '\0');
    if (_NSGetExecutablePath(buffer.data(), &size) == 0) executable = fs::canonical(buffer.c_str(), ec);
    if (executable.empty()) executable = fs::canonical(fs::absolute(argv0), ec);
    if (!ec) {
        const fs::path prefix = executable.parent_path().parent_path();
        candidates.push_back(prefix / "share/material-lab/MoGe2Normals.mlmodelc");
        candidates.push_back(executable.parent_path() / "MoGe2Normals.mlmodelc");
    }
    if (const char* home = getenv("HOME"))
        candidates.push_back(fs::path(home) / "Library/Application Support/Material Lab/Models/MoGe2Normals.mlmodelc");
    for (const auto& candidate : candidates)
        if (fs::exists(candidate, ec)) return candidate;
    return {};
}

constexpr const char* kUsage =
    "material-lab --input IMAGE --output BUNDLE_DIR [--label TEXT --id ID] [recipe flags]\n"
    "material-lab --catalog CATALOG_JSON --output DIR [recipe flags] [--include-unreviewed] [--keep-going]\n"
    "material-lab --validate BUNDLE_DIR_OR_CAPTURE_FILE\n"
    "material-lab mcp [--root DIR]...   Model Context Protocol server on stdio (for Claude and other agents)\n"
    "material-lab layer --base BUNDLE --top BUNDLE --mask height|slope|noise|MASK_IMAGE --output BUNDLE_DIR\n"
    "    [--threshold 0..1] [--softness 0..0.5] [--invert] [--seed N --scale 1..64 --contrast 0.1..8 (noise)]\n"
    "    [--height-blend 0..0.95] [--normal-blend height|reoriented] [--label TEXT --id ID]\n"
    "Recipe flags (--preset applies first, wherever it appears):\n"
    "  --preset NAME  a material preset (red-brick, wood-planks, rusted-steel... see --list-presets [--json])\n"
    "    or a relief prior: flat|stone|fabric|organic|coated-metal|bare-metal\n"
    "  --height-strength 0..0.5  --polarity -1|1  --roughness 0..1  --roughness-variation 0..1\n"
    "  --ao-radius 0..64  --ao-strength 0..4  --normal-strength 0..16  --normal-dx (green-down -Y normals)\n"
    "  --equalize 0..1 (albedo delighting)  --no-tile  --bent-normal\n"
    "  --seamless 0..0.45 (make tileable: edge band width)  --seamless-mode cut|blend (default cut: aligned\n"
    "    minimum-error seam for structured textures; blend: histogram-preserving cross-fade for fine noise)\n"
    "  --repair-albedo off|blend|quilt|auto  rebuild the albedo itself so it tiles (band = --seamless, default 0.12);\n"
    "    the repaired albedo feeds every derived map and the learned estimator (auto: quilt unless its cut is costly)\n"
    "  --metalness 0..1  --relief-mask-r8 RAW  --height-override-r16le RAW\n"
    "  --tile-metres 0..64 (physical tile width; 0 = unknown, 1 m)  --mid-relief-share 0..0.8 (4-30 mm relief floor)\n"
    "  --roughness-albedo-limit 0..1 (max roughness/luminance correlation; 1 off)  --substrate-relief 0..1 (flat preset)\n"
    "Authored inputs (artist-made images; resampled to the source size):\n"
    "  --authored  the input is a hand-made albedo (recorded as authored)\n"
    "  --height-map IMG  --normal-map IMG [--normal-map-dx]  --roughness-map IMG  --ao-map IMG  --metalness-map IMG\n"
    "    replace the derived map; an authored normal map also drives height, AO and the masks\n"
    "Recipes and pipelines:\n"
    "  --recipe FILE|BUNDLE  start from a recipe JSON (snake_case or the apps' camelCase) or a bundle's recipe\n"
    "  --saved-recipe NAME  use a recipe saved in the Material Lab Mac app   --save-recipe FILE  write the recipe\n"
    "  --also-export FORMAT,...  export beside each derived bundle (formats as for --export)\n"
    "  --jobs 1..8  parallel catalog items   --report FILE.json  per-item status   --keep-going\n"
    "  --watch DIR --output DIR  derive every image dropped into DIR until interrupted\n"
    "Variants and larger tiles (after deriving; --input may also be a .pbrmaterial bundle):\n"
    "  --variant SEED [--variant-strength 0..3] [--variant-rotate]  small seeded hue/value/roughness/relief shifts\n"
    "    and a tile offset (rotate: also a quarter turn and mirror)\n"
    "  --large-tile 2|4 [--large-tile-seed N] [--large-tile-patch 0.125..1]  a 2 x 2 or 4 x 4 non-repeating tile\n"
    "    (histogram-preserving tiling and blending; every map uses the same patches)\n"
    "Bundle tools (each validates its bundles first):\n"
    "  --info BUNDLE [--json]   --contact-sheet BUNDLE --output SHEET.png   --diff BUNDLE_A BUNDLE_B [--json]\n"
    "  --preview BUNDLE --output PREVIEW.png   a lit render: a sphere and a flat 2 x 2 tiling\n"
    "  --export BUNDLE --format FORMAT --output PATH   (--list-formats [--json] describes each) FORMAT: glb, usdz,\n"
    "    materialx, unreal, unity (URP/Built-in), unity-hdrp, godot, blender, substance, roblox, minecraft-labpbr\n"
    "Learned geometry (see man material-lab):\n"
    "  --learned  use the bundled MoGe-2 model (or the Material Lab app's)   --version\n"
    "  --learned-normals MODEL.mlpackage|.mlmodelc  run a local Core ML tangent-normal estimator (MoGe-2)\n"
    "  --guide-normals PNG  use precomputed +Y tangent normals instead  --guide-weight 0..1 (default 1)\n"
    "  --learned-cpu-only  run the estimator on CPU for more reproducible output\n"
    "  --save-guide-normals PNG  also write the guide normals fed to the core (reusable with --guide-normals)\n"
    "Measured geometry (another scanner's output, used as measured form like the iPhone's LiDAR):\n"
    "  --guide-measured IMG  a +Y tangent normal map [--guide-measured-dx], or a grey depth map (white = near) with\n"
    "    --measured-depth-mm MM (depth black..white spans) and --tile-metres; with --learned: measured form, learned detail\n"
    "Optional local pre-upscale: --pre-upscale-exec ABSOLUTE_EXECUTABLE --pre-upscale-arg ARG (repeat; include\n"
    "  {input} and {output} placeholders) [--pre-upscale-timeout SECONDS, default 600]. No shell or network is\n"
    "  invoked by Material Lab.\n"
    "High-resolution export: --resolution 4096|8192  derive at that size; a smaller source is enlarged with the pinned\n"
    "  Real-ESRGAN adapter (--upscaler-root VENDOR_PROJECT or $MATERIAL_LAB_REALESRGAN_ROOT, --upscaler-device cpu|mps)\n"
    "  or the --pre-upscale-exec tool ({input} {output} {scale}); fails if none is installed (docs/UPSCALE.md)\n";
// ---------------------------------------------------------------------------------------------
// Recipe files. Accepts a bundle manifest recipe (snake_case), the Mac and iOS apps' recipes (camelCase),
// a full manifest, or a .pbrmaterial bundle; fields absent from the file keep the preset's defaults.
PBRLabPreset presetFromName(NSString* name) {
    if (!name) return PBRLabPresetFlat;
    NSString* key = [[name stringByReplacingOccurrencesOfString:@"-" withString:@""] lowercaseString];
    if ([key isEqualToString:@"stone"]) return PBRLabPresetStone;
    if ([key isEqualToString:@"fabric"]) return PBRLabPresetFabric;
    if ([key isEqualToString:@"organic"]) return PBRLabPresetOrganic;
    if ([key isEqualToString:@"coatedmetal"]) return PBRLabPresetCoatedMetal;
    if ([key isEqualToString:@"baremetal"]) return PBRLabPresetBareMetal;
    if ([key isEqualToString:@"flat"]) return PBRLabPresetFlat;
    throw std::runtime_error("recipe has an unknown preset: " + str(name));
}
PBRLabRecipe recipeFromObject(NSDictionary* r) {
    auto field = [&](const char* snake, const char* camel) -> id { id v = r[@(snake)]; return v ?: r[@(camel)]; };
    PBRLabRecipe recipe = PBRLabDefaultRecipe(presetFromName(asString(r[@"preset"])));
    auto num = [&](const char* snake, const char* camel, float& target) {
        id v = field(snake, camel);
        if (!v) return;
        NSNumber* n = asNumber(v);
        if (!n) throw std::runtime_error(std::string("recipe field ") + snake + " must be a number");
        target = n.floatValue;
    };
    auto boolean = [&](const char* snake, const char* camel, uint32_t& target) {
        id v = field(snake, camel);
        if (!v) return;
        if (!isBoolean(v)) throw std::runtime_error(std::string("recipe field ") + snake + " must be true or false");
        target = [v boolValue] ? 1 : 0;
    };
    num("height_strength", "heightStrength", recipe.height_strength);
    num("roughness_base", "roughnessBase", recipe.roughness_base);
    num("roughness_variation", "roughnessVariation", recipe.roughness_variation);
    num("ao_radius_pixels", "aoRadiusPixels", recipe.ao_radius_pixels);
    num("normal_strength", "normalStrength", recipe.normal_strength);
    num("ao_strength", "aoStrength", recipe.ao_strength);
    num("albedo_equalize", "albedoEqualize", recipe.albedo_equalize);
    num("seamless_blend", "seamlessBlend", recipe.seamless_blend);
    num("guide_normal_weight", "guideNormalWeight", recipe.guide_normal_weight);
    num("mid_relief_share", "midReliefShare", recipe.mid_relief_share);
    num("tile_metres", "tileMetres", recipe.tile_metres);
    num("roughness_albedo_limit", "roughnessAlbedoLimit", recipe.roughness_albedo_limit);
    num("substrate_relief", "substrateRelief", recipe.substrate_relief);
    if (id polarity = field("height_polarity", "heightPolarity")) {
        if (!unitPolarity(polarity)) throw std::runtime_error("recipe field height_polarity must be 1 or -1");
        recipe.height_polarity = [polarity intValue];
    }
    boolean("tile_wrap", "tileWrap", recipe.tile_wrap);
    boolean("normal_y_down", "normalYDown", recipe.normal_y_down);
    boolean("bent_normal_enabled", "bentNormalEnabled", recipe.bent_normal_enabled);
    if (r[@"bentNormal"]) boolean("bentNormal", "bentNormal", recipe.bent_normal_enabled);  // iOS spelling
    boolean("assigned_metalness_enabled", "assignedMetalnessEnabled", recipe.assigned_metalness_enabled);
    if (id metal = field("assigned_metalness", "assignedMetalness")) {
        if (NSNumber* n = asNumber(metal)) {
            recipe.assigned_metalness = n.floatValue;
            if (!r[@"assigned_metalness_enabled"] && !r[@"assignedMetalnessEnabled"]) recipe.assigned_metalness_enabled = 1;
        }
    }
    if (NSString* mode = asString(field("seamless_mode", "seamlessMode"))) {
        if (![mode isEqualToString:@"cut"] && ![mode isEqualToString:@"blend"]) throw std::runtime_error("recipe seamless_mode must be cut or blend");
        recipe.seamless_mode = [mode isEqualToString:@"cut"] ? 1 : 0;
    }
    if (NSString* repair = asString(field("albedo_repair", "albedoRepair"))) {
        NSUInteger index = [@[@"off", @"blend", @"quilt", @"auto"] indexOfObject:repair];
        if (index == NSNotFound) throw std::runtime_error("recipe albedo_repair must be off, blend, quilt or auto");
        recipe.albedo_repair = static_cast<uint32_t>(index);
    }
    return recipe;
}
using mltools::recipeDictionary;
// The material-library preset a recipe object names (bundle manifests and --save-recipe use material_preset, the
// apps materialPreset); empty when none or unknown.
std::string materialPresetOf(NSDictionary* r) {
    NSString* name = asString(r[@"material_preset"]) ?: asString(r[@"materialPreset"]);
    return name && PBRLabFindMaterialPreset(name.UTF8String) ? str(name) : std::string();
}
PBRLabRecipe loadRecipeFile(const fs::path& path, std::string* materialPreset = nullptr) {
    fs::path file = fs::is_directory(path) ? path / "manifest.json" : path;
    NSData* data = boundedDataAt(file, 4 * 1024 * 1024);
    if (!data) throw std::runtime_error("cannot read recipe file: " + file.string());
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSDictionary* object = asDictionary(root);
    if (!object) throw std::runtime_error("recipe file must contain a JSON object: " + file.string());
    if (NSDictionary* nested = asDictionary(object[@"recipe"])) object = nested;
    if (!object[@"preset"]) throw std::runtime_error("recipe file has no preset: " + file.string());
    if (materialPreset) *materialPreset = materialPresetOf(object);
    return recipeFromObject(object);
}
PBRLabRecipe loadSavedRecipe(const std::string& name, std::string* materialPreset = nullptr) {
    const char* home = getenv("HOME");
    const fs::path file = fs::path(home ? home : "") / "Library/Application Support/Material Lab/saved-recipes.json";
    NSData* data = boundedDataAt(file, 4 * 1024 * 1024);
    if (!data) throw std::runtime_error("no saved recipes from the Material Lab app at " + file.string());
    NSArray* saved = asArray([NSJSONSerialization JSONObjectWithData:data options:0 error:nil]);
    std::string available;
    for (id value in saved) {
        NSDictionary* entry = asDictionary(value);
        NSString* entryName = asString(entry[@"name"]);
        if (!entryName || !asDictionary(entry[@"recipe"])) continue;
        if ([entryName caseInsensitiveCompare:ns(name)] == NSOrderedSame) {
            if (materialPreset) *materialPreset = materialPresetOf(entry[@"recipe"]);
            return recipeFromObject(entry[@"recipe"]);
        }
        available += (available.empty() ? "" : ", ") + str(entryName);
    }
    throw std::runtime_error("no saved recipe named \"" + name + "\"" + (available.empty() ? "" : " (saved: " + available + ")"));
}

Options parse(int argc, const char** argv) {
    Options o;
    std::optional<PBRLabRecipe> preset;
    std::vector<std::function<void(PBRLabRecipe&)>> overrides;
    for (int i = 1; i < argc; ++i) {
        std::string flag = argv[i];
        auto value = [&]() -> std::string { if (++i >= argc) throw std::runtime_error("missing value for " + flag); return argv[i]; };
        auto recipeNumber = [&](float PBRLabRecipe::*field) { float n = number(value()); overrides.push_back([=](PBRLabRecipe& r) { r.*field = n; }); };
        if (flag == "--input") o.input = value();
        else if (flag == "--output") o.output = value();
        else if (flag == "--catalog") o.catalog = value();
        else if (flag == "--validate") o.validate = value();
        else if (flag == "--id") o.id = value();
        else if (flag == "--label") o.label = value();
        else if (flag == "--preset") {
            // A relief prior (stone, fabric...) or a material-library preset (red-brick, oak...).
            const std::string name = value();
            if (const PBRLabMaterialPreset* library = PBRLabFindMaterialPreset(name.c_str())) {
                preset = library->recipe;
                o.materialPreset = name;
            } else {
                preset = PBRLabDefaultRecipe(parsePreset(name));
                o.materialPreset.clear();
            }
        }
        else if (flag == "--list-presets") o.listPresets = true;
        else if (flag == "--list-formats") o.listFormats = true;
        else if (flag == "--height-strength") recipeNumber(&PBRLabRecipe::height_strength);
        else if (flag == "--polarity") {
            float n = number(value());
            if (n != 1.0f && n != -1.0f) throw std::runtime_error("--polarity must be 1 or -1");
            overrides.push_back([=](PBRLabRecipe& r) { r.height_polarity = static_cast<int32_t>(n); });
        }
        else if (flag == "--roughness") recipeNumber(&PBRLabRecipe::roughness_base);
        else if (flag == "--roughness-variation") recipeNumber(&PBRLabRecipe::roughness_variation);
        else if (flag == "--ao-radius") recipeNumber(&PBRLabRecipe::ao_radius_pixels);
        else if (flag == "--ao-strength") recipeNumber(&PBRLabRecipe::ao_strength);
        else if (flag == "--normal-strength") recipeNumber(&PBRLabRecipe::normal_strength);
        else if (flag == "--equalize") recipeNumber(&PBRLabRecipe::albedo_equalize);
        else if (flag == "--seamless") recipeNumber(&PBRLabRecipe::seamless_blend);
        else if (flag == "--mid-relief-share") recipeNumber(&PBRLabRecipe::mid_relief_share);
        else if (flag == "--tile-metres") recipeNumber(&PBRLabRecipe::tile_metres);
        else if (flag == "--roughness-albedo-limit") recipeNumber(&PBRLabRecipe::roughness_albedo_limit);
        else if (flag == "--substrate-relief") recipeNumber(&PBRLabRecipe::substrate_relief);
        else if (flag == "--seamless-mode") {
            std::string mode = value();
            if (mode != "cut" && mode != "blend") throw std::runtime_error("--seamless-mode must be cut or blend");
            overrides.push_back([=](PBRLabRecipe& r) { r.seamless_mode = mode == "cut" ? 1 : 0; });
        }
        else if (flag == "--repair-albedo") {
            std::string mode = value();
            uint32_t v = mode == "off" ? 0 : mode == "blend" ? 1 : mode == "quilt" ? 2 : mode == "auto" ? 3 : 99;
            if (v == 99) throw std::runtime_error("--repair-albedo must be off, blend, quilt or auto");
            overrides.push_back([=](PBRLabRecipe& r) { r.albedo_repair = v; });
        }
        else if (flag == "--normal-dx") overrides.push_back([](PBRLabRecipe& r) { r.normal_y_down = 1; });
        else if (flag == "--no-tile") overrides.push_back([](PBRLabRecipe& r) { r.tile_wrap = 0; });
        else if (flag == "--bent-normal") overrides.push_back([](PBRLabRecipe& r) { r.bent_normal_enabled = 1; });
        else if (flag == "--metalness") {
            float n = number(value());
            overrides.push_back([=](PBRLabRecipe& r) { r.assigned_metalness_enabled = 1; r.assigned_metalness = n; });
        }
        else if (flag == "--learned-normals") o.learnedModel = value();
        else if (flag == "--learned") {
            o.learnedModel = findLearnedModel(argv[0]);
            if (o.learnedModel.empty())
                throw std::runtime_error("--learned: no MoGe-2 model found beside material-lab, in the Material Lab app, "
                                         "or at $MATERIAL_LAB_MODEL; pass --learned-normals MODEL instead");
        }
        else if (flag == "--version") {
            std::cout << "material-lab " << kCLIVersion << " (derivation core " << PBRLabVersion() << ")\n";
            std::exit(0);
        }
        else if (flag == "--guide-normals") o.guideNormals = value();
        else if (flag == "--guide-measured") o.measuredGuide = value();
        else if (flag == "--guide-measured-dx") o.measuredGuideDX = true;
        else if (flag == "--measured-depth-mm") {
            o.measuredDepthMM = number(value());
            if (!(o.measuredDepthMM > 0 && o.measuredDepthMM <= 10000)) throw std::runtime_error("--measured-depth-mm must be 0..10000 (exclusive of 0)");
        }
        else if (flag == "--learned-cpu-only") o.learnedCpuOnly = true;
        else if (flag == "--save-guide-normals") o.saveGuideNormals = value();
        else if (flag == "--guide-weight") { recipeNumber(&PBRLabRecipe::guide_normal_weight); o.guideWeightSet = true; }
        else if (flag == "--relief-mask-r8") o.mask = value();
        else if (flag == "--height-override-r16le") o.heightOverride = value();
        else if (flag == "--authored") o.authoredAlbedo = true;
        else if (flag == "--height-map") o.heightMap = value();
        else if (flag == "--normal-map") o.normalMap = value();
        else if (flag == "--normal-map-dx") o.normalMapDX = true;
        else if (flag == "--roughness-map") o.roughnessMap = value();
        else if (flag == "--ao-map") o.aoMap = value();
        else if (flag == "--metalness-map") o.metalnessMap = value();
        else if (flag == "--include-unreviewed") o.includeUnreviewed = true;
        else if (flag == "--keep-going") o.keepGoing = true;
        else if (flag == "--pre-upscale-exec") o.preUpscaleExec = value();
        else if (flag == "--pre-upscale-arg") o.preUpscaleArgs.push_back(value());
        else if (flag == "--pre-upscale-timeout") {
            o.preUpscaleTimeout = number(value());
            if (o.preUpscaleTimeout <= 0 || o.preUpscaleTimeout > 86400) throw std::runtime_error("--pre-upscale-timeout must be 0..86400 seconds");
            o.preUpscaleTimeoutSet = true;
        }
        else if (flag == "--resolution") {
            o.resolution = wholeNumber(value(), flag);
            if (o.resolution != 4096 && o.resolution != 8192) throw std::runtime_error("--resolution must be 4096 or 8192");
        }
        else if (flag == "--upscaler-root") o.upscalerRoot = value();
        else if (flag == "--upscaler-device") {
            o.upscalerDevice = value();
            if (o.upscalerDevice != "cpu" && o.upscalerDevice != "mps") throw std::runtime_error("--upscaler-device must be cpu or mps");
        }
        else if (flag == "--info") o.infoBundle = value();
        else if (flag == "--contact-sheet") o.contactSheetBundle = value();
        else if (flag == "--preview") o.previewBundle = value();
        else if (flag == "--diff") { o.diffBundles.push_back(value()); o.diffBundles.push_back(value()); }
        else if (flag == "--export") o.exportBundle = value();
        else if (flag == "--format") o.exportFormat = value();
        else if (flag == "--json") o.json = true;
        else if (flag == "--recipe") o.recipeFile = value();
        else if (flag == "--saved-recipe") o.savedRecipe = value();
        else if (flag == "--save-recipe") o.saveRecipe = value();
        else if (flag == "--report") o.report = value();
        else if (flag == "--watch") o.watch = value();
        else if (flag == "--jobs") {
            o.jobs = static_cast<int>(number(value()));
            if (o.jobs < 1 || o.jobs > 8) throw std::runtime_error("--jobs must be 1..8");
        }
        else if (flag == "--also-export") {
            std::string list = value();
            for (size_t start = 0; start <= list.size();) {
                size_t comma = list.find(',', start);
                std::string format = list.substr(start, comma == std::string::npos ? std::string::npos : comma - start);
                if (!format.empty()) o.alsoExport.push_back(format);
                if (comma == std::string::npos) break;
                start = comma + 1;
            }
        }
        else if (flag == "--variant") o.variantSeed = wholeNumber(value(), flag);
        else if (flag == "--variant-strength") {
            o.variantStrength = number(value());
            if (!(o.variantStrength >= 0 && o.variantStrength <= 3)) throw std::runtime_error("--variant-strength must be 0..3");
        }
        else if (flag == "--variant-rotate") o.variantRotate = true;
        else if (flag == "--large-tile") {
            o.largeTile = wholeNumber(value(), flag);
            if (o.largeTile != 2 && o.largeTile != 4) throw std::runtime_error("--large-tile must be 2 or 4");
        }
        else if (flag == "--large-tile-seed") o.largeTileSeed = wholeNumber(value(), flag);
        else if (flag == "--large-tile-patch") {
            o.largeTilePatch = number(value());
            if (!(o.largeTilePatch >= .125f && o.largeTilePatch <= 1)) throw std::runtime_error("--large-tile-patch must be 0.125..1");
        }
        else if (flag == "--help") { std::cout << kUsage; std::exit(0); }
        else throw std::runtime_error("unknown option: " + flag);
    }
    if (!o.recipeFile.empty() && !o.savedRecipe.empty()) throw std::runtime_error("use either --recipe or --saved-recipe");
    const bool recipeSource = !o.recipeFile.empty() || !o.savedRecipe.empty();
    if (recipeSource && preset) throw std::runtime_error("--preset cannot be combined with a recipe file (the recipe names its preset)");
    o.recipe = !o.recipeFile.empty() ? loadRecipeFile(o.recipeFile, &o.materialPreset)
             : !o.savedRecipe.empty() ? loadSavedRecipe(o.savedRecipe, &o.materialPreset)
             : preset.value_or(PBRLabDefaultRecipe(PBRLabPresetFlat));
    const bool hasGuide = !o.learnedModel.empty() || !o.guideNormals.empty() || !o.measuredGuide.empty();
    if (!o.measuredGuide.empty() && !o.guideNormals.empty())
        throw std::runtime_error("use --guide-measured with --learned (measured form, learned detail) or alone, not with --guide-normals");
    if ((o.measuredDepthMM > 0 || o.measuredGuideDX) && o.measuredGuide.empty())
        throw std::runtime_error("--measured-depth-mm and --guide-measured-dx describe --guide-measured");
    // Authored height or normals supply the geometry a learned-geometry recipe asks for.
    const bool authoredGeometry = !o.normalMap.empty() || !o.heightMap.empty() || !o.heightOverride.empty();
    if (!o.learnedModel.empty() && !o.guideNormals.empty())
        throw std::runtime_error("use either --learned-normals or --guide-normals, not both");
    // A guide defaults to full weight, unless a recipe file already chose one.
    if (hasGuide && !(recipeSource && o.recipe.guide_normal_weight > 0)) o.recipe.guide_normal_weight = 1.0f;
    for (auto& apply : overrides) apply(o.recipe);
    if (o.recipe.guide_normal_weight > 0 && !hasGuide && !authoredGeometry)
        throw std::runtime_error(recipeSource && !o.guideWeightSet
            ? "the recipe uses learned geometry: add --learned-normals MODEL (or --guide-normals PNG), or --guide-weight 0"
            : "--guide-weight needs --learned-normals, --guide-normals or --guide-measured");
    if (o.recipe.albedo_repair != 0 && o.recipe.tile_wrap == 0)
        throw std::runtime_error("--repair-albedo makes a tileable albedo; it cannot be combined with --no-tile");
    if (!o.heightMap.empty() && !o.heightOverride.empty())
        throw std::runtime_error("use either --height-map or --height-override-r16le");
    if (o.normalMapDX && o.normalMap.empty()) throw std::runtime_error("--normal-map-dx describes --normal-map");
    // An authored metalness map fills the ORM blue channel, which exists only with assigned metalness.
    if (!o.metalnessMap.empty()) o.recipe.assigned_metalness_enabled = 1;
    if (!o.saveGuideNormals.empty() && (o.learnedModel.empty() || !o.catalog.empty()))
        throw std::runtime_error("--save-guide-normals needs --learned-normals and a single --input");
    if (o.listPresets || o.listFormats) {
        // Lists and exits; no other options apply.
    } else if (o.usesTool()) {
        const int tools = !o.infoBundle.empty() + !o.contactSheetBundle.empty() + !o.exportBundle.empty() + !o.diffBundles.empty() + !o.previewBundle.empty();
        if (tools != 1 || !o.input.empty() || !o.catalog.empty() || !o.validate.empty())
            throw std::runtime_error("use one of --info, --contact-sheet, --preview, --diff or --export at a time, without derive options");
        if (!o.contactSheetBundle.empty() && o.output.empty()) throw std::runtime_error("--contact-sheet needs --output SHEET.png");
        if (!o.previewBundle.empty() && o.output.empty()) throw std::runtime_error("--preview needs --output PREVIEW.png");
        if (!o.exportBundle.empty() && (o.output.empty() || o.exportFormat.empty()))
            throw std::runtime_error("--export needs --format and --output");
    } else if (!o.validate.empty()) {
        if (!o.input.empty() || !o.catalog.empty() || !o.output.empty() ||
            !o.preUpscaleExec.empty() || !o.preUpscaleArgs.empty())
            throw std::runtime_error("--validate cannot be combined with derive options");
    } else if (!o.saveRecipe.empty() && o.input.empty() && o.catalog.empty() && o.watch.empty()) {
        // --save-recipe on its own writes the recipe and exits.
    } else if (o.output.empty() || (!o.input.empty() + !o.catalog.empty() + !o.watch.empty()) != 1)
        throw std::runtime_error("provide exactly one of --input, --catalog or --watch, plus --output");
    for (const auto& format : o.alsoExport) {
        const auto& known = mltools::exportFormats();
        if (std::find(known.begin(), known.end(), format) == known.end())
            throw std::runtime_error("unknown --also-export format: " + format);
    }
    if (o.jobs > 1 && o.catalog.empty()) throw std::runtime_error("--jobs applies to --catalog batches");
    if ((o.variantStrength != 1 || o.variantRotate) && !o.variantSeed) throw std::runtime_error("--variant-strength and --variant-rotate need --variant SEED");
    if ((o.largeTileSeed != 1 || o.largeTilePatch != 0.5f) && !o.largeTile) throw std::runtime_error("--large-tile-seed and --large-tile-patch need --large-tile");
    if (o.largeTile && o.recipe.tile_wrap == 0) throw std::runtime_error("--large-tile needs a tileable material; it cannot be combined with --no-tile");
    if (!o.composes() && !o.input.empty() && fs::is_directory(o.input))
        throw std::runtime_error("a .pbrmaterial --input needs --variant or --large-tile");
    if ((!o.upscalerRoot.empty() || o.upscalerDevice != "cpu") && !o.resolution)
        throw std::runtime_error("--upscaler-root and --upscaler-device apply to --resolution");
    if (o.resolution && (!o.mask.empty() || !o.heightOverride.empty()))
        throw std::runtime_error("--relief-mask-r8 and --height-override-r16le are raw at the source size; use --height-map with --resolution");
    if (o.preUpscaleExec.empty() != o.preUpscaleArgs.empty())
        throw std::runtime_error("pre-upscale executable and repeated arguments must be supplied together");
    if (!o.preUpscaleExec.empty()) {
        if (!o.preUpscaleExec.is_absolute() || !fs::is_regular_file(o.preUpscaleExec) ||
            access(o.preUpscaleExec.c_str(), X_OK) != 0)
            throw std::runtime_error("pre-upscale executable must be an executable absolute file path");
        bool hasInput = false, hasOutput = false;
        for (const auto& arg : o.preUpscaleArgs) {
            hasInput |= arg.find("{input}") != std::string::npos;
            hasOutput |= arg.find("{output}") != std::string::npos;
        }
        if (!hasInput || !hasOutput)
            throw std::runtime_error("pre-upscale arguments must contain both {input} and {output}");
    }
    return o;
}

// ---------------------------------------------------------------------------------------------
// Map roles shared by writer and validator.
struct MapRole { PBRLabMapKind kind; const char* name; const char* provenance; const char* format; };
constexpr std::array<MapRole, 11> kMapRoles{{
    {PBRLabMapAlbedo, "albedo", "source_color_converted_to_srgb", "rgba8_srgb_png"},
    {PBRLabMapHeight, "height", "estimated_or_authored_height", "r16_unorm_png"},
    {PBRLabMapNormal, "normal", "derived_from_pseudo_height", "rgba8_linear_png"},
    {PBRLabMapRoughness, "roughness", "artist_prior_with_optional_height_variation", "rgba8_linear_png"},
    {PBRLabMapAO, "ao", "heightfield_horizon_estimate", "rgba8_linear_png"},
    {PBRLabMapCavity, "cavity", "heightfield_diagnostic", "rgba8_linear_png"},
    {PBRLabMapConvexity, "convexity", "heightfield_diagnostic", "rgba8_linear_png"},
    {PBRLabMapSlope, "slope", "heightfield_diagnostic", "rgba8_linear_png"},
    {PBRLabMapEdge, "edge", "heightfield_diagnostic", "rgba8_linear_png"},
    {PBRLabMapBentNormal, "bent_normal", "heightfield_horizon_estimate", "rgba8_linear_png"},
    {PBRLabMapORM, "orm", "estimated_ao_artist_roughness_artist_assigned_metalness", "rgba8_linear_png"},
}};
constexpr size_t kRequiredMapCount = 9; // The first nine roles are always present.
const MapRole* roleNamed(NSString* name) {
    for (const auto& role : kMapRoles) if ([name isEqualToString:@(role.name)]) return &role;
    return nullptr;
}

// ---------------------------------------------------------------------------------------------
// Pre-upscale subprocess.
struct ScratchDirectory {
    fs::path path;
    ~ScratchDirectory() {
        if (!path.empty()) { std::error_code ignored; fs::remove_all(path, ignored); }
    }
};
// {scale} is replaced only for --resolution passes (scale nonempty); a plain pre-upscale leaves it as written.
std::string substitute(const std::string& value, const std::string& input, const std::string& output, const std::string& scale = {}) {
    std::string out;
    for (size_t i = 0; i < value.size();) { // Single pass: substituted text is never rescanned.
        if (value.compare(i, 7, "{input}") == 0) { out += input; i += 7; }
        else if (value.compare(i, 8, "{output}") == 0) { out += output; i += 8; }
        else if (!scale.empty() && value.compare(i, 7, "{scale}") == 0) { out += scale; i += 7; }
        else out.push_back(value[i++]);
    }
    return out;
}
struct SpawnResources {
    posix_spawnattr_t attributes; posix_spawn_file_actions_t actions;
    SpawnResources() { posix_spawnattr_init(&attributes); posix_spawn_file_actions_init(&actions); }
    ~SpawnResources() { posix_spawnattr_destroy(&attributes); posix_spawn_file_actions_destroy(&actions); }
};
void sleepMilliseconds(long ms) { timespec t{ms / 1000, (ms % 1000) * 1000000L}; nanosleep(&t, nullptr); }
// Returns the waitpid status; terminates the child's process group on timeout or interruption.
int runChild(const fs::path& executable, std::vector<std::string>& arguments, double timeoutSeconds) {
    std::vector<char*> argv;
    for (auto& arg : arguments) argv.push_back(arg.data());
    argv.push_back(nullptr);
    SpawnResources spawn;
    short flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK;
    posix_spawnattr_setflags(&spawn.attributes, flags);
    posix_spawnattr_setpgroup(&spawn.attributes, 0);
    sigset_t defaults, empty;
    sigemptyset(&defaults); sigaddset(&defaults, SIGINT); sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGPIPE);
    sigemptyset(&empty);
    posix_spawnattr_setsigdefault(&spawn.attributes, &defaults);
    posix_spawnattr_setsigmask(&spawn.attributes, &empty);
    posix_spawn_file_actions_addopen(&spawn.actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&spawn.actions, STDERR_FILENO, STDOUT_FILENO); // Keep our stdout machine-readable.
    posix_spawn_file_actions_addinherit_np(&spawn.actions, STDERR_FILENO);
    checkInterrupted();
    pid_t child = 0;
    int spawned = posix_spawn(&child, executable.c_str(), &spawn.actions, &spawn.attributes, argv.data(), environ);
    if (spawned != 0) throw std::runtime_error("pre-upscale spawn failed: " + std::string(std::strerror(spawned)));
    gChildGroup = child;
    const auto start = std::chrono::steady_clock::now();
    std::optional<std::chrono::steady_clock::time_point> termSent;
    std::string failure;
    int status = 0;
    for (;;) {
        pid_t done = waitpid(child, &status, WNOHANG);
        if (done == child) break;
        if (done < 0 && errno != EINTR) { failure = "pre-upscale wait failed"; break; }
        const auto now = std::chrono::steady_clock::now();
        if (!termSent && (gInterrupted || std::chrono::duration<double>(now - start).count() > timeoutSeconds)) {
            failure = gInterrupted ? "pre-upscale interrupted" : "pre-upscale timed out after " + std::to_string(timeoutSeconds) + " s";
            ::kill(-child, SIGTERM);
            termSent = now;
        } else if (termSent && now - *termSent > std::chrono::seconds(5)) {
            ::kill(-child, SIGKILL);
        }
        sleepMilliseconds(20);
    }
    gChildGroup = 0;
    if (!failure.empty()) {
        if (gInterrupted) throw Interrupted(failure);
        throw std::runtime_error(failure);
    }
    return status;
}
struct PreUpscaleResult { NSData* processed = nil; NSMutableDictionary* provenance = nil; };
struct Upscaler { fs::path executable; std::vector<std::string> arguments; double timeout = 600; };
// One run of a local upscaler on `inputPath` (whose bytes are `original`), writing `output`.
PreUpscaleResult runUpscaler(const fs::path& inputPath, NSData* original, const Upscaler& upscaler, const fs::path& output,
                             const std::string& scale = {}) {
    const fs::path input = fs::absolute(inputPath);
    std::vector<std::string> arguments{upscaler.executable.string()};
    NSMutableArray* templates = [NSMutableArray array];
    NSMutableArray* localFileHashes = [NSMutableArray array];
    for (const auto& arg : upscaler.arguments) {
        [templates addObject:ns(arg)];
        // Only explicit paths are hashed; bare words such as "-I" or "stone" are never looked up in the cwd.
        const bool pathLike = !arg.empty() && (arg.front() == '/' || arg.find('/') != std::string::npos);
        if (pathLike && arg.find('{') == std::string::npos) {
            std::error_code ec;
            fs::path candidate = fs::absolute(arg, ec);
            if (!ec && fs::is_regular_file(candidate, ec) && !ec &&
                fs::file_size(candidate, ec) <= 128ull * 1024 * 1024 && !ec) {
                if (NSData* bytes = dataAt(candidate))
                    [localFileHashes addObject:@{@"path": ns(candidate.filename().string()), @"sha256": ns(hash(bytes))}];
            }
        }
        arguments.push_back(substitute(arg, input.string(), output.string(), scale));
    }
    NSData* tool = dataAt(upscaler.executable);
    if (!tool) throw std::runtime_error("cannot hash pre-upscale executable");
    int status = runChild(upscaler.executable, arguments, upscaler.timeout);
    if (WIFSIGNALED(status))
        throw std::runtime_error("pre-upscale process terminated by signal " + std::to_string(WTERMSIG(status)));
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
        throw std::runtime_error("pre-upscale process exited with status " + std::to_string(WEXITSTATUS(status)));
    NSData* processed = boundedDataAt(output, 128ull * 1024 * 1024);
    if (!processed || !processed.length)
        throw std::runtime_error("pre-upscale process did not produce a bounded regular output image");
    NSString* inputHash = ns(hash(original));
    NSString* outputHash = ns(hash(processed));
    NSMutableDictionary* provenance = [@{
        @"mode": @"external_local_argv_process",
        @"executable": ns(upscaler.executable.filename().string()),
        @"executable_sha256": ns(hash(tool)),
        @"arguments_template": templates,
        @"local_argument_files": localFileHashes,
        @"input_sha256": inputHash,
        @"output_sha256": outputHash
    } mutableCopy];
    fs::path receiptPath = output;
    receiptPath += ".upscale.json";
    std::error_code ec;
    if (fs::exists(fs::symlink_status(receiptPath, ec))) {
        NSData* receiptBytes = boundedDataAt(receiptPath, 1024 * 1024);
        if (!receiptBytes) throw std::runtime_error("pre-upscale receipt is not a bounded regular JSON file");
        NSError* receiptError = nil;
        NSDictionary* receipt = asDictionary([NSJSONSerialization JSONObjectWithData:receiptBytes options:0 error:&receiptError]);
        if (!receipt || !sameDigest(receipt[@"sourceSHA256"], inputHash) || !sameDigest(receipt[@"outputSHA256"], outputHash))
            throw std::runtime_error("pre-upscale receipt hashes do not match actual input/output bytes");
        provenance[@"receipt"] = receipt;
        provenance[@"receipt_sha256"] = ns(hash(receiptBytes));
        provenance[@"receipt_json_base64"] = [receiptBytes base64EncodedStringWithOptions:0];
    }
    return {processed, provenance};
}
PreUpscaleResult runPreUpscale(const fs::path& inputPath, NSData* original, const Options& options,
                               ScratchDirectory& scratch) {
    scratch.path = fs::temp_directory_path() / ("material-lab-pre-upscale-" + str([[NSUUID UUID] UUIDString]));
    fs::create_directory(scratch.path);
    return runUpscaler(inputPath, original, Upscaler{options.preUpscaleExec, options.preUpscaleArgs, options.preUpscaleTimeout},
                       scratch.path / "upscaled.png");
}

// The pinned Real-ESRGAN adapter (scripts/pinned_realesrgan.py) run with the vendor tree's pinned Python.
fs::path executablePath() {
    uint32_t size = 0;
    _NSGetExecutablePath(nullptr, &size);
    std::string buffer(size, '\0');
    std::error_code ec;
    if (_NSGetExecutablePath(buffer.data(), &size) != 0) return {};
    fs::path path = fs::canonical(buffer.c_str(), ec);
    return ec ? fs::path() : path;
}
Upscaler pinnedUpscaler(const Options& options, uint32_t from) {
    const std::string need = "--resolution " + std::to_string(options.resolution) + " needs an upscaler to enlarge this " +
        std::to_string(from) + " px source: ";
    fs::path root = options.upscalerRoot;
    if (root.empty()) if (const char* env = getenv("MATERIAL_LAB_REALESRGAN_ROOT")) root = env;
    if (root.empty())
        throw std::runtime_error(need + "the pinned Real-ESRGAN upscaler is not configured. Pass --upscaler-root VENDOR_PROJECT "
                                 "(or set MATERIAL_LAB_REALESRGAN_ROOT), or name another local upscaler with --pre-upscale-exec "
                                 "and --pre-upscale-arg ({input} {output} {scale}); see docs/UPSCALE.md");
    root = fs::absolute(root);
    std::error_code ec;
    fs::path python = root / "third_party/realesrgan/.venv/bin/python3.11";
    if (const char* env = getenv("MATERIAL_LAB_REALESRGAN_PYTHON")) python = env;
    if (!fs::is_regular_file(python, ec) || access(python.c_str(), X_OK) != 0)
        throw std::runtime_error(need + "the pinned Real-ESRGAN Python is not installed at " + python.string() +
                                 " (set MATERIAL_LAB_REALESRGAN_PYTHON to override); see docs/UPSCALE.md");
    if (!fs::is_regular_file(root / "script/vendor_realesrgan.py", ec))
        throw std::runtime_error(need + root.string() + " is not a pinned Real-ESRGAN vendor project (no script/vendor_realesrgan.py)");
    std::vector<fs::path> adapters;
    if (const char* env = getenv("MATERIAL_LAB_REALESRGAN_ADAPTER")) adapters.emplace_back(env);
    const fs::path executable = executablePath();
    if (!executable.empty()) {
        adapters.push_back(executable.parent_path() / "pinned_realesrgan.py");
        adapters.push_back(executable.parent_path().parent_path() / "share/material-lab/pinned_realesrgan.py");
        adapters.push_back(executable.parent_path().parent_path().parent_path() / "scripts/pinned_realesrgan.py");  // build/core
    }
    fs::path adapter;
    for (const auto& candidate : adapters) if (fs::is_regular_file(candidate, ec)) { adapter = fs::canonical(candidate, ec); break; }
    if (adapter.empty())
        throw std::runtime_error(need + "pinned_realesrgan.py was not found beside material-lab, in share/material-lab, or at "
                                 "$MATERIAL_LAB_REALESRGAN_ADAPTER");
    return Upscaler{python, {"-I", adapter.string(), "--vendor-project-root", root.string(), "--input", "{input}", "--output",
                             "{output}", "--scale", "{scale}", "--device", options.upscalerDevice},
                    options.preUpscaleTimeoutSet ? options.preUpscaleTimeout : 3600};
}

// Square RGBA8 resample with vImage's high-quality (Lanczos) kernel.
Image resampleImage(const Image& image, uint32_t size) {
    Image out;
    out.width = out.height = size;
    out.pixels.resize(static_cast<size_t>(size) * size * 4);
    vImage_Buffer source{const_cast<uint8_t*>(image.pixels.data()), image.height, image.width, static_cast<size_t>(image.width) * 4};
    vImage_Buffer destination{out.pixels.data(), size, size, static_cast<size_t>(size) * 4};
    if (vImageScale_ARGB8888(&source, &destination, nullptr, kvImageHighQualityResampling) != kvImageNoError)
        throw std::runtime_error("cannot resample the image");
    return out;
}

// Periodic padding: `pad` pixels of wrap on every side (pad <= size).
Image wrapPad(const Image& image, uint32_t pad) {
    const uint32_t n = image.width, m = n + 2 * pad;
    Image out;
    out.width = out.height = m;
    out.pixels.resize(static_cast<size_t>(m) * m * 4);
    for (uint32_t y = 0; y < m; ++y)
        for (uint32_t x = 0; x < m; ++x)
            std::memcpy(&out.pixels[(static_cast<size_t>(y) * m + x) * 4],
                        &image.pixels[(static_cast<size_t>((y + n - pad) % n) * n + (x + n - pad) % n) * 4], 4);
    return out;
}
Image crop(const Image& image, uint32_t offset, uint32_t size) {
    Image out;
    out.width = out.height = size;
    out.pixels.resize(static_cast<size_t>(size) * size * 4);
    for (uint32_t y = 0; y < size; ++y)
        std::memcpy(&out.pixels[static_cast<size_t>(y) * size * 4],
                    &image.pixels[(static_cast<size_t>(y + offset) * image.width + offset) * 4], static_cast<size_t>(size) * 4);
    return out;
}
// Resample a tileable image so it stays tileable: pad with wrap, scale, crop one period. The pad is a multiple of
// size / gcd(size, target), so the padded image scales by exactly target / size and the crop lands on whole pixels.
Image resampleWrapped(const Image& image, uint32_t target, bool wrap) {
    if (image.width == target) return image;
    if (!wrap) return resampleImage(image, target);
    const uint32_t n = image.width, unit = n / std::gcd(n, target);
    uint32_t pad = unit * ((std::max<uint32_t>(8, n / 16) + unit - 1) / unit);
    if (pad > n) pad = n;
    const Image scaled = resampleImage(wrapPad(image, pad), (n + 2 * pad) / unit * (target / std::gcd(n, target)));
    return crop(scaled, pad / unit * (target / std::gcd(n, target)), target);
}

// --resolution: reach the target with 2x/4x upscaler passes that land exactly on it. A source more than half the target
// gets one 2x pass and a resample down; otherwise the source is first resampled up (by less than 2x) to target / P, P the
// largest power of two <= target / source, then P is applied in 4x and 2x passes. When the recipe tiles, every step is
// wrap-padded and cropped, so the upscaled albedo still tiles. Each pass reads a PNG of the oriented sRGB pixels.
Image toResolution(Image image, const Options& options, ScratchDirectory& scratch, NSMutableDictionary* __strong& provenance) {
    const uint32_t target = options.resolution, from = image.width;
    const bool wrap = options.recipe.tile_wrap != 0;
    NSMutableArray* passes = [NSMutableArray array];
    const bool custom = !options.preUpscaleExec.empty();
    std::vector<int> scales;
    uint32_t start = from;
    if (from < target) {
        if (from * 2 > target) scales = {2};
        else {
            uint32_t factor = 2;
            while (factor * 2 * from <= target && factor < 64) factor *= 2;
            start = target / factor;
            for (; factor >= 4; factor /= 4) scales.push_back(4);
            if (factor == 2) scales.push_back(2);
        }
    }
    const bool preResampled = start != from;
    if (preResampled) image = resampleWrapped(image, start, wrap);
    if (!scales.empty()) {
        const Upscaler upscaler = custom ? Upscaler{options.preUpscaleExec, options.preUpscaleArgs, options.preUpscaleTimeout}
                                         : pinnedUpscaler(options, from);
        scratch.path = fs::temp_directory_path() / ("material-lab-resolution-" + str([[NSUUID UUID] UUIDString]));
        fs::create_directory(scratch.path);
        for (size_t pass = 0; pass < scales.size(); ++pass) {
            const int scale = scales[pass];
            const uint32_t pad = wrap ? std::max<uint32_t>(8, image.width / 16) : 0;
            const Image input = pad ? wrapPad(image, std::min(pad, image.width)) : image;
            PBRLabMap map{input.pixels.data(), input.width, input.height, static_cast<size_t>(input.width) * 4,
                          input.pixels.size(), PBRLabPixelFormatRGBA8SRGB};
            std::vector<uint8_t> png;
            std::string pngError;
            const fs::path inputFile = scratch.path / ("pass-" + std::to_string(pass + 1) + "-input.png");
            if (!pbrlab::encodePNG(map, png, pngError) || !pbrlab::writeFileAtomically(inputFile.string(), png, pngError))
                throw std::runtime_error("cannot write the upscaler input: " + pngError);
            const fs::path output = scratch.path / ("pass-" + std::to_string(pass + 1) + ".png");
            PreUpscaleResult result = runUpscaler(inputFile, [NSData dataWithBytes:png.data() length:png.size()], upscaler, output,
                                                  std::to_string(scale));
            Image next = decodeSRGB(result.processed, 8192 + 2 * 8192 / 16);
            if (next.width != input.width * static_cast<uint32_t>(scale))
                throw std::runtime_error("the upscaler returned " + std::to_string(next.width) + " px for a " +
                                         std::to_string(scale) + "x pass of " + std::to_string(input.width) + " px");
            result.provenance[@"scale"] = @(scale);
            result.provenance[@"output_dimensions_px"] = @[@(next.width), @(next.height)];
            result.provenance[@"wrap_padding_px"] = @(input.width == image.width ? 0 : (input.width - image.width) / 2);
            [passes addObject:result.provenance];
            image = input.width == image.width ? std::move(next)
                                               : crop(next, (input.width - image.width) / 2 * scale, image.width * scale);
            std::error_code ignored;
            fs::remove(inputFile, ignored);
            checkInterrupted();
        }
    }
    const bool resampledDown = image.width != target;
    if (resampledDown) image = resampleWrapped(image, target, wrap);
    provenance = [@{@"target_px": @(target), @"source_px": @(from), @"passes": passes,
                    @"upscaler": passes.count ? (custom ? @"custom" : @"pinned_realesrgan") : @"none",
                    @"pre_resample_px": @(start), @"wrap": @(wrap),
                    @"resample": preResampled || resampledDown ? @"vimage_high_quality_lanczos" : @"none",
                    @"processed_rgba8_sha256": ns(hash(image.pixels.data(), image.pixels.size()))} mutableCopy];
    return image;
}

// ---------------------------------------------------------------------------------------------
// Learned guide normals (docs/LEARNED_NORMALS.md). The Core ML model returns +Y tangent normals for a
// 518x518 RGB tile; the core's PBRLabGuideTiler owns the tiling contract (wrap padding, two orientations, fold).
constexpr int kLearnedTile = PBRLAB_GUIDE_TILE;
struct GuideNormals { std::vector<uint8_t> rgba; NSMutableDictionary* provenance = nil; };

struct LoadedModel { MLModel* model = nil; NSDictionary* metadata = nil; std::string file; };
std::mutex gLearnedMutex;
std::mutex gOutputMutex;  // One whole line at a time from concurrent batch jobs.  // Guards the model cache and serializes inference across batch jobs.
LoadedModel& learnedModel(const fs::path& path, bool cpuOnly) {
    static std::map<std::string, LoadedModel> cache;
    std::string key = path.string() + (cpuOnly ? "#cpu" : "#all");
    auto found = cache.find(key);
    if (found != cache.end()) return found->second;
    NSURL* url = [NSURL fileURLWithPath:ns(path.string())];
    NSError* error = nil;
    const std::string ext = path.extension().string();
    if (ext == ".mlpackage" || ext == ".mlmodel") {
        url = [MLModel compileModelAtURL:url error:&error];
        if (!url) throw std::runtime_error("cannot compile Core ML model: " + str(error.localizedDescription ?: @"unknown"));
    } else if (ext != ".mlmodelc") throw std::runtime_error("--learned-normals expects an .mlpackage, .mlmodel or .mlmodelc");
    MLModelConfiguration* configuration = [MLModelConfiguration new];
    configuration.computeUnits = cpuOnly ? MLComputeUnitsCPUOnly : MLComputeUnitsAll;
    MLModel* model = [MLModel modelWithContentsOfURL:url configuration:configuration error:&error];
    if (!model) throw std::runtime_error("cannot load Core ML model: " + str(error.localizedDescription ?: @"unknown"));
    NSDictionary* metadata = asDictionary(model.modelDescription.metadata[MLModelCreatorDefinedKey]);
    if (![asString(metadata[@"materiallab.contract"]) isEqualToString:@"tangent_normals_plus_y_v1"])
        throw std::runtime_error("Core ML model does not declare materiallab.contract = tangent_normals_plus_y_v1");
    return cache[key] = LoadedModel{model, metadata, path.filename().string()};
}

// The tiling contract lives in the core (PBRLabGuideTiler) so every client feeds identical guide normals.
Image resampleImage(const Image& image, uint32_t size);
GuideNormals runLearnedNormals(const Image& image, const Options& options) {
    std::lock_guard<std::mutex> lock(gLearnedMutex);
    const int n = static_cast<int>(image.width);
    LoadedModel& loaded = learnedModel(options.learnedModel, options.learnedCpuOnly);
    // The tiler takes sources up to 4096 (its working size is at most 2072); an 8K derivation feeds it a 4096 copy
    // and still finishes the guide at the full size.
    const Image reduced = image.width > 4096 ? resampleImage(image, 4096) : Image{};
    const Image& estimatorInput = image.width > 4096 ? reduced : image;
    std::unique_ptr<PBRLabGuideTiler, decltype(&PBRLabGuideTilerFree)> tiler(
        PBRLabGuideTilerCreate(estimatorInput.pixels.data(), static_cast<size_t>(estimatorInput.width) * 4, estimatorInput.width,
                               options.recipe.tile_wrap),
        &PBRLabGuideTilerFree);
    if (!tiler) throw std::runtime_error("cannot prepare the learned estimator input");
    CVPixelBufferRef tile = nullptr;
    NSDictionary* attributes = @{(__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    if (CVPixelBufferCreate(kCFAllocatorDefault, kLearnedTile, kLearnedTile, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attributes, &tile) != kCVReturnSuccess)
        throw std::runtime_error("cannot allocate Core ML input buffer");
    try {
        std::vector<float> predicted(static_cast<size_t>(kLearnedTile) * kLearnedTile * 3);
        const uint32_t passes = PBRLabGuideTilerPassCount(tiler.get());
        for (uint32_t pass = 0; pass < passes; ++pass) {
            checkInterrupted();
            CVPixelBufferLockBaseAddress(tile, 0);
            const int filled = PBRLabGuideTilerFillInput(tiler.get(), pass, static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(tile)),
                                                         CVPixelBufferGetBytesPerRow(tile));
            CVPixelBufferUnlockBaseAddress(tile, 0);
            if (!filled) throw std::runtime_error("cannot fill the learned estimator input");
            NSError* error = nil;
            MLDictionaryFeatureProvider* input = [[MLDictionaryFeatureProvider alloc]
                initWithDictionary:@{@"image": [MLFeatureValue featureValueWithPixelBuffer:tile]} error:&error];
            id<MLFeatureProvider> output = input ? [loaded.model predictionFromFeatures:input error:&error] : nil;
            MLMultiArray* normals = [output featureValueForName:@"normals"].multiArrayValue;
            if (!normals || normals.shape.count != 4 || normals.shape[1].intValue != 3 ||
                normals.shape[2].intValue != kLearnedTile || normals.shape[3].intValue != kLearnedTile)
                throw std::runtime_error("learned estimator failed: " + str(error.localizedDescription ?: @"unexpected output shape"));
            const NSInteger cs = normals.strides[1].integerValue, ys = normals.strides[2].integerValue, xs = normals.strides[3].integerValue;
            const MLMultiArrayDataType type = normals.dataType;
            float* out = predicted.data();
            [normals getBytesWithHandler:^(const void* bytes, NSInteger) {
                auto read = [&](NSInteger offset) -> float {
                    if (type == MLMultiArrayDataTypeFloat16) return static_cast<float>(static_cast<const __fp16*>(bytes)[offset]);
                    if (type == MLMultiArrayDataTypeDouble) return static_cast<float>(static_cast<const double*>(bytes)[offset]);
                    return static_cast<const float*>(bytes)[offset];
                };
                for (int c = 0; c < 3; ++c) for (int y = 0; y < kLearnedTile; ++y) for (int x = 0; x < kLearnedTile; ++x)
                    out[(static_cast<size_t>(c) * kLearnedTile + y) * kLearnedTile + x] = read(c * cs + y * ys + x * xs);
            }];
            if (!PBRLabGuideTilerAddPrediction(tiler.get(), pass, predicted.data(), kLearnedTile * kLearnedTile, kLearnedTile, 1))
                throw std::runtime_error("cannot accumulate a learned estimator prediction");
        }
    } catch (...) { CVPixelBufferRelease(tile); throw; }
    CVPixelBufferRelease(tile);
    GuideNormals guide;
    guide.rgba.resize(static_cast<size_t>(n) * n * 4);
    if (!PBRLabGuideTilerFinish(tiler.get(), image.width, guide.rgba.data(), static_cast<size_t>(n) * 4))
        throw std::runtime_error("cannot finish the learned guide normals");
    NSString* weightsHash = asString(loaded.metadata[@"materiallab.weights_sha256"]);
    guide.provenance = [@{
        @"estimator": @"moge-2-vits-normal",
        @"contract": @"tangent_normals_plus_y_v1",
        @"weights_sha256": weightsHash ?: @"unknown",
        @"moge_commit": asString(loaded.metadata[@"materiallab.moge_commit"]) ?: @"unknown",
        @"model_file": ns(loaded.file),
        @"compute_units": options.learnedCpuOnly ? @"cpu_only" : @"all",
        @"work_resolution": @(PBRLabGuideTilerWorkResolution(tiler.get())),
        @"tiles": @(PBRLabGuideTilerTileCount(tiler.get())),
        @"tiling": @(PBRLabGuideTilerContract(tiler.get())),
        @"normals_sha256": ns(hash(guide.rgba.data(), guide.rgba.size()))
    } mutableCopy];
    return guide;
}
enum class DataMap { normalRGBA8, gray8, height16 };
std::vector<uint8_t> loadDataMap(const fs::path& path, uint32_t size, DataMap kind, const char* flag);
GuideNormals loadGuideNormalsPNG(const fs::path& path, uint32_t size, bool resample = false) {
    if (resample) {
        // --resolution: precomputed guides are usually at the source size; resample them to the derivation size.
        GuideNormals guide;
        guide.rgba = loadDataMap(path, size, DataMap::normalRGBA8, "--guide-normals");
        guide.provenance = [@{@"estimator": @"external", @"contract": @"tangent_normals_plus_y_v1",
                              @"model_file": ns(path.filename().string()), @"weights_sha256": @"unknown",
                              @"resampled_to_px": @(size),
                              @"normals_sha256": ns(hash(guide.rgba.data(), guide.rgba.size()))} mutableCopy];
        return guide;
    }
    NSData* data = boundedDataAt(path, 256ull * 1024 * 1024);
    if (!data) throw std::runtime_error("cannot read --guide-normals file: " + path.string());
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr);
    CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, nullptr) : nullptr;
    if (source) CFRelease(source);
    if (!image) throw std::runtime_error("cannot decode --guide-normals PNG");
    if (CGImageGetWidth(image) != size || CGImageGetHeight(image) != size) {
        CGImageRelease(image); throw std::runtime_error("--guide-normals must match the source dimensions");
    }
    GuideNormals guide;
    guide.rgba.resize(static_cast<size_t>(size) * size * 4);
    // Normals are data: draw without colour management into a device RGB context.
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(guide.rgba.data(), size, size, 8, static_cast<size_t>(size) * 4, space,
        static_cast<CGBitmapInfo>(static_cast<uint32_t>(kCGImageAlphaNoneSkipLast) | static_cast<uint32_t>(kCGBitmapByteOrder32Big)));
    CGColorSpaceRelease(space);
    if (!context) { CGImageRelease(image); throw std::runtime_error("cannot allocate guide normal buffer"); }
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextDrawImage(context, CGRectMake(0, 0, size, size), image);
    CGContextRelease(context);
    CGImageRelease(image);
    for (size_t i = 0; i < guide.rgba.size(); i += 4) guide.rgba[i + 3] = 255;
    guide.provenance = [@{@"estimator": @"external", @"contract": @"tangent_normals_plus_y_v1",
                          @"model_file": ns(path.filename().string()), @"weights_sha256": @"unknown",
                          @"normals_sha256": ns(hash(guide.rgba.data(), guide.rgba.size()))} mutableCopy];
    return guide;
}

// An authored data map (any ImageIO format) resampled to size x size without colour management: RGBA8 normals,
// R8 masks, or R16 little-endian height (16-bit sources keep their precision).
std::vector<uint8_t> loadDataMap(const fs::path& path, uint32_t size, DataMap kind, const char* flag) {
    NSData* data = boundedDataAt(path, 256ull * 1024 * 1024);
    if (!data) throw std::runtime_error(std::string("cannot read ") + flag + " file: " + path.string());
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr);
    CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, nullptr) : nullptr;
    if (source) CFRelease(source);
    if (!image) throw std::runtime_error(std::string("cannot decode ") + flag + " image: " + path.string());
    const bool rgba = kind == DataMap::normalRGBA8, sixteen = kind == DataMap::height16;
    const size_t channels = rgba ? 4 : 1, bytes = sixteen ? 2 : 1;
    std::vector<uint8_t> out(static_cast<size_t>(size) * size * channels * bytes);
    CGColorSpaceRef space = rgba ? CGColorSpaceCreateDeviceRGB() : CGColorSpaceCreateDeviceGray();
    const uint32_t info = rgba ? static_cast<uint32_t>(kCGImageAlphaNoneSkipLast) | static_cast<uint32_t>(kCGBitmapByteOrder32Big)
                               : static_cast<uint32_t>(kCGImageAlphaNone) | (sixteen ? static_cast<uint32_t>(kCGBitmapByteOrder16Little) : 0u);
    CGContextRef context = CGBitmapContextCreate(out.data(), size, size, sixteen ? 16 : 8, size * channels * bytes, space,
                                                 static_cast<CGBitmapInfo>(info));
    CGColorSpaceRelease(space);
    if (!context) { CGImageRelease(image); throw std::runtime_error(std::string("cannot allocate the ") + flag + " buffer"); }
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, CGRectMake(0, 0, size, size), image);
    CGContextRelease(context);
    CGImageRelease(image);
    if (rgba) for (size_t i = 3; i < out.size(); i += 4) out[i] = 255;
    return out;
}

// --guide-measured: a scanner's tangent normal map (+Y unless --guide-measured-dx) or depth map (grey, white = near,
// spanning --measured-depth-mm), resampled to the derivation size. Depth is converted to slopes with the tile size.
struct MeasuredGuide { std::vector<uint8_t> rgba; NSMutableDictionary* section = nil; };
MeasuredGuide loadMeasuredGuide(const Options& options, uint32_t size) {
    const fs::path& path = options.measuredGuide;
    NSData* data = boundedDataAt(path, 256ull * 1024 * 1024);
    if (!data) throw std::runtime_error("cannot read --guide-measured file: " + path.string());
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr);
    CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, nullptr) : nullptr;
    if (source) CFRelease(source);
    if (!image) throw std::runtime_error("cannot decode --guide-measured image: " + path.string());
    const bool grey = CGColorSpaceGetModel(CGImageGetColorSpace(image)) == kCGColorSpaceModelMonochrome;
    const size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    CGImageRelease(image);
    if (width != height) throw std::runtime_error("--guide-measured must be square (crop it like the photo)");
    MeasuredGuide out;
    out.section = [@{@"source": @"external_scan", @"file": ns(path.filename().string()), @"sha256": ns(hash(data)),
                     @"kind": grey ? @"depth" : @"normal", @"size_px": @(width)} mutableCopy];
    out.rgba.resize(static_cast<size_t>(size) * size * 4);
    if (grey) {
        if (options.measuredDepthMM <= 0) throw std::runtime_error("a --guide-measured depth map needs --measured-depth-mm (the depth black..white spans)");
        if (options.recipe.tile_metres <= 0) throw std::runtime_error("a --guide-measured depth map needs --tile-metres (the tile's physical width)");
        const auto depth = loadDataMap(path, size, DataMap::height16, "--guide-measured");
        const float span = options.measuredDepthMM / 1000.0f / options.recipe.tile_metres;
        char error[256]{};
        if (!PBRLabMeasuredDepthToGuideNormals(depth.data(), static_cast<size_t>(size) * 2, size, span, out.rgba.data(),
                                               static_cast<size_t>(size) * 4, error, sizeof(error)))
            throw std::runtime_error(std::string("cannot convert the measured depth: ") + error);
        out.section[@"depth_range_mm"] = @(options.measuredDepthMM);
        out.section[@"plane_removed"] = @YES;
    } else {
        out.rgba = loadDataMap(path, size, DataMap::normalRGBA8, "--guide-measured");
        if (options.measuredGuideDX) for (size_t i = 1; i < out.rgba.size(); i += 4) out.rgba[i] = 255 - out.rgba[i];
        out.section[@"normal_convention"] = options.measuredGuideDX ? @"-Y" : @"+Y";
    }
    return out;
}

// ---------------------------------------------------------------------------------------------
// Derivation.
int progressCallback(float, void*) { return gInterrupted ? 0 : 1; }
struct ReviewInfo { bool reviewed = false; bool includedByOptIn = false; };
void deriveOne(const fs::path& inputPath, const fs::path& outputPath, const std::string& id,
               const std::string& label, const Options& options, const ReviewInfo* review = nullptr, bool announce = true) {
    std::error_code ec;
    if (fs::exists(fs::symlink_status(outputPath, ec)))
        throw std::runtime_error("bundle output already exists: " + outputPath.string());
    NSString* labelText = ns(label);
    NSString* idText = ns(id);
    // Read once: the same bytes are hashed for provenance and decoded (or handed to the pre-upscaler).
    NSData* sourceData = boundedDataAt(inputPath, 256ull * 1024 * 1024);
    if (!sourceData) throw std::runtime_error("cannot read input image (missing, linked, or over 256 MiB): " + inputPath.string());
    ScratchDirectory preUpscaleScratch;
    PreUpscaleResult pre;
    // With --resolution the --pre-upscale-exec tool is the resolution upscaler, not a separate pre-pass.
    if (!options.preUpscaleExec.empty() && !options.resolution) pre = runPreUpscale(inputPath, sourceData, options, preUpscaleScratch);
    checkInterrupted();
    Image image = decodeSRGB(pre.processed ?: sourceData);
    if (pre.provenance) pre.provenance[@"output_dimensions_px"] = @[@(image.width), @(image.height)];
    NSMutableDictionary* resolutionProvenance = nil;
    if (options.resolution) image = toResolution(std::move(image), options, preUpscaleScratch, resolutionProvenance);
    const size_t count = static_cast<size_t>(image.width) * image.height;
    // Explicit albedo repair runs first: the repaired albedo is both the exported albedo and the image every
    // derived map and the learned estimator see. The derivation then runs with conditioning switched off.
    const bool repairAlbedo = options.recipe.albedo_repair != 0;
    PBRLabRecipe derivationRecipe = options.recipe;
    PBRLabAlbedoRepairInfo repairInfo{};
    const std::string sourcePixelsHash = hash(image.pixels.data(), image.pixels.size());
    if (repairAlbedo) {
        PBRLabInput plain{};
        plain.rgba8 = image.pixels.data();
        plain.rgba_row_bytes = static_cast<size_t>(image.width) * 4;
        plain.width = image.width;
        plain.height = image.height;
        std::vector<uint8_t> repaired(image.pixels.size());
        char repairError[256]{};
        if (!PBRLabConditionAlbedo(&plain, &options.recipe, repaired.data(), static_cast<size_t>(image.width) * 4,
                                   &repairInfo, repairError, sizeof(repairError)))
            throw std::runtime_error(std::string("albedo repair failed: ") + repairError);
        image.pixels.swap(repaired);
        derivationRecipe.albedo_equalize = 0;
        derivationRecipe.seamless_blend = 0;
        derivationRecipe.albedo_repair = 0;
        checkInterrupted();
    }
    auto mask = options.mask.empty() ? std::vector<uint8_t>{} : rawFile(options.mask, count);
    auto authored = !options.heightMap.empty() ? loadDataMap(options.heightMap, image.width, DataMap::height16, "--height-map")
                  : options.heightOverride.empty() ? std::vector<uint8_t>{} : rawFile(options.heightOverride, count * 2);
    auto authoredNormal = options.normalMap.empty() ? std::vector<uint8_t>{}
                        : loadDataMap(options.normalMap, image.width, DataMap::normalRGBA8, "--normal-map");
    if (options.normalMapDX) for (size_t i = 1; i < authoredNormal.size(); i += 4) authoredNormal[i] = 255 - authoredNormal[i];
    auto authoredRoughness = options.roughnessMap.empty() ? std::vector<uint8_t>{}
                           : loadDataMap(options.roughnessMap, image.width, DataMap::gray8, "--roughness-map");
    auto authoredAO = options.aoMap.empty() ? std::vector<uint8_t>{} : loadDataMap(options.aoMap, image.width, DataMap::gray8, "--ao-map");
    auto authoredMetal = options.metalnessMap.empty() ? std::vector<uint8_t>{}
                       : loadDataMap(options.metalnessMap, image.width, DataMap::gray8, "--metalness-map");
    // The manifest records each authored input file by hash.
    NSMutableDictionary* authoredInputs = [NSMutableDictionary dictionary];
    auto recordAuthored = [&](const char* role, const fs::path& path) {
        if (path.empty()) return;
        NSData* file = boundedDataAt(path, 256ull * 1024 * 1024);
        authoredInputs[@(role)] = @{@"file": ns(path.filename().string()), @"sha256": ns(hash(file))};
    };
    recordAuthored("height", options.heightMap.empty() ? options.heightOverride : options.heightMap);
    recordAuthored("normal", options.normalMap);
    recordAuthored("roughness", options.roughnessMap);
    recordAuthored("ao", options.aoMap);
    recordAuthored("metalness", options.metalnessMap);
    GuideNormals guide;
    // Authored height or normals are the geometry, so the learned estimator is not run.
    const bool useGuide = options.recipe.guide_normal_weight > 0 && authored.empty() && authoredNormal.empty();
    const bool measured = useGuide && !options.measuredGuide.empty();
    NSMutableDictionary* depthSection = nil;
    if (useGuide && (!options.learnedModel.empty() || !measured))
        guide = !options.learnedModel.empty() ? runLearnedNormals(image, options)
                                              : loadGuideNormalsPNG(options.guideNormals, image.width, options.resolution != 0);
    if (measured) {
        // Measured form (as Material Capture does with LiDAR): the scan alone, or its form with the learned detail.
        MeasuredGuide scan = loadMeasuredGuide(options, image.width);
        depthSection = scan.section;
        if (!options.learnedModel.empty()) {
            std::vector<uint8_t> combined(scan.rgba.size());
            if (!PBRLabSplitGuideBands(scan.rgba.data(), guide.rgba.data(), static_cast<size_t>(image.width) * 4, image.width, 0,
                                       combined.data(), static_cast<size_t>(image.width) * 4))
                throw std::runtime_error("cannot combine the measured and learned guides");
            guide.rgba.swap(combined);
            guide.provenance[@"learned_normals_sha256"] = guide.provenance[@"normals_sha256"];
            guide.provenance[@"combination"] = @"measured_form_learned_detail_v1";
            guide.provenance[@"measured_normals_sha256"] = ns(hash(scan.rgba.data(), scan.rgba.size()));
            guide.provenance[@"normals_sha256"] = ns(hash(guide.rgba.data(), guide.rgba.size()));
        } else {
            guide.rgba = std::move(scan.rgba);
            guide.provenance = [@{@"estimator": @"measured_scan", @"contract": @"tangent_normals_plus_y_v1",
                                  @"model_file": ns(options.measuredGuide.filename().string()), @"weights_sha256": @"unknown",
                                  @"normals_sha256": ns(hash(guide.rgba.data(), guide.rgba.size()))} mutableCopy];
        }
    }
    if (useGuide && !options.saveGuideNormals.empty()) {
        PBRLabMap guideMap{guide.rgba.data(), image.width, image.height, static_cast<size_t>(image.width) * 4,
                           guide.rgba.size(), PBRLabPixelFormatRGBA8Linear};
        std::vector<uint8_t> png;
        std::string pngError;
        if (!pbrlab::encodePNG(guideMap, png, pngError) ||
            !pbrlab::writeFileAtomically(options.saveGuideNormals.string(), png, pngError))
            throw std::runtime_error("cannot write --save-guide-normals: " + pngError);
    }
    PBRLabInput input{image.pixels.data(), static_cast<size_t>(image.width) * 4,
                      mask.empty() ? nullptr : mask.data(), mask.empty() ? 0 : image.width,
                      authored.empty() ? nullptr : authored.data(), authored.empty() ? 0 : static_cast<size_t>(image.width) * 2,
                      image.width, image.height, useGuide ? guide.rgba.data() : nullptr,
                      useGuide ? static_cast<size_t>(image.width) * 4 : 0,
                      authoredNormal.empty() ? nullptr : authoredNormal.data(), authoredNormal.empty() ? 0 : static_cast<size_t>(image.width) * 4,
                      authoredRoughness.empty() ? nullptr : authoredRoughness.data(), authoredRoughness.empty() ? 0 : image.width,
                      authoredAO.empty() ? nullptr : authoredAO.data(), authoredAO.empty() ? 0 : image.width,
                      authoredMetal.empty() ? nullptr : authoredMetal.data(), authoredMetal.empty() ? 0 : image.width,
                      measured ? 1u : 0u /* guide_normals_measured: --guide-measured only; learned and external guides are estimates */};
    char error[256]{};
    std::unique_ptr<PBRLabResult, decltype(&PBRLabFreeResult)> result(
        PBRLabDerive(&input, &derivationRecipe, progressCallback, nullptr, error, sizeof(error)), &PBRLabFreeResult);
    checkInterrupted();
    if (!result) throw std::runtime_error(std::string("derivation failed: ") + error);
    if (!outputPath.parent_path().empty()) fs::create_directories(outputPath.parent_path());
    fs::path temp = outputPath;
    temp += ".tmp-" + str([[NSUUID UUID] UUIDString]);
    fs::create_directory(temp);
    try {
        NSMutableDictionary* maps = [NSMutableDictionary dictionary];
        // PNG compression dominates export time; encode every map concurrently, then write in order.
        constexpr size_t roleCount = std::size(kMapRoles);
        std::array<std::vector<uint8_t>, roleCount> encoded;
        std::array<std::string, roleCount> encodeErrors;
        std::array<bool, roleCount> encodedOK{};
        const PBRLabResult* derived = result.get();
        auto* encodedData = encoded.data();
        auto* errorData = encodeErrors.data();
        auto* okData = encodedOK.data();
        dispatch_apply(roleCount, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t k) {
            PBRLabMap map{};
            if (!PBRLabGetMap(derived, kMapRoles[k].kind, &map)) return;
            okData[k] = pbrlab::encodePNG(map, encodedData[k], errorData[k]);
        });
        for (size_t k = 0; k < roleCount; ++k) {
            const auto& role = kMapRoles[k];
            PBRLabMap map{};
            if (!PBRLabGetMap(result.get(), role.kind, &map)) continue;
            NSString* name = @(role.name);
            NSString* filename = [name stringByAppendingString:@".png"];
            const std::vector<uint8_t>& png = encoded[k];
            std::string pngError = encodeErrors[k];
            if (!encodedOK[k] ||
                !pbrlab::writeFileAtomically((temp / str(filename)).string(), png, pngError))
                throw std::runtime_error(pngError);
            NSString* provenance = @(role.provenance);
            if (role.kind == PBRLabMapAlbedo && repairAlbedo) provenance = @"repaired_tileable_albedo_derived_from_source";
            else if (role.kind == PBRLabMapAlbedo && options.authoredAlbedo) provenance = @"authored_albedo";
            if (role.kind == PBRLabMapNormal && !authoredNormal.empty()) provenance = @"authored_normal_map";
            if (role.kind == PBRLabMapRoughness && !authoredRoughness.empty()) provenance = @"authored_roughness_map";
            if (role.kind == PBRLabMapAO && !authoredAO.empty()) provenance = @"authored_ao_map";
            if (role.kind == PBRLabMapORM && (!authoredMetal.empty() || !authoredRoughness.empty() || !authoredAO.empty()))
                provenance = @"authored_and_estimated_channels";
            if (role.kind == PBRLabMapHeight) provenance = !authored.empty() ? @"authored_height_override" :
                !authoredNormal.empty() ? @"integrated_from_authored_normal_map" :
                measured ? (options.recipe.preset == PBRLabPresetFlat ? @"measured_guide"
                                                                      : @"estimated_from_albedo_and_measured_guide") :
                useGuide ? (options.recipe.preset == PBRLabPresetFlat ? @"learned_normals"
                                                                      : @"estimated_from_albedo_and_learned_normals") :
                options.recipe.preset == PBRLabPresetFlat ? @"flat_prior" : @"estimated_from_albedo";
            maps[name] = @{@"file": filename, @"sha256": ns(hash(png.data(), png.size())), @"width": @(map.width),
                           @"height": @(map.height), @"pixel_format": @(role.format), @"provenance": provenance};
        }
        PBRLabSeamMetrics seam = PBRLabGetSeamMetrics(result.get());
        const PBRLabRecipe& r = options.recipe;
        NSMutableDictionary* recipe = [recipeDictionary(r) mutableCopy];
        recipe[@"guide_normal_weight"] = @(useGuide ? r.guide_normal_weight : 0.0f);
        if (!options.materialPreset.empty()) recipe[@"material_preset"] = ns(options.materialPreset);
        NSMutableDictionary* sourceManifest = [@{@"path": ns(inputPath.filename().string()), @"sha256": ns(hash(sourceData)),
                                                @"color_space": @"converted_to_sRGB",
                                                @"source_kind": options.authoredAlbedo ? @"authored_albedo" : @"user_supplied_image"} mutableCopy];
        if (pre.provenance) {
            sourceManifest[@"processed_sha256"] = pre.provenance[@"output_sha256"];
            sourceManifest[@"pre_upscale"] = pre.provenance;
        }
        if (resolutionProvenance) sourceManifest[@"resolution"] = resolutionProvenance;
        NSMutableDictionary* manifest = [@{
            @"schema_version": @1,
            @"bundle_kind": @"pbr-material-bundle",
            @"algorithm_version": ns(PBRLabVersion()),
            @"material_id": idText,
            @"semantic_label": labelText,
            @"source": sourceManifest,
            @"recipe": recipe,
            @"normal_convention": r.normal_y_down ? @"-Y" : @"+Y",
            @"maps": maps,
            @"seam_metrics": @{@"height_value_delta": @(seam.height_value_delta),
                                @"height_gradient_delta": @(seam.height_gradient_delta),
                                @"albedo_value_delta": @(seam.albedo_value_delta)},
            @"runtime_admitted": @NO
        } mutableCopy];
        if (useGuide) manifest[@"guide_normals"] = guide.provenance;
        if (depthSection) {
            const PBRLabDerivationInfo measuredInfo = PBRLabGetDerivationInfo(result.get());
            depthSection[@"measured_form"] = @YES;
            depthSection[@"learned_detail"] = @(!options.learnedModel.empty());
            depthSection[@"measured_form_rms_slope"] = @(measuredInfo.measured_form_rms_slope);
            if (r.tile_metres > 0) depthSection[@"height_span_mm"] = @(measuredInfo.height_span_tile_widths * r.tile_metres * 1000);
            manifest[@"depth"] = depthSection;
        }
        if (authoredInputs.count) manifest[@"authored_inputs"] = authoredInputs;
        if (repairAlbedo) {
            auto seamJSON = [](const PBRLabWrapSeam& seam) {
                return @{@"pixel_x": @(seam.pixel_x), @"pixel_y": @(seam.pixel_y), @"tone_x": @(seam.tone_x),
                         @"tone_y": @(seam.tone_y), @"detail": @(seam.detail)};
            };
            PBRLabMap albedoMap{};
            PBRLabGetMap(result.get(), PBRLabMapAlbedo, &albedoMap);
            manifest[@"albedo_repair"] = @{
                @"mode": @[@"off", @"blend", @"quilt", @"auto"][r.albedo_repair],
                @"method": repairInfo.method == 2 ? @"quilt" : @"blend",
                @"band_fraction": @(repairInfo.band_fraction),
                @"cut_cost_ratio": @(repairInfo.cut_cost_ratio),
                @"offset_px": @[@(repairInfo.offset_x), @(repairInfo.offset_y)],
                @"albedo_equalize": @(r.albedo_equalize),
                @"source_sha256": sourceManifest[@"processed_sha256"] ?: sourceManifest[@"sha256"],
                @"source_rgba8_sha256": ns(sourcePixelsHash),
                @"repaired_rgba8_sha256": ns(hash(albedoMap.pixels, albedoMap.byte_count)),
                @"seam_before": seamJSON(repairInfo.before),
                @"seam_after": seamJSON(repairInfo.after),
                @"seam_measure": @"linear_light_luminance_v1"
            };
        }
        const PBRLabDerivationInfo info = PBRLabGetDerivationInfo(result.get());
        manifest[@"relief"] = @{@"height_span_tile_widths": @(info.height_span_tile_widths),
                                @"rms_slope": @(info.rms_slope),
                                @"learned_form_share": @(info.learned_form_share),
                                @"learned_detail_correlation": @(info.learned_detail_correlation),
                                @"detail_polarity": @(info.detail_polarity),
                                @"height_wrap_seam_ratio": @(info.height_wrap_seam_ratio),
                                @"mid_relief_share_before": @(info.mid_relief_share_before),
                                @"mid_relief_share_after": @(info.mid_relief_share_after),
                                @"roughness_albedo_correlation_before": @(info.roughness_albedo_correlation_before),
                                @"roughness_albedo_correlation_after": @(info.roughness_albedo_correlation_after)};
        if (review) {
            manifest[@"source_review_status"] = review->reviewed ? @"reviewed" : @"unreviewed";
            manifest[@"included_by_opt_in"] = @(review->includedByOptIn);
        }
        NSError* jsonError = nil;
        NSData* json = [NSJSONSerialization dataWithJSONObject:manifest
            options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&jsonError];
        std::string writeError;
        if (!json || !pbrlab::writeFileAtomically((temp / "manifest.json").string(),
                std::vector<uint8_t>(static_cast<const uint8_t*>(json.bytes), static_cast<const uint8_t*>(json.bytes) + json.length), writeError))
            throw std::runtime_error("cannot write material manifest " + writeError);
        checkInterrupted();
        if (fs::exists(fs::symlink_status(outputPath, ec)))
            throw std::runtime_error("bundle output appeared during derivation: " + outputPath.string());
        fs::rename(temp, outputPath);
    } catch (...) { std::error_code ignored; fs::remove_all(temp, ignored); throw; }
    if (announce) { std::lock_guard<std::mutex> lock(gOutputMutex); std::cout << outputPath.string() << '\n'; }
}

// ---------------------------------------------------------------------------------------------
// Bundle validation.
// version: 0 = 1.0.0, 1 = 1.1.0, 2 = 1.2.0, 3 = 1.3.0, 4 = 1.4.0, 5 = 1.5.0. Fields introduced by a version are required from it on.
int algorithmLevel(NSString* algorithm) {
    if ([algorithm isEqualToString:@"1.0.0"]) return 0;
    if ([algorithm isEqualToString:@"1.1.0"]) return 1;
    if ([algorithm isEqualToString:@"1.2.0"]) return 2;
    if ([algorithm isEqualToString:@"1.3.0"]) return 3;
    if ([algorithm isEqualToString:@"1.4.0"]) return 4;
    if ([algorithm isEqualToString:@"1.5.0"]) return 5;
    return -1;
}
bool validateRecipe(NSDictionary* recipe, bool snakeCase, int level, std::string& why) {
    const bool requireV11 = level >= 1;
    auto key = [&](const char* snake, const char* camel) { return snakeCase ? @(snake) : @(camel); };
    NSSet* presets = snakeCase ? [NSSet setWithArray:@[@"flat", @"stone", @"fabric", @"organic", @"coated-metal", @"bare-metal"]]
                               : [NSSet setWithArray:@[@"flat", @"stone", @"fabric", @"organic", @"coatedMetal", @"bareMetal"]];
    NSString* preset = asString(recipe[@"preset"]);
    if (!preset || ![presets containsObject:preset]) { why = "preset"; return false; }
    struct Range { const char* snake; const char* camel; double lo, hi; int since; };
    static constexpr Range ranges[] = {
        {"height_strength", "heightStrength", 0, .5, 0},
        {"roughness_base", "roughnessBase", 0, 1, 0},
        {"roughness_variation", "roughnessVariation", 0, 1, 0},
        {"ao_radius_pixels", "aoRadiusPixels", 0, 64, 0},
        {"normal_strength", "normalStrength", 0, 16, 1},
        {"ao_strength", "aoStrength", 0, 4, 1},
        {"albedo_equalize", "albedoEqualize", 0, 1, 1},
        {"seamless_blend", "seamlessBlend", 0, .45, 1},
        {"guide_normal_weight", "guideNormalWeight", 0, 1, 2},
    };
    for (const auto& range : ranges) {
        id value = recipe[key(range.snake, range.camel)];
        if (level < range.since && !value) continue;
        // Recipes are stored as float32 then widened; allow a single-precision rounding margin at the bounds.
        if (!finiteNumber(value, range.lo - 1e-6, range.hi + 1e-6)) { why = snakeCase ? range.snake : range.camel; return false; }
    }
    if (!unitPolarity(recipe[key("height_polarity", "heightPolarity")])) { why = "height polarity"; return false; }
    // Optional, from 1.5.0 on (absent means the preset default, which is what the apps derive with).
    static constexpr Range v15[] = {
        {"mid_relief_share", "midReliefShare", 0, .8, 5},
        {"tile_metres", "tileMetres", 0, 64, 5},
        {"roughness_albedo_limit", "roughnessAlbedoLimit", 0, 1, 5},
        {"substrate_relief", "substrateRelief", 0, 1, 5},
    };
    for (const auto& range : v15) {
        id value = recipe[key(range.snake, range.camel)];
        if (!value) continue;
        if (level < range.since || !finiteNumber(value, range.lo - 1e-6, range.hi + 1e-6)) { why = snakeCase ? range.snake : range.camel; return false; }
    }
    // Optional: the material-library preset the recipe started from.
    if (id named = recipe[key("material_preset", "materialPreset")]) {
        NSString* text = asString(named);
        if (!text || !PBRLabFindMaterialPreset(text.UTF8String)) { why = "material preset"; return false; }
    }
    // Optional (absent means off); from 1.4.0 on.
    if (id repair = recipe[key("albedo_repair", "albedoRepair")]) {
        NSString* text = asString(repair);
        if (!text || ![@[@"off", @"blend", @"quilt", @"auto"] containsObject:text] || (level < 4 && ![text isEqualToString:@"off"])) {
            why = "albedo repair"; return false;
        }
    }
    // Optional (absent means the pre-cut behaviour, "blend"); when present it must name a known method.
    if (id mode = recipe[key("seamless_mode", "seamlessMode")]) {
        NSString* text = asString(mode);
        if (!text || !([text isEqualToString:@"cut"] || [text isEqualToString:@"blend"])) { why = "seamless mode"; return false; }
    }
    NSArray* flags = snakeCase ? @[@"tile_wrap", @"bent_normal_enabled", @"assigned_metalness_enabled"]
                               : @[@"tileWrap", @"bentNormal"];
    for (NSString* flag in flags) if (!isBoolean(recipe[flag])) { why = str(flag); return false; }
    NSString* yDown = key("normal_y_down", "normalYDown");
    if ((requireV11 || recipe[yDown]) && !isBoolean(recipe[yDown])) { why = str(yDown); return false; }
    if (snakeCase) {
        if (!finiteNumber(recipe[@"assigned_metalness"], 0, 1)) { why = "assigned_metalness"; return false; }
    } else {
        id metal = recipe[@"assignedMetalness"];
        if (metal && metal != [NSNull null] && !finiteNumber(metal, 0, 1)) { why = "assignedMetalness"; return false; }
    }
    return true;
}
constexpr const char* kLegacyNormalWarning =
    "algorithm 1.0.0 normal and bent-normal maps are green-down (-Y, DirectX) despite the recorded +Y claim; "
    "flip green or re-derive with 1.1.0 or later";
void validateMapPNG(NSData* file, const MapRole& role, const std::string& label, uint32_t& width, uint32_t& height) {
    pbrlab::PNGInfo info;
    std::string why;
    if (!pbrlab::inspectPNG(static_cast<const uint8_t*>(file.bytes), file.length, info, why))
        throw std::runtime_error(label + ": " + why);
    const bool r16 = role.kind == PBRLabMapHeight;
    if (info.bitDepth != (r16 ? 16 : 8) || info.colorType != (r16 ? 0 : 6) || info.interlace != 0)
        throw std::runtime_error("PNG channel format does not match map role: " + label);
    if (role.kind == PBRLabMapAlbedo ? info.hasGAMA : info.hasSRGB)
        throw std::runtime_error("PNG colour tagging does not match map role: " + label);
    // Independent full decode through ImageIO as well.
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)file, nullptr);
    CGImageRef image = nullptr;
    if (source && CGImageSourceGetStatus(source) == kCGImageStatusComplete && CGImageSourceGetCount(source) == 1) {
        NSDictionary* options = @{(__bridge NSString*)kCGImageSourceShouldCacheImmediately: @YES};
        image = CGImageSourceCreateImageAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    }
    if (source) CFRelease(source);
    if (!image) throw std::runtime_error("PNG decode failed: " + label);
    const bool matches = CGImageGetWidth(image) == info.width && CGImageGetHeight(image) == info.height &&
                         CGImageGetBitsPerComponent(image) == info.bitDepth;
    CGImageRelease(image);
    if (!matches) throw std::runtime_error("PNG decode disagrees with header: " + label);
    width = info.width; height = info.height;
}
// Composed bundles (docs/BUNDLE_FORMAT.md): exactly one operation section naming verifiable sources.
bool validSourceRecord(id value) {
    NSDictionary* record = asDictionary(value);
    return record && nonemptyString(record[@"path"], 4096) && validSHA256String(record[@"manifest_sha256"]);
}
void validateComposed(NSDictionary* manifest, NSDictionary* source, uint32_t bundleWidth) {
    NSDictionary* layers = asDictionary(manifest[@"layers"]);
    NSDictionary* variant = asDictionary(manifest[@"variant"]);
    NSDictionary* largeTile = asDictionary(manifest[@"large_tile"]);
    const int sections = (manifest[@"layers"] != nil) + (manifest[@"variant"] != nil) + (manifest[@"large_tile"] != nil);
    const bool composed = [asString(source[@"source_kind"]) isEqualToString:@"derived_bundle"];
    if (!sections && !composed) return;
    if (sections != 1 || !composed)
        throw std::runtime_error("a composed bundle needs source_kind \"derived_bundle\" and exactly one of layers, variant, large_tile");
    if (layers) {
        NSDictionary* mask = asDictionary(layers[@"mask"]);
        NSString* type = asString(mask[@"type"]);
        bool ok = validSourceRecord(layers[@"base"]) && validSourceRecord(layers[@"top"]) && mask &&
            [@[@"height", @"slope", @"noise", @"image"] containsObject:type ?: @""] &&
            finiteNumber(mask[@"threshold"], 0, 1) && finiteNumber(mask[@"softness"], 0, .5 + 1e-6) && isBoolean(mask[@"invert"]) &&
            finiteNumber(layers[@"height_blend"], 0, .95 + 1e-6) &&
            [@[@"height", @"reoriented"] containsObject:asString(layers[@"normal_blend"]) ?: @""] &&
            validSHA256String(layers[@"weights_sha256"]) &&
            sameDigest(source[@"sha256"], asDictionary(layers[@"base"])[@"manifest_sha256"]);
        if (ok && [type isEqualToString:@"image"]) ok = nonemptyString(mask[@"file"], 4096) && validSHA256String(mask[@"sha256"]);
        if (ok && [type isEqualToString:@"noise"])
            ok = finiteNumber(mask[@"seed"], 0, 4294967295.0) && finiteNumber(mask[@"scale"], 1, 64) && finiteNumber(mask[@"contrast"], .1 - 1e-6, 8 + 1e-6);
        if (!ok) throw std::runtime_error("layers section (base, top, mask, height blend, normal blend, weights hash) is missing or invalid");
    } else if (variant) {
        NSDictionary* amounts = asDictionary(variant[@"amounts"]);
        NSDictionary* drawn = asDictionary(variant[@"drawn"]);
        NSArray* offset = asArray(drawn[@"offset_px"]);
        bool ok = validSourceRecord(variant[@"source"]) && finiteNumber(variant[@"seed"], 0, 4294967295.0) && amounts && drawn &&
            sameDigest(source[@"sha256"], asDictionary(variant[@"source"])[@"manifest_sha256"]) &&
            finiteNumber(drawn[@"hue_degrees"], -180, 180) && finiteNumber(drawn[@"saturation_scale"], .5 - 1e-6, 1.5 + 1e-6) &&
            finiteNumber(drawn[@"value_scale"], .5 - 1e-6, 1.5 + 1e-6) && finiteNumber(drawn[@"roughness_offset"], -.5 - 1e-6, .5 + 1e-6) &&
            finiteNumber(drawn[@"relief_scale"], .1 - 1e-6, 1.9 + 1e-6) && offset.count == 2 &&
            finiteNumber(offset[0], 0, bundleWidth) && finiteNumber(offset[1], 0, bundleWidth) &&
            finiteNumber(drawn[@"quarter_turns"], 0, 3) && isBoolean(drawn[@"mirrored"]);
        if (!ok) throw std::runtime_error("variant section (source, seed, amounts, drawn shifts) is missing or invalid");
    } else {
        NSNumber* tiles = asNumber(largeTile[@"tiles"]);
        bool ok = largeTile && validSourceRecord(largeTile[@"source"]) && tiles && (tiles.intValue == 2 || tiles.intValue == 4) &&
            sameDigest(source[@"sha256"], asDictionary(largeTile[@"source"])[@"manifest_sha256"]) &&
            finiteNumber(largeTile[@"seed"], 0, 4294967295.0) && finiteNumber(largeTile[@"patch"], .125 - 1e-6, 1 + 1e-6) &&
            finiteNumber(largeTile[@"sharpness"], 1 - 1e-6, 16 + 1e-6) &&
            exactNumber(largeTile[@"source_size_px"], static_cast<double>(bundleWidth / std::max(1, tiles.intValue))) &&
            bundleWidth % static_cast<uint32_t>(std::max(1, tiles.intValue)) == 0;
        if (!ok) throw std::runtime_error("large_tile section (source, tiles, seed, patch, sharpness, source size) is missing or invalid");
    }
}
void validate(const fs::path& bundle, bool quiet = false) {
    const fs::path manifestPath = bundle / "manifest.json";
    NSData* data = boundedDataAt(manifestPath, 4 * 1024 * 1024);
    if (!fs::is_directory(bundle) || !data) throw std::runtime_error("bundle manifest missing, linked, or oversized");
    NSError* jsonError = nil;
    NSDictionary* manifest = asDictionary([NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError]);
    if (!manifest) throw std::runtime_error("manifest root must be a JSON object");
    NSDictionary* maps = asDictionary(manifest[@"maps"]);
    NSDictionary* recipe = asDictionary(manifest[@"recipe"]);
    NSDictionary* source = asDictionary(manifest[@"source"]);
    NSDictionary* seamMetrics = asDictionary(manifest[@"seam_metrics"]);
    NSString* algorithm = asString(manifest[@"algorithm_version"]);
    if (!exactNumber(manifest[@"schema_version"], 1) ||
        ![asString(manifest[@"bundle_kind"]) isEqualToString:@"pbr-material-bundle"] ||
        !maps || !recipe || !source || !seamMetrics || !algorithm ||
        !nonemptyString(manifest[@"material_id"], 240) || !nonemptyString(manifest[@"semantic_label"], 1000))
        throw std::runtime_error("invalid material bundle manifest");
    // Admission is a separate explicit step: the flag must be literally JSON false.
    if (!isBoolean(manifest[@"runtime_admitted"]) || [manifest[@"runtime_admitted"] boolValue])
        throw std::runtime_error("runtime_admitted must be the boolean false");
    const int level = algorithmLevel(algorithm);
    if (level < 0) throw std::runtime_error("unsupported algorithm_version: " + str(algorithm));
    const bool legacy = level == 0;
    std::string why;
    if (!validateRecipe(recipe, true, level, why))
        throw std::runtime_error("manifest recipe parameter missing or out of range: " + why);
    id convention = manifest[@"normal_convention"];
    if (!legacy || convention) {
        NSString* expected = [recipe[@"normal_y_down"] boolValue] ? @"-Y" : @"+Y";
        if (![asString(convention) isEqualToString:expected])
            throw std::runtime_error("normal_convention must be \"+Y\" or \"-Y\" and agree with recipe.normal_y_down");
    }
    if (legacy) warn(kLegacyNormalWarning);
    NSNumber* guideWeight = asNumber(recipe[@"guide_normal_weight"]);
    NSDictionary* guideNormals = asDictionary(manifest[@"guide_normals"]);
    if (guideWeight && guideWeight.doubleValue > 0) {
        if (!guideNormals || !nonemptyString(guideNormals[@"estimator"], 120) ||
            ![asString(guideNormals[@"contract"]) isEqualToString:@"tangent_normals_plus_y_v1"] ||
            !validSHA256String(guideNormals[@"normals_sha256"]) || !nonemptyString(guideNormals[@"model_file"], 255))
            throw std::runtime_error("guide_normal_weight > 0 requires guide_normals provenance with estimator, contract and hashes");
    } else if (manifest[@"guide_normals"]) throw std::runtime_error("guide_normals present but recipe.guide_normal_weight is 0");
    // CLI 1.4.0 --guide-measured: an external scan behind the guide (the iPhone's LiDAR section has source "lidar").
    NSDictionary* depth = asDictionary(manifest[@"depth"]);
    if (depth && [asString(depth[@"source"]) isEqualToString:@"external_scan"]) {
        NSString* kind = asString(depth[@"kind"]);
        if (!guideNormals || !nonemptyString(depth[@"file"], 4096) || !validSHA256String(depth[@"sha256"]) ||
            !([kind isEqualToString:@"normal"] || ([kind isEqualToString:@"depth"] && finiteNumber(depth[@"depth_range_mm"], 1e-6, 10000))) ||
            ![depth[@"measured_form"] isEqual:@YES] || !finiteNumber(depth[@"measured_form_rms_slope"], 0, 1e4))
            throw std::runtime_error("depth (external scan) needs guide normals, the scan's file and hash, its kind and depth range");
    }
    if (!validSHA256String(source[@"sha256"]) || !nonemptyString(source[@"color_space"], 120) ||
        !nonemptyString(source[@"path"], 4096))
        throw std::runtime_error("manifest source identity or hash is invalid");
    for (NSString* key in @[@"height_value_delta", @"height_gradient_delta", @"albedo_value_delta"])
        if (!finiteNumber(seamMetrics[key], 0, 2)) throw std::runtime_error("manifest seam metrics are missing or invalid");
    // 1.4.0: a repaired albedo is derived data; its provenance, hashes and seam measures must be recorded.
    NSString* repairMode = asString(recipe[@"albedo_repair"]);
    const bool repaired = repairMode && ![repairMode isEqualToString:@"off"];
    NSDictionary* repair = asDictionary(manifest[@"albedo_repair"]);
    if (repaired) {
        auto seamValid = [](id value) {
            NSDictionary* seam = asDictionary(value);
            if (!seam) return false;
            for (NSString* k in @[@"pixel_x", @"pixel_y", @"tone_x", @"tone_y", @"detail"])
                if (!finiteNumber(seam[k], 0, 1e6)) return false;
            return true;
        };
        NSArray* offsets = [repair[@"offset_px"] isKindOfClass:[NSArray class]] ? repair[@"offset_px"] : nil;
        NSString* method = asString(repair[@"method"]);
        NSString* expectedSource = asString(source[@"processed_sha256"]) ?: asString(source[@"sha256"]);
        if (!repair || ![asString(repair[@"mode"]) isEqualToString:repairMode] ||
            !(([method isEqualToString:@"quilt"] && ![repairMode isEqualToString:@"blend"]) ||
              ([method isEqualToString:@"blend"] && ![repairMode isEqualToString:@"quilt"])) ||
            !finiteNumber(repair[@"band_fraction"], 1e-6, .45 + 1e-6) || !finiteNumber(repair[@"cut_cost_ratio"], 0, 1e6) ||
            offsets.count != 2 || !finiteNumber(offsets[0], 0, 4096) || !finiteNumber(offsets[1], 0, 4096) ||
            !sameDigest(repair[@"source_sha256"], expectedSource) ||
            !validSHA256String(repair[@"source_rgba8_sha256"]) || !validSHA256String(repair[@"repaired_rgba8_sha256"]) ||
            !seamValid(repair[@"seam_before"]) || !seamValid(repair[@"seam_after"]) ||
            ![asString(asDictionary(maps[@"albedo"])[@"provenance"]) isEqualToString:@"repaired_tileable_albedo_derived_from_source"])
            throw std::runtime_error("albedo_repair requires mode, method, band, offsets, source and repaired hashes, seam measures and repaired albedo provenance");
    } else if (manifest[@"albedo_repair"]) throw std::runtime_error("albedo_repair present but recipe.albedo_repair is off");
    // 1.3.0: estimated height is range-normalized, so the depth it spans must be recorded.
    NSDictionary* relief = asDictionary(manifest[@"relief"]);
    if (level >= 3 || manifest[@"relief"]) {
        if (!relief || !finiteNumber(relief[@"height_span_tile_widths"], 0, 64) || !finiteNumber(relief[@"rms_slope"], 0, 1e4) ||
            !finiteNumber(relief[@"learned_form_share"], 0, 1 + 1e-6) || !finiteNumber(relief[@"learned_detail_correlation"], -1 - 1e-6, 1 + 1e-6) ||
            !unitPolarity(relief[@"detail_polarity"]) || !finiteNumber(relief[@"height_wrap_seam_ratio"], 0, 1e6))
            throw std::runtime_error("manifest relief (height span, slope, learned share/correlation, detail polarity) is missing or invalid");
        // 1.5.0 (optional; the CLI and the Mac app record them): the mid-scale relief share and the roughness/albedo
        // correlation, before and after their corrections. Recorded all together or not at all.
        NSArray* v15Relief = @[@"mid_relief_share_before", @"mid_relief_share_after", @"roughness_albedo_correlation_before", @"roughness_albedo_correlation_after"];
        NSUInteger present = 0;
        for (NSString* name in v15Relief) present += relief[name] != nil;
        if (present && (level < 5 || present != v15Relief.count || !finiteNumber(relief[@"mid_relief_share_before"], 0, 1 + 1e-6) ||
                        !finiteNumber(relief[@"mid_relief_share_after"], 0, 1 + 1e-6) ||
                        !finiteNumber(relief[@"roughness_albedo_correlation_before"], -1 - 1e-6, 1 + 1e-6) ||
                        !finiteNumber(relief[@"roughness_albedo_correlation_after"], -1 - 1e-6, 1 + 1e-6)))
            throw std::runtime_error("manifest relief 1.5.0 fields (mid-relief share, roughness/albedo correlation) are incomplete or invalid");
    }
    id reviewStatus = manifest[@"source_review_status"];
    if (reviewStatus && ![asString(reviewStatus) isEqualToString:@"reviewed"] && ![asString(reviewStatus) isEqualToString:@"unreviewed"] &&
        !(legacy && asString(reviewStatus)))
        throw std::runtime_error("source_review_status must be \"reviewed\" or \"unreviewed\"");
    if (manifest[@"included_by_opt_in"] && !isBoolean(manifest[@"included_by_opt_in"]))
        throw std::runtime_error("included_by_opt_in must be boolean");

    // Maps: exactly the known roles, all nine required ones, and optional ones iff their recipe flag.
    for (id name in maps)
        if (!asString(name) || !roleNamed(name)) throw std::runtime_error("unknown map role: " + str(asString(name)));
    const bool wantORM = [recipe[@"assigned_metalness_enabled"] boolValue];
    const bool wantBent = [recipe[@"bent_normal_enabled"] boolValue];
    uint32_t bundleWidth = 0, bundleHeight = 0;
    for (size_t index = 0; index < kMapRoles.size(); ++index) {
        const MapRole& role = kMapRoles[index];
        NSString* name = @(role.name);
        const bool expected = index < kRequiredMapCount ||
            (role.kind == PBRLabMapORM && wantORM) || (role.kind == PBRLabMapBentNormal && wantBent);
        id raw = maps[name];
        if (!expected) {
            if (raw) throw std::runtime_error("map present without its recipe flag: " + str(name));
            continue;
        }
        NSDictionary* record = asDictionary(raw);
        if (!record) throw std::runtime_error("required map missing: " + str(name));
        NSString* filename = asString(record[@"file"]);
        if (!validSHA256String(record[@"sha256"]) || !asNumber(record[@"width"]) || !asNumber(record[@"height"]) ||
            !asString(record[@"pixel_format"]) || !nonemptyString(record[@"provenance"], 240) || !filename)
            throw std::runtime_error("malformed map record: " + str(name));
        if (![filename isEqualToString:[name stringByAppendingString:@".png"]])
            throw std::runtime_error("map file must be named " + str(name) + ".png");
        if (![record[@"pixel_format"] isEqualToString:@(role.format)])
            throw std::runtime_error("map pixel_format does not match its role: " + str(name));
        NSData* file = boundedDataAt(bundle / str(filename), 512ull * 1024 * 1024);
        if (!file) throw std::runtime_error("map file missing, linked, or oversized: " + str(filename));
        if (!sameDigest(ns(hash(file)), record[@"sha256"])) throw std::runtime_error("map SHA-256 mismatch: " + str(filename));
        uint32_t width = 0, height = 0;
        validateMapPNG(file, role, str(filename), width, height);
        if (width != [record[@"width"] doubleValue] || height != [record[@"height"] doubleValue])
            throw std::runtime_error("PNG dimensions do not match manifest: " + str(filename));
        if (width < 2 || width > 8192 || height != width ||
            (bundleWidth && (width != bundleWidth || height != bundleHeight)))
            throw std::runtime_error("map dimensions are inconsistent or out of range");
        bundleWidth = width; bundleHeight = height;
    }

    NSString* sourceHash = source[@"sha256"];
    id preValue = source[@"pre_upscale"];
    if (preValue) {
        NSDictionary* pre = asDictionary(preValue);
        if (!pre) throw std::runtime_error("pre-upscale provenance must be an object");
        NSString* inputHash = pre[@"input_sha256"];
        NSString* outputHash = pre[@"output_sha256"];
        NSArray* templates = asArray(pre[@"arguments_template"]);
        NSArray* files = asArray(pre[@"local_argument_files"]);
        bool wellFormed = [asString(pre[@"mode"]) isEqualToString:@"external_local_argv_process"] &&
            nonemptyString(pre[@"executable"], 4096) && validSHA256String(pre[@"executable_sha256"]) &&
            templates && files && sameDigest(inputHash, sourceHash) && sameDigest(source[@"processed_sha256"], outputHash);
        for (id item in templates) wellFormed = wellFormed && asString(item);
        for (id item in files) {
            NSDictionary* entry = asDictionary(item);
            wellFormed = wellFormed && entry && asString(entry[@"path"]) && validSHA256String(entry[@"sha256"]);
        }
        if (!wellFormed) throw std::runtime_error("pre-upscale source or processed hash mismatch");
        NSArray* dimensions = asArray(pre[@"output_dimensions_px"]);
        if (dimensions.count != 2 || !exactNumber(dimensions[0], bundleWidth) || !exactNumber(dimensions[1], bundleHeight))
            throw std::runtime_error("pre-upscale output dimensions do not match exported maps");
        id receiptValue = pre[@"receipt"];
        id receiptHash = pre[@"receipt_sha256"];
        id receiptText = pre[@"receipt_json_base64"];
        if (receiptValue || receiptHash || receiptText) {
            if (!asDictionary(receiptValue) || !validSHA256String(receiptHash) ||
                !asString(receiptText) || [receiptText length] > 1400000)
                throw std::runtime_error("pre-upscale receipt proof is incomplete");
            NSData* receiptBytes = [[NSData alloc] initWithBase64EncodedString:receiptText options:0];
            if (!receiptBytes || !receiptBytes.length || receiptBytes.length > 1024 * 1024 ||
                ![[NSString alloc] initWithData:receiptBytes encoding:NSUTF8StringEncoding] ||
                !sameDigest(ns(hash(receiptBytes)), receiptHash))
                throw std::runtime_error("pre-upscale receipt SHA-256 mismatch");
            NSError* receiptError = nil;
            NSDictionary* parsed = asDictionary([NSJSONSerialization JSONObjectWithData:receiptBytes options:0 error:&receiptError]);
            if (!parsed || ![parsed isEqualToDictionary:receiptValue])
                throw std::runtime_error("pre-upscale receipt bytes do not match embedded object");
            if (!sameDigest(parsed[@"sourceSHA256"], inputHash) || !sameDigest(parsed[@"outputSHA256"], outputHash))
                throw std::runtime_error("pre-upscale receipt source/output hashes disagree");
            id receiptSize = parsed[@"outputSize"];
            if (receiptSize && (asArray(receiptSize).count != 2 || !exactNumber(receiptSize[0], bundleWidth) ||
                                !exactNumber(receiptSize[1], bundleHeight)))
                throw std::runtime_error("pre-upscale receipt output dimensions disagree");
        }
    } else if (source[@"processed_sha256"]) {
        throw std::runtime_error("processed source hash has no pre-upscale provenance");
    }
    // CLI 1.4.0 --resolution: upscaler passes (each hashed), then an optional resample to the exported size.
    if (id resolutionValue = source[@"resolution"]) {
        NSDictionary* resolution = asDictionary(resolutionValue);
        NSArray* passes = asArray(resolution[@"passes"]);
        NSString* upscaler = asString(resolution[@"upscaler"]);
        bool ok = resolution && !preValue && passes && passes.count <= 3 &&
            (exactNumber(resolution[@"target_px"], 4096) || exactNumber(resolution[@"target_px"], 8192)) &&
            exactNumber(resolution[@"target_px"], bundleWidth) && finiteNumber(resolution[@"source_px"], 2, 8192) &&
            [@[@"none", @"pinned_realesrgan", @"custom"] containsObject:upscaler ?: @""] &&
            ([upscaler isEqualToString:@"none"] == (passes.count == 0)) &&
            [@[@"none", @"vimage_high_quality_lanczos"] containsObject:asString(resolution[@"resample"]) ?: @""] &&
            validSHA256String(resolution[@"processed_rgba8_sha256"]);
        // Each pass reads a fresh (wrap-padded) PNG of the previous result, so passes are hashed one by one.
        for (id item in passes) {
            NSDictionary* pass = asDictionary(item);
            NSArray* templates = asArray(pass[@"arguments_template"]);
            NSArray* dimensions = asArray(pass[@"output_dimensions_px"]);
            ok = ok && pass && nonemptyString(pass[@"executable"], 4096) && validSHA256String(pass[@"executable_sha256"]) &&
                templates && validSHA256String(pass[@"input_sha256"]) && validSHA256String(pass[@"output_sha256"]) &&
                (exactNumber(pass[@"scale"], 2) || exactNumber(pass[@"scale"], 4)) && dimensions.count == 2 &&
                finiteNumber(dimensions[0], 2, 8192) && finiteNumber(dimensions[1], 2, 8192);
            if (ok && pass[@"receipt"]) {
                NSDictionary* receipt = asDictionary(pass[@"receipt"]);
                ok = receipt && sameDigest(receipt[@"sourceSHA256"], pass[@"input_sha256"]) &&
                     sameDigest(receipt[@"outputSHA256"], pass[@"output_sha256"]);
            }
        }
        if (!ok) throw std::runtime_error("source.resolution (target, upscaler passes and hashes, resample) is missing or invalid");
    }
    validateComposed(manifest, source, bundleWidth);
    if (!quiet) std::cout << "valid: " << bundle.string() << " (" << maps.count << " maps)\n";
}

// ---------------------------------------------------------------------------------------------
// Capture validation.
bool hasLocationKey(id value) {
    if (NSDictionary* dictionary = asDictionary(value)) {
        for (id key in dictionary) {
            NSString* lower = [asString(key) lowercaseString];
            if ([lower containsString:@"gps"] || [lower containsString:@"location"] ||
                [lower containsString:@"latitude"] || [lower containsString:@"longitude"]) return true;
            if (hasLocationKey(dictionary[key])) return true;
        }
    } else if (NSArray* array = asArray(value)) {
        for (id item in array) if (hasLocationKey(item)) return true;
    }
    return false;
}
void verifyDigest(NSData* bytes, id expected, const std::string& label) {
    if (!bytes || !sameDigest(ns(hash(bytes)), expected)) throw std::runtime_error(label + " SHA-256 mismatch");
}
NSData* decodeBase64(id value) {
    NSString* text = asString(value);
    return text ? [[NSData alloc] initWithBase64EncodedString:text options:0] : nil;
}
struct DecodedSize { uint32_t width, height; int bits; };
DecodedSize inspectEncoded(NSData* bytes, const std::string& label, uint32_t maxSide, bool square, id mimeValue) {
    NSString* mime = asString(mimeValue);
    if (!bytes || !bytes.length || bytes.length > 64 * 1024 * 1024)
        throw std::runtime_error(label + " encoded image is missing or oversized");
    auto* p = static_cast<const uint8_t*>(bytes.bytes);
    if ([mime isEqualToString:@"image/png"]) {
        constexpr uint8_t signature[8] = {137,80,78,71,13,10,26,10};
        if (bytes.length < 33 || std::memcmp(p, signature, 8) || std::memcmp(p + 12, "IHDR", 4))
            throw std::runtime_error(label + " is not PNG");
    } else if (!([mime isEqualToString:@"image/jpeg"] || [mime isEqualToString:@"image/heic"]))
        throw std::runtime_error(label + " has unsupported MIME type");
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)bytes, nullptr);
    if (!source || CGImageSourceGetStatus(source) != kCGImageStatusComplete || CGImageSourceGetCount(source) != 1) {
        if (source) CFRelease(source);
        throw std::runtime_error(label + " image decode failed");
    }
    CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr);
    bool metadataHasLocation = properties && hasLocationKey((__bridge id)properties);
    if (properties) CFRelease(properties);
    if (metadataHasLocation) { CFRelease(source); throw std::runtime_error(label + " contains embedded location metadata"); }
    NSDictionary* options = @{(__bridge NSString*)kCGImageSourceShouldCacheImmediately: @YES};
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!image) throw std::runtime_error(label + " image decode failed");
    DecodedSize result{static_cast<uint32_t>(CGImageGetWidth(image)), static_cast<uint32_t>(CGImageGetHeight(image)),
                       static_cast<int>(CGImageGetBitsPerComponent(image))};
    CGImageRelease(image);
    if (result.width < 2 || result.height < 2 || result.width > maxSide || result.height > maxSide ||
        (square && result.width != result.height))
        throw std::runtime_error(label + " dimensions are out of range");
    return result;
}
void validateCapture(const fs::path& capturePath) {
    NSData* file = boundedDataAt(capturePath, 64ull * 1024 * 1024);
    if (!file || !file.length) throw std::runtime_error("capture envelope missing, linked, or larger than 64 MiB");
    NSError* jsonError = nil;
    NSDictionary* capture = asDictionary([NSJSONSerialization JSONObjectWithData:file options:0 error:&jsonError]);
    NSString* algorithm = asString(capture[@"algorithmVersion"]);
    NSDictionary* recipe = asDictionary(capture[@"recipe"]);
    NSDictionary* captureMetadata = asDictionary(capture[@"capture"]);
    NSDictionary* seamMetrics = asDictionary(capture[@"seamMetrics"]);
    NSDictionary* derived = asDictionary(capture[@"derived"]);
    if (!capture || !exactNumber(capture[@"schemaVersion"], 1) ||
        ![asString(capture[@"bundleKind"]) isEqualToString:@"pbr-capture"] ||
        !isBoolean(capture[@"runtimeAdmitted"]) || [capture[@"runtimeAdmitted"] boolValue] ||
        !asString(capture[@"captureId"]) || ![[NSUUID alloc] initWithUUIDString:capture[@"captureId"]] ||
        !nonemptyString(capture[@"semanticLabel"], 240) || !nonemptyString(capture[@"category"], 240) ||
        ![asString(capture[@"sourceMime"]) isEqualToString:@"image/png"] || !asString(capture[@"sourceBase64"]) ||
        !algorithm || !recipe || !captureMetadata || !derived || !seamMetrics)
        throw std::runtime_error("invalid capture envelope fields");
    const int level = algorithmLevel(algorithm);
    if (level < 0) throw std::runtime_error("unsupported capture algorithmVersion: " + str(algorithm));
    const bool legacy = level == 0;
    std::string why;
    if (!validateRecipe(recipe, false, level, why))
        throw std::runtime_error("capture recipe is missing or out of range: " + why);
    if (legacy) warn(kLegacyNormalWarning);
    if (!nonemptyString(captureMetadata[@"capturedAt"], 80) ||
        !nonemptyString(captureMetadata[@"orientation"], 120) ||
        !nonemptyString(captureMetadata[@"colorProfile"], 120) ||
        !nonemptyString(captureMetadata[@"captureMode"], 120) ||
        !asDictionary(captureMetadata[@"crop"]) || !asDictionary(captureMetadata[@"imageQuality"]) ||
        !isBoolean(captureMetadata[@"fallbackUsed"]) ||
        (captureMetadata[@"constantColorCenterConfidence"] &&
         captureMetadata[@"constantColorCenterConfidence"] != [NSNull null] &&
         !finiteNumber(captureMetadata[@"constantColorCenterConfidence"], 0, 1)))
        throw std::runtime_error("capture metadata is missing or invalid");
    for (NSString* key in @[@"heightValueDelta", @"heightGradientDelta", @"albedoValueDelta"])
        if (!finiteNumber(seamMetrics[key], 0, 2))
            throw std::runtime_error("capture seam metrics are missing or invalid");
    if (hasLocationKey(capture)) throw std::runtime_error("capture contains GPS or location metadata");
    NSData* source = decodeBase64(capture[@"sourceBase64"]);
    verifyDigest(source, capture[@"sourceSHA256"], "source");
    DecodedSize sourceSize = inspectEncoded(source, "source", 4096, true, @"image/png");
    auto verifyEmbeddedPhoto = [&](NSString* prefix) {
        bool present = false;
        for (NSString* suffix in @[@"Mime", @"Base64", @"SHA256", @"Width", @"Height"]) {
            id value = captureMetadata[[prefix stringByAppendingString:suffix]];
            if (value && value != [NSNull null]) present = true;
        }
        if (!present) return;
        id mime = captureMetadata[[prefix stringByAppendingString:@"Mime"]];
        NSNumber* width = asNumber(captureMetadata[[prefix stringByAppendingString:@"Width"]]);
        NSNumber* height = asNumber(captureMetadata[[prefix stringByAppendingString:@"Height"]]);
        NSData* photo = decodeBase64(captureMetadata[[prefix stringByAppendingString:@"Base64"]]);
        if (!asString(mime) || !photo || !width || !height)
            throw std::runtime_error(str(prefix) + " embedded photo fields are incomplete");
        verifyDigest(photo, captureMetadata[[prefix stringByAppendingString:@"SHA256"]], str(prefix));
        auto size = inspectEncoded(photo, str(prefix), 8192, false, mime);
        if (size.width != width.doubleValue || size.height != height.doubleValue ||
            static_cast<uint64_t>(size.width) * size.height > 50000000)
            throw std::runtime_error(str(prefix) + " embedded photo dimensions mismatch");
    };
    verifyEmbeddedPhoto(@"original");
    verifyEmbeddedPhoto(@"fallbackOriginal");
    for (size_t index = 0; index < kRequiredMapCount; ++index)
        if (!asDictionary(derived[@(kMapRoles[index].name)]))
            throw std::runtime_error("required capture map missing: " + std::string(kMapRoles[index].name));
    for (id kindValue in derived) {
        NSString* kind = asString(kindValue);
        const MapRole* role = kind ? roleNamed(kind) : nullptr;
        NSDictionary* record = asDictionary(derived[kindValue]);
        if (!role || !record || ![asString(record[@"mime"]) isEqualToString:@"image/png"] ||
            !asNumber(record[@"width"]) || !asNumber(record[@"height"]) ||
            !asString(record[@"pixelFormat"]) || !asString(record[@"provenance"]))
            throw std::runtime_error("invalid derived map record: " + str(kind));
        NSData* bytes = decodeBase64(record[@"base64"]);
        verifyDigest(bytes, record[@"sha256"], str(kind));
        auto size = inspectEncoded(bytes, str(kind), 4096, true, @"image/png");
        if (size.width != sourceSize.width || size.height != sourceSize.height ||
            size.width != [record[@"width"] doubleValue] || size.height != [record[@"height"] doubleValue])
            throw std::runtime_error("derived map dimensions mismatch: " + str(kind));
        pbrlab::PNGInfo info;
        std::string pngWhy;
        const bool r16 = role->kind == PBRLabMapHeight;
        if (![record[@"pixelFormat"] isEqualToString:@(role->format)] ||
            !pbrlab::inspectPNG(static_cast<const uint8_t*>(bytes.bytes), bytes.length, info, pngWhy) ||
            info.bitDepth != (r16 ? 16 : 8) || info.colorType != (r16 ? 0 : 6))
            throw std::runtime_error("derived map pixel format mismatch: " + str(kind) + (pngWhy.empty() ? "" : " (" + pngWhy + ")"));
    }
    std::cout << "valid capture: " << capturePath.string() << " (" << derived.count << " derived maps)\n";
}

// ---------------------------------------------------------------------------------------------
// Catalog batch.
bool isWithin(const fs::path& child, const fs::path& parent) {
    auto c = child.begin(), p = parent.begin();
    for (; p != parent.end(); ++p, ++c) if (c == child.end() || *c != *p) return false;
    return true;
}
fs::path resolveCatalogPath(const fs::path& catalogDir, NSString* relative) {
    fs::path rel = str(relative);
    if (rel.empty() || rel.is_absolute() || rel.has_root_name()) throw std::runtime_error("unsafe catalog relative path: " + rel.string());
    fs::path walk = catalogDir;
    for (const auto& component : rel) {
        if (component == ".." ) throw std::runtime_error("unsafe catalog relative path: " + rel.string());
        if (component.empty() || component == ".") continue;
        walk /= component;
        if (fs::is_symlink(walk)) throw std::runtime_error("catalog path contains a symbolic link: " + rel.string());
    }
    std::error_code ec;
    fs::path canonical = fs::canonical(walk, ec);
    if (ec) throw std::runtime_error("catalog source not found: " + rel.string());
    if (!isWithin(canonical, catalogDir) || canonical == catalogDir)
        throw std::runtime_error("catalog path escapes the catalog directory: " + rel.string());
    return canonical;
}
struct BatchItem { fs::path source, output; std::string id, label; ReviewInfo review; };
struct ItemResult { bool attempted = false, ok = false; double seconds = 0; std::string error; std::vector<std::string> exports; };

// Follow-on exports beside the bundle: <stem>.glb / <stem>.usdz, or a <stem>-<format> folder.
std::vector<std::string> alsoExport(const fs::path& bundle, const Options& options) {
    std::vector<std::string> written;
    for (const auto& format : options.alsoExport) {
        const std::string stem = bundle.stem().string();
        const fs::path target = bundle.parent_path() /
            (format == "glb" || format == "usdz" ? stem + "." + format : stem + "-" + format);
        mltools::exportBundle(bundle, format, target, false);
        written.push_back(target.string());
    }
    return written;
}

// --variant / --large-tile: derive (unless the input is already a bundle) into a hidden stage beside the output, then
// apply the variant and the larger tile in that order; only the final bundle remains.
void composeItem(const fs::path& source, const fs::path& output, const std::string& id, const std::string& label,
                 const Options& options, const ReviewInfo* review) {
    std::error_code ec;
    if (fs::exists(fs::symlink_status(output, ec))) throw std::runtime_error("bundle output already exists: " + output.string());
    if (!output.parent_path().empty()) fs::create_directories(output.parent_path());
    std::vector<fs::path> stages;
    auto stage = [&]() {
        fs::path path = output.parent_path() / ("." + output.stem().string() + ".stage-" + str([[NSUUID UUID] UUIDString]) + ".pbrmaterial");
        stages.push_back(path);
        return path;
    };
    try {
        fs::path current = source;
        if (fs::is_directory(source)) validate(source, true);
        else { current = stage(); deriveOne(source, current, id, label, options, review, false); }
        // The explicit --label/--id name the final bundle; otherwise each operation names its result.
        const std::string finalLabel = options.label, finalID = options.id.empty() ? std::string() : sanitized(options.id);
        if (options.variantSeed) {
            PBRLabVariantParams params = PBRLabDefaultVariantParams(*options.variantSeed);
            params.hue_degrees = std::min(180.0f, params.hue_degrees * options.variantStrength);
            params.saturation = std::min(.5f, params.saturation * options.variantStrength);
            params.value = std::min(.5f, params.value * options.variantStrength);
            params.roughness = std::min(.5f, params.roughness * options.variantStrength);
            params.relief = std::min(.9f, params.relief * options.variantStrength);
            params.rotation = options.variantRotate ? 1 : 0;
            const fs::path next = options.largeTile ? stage() : output;
            mltools::variantBundle(current, params, next, options.largeTile ? std::string() : finalLabel,
                                   options.largeTile ? std::string() : finalID);
            current = next;
        }
        if (options.largeTile) {
            PBRLabLargeTileParams params = PBRLabDefaultLargeTileParams(options.largeTile, options.largeTileSeed);
            params.patch = options.largeTilePatch;
            mltools::largeTileBundle(current, params, output, finalLabel, finalID);
        }
        validate(output, true);
    } catch (...) {
        for (const auto& path : stages) { std::error_code ignored; fs::remove_all(path, ignored); }
        throw;
    }
    for (const auto& path : stages) { std::error_code ignored; fs::remove_all(path, ignored); }
    { std::lock_guard<std::mutex> lock(gOutputMutex); std::cout << output.string() << '\n'; }
}

ItemResult processItem(const fs::path& source, const fs::path& output, const std::string& id, const std::string& label,
                       const Options& options, const ReviewInfo* review) {
    ItemResult result;
    result.attempted = true;
    const auto started = std::chrono::steady_clock::now();
    try {
        @autoreleasepool {
            if (options.composes()) composeItem(source, output, id, label, options, review);
            else deriveOne(source, output, id, label, options, review);
            result.exports = alsoExport(output, options);
        }
        result.ok = true;
    } catch (const Interrupted&) {
        throw;
    } catch (const std::exception& e) {
        result.error = e.what();
    }
    result.seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count();
    return result;
}

void writeReport(const fs::path& path, const std::vector<BatchItem>& items, const std::vector<ItemResult>& results) {
    NSMutableArray* rows = [NSMutableArray array];
    for (size_t i = 0; i < items.size() && i < results.size(); ++i) {
        const auto& r = results[i];
        NSMutableDictionary* row = [@{@"id": ns(items[i].id), @"source": ns(items[i].source.string()),
                                      @"output": ns(items[i].output.string()),
                                      @"status": !r.attempted ? @"not_attempted" : r.ok ? @"derived" : @"failed",
                                      @"seconds": @(std::round(r.seconds * 1000) / 1000)} mutableCopy];
        if (!r.error.empty()) row[@"error"] = ns(r.error);
        if (!r.exports.empty()) {
            NSMutableArray* exports = [NSMutableArray array];
            for (const auto& e : r.exports) [exports addObject:ns(e)];
            row[@"exports"] = exports;
        }
        [rows addObject:row];
    }
    NSDictionary* report = @{@"tool": @"material-lab", @"algorithm_version": ns(PBRLabVersion()), @"items": rows};
    NSData* data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    std::string error;
    if (!pbrlab::writeFileAtomically(path.string(),
            std::vector<uint8_t>(static_cast<const uint8_t*>(data.bytes), static_cast<const uint8_t*>(data.bytes) + data.length), error))
        throw std::runtime_error("cannot write report: " + error);
}
int batch(const Options& options) {
    NSData* data = boundedDataAt(options.catalog, 64ull * 1024 * 1024);
    if (!data) throw std::runtime_error("cannot read catalog");
    NSError* error = nil;
    NSDictionary* catalog = asDictionary([NSJSONSerialization JSONObjectWithData:data options:0 error:&error]);
    if (!catalog) throw std::runtime_error("catalog root must be an object");
    NSArray* materials = asArray(catalog[@"items"]) ?: asArray(catalog[@"materials"]) ?: asArray(catalog[@"assets"]);
    if (!materials) throw std::runtime_error("catalog has no items, materials, or assets array");
    const fs::path catalogDir = fs::canonical(fs::absolute(options.catalog).parent_path());
    // Plan every item (paths, IDs, labels) before any expensive work, so duplicates fail fast.
    std::vector<BatchItem> plan;
    std::set<std::string> ids;
    size_t skipped = 0;
    for (id value in materials) {
        NSDictionary* material = asDictionary(value);
        if (!material) throw std::runtime_error("invalid catalog record");
        NSString* status = asString(material[@"review_status"]);
        const bool reviewed = (isBoolean(material[@"reviewed"]) && [material[@"reviewed"] boolValue]) ||
            [status isEqualToString:@"approved"] || [status isEqualToString:@"reviewed"];
        if (!reviewed && !options.includeUnreviewed) { ++skipped; continue; }
        NSString* relative = asString(material[@"path"]) ?: asString(material[@"relative_path"]);
        if (!relative) throw std::runtime_error("catalog entry missing string path");
        id identityValue = material[@"id"];
        if (identityValue && !asString(identityValue)) throw std::runtime_error("catalog id must be a string");
        BatchItem item;
        item.source = resolveCatalogPath(catalogDir, relative);
        item.id = sanitized(identityValue ? str(identityValue) : fs::path(str(relative)).stem().string());
        if (!ids.insert(item.id).second) throw std::runtime_error("duplicate material ID: " + item.id);
        NSString* label = asString(material[@"label"]) ?: asString(material[@"material_label"]);
        item.label = label.length ? str(label) : item.id;
        item.output = options.output / (item.id + ".pbrmaterial");
        item.review = {reviewed, !reviewed};
        plan.push_back(item);
    }
    if (plan.empty()) throw std::runtime_error("no reviewed materials in catalog; use --include-unreviewed to opt in to candidates");
    fs::create_directories(options.output);
    // Items run on `jobs` workers (derivation itself is multi-threaded, so a few jobs mostly overlap I/O,
    // decoding and PNG encoding). Learned inference is serialized; the first failure stops new work unless
    // --keep-going.
    std::vector<ItemResult> results(plan.size());
    std::atomic<size_t> next{0};
    std::atomic<bool> stop{false};
    std::mutex outputMutex;
    auto worker = [&] {
        for (size_t i; !stop && !gInterrupted && (i = next.fetch_add(1)) < plan.size();) {
            const auto& item = plan[i];
            results[i] = processItem(item.source, item.output, item.id, item.label, options, &item.review);
            if (!results[i].ok) {
                std::lock_guard<std::mutex> lock(outputMutex);
                std::cerr << "material-lab: " << item.id << ": " << results[i].error << '\n';
                if (!options.keepGoing) stop = true;
            }
        }
    };
    std::vector<std::thread> threads;
    for (int t = 1; t < std::min<int>(options.jobs, static_cast<int>(plan.size())); ++t) threads.emplace_back(worker);
    worker();
    for (auto& thread : threads) thread.join();
    checkInterrupted();
    size_t made = 0, failed = 0, notAttempted = 0;
    for (size_t i = 0; i < plan.size(); ++i) {
        if (results[i].attempted) (results[i].ok ? made : failed)++;
        else ++notAttempted;
    }
    if (!options.report.empty()) writeReport(options.report, plan, results);
    if (failed && !options.keepGoing)
        std::cerr << "material-lab: stopping; derived " << made << ", failed " << failed << ", not attempted "
                  << notAttempted << " (use --keep-going to continue)\n";
    std::cout << "derived " << made << " material bundles";
    if (failed) std::cout << ", " << failed << " failed";
    if (skipped) std::cout << ", " << skipped << " unreviewed skipped";
    std::cout << '\n';
    return failed ? 1 : 0;
}

// --watch: derive every new image dropped into a folder, until interrupted. A file is taken once its size
// has been stable for two polls; images that already have a bundle in --output are skipped.
int watchFolder(const Options& options) {
    if (!fs::is_directory(options.watch)) throw std::runtime_error("--watch needs a folder: " + options.watch.string());
    fs::create_directories(options.output);
    static const std::set<std::string> extensions = {".png", ".jpg", ".jpeg", ".tif", ".tiff", ".heic", ".webp"};
    std::map<fs::path, uintmax_t> sizes;
    std::set<fs::path> done;
    std::vector<BatchItem> items;
    std::vector<ItemResult> results;
    std::cout << "watching " << options.watch.string() << " (Ctrl-C to stop)" << std::endl;
    while (!gInterrupted) {
        std::error_code ec;
        for (const auto& entry : fs::directory_iterator(options.watch, ec)) {
            if (gInterrupted) break;
            const fs::path path = entry.path();
            std::string ext = path.extension().string();
            std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
            if (!entry.is_regular_file(ec) || !extensions.count(ext) || done.count(path) ||
                path.filename().string().starts_with(".")) continue;
            const std::string id = sanitized(path.stem().string());
            const fs::path output = options.output / (id + ".pbrmaterial");
            if (fs::exists(fs::symlink_status(output, ec))) { done.insert(path); continue; }
            const uintmax_t size = entry.file_size(ec);
            auto seen = sizes.find(path);
            if (seen == sizes.end() || seen->second != size || size == 0) { sizes[path] = size; continue; }
            done.insert(path);
            BatchItem item{path, output, id, id, {}};
            items.push_back(item);
            results.push_back(processItem(path, output, id, id, options, nullptr));
            if (!results.back().ok) std::cerr << "material-lab: " << id << ": " << results.back().error << '\n';
            if (!options.report.empty()) writeReport(options.report, items, results);
        }
        for (int tick = 0; tick < 20 && !gInterrupted; ++tick) usleep(100000);
    }
    std::cout << "stopped watching; derived " << std::count_if(results.begin(), results.end(), [](const ItemResult& r) { return r.ok; })
              << " of " << results.size() << '\n';
    return 0;
}

// material-lab layer --base A --top B --mask height|slope|noise|FILE [params] --output OUT
int layerCommand(int argc, const char** argv) {
    fs::path base, top, output, maskFile;
    std::string maskName, label, id;
    PBRLabLayerParams params = PBRLabDefaultLayerParams(PBRLabLayerMaskHeight);
    std::vector<std::function<void(PBRLabLayerParams&)>> overrides;
    for (int i = 2; i < argc; ++i) {
        const std::string flag = argv[i];
        auto value = [&]() -> std::string { if (++i >= argc) throw std::runtime_error("missing value for " + flag); return argv[i]; };
        auto field = [&](float PBRLabLayerParams::*target) { const float n = number(value()); overrides.push_back([=](PBRLabLayerParams& p) { p.*target = n; }); };
        if (flag == "--base") base = value();
        else if (flag == "--top") top = value();
        else if (flag == "--output") output = value();
        else if (flag == "--label") label = value();
        else if (flag == "--id") id = value();
        else if (flag == "--mask") maskName = value();
        else if (flag == "--threshold") field(&PBRLabLayerParams::threshold);
        else if (flag == "--softness") field(&PBRLabLayerParams::softness);
        else if (flag == "--scale") field(&PBRLabLayerParams::noise_scale);
        else if (flag == "--contrast") field(&PBRLabLayerParams::noise_contrast);
        else if (flag == "--height-blend") field(&PBRLabLayerParams::height_blend);
        else if (flag == "--invert") overrides.push_back([](PBRLabLayerParams& p) { p.invert = 1; });
        else if (flag == "--seed") {
            const float n = number(value());
            if (n < 0 || n > 4294967295.0f || n != std::floor(n)) throw std::runtime_error("--seed must be a whole number 0..4294967295");
            overrides.push_back([=](PBRLabLayerParams& p) { p.seed = static_cast<uint32_t>(n); });
        }
        else if (flag == "--normal-blend") {
            const std::string mode = value();
            if (mode != "height" && mode != "reoriented") throw std::runtime_error("--normal-blend must be height or reoriented");
            overrides.push_back([=](PBRLabLayerParams& p) { p.normal_blend = mode == "reoriented" ? 1 : 0; });
        }
        else if (flag == "--help") { std::cout << kUsage; return 0; }
        else throw std::runtime_error("unknown layer option: " + flag);
    }
    if (base.empty() || top.empty() || output.empty() || maskName.empty())
        throw std::runtime_error("layer needs --base, --top, --mask and --output");
    // The mask defaults (threshold, softness) depend on its kind; explicit flags then override them.
    if (maskName == "height") params = PBRLabDefaultLayerParams(PBRLabLayerMaskHeight);
    else if (maskName == "slope") params = PBRLabDefaultLayerParams(PBRLabLayerMaskSlope);
    else if (maskName == "noise") params = PBRLabDefaultLayerParams(PBRLabLayerMaskNoise);
    else {
        maskFile = maskName;
        if (!fs::is_regular_file(maskFile)) throw std::runtime_error("--mask must be height, slope, noise or an image file: " + maskName);
        params = PBRLabDefaultLayerParams(PBRLabLayerMaskImage);
    }
    for (auto& apply : overrides) apply(params);
    for (const auto& bundle : {base, top}) {
        if (!fs::is_directory(bundle)) throw std::runtime_error("not a .pbrmaterial bundle: " + bundle.string());
        validate(bundle, true);
    }
    if (output.extension() != ".pbrmaterial") output += ".pbrmaterial";
    mltools::layerBundles(base, top, params, maskFile, output, label, id.empty() ? std::string() : sanitized(id));
    validate(output, true);
    std::cout << output.string() << '\n';
    return 0;
}

int run(int argc, const char** argv) {
    if (argc >= 2 && std::string(argv[1]) == "layer") return layerCommand(argc, argv);
    Options options = parse(argc, argv);
    if (options.listFormats) {
        // The apps' table (PBRLabExport.h) must name exactly the exporter's formats, in order.
        const auto& formats = mltools::exportFormats();
        if (PBRLabExportFormatCount() != formats.size()) throw std::runtime_error("export format table is out of date");
        NSMutableArray* list = [NSMutableArray array];
        for (uint32_t i = 0; i < PBRLabExportFormatCount(); ++i) {
            const PBRLabExportFormat* f = PBRLabExportFormatAt(i);
            if (formats[i] != f->identifier) throw std::runtime_error("export format table is out of date");
            if (options.json) {
                [list addObject:@{@"identifier": @(f->identifier), @"title": @(f->title), @"detail": @(f->detail),
                                  @"output": f->file_extension ? @(f->file_extension) : @"folder"}];
            } else {
                char line[256];
                snprintf(line, sizeof line, "  %-17s %s\n", f->identifier, f->detail);
                std::cout << line;
            }
        }
        if (options.json) {
            NSData* data = [NSJSONSerialization dataWithJSONObject:list options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
            std::cout << std::string(static_cast<const char*>(data.bytes), data.length) << '\n';
        }
        return 0;
    }
    if (options.listPresets) {
        if (options.json) {
            NSMutableArray* list = [NSMutableArray array];
            for (uint32_t i = 0; i < PBRLabMaterialPresetCount(); ++i) {
                const PBRLabMaterialPreset* p = PBRLabMaterialPresetAt(i);
                [list addObject:@{@"identifier": @(p->identifier), @"title": @(p->title), @"category": @(p->category),
                                  @"recipe": recipeDictionary(p->recipe)}];
            }
            NSData* data = [NSJSONSerialization dataWithJSONObject:list options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
            std::cout << std::string(static_cast<const char*>(data.bytes), data.length) << '\n';
            return 0;
        }
        std::string category;
        for (uint32_t i = 0; i < PBRLabMaterialPresetCount(); ++i) {
            const PBRLabMaterialPreset* p = PBRLabMaterialPresetAt(i);
            if (category != p->category) {
                category = p->category;
                std::cout << (i ? "\n" : "") << category << '\n';
            }
            char line[160];
            snprintf(line, sizeof line, "  %-20s %-24s %s, roughness %.2f%s\n", p->identifier, p->title,
                     presetName(p->recipe.preset).c_str(), p->recipe.roughness_base,
                     p->recipe.assigned_metalness_enabled ? (", metalness " + std::to_string(p->recipe.assigned_metalness).substr(0, 4)).c_str() : "");
            std::cout << line;
        }
        std::cout << "\nRelief priors: flat, stone, fabric, organic, coated-metal, bare-metal\n";
        return 0;
    }
    if (options.usesTool()) {
        // Tools trust the bundle layout, so every bundle passes the full validator first.
        auto checked = [](const fs::path& bundle) {
            if (!fs::is_directory(bundle)) throw std::runtime_error("not a .pbrmaterial bundle: " + bundle.string());
            validate(bundle, true);
            return bundle;
        };
        if (!options.infoBundle.empty()) return mltools::info(checked(options.infoBundle), options.json);
        if (!options.contactSheetBundle.empty())
            return mltools::contactSheet(checked(options.contactSheetBundle), options.output);
        if (!options.previewBundle.empty()) return mltools::preview(checked(options.previewBundle), options.output);
        if (!options.diffBundles.empty())
            return mltools::diff(checked(options.diffBundles[0]), checked(options.diffBundles[1]), options.json);
        return mltools::exportBundle(checked(options.exportBundle), options.exportFormat, options.output);
    }
    if (!options.validate.empty()) {
        if (fs::is_directory(options.validate)) validate(options.validate);
        else validateCapture(options.validate);
        return 0;
    }
    if (!options.saveRecipe.empty()) {
        NSMutableDictionary* saved = [recipeDictionary(options.recipe) mutableCopy];
        if (!options.materialPreset.empty()) saved[@"material_preset"] = ns(options.materialPreset);
        NSData* data = [NSJSONSerialization dataWithJSONObject:saved
                                                       options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
        std::string error;
        if (!pbrlab::writeFileAtomically(options.saveRecipe.string(),
                std::vector<uint8_t>(static_cast<const uint8_t*>(data.bytes), static_cast<const uint8_t*>(data.bytes) + data.length), error))
            throw std::runtime_error("cannot write recipe: " + error);
        if (options.input.empty() && options.catalog.empty() && options.watch.empty()) {
            std::cout << options.saveRecipe.string() << '\n';
            return 0;
        }
    }
    if (!options.catalog.empty()) return batch(options);
    if (!options.watch.empty()) return watchFolder(options);
    std::string id = options.id.empty() ? sanitized(options.input.stem().string()) : sanitized(options.id);
    std::string label = options.label.empty() ? id : options.label;
    fs::path destination = options.output;
    if (destination.extension() != ".pbrmaterial") destination += ".pbrmaterial";
    const ItemResult result = processItem(options.input, destination, id, label, options, nullptr);
    if (!options.report.empty()) writeReport(options.report, {BatchItem{options.input, destination, id, label, {}}}, {result});
    if (!result.ok) throw std::runtime_error(result.error);
    for (const auto& exported : result.exports) std::cout << exported << '\n';
    return 0;
}
// One CLI run inside the MCP server: output captured, every failure turned into an exit code.
int runCaptured(const char* argv0, const std::vector<std::string>& arguments, std::string& out, std::string& err) {
    std::vector<const char*> argv{argv0};
    for (const auto& argument : arguments) argv.push_back(argument.c_str());
    std::ostringstream capturedOut, capturedErr;
    std::streambuf* savedOut = std::cout.rdbuf(capturedOut.rdbuf());
    std::streambuf* savedErr = std::cerr.rdbuf(capturedErr.rdbuf());
    int code = 1;
    @autoreleasepool {
        @try {
            try {
                code = run(static_cast<int>(argv.size()), argv.data());
            } catch (const std::exception& e) {
                std::cerr << "material-lab: " << e.what() << '\n';
            }
        } @catch (NSException* exception) {
            std::cerr << "material-lab: internal error: " << str(exception.name) << ": " << str(exception.reason) << '\n';
        }
    }
    std::cout.rdbuf(savedOut);
    std::cerr.rdbuf(savedErr);
    out = capturedOut.str();
    err = capturedErr.str();
    return code;
}

// material-lab mcp [--root DIR]...
int serveMCP(int argc, const char** argv) {
    std::vector<std::string> roots;
    for (int i = 2; i < argc; ++i) {
        const std::string flag = argv[i];
        if (flag == "--root" && i + 1 < argc) roots.emplace_back(argv[++i]);
        else throw std::runtime_error("usage: material-lab mcp [--root DIR]...");
    }
    const char* argv0 = argv[0];
    return mlmcp::serve(roots, [argv0](const std::vector<std::string>& arguments, std::string& out, std::string& err) {
        return runCaptured(argv0, arguments, out, err);
    }, kCLIVersion);
}
} // namespace

int main(int argc, const char** argv) {
    if (argc >= 2 && std::string(argv[1]) == "mcp") {
        // No signal handlers: an interrupt ends the server.
        @autoreleasepool {
            try {
                return serveMCP(argc, argv);
            } catch (const std::exception& e) {
                std::cerr << "material-lab: " << e.what() << '\n';
                return 1;
            }
        }
    }
    installSignalHandlers();
    @autoreleasepool {
        @try {
            try {
                return run(argc, argv);
            } catch (const Interrupted& e) {
                std::cerr << "material-lab: " << e.what() << '\n';
                return 128 + static_cast<int>(gInterrupted ? gInterrupted : SIGINT);
            } catch (const std::exception& e) {
                std::cerr << "material-lab: " << e.what() << '\n';
                return 1;
            }
        } @catch (NSException* exception) {
            std::cerr << "material-lab: internal error: " << str(exception.name) << ": " << str(exception.reason) << '\n';
            return 1;
        }
    }
}
