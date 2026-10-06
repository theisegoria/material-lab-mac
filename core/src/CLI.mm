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
Image decodeSRGB(NSData* bytes) {
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
    if (w < 2 || w > 4096 || h != w) {
        CGImageRelease(image); throw std::runtime_error("input must be square and 2..4096 pixels");
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
    bool learnedCpuOnly = false, guideWeightSet = false;
    bool includeUnreviewed = false, keepGoing = false;
    double preUpscaleTimeout = 600;
    // Bundle tools (src/tools): each takes validated bundles.
    fs::path infoBundle, contactSheetBundle, exportBundle;
    std::vector<fs::path> diffBundles;
    std::string exportFormat;
    bool json = false, listPresets = false;
    // Pipeline.
    fs::path recipeFile, saveRecipe, report, watch;
    std::string savedRecipe;
    // A material-library preset (PBRLabFindMaterialPreset) the recipe started from; recorded in manifests.
    std::string materialPreset;
    std::vector<std::string> alsoExport;
    int jobs = 1;
    bool usesTool() const { return !infoBundle.empty() || !contactSheetBundle.empty() || !exportBundle.empty() || !diffBundles.empty(); }
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
    float n = 0;
    try { n = std::stof(s, &parsed); } catch (const std::exception&) { throw std::runtime_error("invalid number: " + s); }
    if (parsed != s.size() || !std::isfinite(n)) throw std::runtime_error("invalid number: " + s);
    return n;
}
constexpr const char* kCLIVersion = "1.0.1";

// --learned: the model shipped beside the binary (<prefix>/share/material-lab), the one the Mac app installs,
// or MATERIAL_LAB_MODEL. Returns an empty path when none is found.
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
    "Recipes and pipelines:\n"
    "  --recipe FILE|BUNDLE  start from a recipe JSON (snake_case or the apps' camelCase) or a bundle's recipe\n"
    "  --saved-recipe NAME  use a recipe saved in the Material Lab Mac app   --save-recipe FILE  write the recipe\n"
    "  --also-export FORMAT,...  export beside each derived bundle (formats as for --export)\n"
    "  --jobs 1..8  parallel catalog items   --report FILE.json  per-item status   --keep-going\n"
    "  --watch DIR --output DIR  derive every image dropped into DIR until interrupted\n"
    "Bundle tools (each validates its bundles first):\n"
    "  --info BUNDLE [--json]   --contact-sheet BUNDLE --output SHEET.png   --diff BUNDLE_A BUNDLE_B [--json]\n"
    "  --export BUNDLE --format FORMAT --output PATH   FORMAT: glb, usdz, materialx, unreal, unity (URP/Built-in),\n"
    "    unity-hdrp, godot, blender, substance, roblox, minecraft-labpbr\n"
    "Learned geometry (see man material-lab):\n"
    "  --learned  use the bundled MoGe-2 model (or the Material Lab app's)   --version\n"
    "  --learned-normals MODEL.mlpackage|.mlmodelc  run a local Core ML tangent-normal estimator (MoGe-2)\n"
    "  --guide-normals PNG  use precomputed +Y tangent normals instead  --guide-weight 0..1 (default 1)\n"
    "  --learned-cpu-only  run the estimator on CPU for more reproducible output\n"
    "  --save-guide-normals PNG  also write the guide normals fed to the core (reusable with --guide-normals)\n"
    "Optional local pre-upscale: --pre-upscale-exec ABSOLUTE_EXECUTABLE --pre-upscale-arg ARG (repeat; include\n"
    "  {input} and {output} placeholders) [--pre-upscale-timeout SECONDS, default 600]. No shell or network is\n"
    "  invoked by Material Lab.\n";
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
// The recipe as written into bundle manifests and by --save-recipe (snake_case).
NSDictionary* recipeDictionary(const PBRLabRecipe& r) {
    return @{
        @"preset": ns(presetName(r.preset)),
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
        @"seamless_mode": r.seamless_mode == 1 ? @"cut" : @"blend",
        @"albedo_repair": @[@"off", @"blend", @"quilt", @"auto"][r.albedo_repair]
    };
}
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
        else if (flag == "--learned-cpu-only") o.learnedCpuOnly = true;
        else if (flag == "--save-guide-normals") o.saveGuideNormals = value();
        else if (flag == "--guide-weight") { recipeNumber(&PBRLabRecipe::guide_normal_weight); o.guideWeightSet = true; }
        else if (flag == "--relief-mask-r8") o.mask = value();
        else if (flag == "--height-override-r16le") o.heightOverride = value();
        else if (flag == "--include-unreviewed") o.includeUnreviewed = true;
        else if (flag == "--keep-going") o.keepGoing = true;
        else if (flag == "--pre-upscale-exec") o.preUpscaleExec = value();
        else if (flag == "--pre-upscale-arg") o.preUpscaleArgs.push_back(value());
        else if (flag == "--pre-upscale-timeout") {
            o.preUpscaleTimeout = number(value());
            if (o.preUpscaleTimeout <= 0 || o.preUpscaleTimeout > 86400) throw std::runtime_error("--pre-upscale-timeout must be 0..86400 seconds");
        }
        else if (flag == "--info") o.infoBundle = value();
        else if (flag == "--contact-sheet") o.contactSheetBundle = value();
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
        else if (flag == "--help") { std::cout << kUsage; std::exit(0); }
        else throw std::runtime_error("unknown option: " + flag);
    }
    if (!o.recipeFile.empty() && !o.savedRecipe.empty()) throw std::runtime_error("use either --recipe or --saved-recipe");
    const bool recipeSource = !o.recipeFile.empty() || !o.savedRecipe.empty();
    if (recipeSource && preset) throw std::runtime_error("--preset cannot be combined with a recipe file (the recipe names its preset)");
    o.recipe = !o.recipeFile.empty() ? loadRecipeFile(o.recipeFile, &o.materialPreset)
             : !o.savedRecipe.empty() ? loadSavedRecipe(o.savedRecipe, &o.materialPreset)
             : preset.value_or(PBRLabDefaultRecipe(PBRLabPresetFlat));
    const bool hasGuide = !o.learnedModel.empty() || !o.guideNormals.empty();
    if (!o.learnedModel.empty() && !o.guideNormals.empty())
        throw std::runtime_error("use either --learned-normals or --guide-normals, not both");
    // A guide defaults to full weight, unless a recipe file already chose one.
    if (hasGuide && !(recipeSource && o.recipe.guide_normal_weight > 0)) o.recipe.guide_normal_weight = 1.0f;
    for (auto& apply : overrides) apply(o.recipe);
    if (o.recipe.guide_normal_weight > 0 && !hasGuide)
        throw std::runtime_error(recipeSource && !o.guideWeightSet
            ? "the recipe uses learned geometry: add --learned-normals MODEL (or --guide-normals PNG), or --guide-weight 0"
            : "--guide-weight needs --learned-normals or --guide-normals");
    if (o.recipe.albedo_repair != 0 && o.recipe.tile_wrap == 0)
        throw std::runtime_error("--repair-albedo makes a tileable albedo; it cannot be combined with --no-tile");
    if (!o.saveGuideNormals.empty() && (o.learnedModel.empty() || !o.catalog.empty()))
        throw std::runtime_error("--save-guide-normals needs --learned-normals and a single --input");
    if (o.listPresets) {
        // Lists and exits; no other options apply.
    } else if (o.usesTool()) {
        const int tools = !o.infoBundle.empty() + !o.contactSheetBundle.empty() + !o.exportBundle.empty() + !o.diffBundles.empty();
        if (tools != 1 || !o.input.empty() || !o.catalog.empty() || !o.validate.empty())
            throw std::runtime_error("use one of --info, --contact-sheet, --diff or --export at a time, without derive options");
        if (!o.contactSheetBundle.empty() && o.output.empty()) throw std::runtime_error("--contact-sheet needs --output SHEET.png");
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
std::string substitute(const std::string& value, const std::string& input, const std::string& output) {
    std::string out;
    for (size_t i = 0; i < value.size();) { // Single pass: substituted text is never rescanned.
        if (value.compare(i, 7, "{input}") == 0) { out += input; i += 7; }
        else if (value.compare(i, 8, "{output}") == 0) { out += output; i += 8; }
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
PreUpscaleResult runPreUpscale(const fs::path& inputPath, NSData* original, const Options& options,
                               ScratchDirectory& scratch) {
    scratch.path = fs::temp_directory_path() / ("material-lab-pre-upscale-" + str([[NSUUID UUID] UUIDString]));
    fs::create_directory(scratch.path);
    const fs::path input = fs::absolute(inputPath);
    const fs::path output = scratch.path / "upscaled.png";
    std::vector<std::string> arguments{options.preUpscaleExec.string()};
    NSMutableArray* templates = [NSMutableArray array];
    NSMutableArray* localFileHashes = [NSMutableArray array];
    for (const auto& arg : options.preUpscaleArgs) {
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
        arguments.push_back(substitute(arg, input.string(), output.string()));
    }
    NSData* tool = dataAt(options.preUpscaleExec);
    if (!tool) throw std::runtime_error("cannot hash pre-upscale executable");
    int status = runChild(options.preUpscaleExec, arguments, options.preUpscaleTimeout);
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
        @"executable": ns(options.preUpscaleExec.filename().string()),
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
GuideNormals runLearnedNormals(const Image& image, const Options& options) {
    std::lock_guard<std::mutex> lock(gLearnedMutex);
    const int n = static_cast<int>(image.width);
    LoadedModel& loaded = learnedModel(options.learnedModel, options.learnedCpuOnly);
    std::unique_ptr<PBRLabGuideTiler, decltype(&PBRLabGuideTilerFree)> tiler(
        PBRLabGuideTilerCreate(image.pixels.data(), static_cast<size_t>(n) * 4, image.width, options.recipe.tile_wrap),
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
GuideNormals loadGuideNormalsPNG(const fs::path& path, uint32_t size) {
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

// ---------------------------------------------------------------------------------------------
// Derivation.
int progressCallback(float, void*) { return gInterrupted ? 0 : 1; }
struct ReviewInfo { bool reviewed = false; bool includedByOptIn = false; };
void deriveOne(const fs::path& inputPath, const fs::path& outputPath, const std::string& id,
               const std::string& label, const Options& options, const ReviewInfo* review = nullptr) {
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
    if (!options.preUpscaleExec.empty()) pre = runPreUpscale(inputPath, sourceData, options, preUpscaleScratch);
    checkInterrupted();
    Image image = decodeSRGB(pre.processed ?: sourceData);
    if (pre.provenance) pre.provenance[@"output_dimensions_px"] = @[@(image.width), @(image.height)];
    const size_t count = static_cast<size_t>(image.width) * image.height;
    // Explicit albedo repair runs first: the repaired albedo is both the exported albedo and the image every
    // derived map and the learned estimator see. The derivation then runs with conditioning switched off.
    const bool repairAlbedo = options.recipe.albedo_repair != 0;
    PBRLabRecipe derivationRecipe = options.recipe;
    PBRLabAlbedoRepairInfo repairInfo{};
    const std::string sourcePixelsHash = hash(image.pixels.data(), image.pixels.size());
    if (repairAlbedo) {
        PBRLabInput plain{image.pixels.data(), static_cast<size_t>(image.width) * 4, nullptr, 0, nullptr, 0,
                          image.width, image.height, nullptr, 0};
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
    auto authored = options.heightOverride.empty() ? std::vector<uint8_t>{} : rawFile(options.heightOverride, count * 2);
    GuideNormals guide;
    const bool useGuide = options.recipe.guide_normal_weight > 0 && authored.empty();
    if (useGuide) guide = !options.learnedModel.empty() ? runLearnedNormals(image, options)
                                                       : loadGuideNormalsPNG(options.guideNormals, image.width);
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
                      useGuide ? static_cast<size_t>(image.width) * 4 : 0};
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
            if (role.kind == PBRLabMapHeight) provenance = !authored.empty() ? @"authored_height_override" :
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
                                                @"color_space": @"converted_to_sRGB", @"source_kind": @"user_supplied_image"} mutableCopy];
        if (pre.provenance) {
            sourceManifest[@"processed_sha256"] = pre.provenance[@"output_sha256"];
            sourceManifest[@"pre_upscale"] = pre.provenance;
        }
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
                                @"height_wrap_seam_ratio": @(info.height_wrap_seam_ratio)};
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
    { std::lock_guard<std::mutex> lock(gOutputMutex); std::cout << outputPath.string() << '\n'; }
}

// ---------------------------------------------------------------------------------------------
// Bundle validation.
// version: 0 = 1.0.0, 1 = 1.1.0, 2 = 1.2.0, 3 = 1.3.0, 4 = 1.4.0. Fields introduced by a version are required from it on.
int algorithmLevel(NSString* algorithm) {
    if ([algorithm isEqualToString:@"1.0.0"]) return 0;
    if ([algorithm isEqualToString:@"1.1.0"]) return 1;
    if ([algorithm isEqualToString:@"1.2.0"]) return 2;
    if ([algorithm isEqualToString:@"1.3.0"]) return 3;
    if ([algorithm isEqualToString:@"1.4.0"]) return 4;
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
        NSData* file = boundedDataAt(bundle / str(filename), 128ull * 1024 * 1024);
        if (!file) throw std::runtime_error("map file missing, linked, or oversized: " + str(filename));
        if (!sameDigest(ns(hash(file)), record[@"sha256"])) throw std::runtime_error("map SHA-256 mismatch: " + str(filename));
        uint32_t width = 0, height = 0;
        validateMapPNG(file, role, str(filename), width, height);
        if (width != [record[@"width"] doubleValue] || height != [record[@"height"] doubleValue])
            throw std::runtime_error("PNG dimensions do not match manifest: " + str(filename));
        if (width < 2 || width > 4096 || height != width ||
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

ItemResult processItem(const fs::path& source, const fs::path& output, const std::string& id, const std::string& label,
                       const Options& options, const ReviewInfo* review) {
    ItemResult result;
    result.attempted = true;
    const auto started = std::chrono::steady_clock::now();
    try {
        @autoreleasepool {
            deriveOne(source, output, id, label, options, review);
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

int run(int argc, const char** argv) {
    Options options = parse(argc, argv);
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
} // namespace

int main(int argc, const char** argv) {
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
