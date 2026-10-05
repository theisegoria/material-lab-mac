#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#include "Tools.hpp"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <iomanip>
#include <iostream>
#include <map>
#include <sstream>
#include <stdexcept>

namespace mltools {
namespace {

const char* const kMapOrder[] = {"albedo", "height", "normal", "roughness", "ao", "cavity", "convexity", "slope",
                                 "edge", "bent_normal", "orm"};

NSDictionary* loadManifest(const fs::path& bundle) {
    const auto bytes = readFile(bundle / "manifest.json");
    NSData* data = [NSData dataWithBytes:bytes.data() length:bytes.size()];
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![root isKindOfClass:[NSDictionary class]]) throw std::runtime_error("manifest is not a JSON object");
    return root;
}
NSDictionary* dict(id value) { return [value isKindOfClass:[NSDictionary class]] ? value : nil; }
std::string text(id value, const char* fallback = "") {
    if ([value isKindOfClass:[NSString class]]) return [(NSString*)value UTF8String];
    if ([value isKindOfClass:[NSNumber class]]) {
        if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return [(NSNumber*)value boolValue] ? "true" : "false";
        return [[(NSNumber*)value stringValue] UTF8String];
    }
    return fallback;
}
double number(id value, double fallback = 0) {
    return [value isKindOfClass:[NSNumber class]] ? [(NSNumber*)value doubleValue] : fallback;
}
bool flag(id value) { return [value isKindOfClass:[NSNumber class]] && [(NSNumber*)value boolValue]; }
std::string fixed(double value, int digits) {
    std::ostringstream out;
    out << std::fixed << std::setprecision(digits) << value;
    return out.str();
}
std::string shortHash(id value) { std::string h = text(value); return h.size() > 12 ? h.substr(0, 12) + "…" : h; }

std::string recipeSummary(NSDictionary* r) {
    std::ostringstream out;
    out << text(r[@"preset"], "?") << " · height " << fixed(number(r[@"height_strength"]), 2)
        << (number(r[@"height_polarity"], 1) < 0 ? " (bright recessed)" : " (bright raised)")
        << " · normal ×" << fixed(number(r[@"normal_strength"], 1), 2)
        << " · roughness " << fixed(number(r[@"roughness_base"]), 2) << " ±" << fixed(number(r[@"roughness_variation"]), 2)
        << " · AO r" << fixed(number(r[@"ao_radius_pixels"]), 0) << " ×" << fixed(number(r[@"ao_strength"], 1), 2);
    std::vector<std::string> extras;
    if (flag(r[@"tile_wrap"])) extras.push_back("wrap filters");
    if (number(r[@"albedo_equalize"]) > 0) extras.push_back("remove lighting " + fixed(number(r[@"albedo_equalize"]), 2));
    if (number(r[@"seamless_blend"]) > 0)
        extras.push_back("tileable " + fixed(number(r[@"seamless_blend"]), 2) + " " + text(r[@"seamless_mode"], "blend"));
    if (!text(r[@"albedo_repair"]).empty() && text(r[@"albedo_repair"]) != "off") extras.push_back("repair " + text(r[@"albedo_repair"]));
    if (number(r[@"guide_normal_weight"]) > 0)
        extras.push_back("learned " + fixed(number(r[@"guide_normal_weight"]) * 100, 0) + " %");
    if (flag(r[@"assigned_metalness_enabled"])) extras.push_back("metalness " + fixed(number(r[@"assigned_metalness"]), 2));
    if (flag(r[@"bent_normal_enabled"])) extras.push_back("bent normal");
    if (!extras.empty()) {
        out << "\n                ";
        for (size_t i = 0; i < extras.size(); ++i) out << (i ? " · " : "") << extras[i];
    }
    return out.str();
}

double worstSeam(NSDictionary* seam) {
    double worst = 0;
    for (NSString* key in @[@"pixel_x", @"pixel_y", @"tone_x", @"tone_y"]) worst = std::max(worst, number(seam[key]));
    return worst;
}

CGImageRef imageFor(const Raster& raster) {
    // Every map is shown as encoded: data maps are not colour-converted, height is stretched to its own range.
    std::vector<uint8_t> rgba(static_cast<size_t>(raster.width) * raster.height * 4, 255);
    if (raster.channels == 1) {
        float lo = 1, hi = 0;
        for (uint32_t y = 0; y < raster.height; ++y) for (uint32_t x = 0; x < raster.width; ++x) {
            float v = raster.at(x, y, 0); lo = std::min(lo, v); hi = std::max(hi, v);
        }
        const float span = std::max(hi - lo, 1e-6f);
        for (uint32_t y = 0; y < raster.height; ++y) for (uint32_t x = 0; x < raster.width; ++x) {
            const uint8_t v = static_cast<uint8_t>(std::lround((raster.at(x, y, 0) - lo) / span * 255));
            uint8_t* px = &rgba[(static_cast<size_t>(y) * raster.width + x) * 4];
            px[0] = px[1] = px[2] = v;
        }
    } else {
        rgba = raster.bytes;
        for (size_t i = 3; i < rgba.size(); i += 4) rgba[i] = 255;  // Show colour even under transparency.
    }
    CFDataRef data = CFDataCreate(nullptr, rgba.data(), static_cast<CFIndex>(rgba.size()));
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef image = CGImageCreate(raster.width, raster.height, 8, 32, raster.width * 4, space,
                                     static_cast<CGBitmapInfo>(static_cast<uint32_t>(kCGImageAlphaNoneSkipLast) | static_cast<uint32_t>(kCGBitmapByteOrder32Big)), provider, nullptr, true,
                                     kCGRenderingIntentDefault);
    CGColorSpaceRelease(space);
    CGDataProviderRelease(provider);
    CFRelease(data);
    return image;
}

void drawText(CGContextRef context, const std::string& string, CGFloat x, CGFloat y, CGFloat size, bool bold,
              CGFloat gray) {
    CTFontRef font = CTFontCreateUIFontForLanguage(bold ? kCTFontUIFontEmphasizedSystem : kCTFontUIFontSystem, size, nullptr);
    CGColorRef color = CGColorCreateGenericGray(gray, 1);
    NSDictionary* attributes = @{(__bridge NSString*)kCTFontAttributeName: (__bridge id)font,
                                 (__bridge NSString*)kCTForegroundColorAttributeName: (__bridge id)color};
    NSAttributedString* line = [[NSAttributedString alloc] initWithString:@(string.c_str()) attributes:attributes];
    CTLineRef ctLine = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)line);
    CGContextSetTextPosition(context, x, y);
    CTLineDraw(ctLine, context);
    CFRelease(ctLine);
    CGColorRelease(color);
    CFRelease(font);
}

std::string mapTitle(const std::string& name) {
    static const std::map<std::string, std::string> titles = {
        {"albedo", "Albedo"}, {"height", "Height (stretched)"}, {"normal", "Normal"}, {"roughness", "Roughness"},
        {"ao", "Ambient occlusion"}, {"cavity", "Cavity"}, {"convexity", "Convexity"}, {"slope", "Slope"},
        {"edge", "Edge"}, {"bent_normal", "Bent normal"}, {"orm", "ORM"}};
    auto it = titles.find(name);
    return it == titles.end() ? name : it->second;
}

struct Difference { double mean = 0, max = 0, psnr = INFINITY; bool comparable = false; };
Difference compare(const Raster& a, const Raster& b) {
    Difference d;
    if (a.width != b.width || a.height != b.height || a.channels != b.channels || a.bits != b.bits) return d;
    d.comparable = true;
    const int channels = a.channels == 4 ? 3 : 1;  // Alpha is coverage, not material.
    double sum = 0, squares = 0;
    size_t count = 0;
    for (uint32_t y = 0; y < a.height; ++y) for (uint32_t x = 0; x < a.width; ++x) for (int c = 0; c < channels; ++c) {
        const double delta = std::abs(static_cast<double>(a.at(x, y, c)) - b.at(x, y, c));
        sum += delta; squares += delta * delta; d.max = std::max(d.max, delta); ++count;
    }
    d.mean = sum / static_cast<double>(count);
    const double mse = squares / static_cast<double>(count);
    d.psnr = mse > 0 ? 10 * std::log10(1.0 / mse) : INFINITY;
    return d;
}

void printJSON(id object) {
    NSData* data = [NSJSONSerialization dataWithJSONObject:object
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:nil];
    std::cout << std::string(static_cast<const char*>(data.bytes), data.length) << '\n';
}

} // namespace

int info(const fs::path& bundle, bool json) {
    NSDictionary* m = loadManifest(bundle);
    NSDictionary* recipe = dict(m[@"recipe"]);
    NSDictionary* maps = dict(m[@"maps"]);
    NSDictionary* seams = dict(m[@"seam_metrics"]);
    NSDictionary* relief = dict(m[@"relief"]);
    NSDictionary* guide = dict(m[@"guide_normals"]);
    NSDictionary* repair = dict(m[@"albedo_repair"]);
    NSDictionary* source = dict(m[@"source"]);
    if (json) {
        NSMutableDictionary* out = [NSMutableDictionary dictionary];
        out[@"bundle"] = @(fs::absolute(bundle).string().c_str());
        for (NSString* key in @[@"semantic_label", @"material_id", @"algorithm_version", @"normal_convention",
                                @"recipe", @"seam_metrics", @"relief", @"guide_normals", @"albedo_repair", @"runtime_admitted"])
            if (m[key]) out[key] = m[key];
        if (source) out[@"source"] = @{@"path": source[@"path"] ?: @"", @"sha256": source[@"sha256"] ?: @""};
        NSMutableDictionary* mapSummary = [NSMutableDictionary dictionary];
        for (NSString* name in maps) {
            NSDictionary* record = dict(maps[name]);
            mapSummary[name] = @{@"width": record[@"width"] ?: @0, @"height": record[@"height"] ?: @0,
                                 @"pixel_format": record[@"pixel_format"] ?: @"", @"provenance": record[@"provenance"] ?: @""};
        }
        out[@"maps"] = mapSummary;
        printJSON(out);
        return 0;
    }
    auto row = [](const char* label, const std::string& value) {
        std::cout << "  " << std::left << std::setw(12) << label << "  " << value << '\n';
    };
    std::cout << "Material Lab bundle: " << bundle.filename().string() << '\n';
    row("Label", text(m[@"semantic_label"]) + "  (id " + text(m[@"material_id"]) + ")");
    row("Algorithm", text(m[@"algorithm_version"]) + " · normals " + text(m[@"normal_convention"], "+Y"));
    if (source) row("Source", text(source[@"path"]) + "  sha256 " + shortHash(source[@"sha256"]));
    if (recipe) row("Recipe", recipeSummary(recipe));
    std::ostringstream mapLine;
    int count = 0;
    for (const char* name : kMapOrder) {
        NSDictionary* record = dict(maps[@(name)]);
        if (!record) continue;
        if (count && count % 4 == 0) mapLine << "\n                ";
        else if (count) mapLine << " · ";
        mapLine << name << " " << text(record[@"width"]) << "²";
        ++count;
    }
    row("Maps", mapLine.str());
    if (seams) {
        std::string line = "albedo " + fixed(number(seams[@"albedo_value_delta"]), 4) + " · height " +
                           fixed(number(seams[@"height_value_delta"]), 4);
        if (relief && relief[@"height_wrap_seam_ratio"])
            line += " · height wrap ratio " + fixed(number(relief[@"height_wrap_seam_ratio"]), 2) + "×";
        row("Seams", line);
    }
    if (relief)
        row("Relief", "depth " + fixed(number(relief[@"height_span_tile_widths"]), 4) + " tile widths · rms slope " +
                      fixed(number(relief[@"rms_slope"]), 3) + " · learned form " +
                      fixed(number(relief[@"learned_form_share"]) * 100, 0) + " %");
    if (guide)
        row("Learned", text(guide[@"estimator"]) + " · " + text(guide[@"compute_units"]) + " · " + text(guide[@"tiles"]) +
                       " tiles at " + text(guide[@"work_resolution"]) + "²");
    if (repair)
        row("Repair", text(repair[@"method"]) + " · worst seam " + fixed(worstSeam(dict(repair[@"seam_before"])), 2) +
                      "× → " + fixed(worstSeam(dict(repair[@"seam_after"])), 2) + "×");
    row("Admitted", flag(m[@"runtime_admitted"]) ? "yes" : "no (estimates: review before importing into an engine)");
    return 0;
}

int contactSheet(const fs::path& bundle, const fs::path& output) {
    NSDictionary* m = loadManifest(bundle);
    NSDictionary* maps = dict(m[@"maps"]);
    std::vector<std::string> names;
    for (const char* name : kMapOrder) if (maps[@(name)]) names.emplace_back(name);
    const int tile = 320, gap = 18, label = 30, header = 70, columns = 4;
    const int rows = static_cast<int>((names.size() + columns - 1) / columns);
    const int width = gap + columns * (tile + gap);
    const int height = header + rows * (tile + label + gap) + gap;
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    std::vector<uint8_t> pixels(static_cast<size_t>(width) * height * 4);
    CGContextRef context = CGBitmapContextCreate(pixels.data(), width, height, 8, width * 4, space,
                                                 static_cast<uint32_t>(kCGImageAlphaPremultipliedLast) | static_cast<uint32_t>(kCGBitmapByteOrder32Big));
    CGColorSpaceRelease(space);
    if (!context) throw std::runtime_error("cannot allocate the contact sheet");
    CGContextSetRGBFillColor(context, 0.09, 0.09, 0.10, 1);
    CGContextFillRect(context, CGRectMake(0, 0, width, height));
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    drawText(context, text(m[@"semantic_label"], "material"), gap, height - 38, 24, true, 0.95);
    drawText(context, "Material Lab " + text(m[@"algorithm_version"]) + " · normals " + text(m[@"normal_convention"], "+Y") +
             " · " + bundle.filename().string(), gap, height - 60, 13, false, 0.6);
    for (size_t i = 0; i < names.size(); ++i) {
        const int column = static_cast<int>(i % columns), rowIndex = static_cast<int>(i / columns);
        const CGFloat x = gap + column * (tile + gap);
        const CGFloat top = height - header - rowIndex * (tile + label + gap);
        CGImageRef image = imageFor(loadMap(bundle, names[i]));
        CGContextDrawImage(context, CGRectMake(x, top - tile, tile, tile), image);
        CGImageRelease(image);
        drawText(context, mapTitle(names[i]), x, top - tile - 21, 14, false, 0.85);
    }
    CGContextRelease(context);
    // Un-premultiply is unnecessary: the sheet is opaque.
    writeFile(output, encodeRGBA8(width, height, pixels, true));
    std::cout << output.string() << '\n';
    return 0;
}

int diff(const fs::path& a, const fs::path& b, bool json) {
    NSDictionary* ma = loadManifest(a);
    NSDictionary* mb = loadManifest(b);
    NSDictionary* ra = dict(ma[@"recipe"]) ?: @{};
    NSDictionary* rb = dict(mb[@"recipe"]) ?: @{};
    NSMutableSet* keys = [NSMutableSet setWithArray:ra.allKeys];
    [keys addObjectsFromArray:rb.allKeys];
    NSMutableArray* recipeChanges = [NSMutableArray array];
    for (NSString* key in [keys.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
        id va = ra[key], vb = rb[key];
        if ((va || vb) && ![va isEqual:vb]) [recipeChanges addObject:@{@"key": key, @"a": va ?: [NSNull null], @"b": vb ?: [NSNull null]}];
    }
    NSDictionary* mapsA = dict(ma[@"maps"]) ?: @{};
    NSDictionary* mapsB = dict(mb[@"maps"]) ?: @{};
    NSMutableArray* mapRows = [NSMutableArray array];
    bool identical = recipeChanges.count == 0;
    for (const char* name : kMapOrder) {
        NSString* key = @(name);
        if (!mapsA[key] && !mapsB[key]) continue;
        if (!mapsA[key] || !mapsB[key]) {
            identical = false;
            [mapRows addObject:@{@"map": key, @"status": mapsA[key] ? @"only in A" : @"only in B"}];
            continue;
        }
        const std::string hashA = text(dict(mapsA[key])[@"sha256"]), hashB = text(dict(mapsB[key])[@"sha256"]);
        if (!hashA.empty() && hashA == hashB) {
            [mapRows addObject:@{@"map": key, @"status": @"identical"}];
            continue;
        }
        identical = false;
        const Difference d = compare(loadMap(a, name), loadMap(b, name));
        if (!d.comparable) { [mapRows addObject:@{@"map": key, @"status": @"different size or format"}]; continue; }
        [mapRows addObject:@{@"map": key, @"status": @"different", @"mean_abs": @(d.mean), @"max_abs": @(d.max),
                             @"psnr_db": std::isfinite(d.psnr) ? @(d.psnr) : @"inf"}];
    }
    if (json) {
        printJSON(@{@"a": @(a.string().c_str()), @"b": @(b.string().c_str()), @"identical": @(identical),
                    @"recipe_changes": recipeChanges, @"maps": mapRows});
        return 0;
    }
    std::cout << "A  " << a.filename().string() << "  (" << text(ma[@"algorithm_version"]) << ")\n"
              << "B  " << b.filename().string() << "  (" << text(mb[@"algorithm_version"]) << ")\n";
    if (recipeChanges.count) {
        std::cout << "Recipe changes:\n";
        for (NSDictionary* change in recipeChanges)
            std::cout << "  " << std::left << std::setw(26) << text(change[@"key"]) << text(change[@"a"], "—") << " → "
                      << text(change[@"b"], "—") << '\n';
    } else std::cout << "Recipe: identical\n";
    std::cout << "Maps:\n";
    for (NSDictionary* rowValue in mapRows) {
        std::cout << "  " << std::left << std::setw(12) << text(rowValue[@"map"]);
        if ([rowValue[@"status"] isEqual:@"different"])
            std::cout << "mean " << fixed(number(rowValue[@"mean_abs"]) * 255, 2) << "/255  max "
                      << fixed(number(rowValue[@"max_abs"]) * 255, 1) << "/255  PSNR "
                      << ([rowValue[@"psnr_db"] isKindOfClass:[NSNumber class]] ? fixed(number(rowValue[@"psnr_db"]), 1) + " dB" : "inf")
                      << '\n';
        else std::cout << text(rowValue[@"status"]) << '\n';
    }
    std::cout << (identical ? "Bundles are identical.\n" : "");
    return 0;
}

} // namespace mltools
