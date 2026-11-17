#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#include "MCPServer.hpp"
#include <cmath>
#include <filesystem>
#include <iostream>
#include <stdexcept>

namespace mlmcp {
namespace {
namespace fs = std::filesystem;

NSString* ns(const std::string& s) { return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @""; }
std::string str(NSString* s) { return s ? std::string(s.UTF8String ?: "") : std::string(); }

// The tools, as the JSON the client receives. Paths are absolute (or start with ~).
constexpr const char* kTools = R"JSON([
{"name":"list_presets","description":"List Material Lab's material presets (red-brick, wood-planks, rusted-steel...) with their recipes. Use an identifier as derive_material's preset.","inputSchema":{"type":"object","properties":{}}},
{"name":"list_formats","description":"List the engine and interchange export formats (glb, usdz, materialx, unreal, unity, unity-hdrp, godot, blender, substance, roblox, minecraft-labpbr).","inputSchema":{"type":"object","properties":{}}},
{"name":"derive_material","description":"Derive a full PBR material (albedo, 16-bit height, normal, roughness, AO, cavity/convexity/slope/edge masks, optional bent normal and ORM) from one photo of a surface and write it as a .pbrmaterial bundle. Every map is an estimate from the photo. Returns the bundle path and its measured relief, seams and provenance. Follow with preview_material to look at the maps.","inputSchema":{"type":"object","required":["input","output"],"properties":{
 "input":{"type":"string","description":"Photo or albedo image (PNG, JPEG, HEIC, TIFF...)."},
 "output":{"type":"string","description":"Bundle to create; .pbrmaterial is appended if missing. Must not exist."},
 "preset":{"type":"string","description":"A material preset from list_presets, or a relief prior: flat, stone, fabric, organic, coated-metal, bare-metal."},
 "recipe":{"type":"string","description":"Start from a recipe JSON file or another bundle's recipe instead of a preset."},
 "learned":{"type":"boolean","description":"Use the bundled MoGe-2 normal estimator for large-scale form (slower, usually better geometry)."},
 "learned_cpu_only":{"type":"boolean"},
 "tileable":{"type":"boolean","description":"Treat the image as wrapping (default true). False for a non-tiling photo."},
 "repair_albedo":{"type":"string","enum":["off","blend","quilt","auto"],"description":"Rebuild the albedo itself so it tiles; auto picks the method."},
 "seamless":{"type":"number","description":"Edge band width for make-tileable, 0..0.45."},
 "seamless_mode":{"type":"string","enum":["cut","blend"]},
 "height_strength":{"type":"number","description":"0..0.5"},
 "polarity":{"type":"integer","enum":[-1,1],"description":"-1 when dark means raised."},
 "normal_strength":{"type":"number","description":"0..16"},
 "normal_dx":{"type":"boolean","description":"Write DirectX (green-down) normals."},
 "roughness":{"type":"number","description":"0..1"},
 "roughness_variation":{"type":"number","description":"0..1"},
 "roughness_albedo_limit":{"type":"number","description":"Max roughness/luminance correlation, 0..1 (1 off)."},
 "metalness":{"type":"number","description":"0..1; also adds a packed ORM map."},
 "ao_strength":{"type":"number","description":"0..4"},
 "ao_radius":{"type":"number","description":"0..64 pixels at the 1024 reference."},
 "bent_normal":{"type":"boolean"},
 "equalize":{"type":"number","description":"Albedo delighting, 0..1."},
 "tile_metres":{"type":"number","description":"Physical width of the tile in metres, 0..64 (0 = unknown)."},
 "mid_relief_share":{"type":"number","description":"Floor for 4-30 mm relief, 0..0.8."},
 "substrate_relief":{"type":"number","description":"Fine relief for the flat prior, 0..1."},
 "authored_albedo":{"type":"boolean","description":"The input is a hand-made albedo, not a photo."},
 "height_map":{"type":"string","description":"Artist-made height image that replaces the estimate."},
 "normal_map":{"type":"string","description":"Artist-made normal map; also drives height, AO and masks."},
 "normal_map_dx":{"type":"boolean","description":"The normal_map is DirectX (green-down)."},
 "roughness_map":{"type":"string"},"ao_map":{"type":"string"},"metalness_map":{"type":"string"},
 "resolution":{"type":"integer","enum":[4096,8192],"description":"Derive at 4096 or 8192: a smaller photo is enlarged with the pinned Real-ESRGAN upscaler first (fails clearly when it is not installed). Slow and memory-hungry; 8192 needs a quiet machine."},
 "upscaler_root":{"type":"string","description":"Pinned Real-ESRGAN vendor project for resolution (else $MATERIAL_LAB_REALESRGAN_ROOT)."},
 "guide_measured":{"type":"string","description":"Another scanner's tangent normal map, or grey depth map (white = near), used as measured form."},
 "measured_depth_mm":{"type":"number","description":"Depth that a guide_measured depth map's black..white spans, in mm (needs tile_metres)."},
 "also_export":{"type":"array","items":{"type":"string"},"description":"Formats from list_formats to write beside the bundle."},
 "label":{"type":"string","description":"Human-readable material name."},
 "id":{"type":"string"}}}},
{"name":"layer_materials","description":"Layer one .pbrmaterial bundle (top: moss, dust, snow, paint...) over another (base) through a mask, and write a new bundle. Albedo, roughness and metalness blend; reliefs blend height-aware; normals, AO and masks are re-derived from the blended relief. The manifest records both sources and the mask.","inputSchema":{"type":"object","required":["base","top","mask","output"],"properties":{
 "base":{"type":"string"},"top":{"type":"string"},
 "mask":{"type":"string","description":"height (top where the base is high), slope (where it is steep), noise (seeded tileable fBm), or the absolute path of a painted grey mask image (white = top)."},
 "threshold":{"type":"number","description":"0..1 (height and noise default 0.5, slope 0.25 = 22.5 degrees)."},
 "softness":{"type":"number","description":"0..0.5, transition half-width."},
 "invert":{"type":"boolean","description":"Swap where the top appears (height: in the hollows; slope: on flat ground)."},
 "seed":{"type":"integer","description":"Noise seed."},"scale":{"type":"number","description":"Noise cells per tile, 1..64."},
 "contrast":{"type":"number","description":"Noise contrast, 0.1..8."},
 "height_blend":{"type":"number","description":"0..0.95: let the higher layer win inside the transition (default 0.5)."},
 "normal_blend":{"type":"string","enum":["height","reoriented"],"description":"Re-derive normals from the blended relief (default) or reoriented-normal blend the two normal maps."},
 "output":{"type":"string"},"label":{"type":"string"},"id":{"type":"string"}}}},
{"name":"make_variant","description":"Write a seeded variant of a .pbrmaterial bundle: small deterministic shifts in hue, value, roughness and relief depth plus a tile offset (optionally a quarter turn and mirror), every map re-derived consistently. The same seed always gives the same variant.","inputSchema":{"type":"object","required":["bundle","seed","output"],"properties":{
 "bundle":{"type":"string"},"seed":{"type":"integer"},
 "strength":{"type":"number","description":"Scales every shift, 0..3 (default 1: hue 6 degrees, value 6 %, roughness 0.05, relief 15 %)."},
 "rotate":{"type":"boolean","description":"Also a random quarter turn and mirror."},
 "output":{"type":"string"},"label":{"type":"string"},"id":{"type":"string"}}}},
{"name":"large_tile","description":"Synthesise a 2 x 2 or 4 x 4 non-repeating tile from a tileable .pbrmaterial bundle (histogram-preserving tiling and blending, the same patches for every map) and write it as a new bundle. Best for stochastic surfaces (stone, concrete, ground); structured ones (brick, tiles) get scrambled at patch edges.","inputSchema":{"type":"object","required":["bundle","tiles","output"],"properties":{
 "bundle":{"type":"string"},"tiles":{"type":"integer","enum":[2,4]},"seed":{"type":"integer"},
 "patch":{"type":"number","description":"Patch size as a fraction of the source tile, 0.125..1 (default 0.5)."},
 "output":{"type":"string"},"label":{"type":"string"},"id":{"type":"string"}}}},
{"name":"export_material","description":"Export a .pbrmaterial bundle to one engine or interchange format. glb and usdz write a file; the others write a folder. The output must not exist.","inputSchema":{"type":"object","required":["bundle","format","output"],"properties":{"bundle":{"type":"string"},"format":{"type":"string"},"output":{"type":"string"}}}},
{"name":"inspect_material","description":"Describe a .pbrmaterial bundle: recipe, maps, provenance, seam and relief measures.","inputSchema":{"type":"object","required":["bundle"],"properties":{"bundle":{"type":"string"}}}},
{"name":"validate_material","description":"Strictly validate a .pbrmaterial bundle (manifest, hashes, PNG structure) or a .pbrcapture file.","inputSchema":{"type":"object","required":["path"],"properties":{"path":{"type":"string"}}}},
{"name":"diff_materials","description":"Compare two bundles: per-map mean and max difference, PSNR, and recipe changes.","inputSchema":{"type":"object","required":["a","b"],"properties":{"a":{"type":"string"},"b":{"type":"string"}}}},
{"name":"preview_material","description":"Return an image of a bundle so you can see the result: every map as a labelled contact sheet (view maps, the default), or a lit render on a sphere and a flat 2 x 2 tiling (view lit), which shows relief, gloss and any tiling seam.","inputSchema":{"type":"object","required":["bundle"],"properties":{"bundle":{"type":"string"},"view":{"type":"string","enum":["maps","lit"]}}}}
])JSON";

struct ToolError : std::runtime_error { using std::runtime_error::runtime_error; };

bool isWithin(const fs::path& child, const fs::path& parent) {
    auto c = child.begin(), p = parent.begin();
    for (; p != parent.end(); ++p, ++c) if (c == child.end() || *c != *p) return false;
    return true;
}

fs::path canonicalDirectory(const fs::path& path) {
    std::error_code ec;
    fs::path resolved = fs::weakly_canonical(path, ec);
    return ec ? fs::path() : resolved;
}

class Server {
public:
    Server(const std::vector<std::string>& roots, const Invoke& invoke, const char* version)
        : invoke_(invoke), version_(version), wire_(std::cout.rdbuf()) {
        for (const auto& root : roots) {
            const fs::path resolved = canonicalDirectory(expand(root));
            if (resolved.empty() || !fs::is_directory(resolved)) throw std::runtime_error("--root is not a directory: " + root);
            explicitRoots_.push_back(resolved);
        }
        for (const fs::path& fallback : {fs::path(str(NSHomeDirectory())), fs::path("/tmp"), fs::path(str(NSTemporaryDirectory()))}) {
            const fs::path resolved = canonicalDirectory(fallback);
            if (!resolved.empty()) fallbackRoots_.push_back(resolved);
        }
        tools_ = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:kTools length:strlen(kTools)] options:0 error:nil];
        if (![tools_ isKindOfClass:[NSArray class]]) throw std::runtime_error("internal error: MCP tool table");
    }

    int run() {
        std::cout.rdbuf(std::cerr.rdbuf()); // Only JSON-RPC goes to stdout.
        std::string line;
        while (std::getline(std::cin, line)) {
            if (line.find_first_not_of(" \t\r") == std::string::npos) continue;
            @autoreleasepool { handleLine(line); }
        }
        return 0;
    }

private:
    Invoke invoke_;
    std::string version_;
    std::ostream wire_;
    std::vector<fs::path> explicitRoots_, clientRoots_, fallbackRoots_;
    bool clientHasRoots_ = false;
    NSArray* tools_ = nil;

    static fs::path expand(const std::string& raw) {
        if (raw == "~" || raw.rfind("~/", 0) == 0) return fs::path(str(NSHomeDirectory())) / (raw.size() > 2 ? raw.substr(2) : "");
        return raw;
    }

    void send(NSDictionary* message) {
        NSData* data = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
        if (!data) return;
        wire_.write(static_cast<const char*>(data.bytes), static_cast<std::streamsize>(data.length));
        wire_ << '\n' << std::flush;
    }
    void reply(id requestID, NSDictionary* result) { send(@{@"jsonrpc": @"2.0", @"id": requestID, @"result": result}); }
    void fail(id requestID, int code, NSString* message) {
        send(@{@"jsonrpc": @"2.0", @"id": requestID ?: [NSNull null], @"error": @{@"code": @(code), @"message": message}});
    }

    void handleLine(const std::string& line) {
        NSError* error = nil;
        id parsed = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:line.data() length:line.size()] options:0 error:&error];
        if (!parsed) { fail(nil, -32700, @"Parse error"); return; }
        if (![parsed isKindOfClass:[NSDictionary class]]) { fail(nil, -32600, @"Invalid request"); return; }
        NSDictionary* message = parsed;
        id requestID = message[@"id"];
        const bool hasID = [requestID isKindOfClass:[NSString class]] || [requestID isKindOfClass:[NSNumber class]];
        NSString* method = [message[@"method"] isKindOfClass:[NSString class]] ? message[@"method"] : nil;
        NSDictionary* params = [message[@"params"] isKindOfClass:[NSDictionary class]] ? message[@"params"] : @{};
        if (!method) {
            // A response to our roots/list request.
            if (hasID && [requestID isEqual:@"material-lab-roots"]) takeRoots(message[@"result"]);
            else if (!hasID) fail(nil, -32600, @"Invalid request");
            return;
        }
        if (!hasID) { // Notification.
            if ([method isEqualToString:@"notifications/initialized"] || [method isEqualToString:@"notifications/roots/list_changed"])
                if (clientHasRoots_ && explicitRoots_.empty())
                    send(@{@"jsonrpc": @"2.0", @"id": @"material-lab-roots", @"method": @"roots/list"});
            return;
        }
        if ([method isEqualToString:@"initialize"]) {
            NSDictionary* capabilities = [params[@"capabilities"] isKindOfClass:[NSDictionary class]] ? params[@"capabilities"] : @{};
            clientHasRoots_ = [capabilities[@"roots"] isKindOfClass:[NSDictionary class]];
            NSString* wanted = [params[@"protocolVersion"] isKindOfClass:[NSString class]] ? params[@"protocolVersion"] : @"";
            NSArray* supported = @[@"2025-06-18", @"2025-03-26", @"2024-11-05"];
            reply(requestID, @{
                @"protocolVersion": [supported containsObject:wanted] ? wanted : supported[0],
                @"capabilities": @{@"tools": @{}},
                @"serverInfo": @{@"name": @"material-lab", @"title": @"Material Lab", @"version": ns(version_)},
                @"instructions": @"Material Lab turns one photo of a surface into a PBR material. Typical flow: list_presets, "
                                 @"derive_material, preview_material, then export_material. layer_materials, make_variant and "
                                 @"large_tile build new bundles from derived ones. Paths are absolute. Nothing is "
                                 @"overwritten: choose an output path that does not exist. Maps are estimates from the photo."});
        } else if ([method isEqualToString:@"ping"]) {
            reply(requestID, @{});
        } else if ([method isEqualToString:@"tools/list"]) {
            reply(requestID, @{@"tools": tools_});
        } else if ([method isEqualToString:@"tools/call"]) {
            callTool(requestID, params);
        } else {
            fail(requestID, -32601, [NSString stringWithFormat:@"Method not found: %@", method]);
        }
    }

    void takeRoots(id result) {
        clientRoots_.clear();
        NSArray* roots = [result isKindOfClass:[NSDictionary class]] ? result[@"roots"] : nil;
        if (![roots isKindOfClass:[NSArray class]]) return;
        for (id root in roots) {
            NSString* uri = [root isKindOfClass:[NSDictionary class]] ? root[@"uri"] : nil;
            if (![uri isKindOfClass:[NSString class]]) continue;
            NSURL* url = [NSURL URLWithString:uri];
            if (!url.isFileURL || !url.path) continue;
            const fs::path resolved = canonicalDirectory(str(url.path));
            if (!resolved.empty()) clientRoots_.push_back(resolved);
        }
    }

    // --- Arguments -------------------------------------------------------------------------
    static NSString* text(NSDictionary* args, NSString* key, bool required = false) {
        id value = args[key];
        if ([value isKindOfClass:[NSString class]] && [value length] > 0 && [value length] < 4096) return value;
        if (value && value != [NSNull null]) throw ToolError(str(key) + " must be a non-empty string");
        if (required) throw ToolError("missing argument: " + str(key));
        return nil;
    }
    static bool isBoolean(id value) { return [value isKindOfClass:[NSNumber class]] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID(); }
    static bool flag(NSDictionary* args, NSString* key, bool fallback) {
        id value = args[key];
        if (!value || value == [NSNull null]) return fallback;
        if (!isBoolean(value)) throw ToolError(str(key) + " must be true or false");
        return [value boolValue];
    }

    fs::path resolve(NSString* raw, NSString* key) const {
        const fs::path path = expand(str(raw));
        if (!path.is_absolute()) throw ToolError(str(key) + " must be an absolute path: " + str(raw));
        std::error_code ec;
        const fs::path resolved = fs::weakly_canonical(path, ec);
        if (ec || resolved.empty()) throw ToolError(str(key) + " is not a usable path: " + str(raw));
        return resolved;
    }
    static bool inside(const fs::path& path, const std::vector<fs::path>& roots) {
        for (const auto& root : roots) if (path != root && isWithin(path, root)) return true;
        return false;
    }
    fs::path readable(NSDictionary* args, NSString* key, bool required = true) const {
        NSString* raw = text(args, key, required);
        if (!raw) return {};
        const fs::path path = resolve(raw, key);
        if (!explicitRoots_.empty() && !inside(path, explicitRoots_))
            throw ToolError(str(key) + " is outside the directories this server was started with (--root): " + path.string());
        std::error_code ec;
        if (!fs::exists(path, ec)) throw ToolError(str(key) + " does not exist: " + path.string());
        return path;
    }
    void checkWritable(const fs::path& path, const std::string& key) const {
        if (!explicitRoots_.empty()) {
            if (!inside(path, explicitRoots_))
                throw ToolError(key + " is outside the directories this server was started with (--root): " + path.string());
        } else if (!inside(path, clientRoots_) && !inside(path, fallbackRoots_)) {
            throw ToolError(key + " must be inside your home directory, a temporary directory or a workspace root: " + path.string());
        }
        std::error_code ec;
        if (fs::exists(fs::symlink_status(path, ec))) throw ToolError(key + " already exists (nothing is overwritten): " + path.string());
    }
    fs::path writable(NSDictionary* args, NSString* key) const {
        const fs::path path = resolve(text(args, key, true), key);
        checkWritable(path, str(key));
        return path;
    }

    // --- Tools -----------------------------------------------------------------------------
    struct Run { int code; std::string out, err; };
    Run cli(const std::vector<std::string>& arguments) const {
        Run run;
        run.code = invoke_(arguments, run.out, run.err);
        return run;
    }
    static std::string trimmed(std::string s) {
        while (!s.empty() && (s.back() == '\n' || s.back() == ' ')) s.pop_back();
        return s;
    }
    static std::string failure(const Run& run) {
        std::string message = trimmed(run.err);
        const std::string prefix = "material-lab: ";
        if (message.rfind(prefix, 0) == 0) message.erase(0, prefix.size());
        return message.empty() ? "failed with exit code " + std::to_string(run.code) : message;
    }
    Run mustRun(const std::vector<std::string>& arguments) const {
        Run run = cli(arguments);
        if (run.code != 0) throw ToolError(failure(run));
        return run;
    }
    static NSArray* textContent(const std::string& value) { return @[@{@"type": @"text", @"text": ns(value)}]; }

    NSArray* derive(NSDictionary* args) const {
        std::vector<std::string> a{"--input", readable(args, @"input").string()};
        fs::path output = resolve(text(args, @"output", true), @"output");
        if (output.extension() != ".pbrmaterial") output += ".pbrmaterial";
        checkWritable(output, "output");
        a.insert(a.end(), {"--output", output.string()});
        static NSDictionary* const numbers = @{
            @"seamless": @"--seamless", @"height_strength": @"--height-strength", @"polarity": @"--polarity",
            @"normal_strength": @"--normal-strength", @"roughness": @"--roughness",
            @"roughness_variation": @"--roughness-variation", @"roughness_albedo_limit": @"--roughness-albedo-limit",
            @"metalness": @"--metalness", @"ao_strength": @"--ao-strength", @"ao_radius": @"--ao-radius",
            @"equalize": @"--equalize", @"tile_metres": @"--tile-metres", @"mid_relief_share": @"--mid-relief-share",
            @"substrate_relief": @"--substrate-relief", @"resolution": @"--resolution",
            @"measured_depth_mm": @"--measured-depth-mm"};
        static NSDictionary* const strings = @{@"preset": @"--preset", @"repair_albedo": @"--repair-albedo",
            @"seamless_mode": @"--seamless-mode", @"label": @"--label", @"id": @"--id"};
        static NSDictionary* const flags = @{@"learned": @"--learned", @"learned_cpu_only": @"--learned-cpu-only",
            @"normal_dx": @"--normal-dx", @"bent_normal": @"--bent-normal", @"authored_albedo": @"--authored",
            @"normal_map_dx": @"--normal-map-dx"};
        static NSDictionary* const files = @{@"recipe": @"--recipe", @"height_map": @"--height-map",
            @"normal_map": @"--normal-map", @"roughness_map": @"--roughness-map", @"ao_map": @"--ao-map",
            @"metalness_map": @"--metalness-map", @"upscaler_root": @"--upscaler-root",
            @"guide_measured": @"--guide-measured"};
        static NSSet* const other = [NSSet setWithArray:@[@"input", @"output", @"tileable", @"also_export"]];
        for (NSString* key in [args.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            id value = args[key];
            if (value == [NSNull null] || [other containsObject:key]) continue;
            if (NSString* option = numbers[key]) {
                if (![value isKindOfClass:[NSNumber class]] || isBoolean(value) || !std::isfinite([value doubleValue]))
                    throw ToolError(str(key) + " must be a number");
                char buffer[40];
                snprintf(buffer, sizeof buffer, "%.9g", [value doubleValue]);
                a.insert(a.end(), {str(option), buffer});
            } else if (NSString* option = strings[key]) {
                a.insert(a.end(), {str(option), str(text(args, key, true))});
            } else if (NSString* option = flags[key]) {
                if (flag(args, key, false)) a.push_back(str(option));
            } else if (NSString* option = files[key]) {
                a.insert(a.end(), {str(option), readable(args, key).string()});
            } else {
                throw ToolError("unknown argument: " + str(key));
            }
        }
        if (!flag(args, @"tileable", true)) a.push_back("--no-tile");
        if (id list = args[@"also_export"]; list && list != [NSNull null]) {
            if (![list isKindOfClass:[NSArray class]]) throw ToolError("also_export must be a list of formats");
            std::string joined;
            for (id format in (NSArray*)list) {
                if (![format isKindOfClass:[NSString class]] || [format length] == 0 || [format containsString:@","])
                    throw ToolError("also_export must be a list of formats");
                const std::string name = str(format), stem = output.stem().string();
                checkWritable(output.parent_path() / (name == "glb" || name == "usdz" ? stem + "." + name : stem + "-" + name),
                              "the " + name + " export");
                joined += (joined.empty() ? "" : ",") + name;
            }
            if (!joined.empty()) a.insert(a.end(), {"--also-export", joined});
        }
        return summarize(output, mustRun(a));
    }

    // A written bundle: its path, any export lines and notes, and --info --json.
    NSArray* summarize(const fs::path& output, const Run& run) const {
        NSMutableDictionary* summary = [NSMutableDictionary dictionary];
        summary[@"bundle"] = ns(output.string());
        NSMutableArray* exports = [NSMutableArray array];
        for (NSString* line in [ns(run.out) componentsSeparatedByString:@"\n"])
            if (line.length && ![line isEqualToString:ns(output.string())]) [exports addObject:line];
        if (exports.count) summary[@"exports"] = exports;
        if (!trimmed(run.err).empty()) summary[@"notes"] = ns(trimmed(run.err));
        const Run info = cli({"--info", output.string(), "--json"});
        id parsed = info.code == 0 ? [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:info.out.data() length:info.out.size()] options:0 error:nil] : nil;
        if (parsed) summary[@"material"] = parsed;
        NSData* json = [NSJSONSerialization dataWithJSONObject:summary options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes error:nil];
        return textContent(std::string(static_cast<const char*>(json.bytes), json.length));
    }

    static std::string numberText(NSDictionary* args, NSString* key, bool integer = false) {
        id value = args[key];
        if (![value isKindOfClass:[NSNumber class]] || isBoolean(value) || !std::isfinite([value doubleValue]) ||
            (integer && [value doubleValue] != std::floor([value doubleValue])))
            throw ToolError(str(key) + (integer ? " must be a whole number" : " must be a number"));
        char buffer[40];
        snprintf(buffer, sizeof buffer, "%.9g", [value doubleValue]);
        return buffer;
    }
    // Shared by the composing tools: numeric and text options, unknown keys refused.
    void options(NSDictionary* args, NSDictionary* numbers, NSDictionary* integers, NSDictionary* flags, NSSet* handled,
                 std::vector<std::string>& a) const {
        for (NSString* key in [args.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            if (args[key] == [NSNull null] || [handled containsObject:key]) continue;
            if (NSString* option = numbers[key]) a.insert(a.end(), {str(option), numberText(args, key)});
            else if (NSString* option = integers[key]) a.insert(a.end(), {str(option), numberText(args, key, true)});
            else if (NSString* option = flags[key]) { if (flag(args, key, false)) a.push_back(str(option)); }
            else if ([key isEqualToString:@"label"] || [key isEqualToString:@"id"])
                a.insert(a.end(), {"--" + str(key), str(text(args, key, true))});
            else throw ToolError("unknown argument: " + str(key));
        }
    }
    fs::path bundleOutput(NSDictionary* args) const {
        fs::path output = resolve(text(args, @"output", true), @"output");
        if (output.extension() != ".pbrmaterial") output += ".pbrmaterial";
        checkWritable(output, "output");
        return output;
    }

    NSArray* layer(NSDictionary* args) const {
        std::vector<std::string> a{"layer", "--base", readable(args, @"base").string(), "--top", readable(args, @"top").string()};
        NSString* mask = text(args, @"mask", true);
        if ([@[@"height", @"slope", @"noise"] containsObject:mask]) a.insert(a.end(), {"--mask", str(mask)});
        else a.insert(a.end(), {"--mask", readable(args, @"mask").string()});
        const fs::path output = bundleOutput(args);
        a.insert(a.end(), {"--output", output.string()});
        if (NSString* blend = text(args, @"normal_blend")) a.insert(a.end(), {"--normal-blend", str(blend)});
        options(args, @{@"threshold": @"--threshold", @"softness": @"--softness", @"scale": @"--scale", @"contrast": @"--contrast",
                        @"height_blend": @"--height-blend"},
                @{@"seed": @"--seed"}, @{@"invert": @"--invert"},
                [NSSet setWithArray:@[@"base", @"top", @"mask", @"output", @"normal_blend"]], a);
        return summarize(output, mustRun(a));
    }
    NSArray* variant(NSDictionary* args) const {
        const fs::path bundle = readable(args, @"bundle");
        if (!fs::is_directory(bundle)) throw ToolError("bundle must be a .pbrmaterial folder");
        std::vector<std::string> a{"--input", bundle.string(), "--variant", numberText(args, @"seed", true)};
        const fs::path output = bundleOutput(args);
        a.insert(a.end(), {"--output", output.string()});
        options(args, @{@"strength": @"--variant-strength"}, @{}, @{@"rotate": @"--variant-rotate"},
                [NSSet setWithArray:@[@"bundle", @"seed", @"output"]], a);
        return summarize(output, mustRun(a));
    }
    NSArray* largeTile(NSDictionary* args) const {
        const fs::path bundle = readable(args, @"bundle");
        if (!fs::is_directory(bundle)) throw ToolError("bundle must be a .pbrmaterial folder");
        std::vector<std::string> a{"--input", bundle.string(), "--large-tile", numberText(args, @"tiles", true)};
        const fs::path output = bundleOutput(args);
        a.insert(a.end(), {"--output", output.string()});
        options(args, @{@"patch": @"--large-tile-patch"}, @{@"seed": @"--large-tile-seed"}, @{},
                [NSSet setWithArray:@[@"bundle", @"tiles", @"output"]], a);
        return summarize(output, mustRun(a));
    }

    NSArray* preview(NSDictionary* args) const {
        const fs::path bundle = readable(args, @"bundle");
        const fs::path sheet = fs::path(str(NSTemporaryDirectory())) / ("material-lab-preview-" + str([NSUUID UUID].UUIDString) + ".png");
        struct Cleanup { fs::path path; ~Cleanup() { std::error_code ignored; fs::remove(path, ignored); } } cleanup{sheet};
        NSString* view = text(args, @"view") ?: @"maps";
        const bool lit = [view isEqualToString:@"lit"];
        if (!lit && ![view isEqualToString:@"maps"]) throw ToolError("view must be maps or lit");
        mustRun({lit ? "--preview" : "--contact-sheet", bundle.string(), "--output", sheet.string()});
        // JPEG keeps the image small enough to hand to a model.
        NSData* png = [NSData dataWithContentsOfFile:ns(sheet.string())];
        CGImageSourceRef source = png ? CGImageSourceCreateWithData((__bridge CFDataRef)png, nullptr) : nullptr;
        CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, nullptr) : nullptr;
        NSMutableData* jpeg = [NSMutableData data];
        CGImageDestinationRef destination = image ? CGImageDestinationCreateWithData((__bridge CFMutableDataRef)jpeg, CFSTR("public.jpeg"), 1, nullptr) : nullptr;
        bool ok = false;
        if (destination) {
            CGImageDestinationAddImage(destination, image, (__bridge CFDictionaryRef)@{(__bridge NSString*)kCGImageDestinationLossyCompressionQuality: @0.82});
            ok = CGImageDestinationFinalize(destination);
            CFRelease(destination);
        }
        if (image) CGImageRelease(image);
        if (source) CFRelease(source);
        if (!ok) throw ToolError("could not encode the preview image");
        return @[@{@"type": @"image", @"data": [jpeg base64EncodedStringWithOptions:0], @"mimeType": @"image/jpeg"},
                 @{@"type": @"text", @"text": ns(lit
                     ? bundle.filename().string() + " lit: a sphere wrapped 4 x 2 (key light upper left) and a flat 2 x 2 tiling under a raking light. No displacement."
                     : "Every map of " + bundle.filename().string() + ", in manifest order. Height and data maps are shown as encoded.")}];
    }

    NSArray* dispatch(NSString* name, NSDictionary* args) const {
        if ([name isEqualToString:@"list_presets"]) return textContent(trimmed(mustRun({"--list-presets", "--json"}).out));
        if ([name isEqualToString:@"list_formats"]) return textContent(trimmed(mustRun({"--list-formats", "--json"}).out));
        if ([name isEqualToString:@"derive_material"]) return derive(args);
        if ([name isEqualToString:@"layer_materials"]) return layer(args);
        if ([name isEqualToString:@"make_variant"]) return variant(args);
        if ([name isEqualToString:@"large_tile"]) return largeTile(args);
        if ([name isEqualToString:@"export_material"]) {
            const fs::path bundle = readable(args, @"bundle"), output = writable(args, @"output");
            const Run run = mustRun({"--export", bundle.string(), "--format", str(text(args, @"format", true)), "--output", output.string()});
            return textContent("Exported " + trimmed(run.out));
        }
        if ([name isEqualToString:@"inspect_material"])
            return textContent(trimmed(mustRun({"--info", readable(args, @"bundle").string(), "--json"}).out));
        if ([name isEqualToString:@"validate_material"]) {
            const fs::path path = readable(args, @"path");
            const Run run = mustRun({"--validate", path.string()});
            const std::string report = trimmed(run.out + run.err);
            return textContent(report.empty() ? "valid: " + path.string() : report);
        }
        if ([name isEqualToString:@"diff_materials"])
            return textContent(trimmed(mustRun({"--diff", readable(args, @"a").string(), readable(args, @"b").string(), "--json"}).out));
        if ([name isEqualToString:@"preview_material"]) return preview(args);
        return nil;
    }

    void callTool(id requestID, NSDictionary* params) {
        NSString* name = [params[@"name"] isKindOfClass:[NSString class]] ? params[@"name"] : nil;
        NSDictionary* args = [params[@"arguments"] isKindOfClass:[NSDictionary class]] ? params[@"arguments"] : @{};
        NSArray* content = nil;
        std::string problem;
        @try {
            try {
                content = name ? dispatch(name, args) : nil;
                if (!content) { fail(requestID, -32602, [NSString stringWithFormat:@"Unknown tool: %@", name ?: @""]); return; }
            } catch (const std::exception& e) {
                problem = e.what();
            }
        } @catch (NSException* exception) {
            problem = "internal error: " + str(exception.reason);
        }
        if (content) reply(requestID, @{@"content": content, @"isError": @NO});
        else reply(requestID, @{@"content": textContent(problem), @"isError": @YES});
    }
};
} // namespace

int serve(const std::vector<std::string>& roots, const Invoke& invoke, const char* version) {
    Server server(roots, invoke, version);
    return server.run();
}
} // namespace mlmcp
