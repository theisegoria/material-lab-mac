#import <Foundation/Foundation.h>
#include "Tools.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <dispatch/dispatch.h>
#include <iostream>
#include <stdexcept>

// --preview: a lit render of a bundle on the CPU, the same on every Mac. Left: a sphere wrapped 4 x 2 with the
// material under a key, a fill and a sky. Right: a flat 2 x 2 tiling under a raking light, which shows relief and
// any seam. Cook-Torrance GGX with the bundle's albedo, normal, roughness, AO and metalness; no displacement.
namespace mltools {
namespace {

struct Vec { float x = 0, y = 0, z = 0; };
Vec operator+(Vec a, Vec b) { return {a.x + b.x, a.y + b.y, a.z + b.z}; }
Vec operator-(Vec a, Vec b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }
Vec operator*(Vec a, Vec b) { return {a.x * b.x, a.y * b.y, a.z * b.z}; }
Vec operator*(Vec a, float s) { return {a.x * s, a.y * s, a.z * s}; }
float dot(Vec a, Vec b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
Vec normalize(Vec a) { const float l = std::sqrt(std::max(dot(a, a), 1e-12f)); return a * (1 / l); }
Vec mix(Vec a, Vec b, float t) { return a * (1 - t) + b * t; }

float srgbToLinear(float v) { return v <= 0.04045f ? v / 12.92f : std::pow((v + 0.055f) / 1.055f, 2.4f); }
float linearToSRGB(float v) { v = std::clamp(v, 0.0f, 1.0f); return v <= 0.0031308f ? v * 12.92f : 1.055f * std::pow(v, 1 / 2.4f) - 0.055f; }

// A map as floats, sampled bilinearly with wrap.
struct Texture {
    uint32_t width = 0, height = 0;
    int channels = 0;
    std::vector<float> values;
    void sample(float u, float v, float* out) const {
        const float x = (u - std::floor(u)) * width - 0.5f, y = (v - std::floor(v)) * height - 0.5f;
        const float fx = std::floor(x), fy = std::floor(y);
        const float tx = x - fx, ty = y - fy;
        const auto wrap = [](float value, uint32_t size) { return static_cast<size_t>((static_cast<int64_t>(value) % size + size) % size); };
        const size_t x0 = wrap(fx, width), x1 = wrap(fx + 1, width), y0 = wrap(fy, height), y1 = wrap(fy + 1, height);
        for (int c = 0; c < channels; ++c) {
            const float a = values[(y0 * width + x0) * channels + c], b = values[(y0 * width + x1) * channels + c];
            const float d = values[(y1 * width + x0) * channels + c], e = values[(y1 * width + x1) * channels + c];
            out[c] = (a * (1 - tx) + b * tx) * (1 - ty) + (d * (1 - tx) + e * tx) * ty;
        }
    }
};

Texture texture(const Raster& raster, int channels, int firstChannel, bool srgb) {
    Texture t{raster.width, raster.height, channels, {}};
    t.values.resize(static_cast<size_t>(raster.width) * raster.height * channels);
    for (uint32_t y = 0; y < raster.height; ++y) for (uint32_t x = 0; x < raster.width; ++x) for (int c = 0; c < channels; ++c) {
        const float v = raster.at(x, y, raster.channels == 1 ? 0 : firstChannel + c);
        t.values[(static_cast<size_t>(y) * raster.width + x) * channels + c] = srgb ? srgbToLinear(v) : v;
    }
    return t;
}

struct Material {
    Texture albedo, normal, roughness, ao, metal;
    bool hasMetalMap = false, greenDown = false;
    float metalness = 0;
};

struct Light { Vec direction, colour; };

// One shaded sample. `t`, `b`, `n` are the surface frame (b towards the top of the texture), `view` towards the eye.
Vec shade(const Material& m, float u, float v, Vec t, Vec b, Vec n, Vec view, const std::array<Light, 2>& lights) {
    float albedo[3], normal[3], rough, ao, metal = m.metalness;
    m.albedo.sample(u, v, albedo);
    m.normal.sample(u, v, normal);
    m.roughness.sample(u, v, &rough);
    m.ao.sample(u, v, &ao);
    if (m.hasMetalMap) m.metal.sample(u, v, &metal);
    const float nx = normal[0] * 2 - 1, ny = (normal[1] * 2 - 1) * (m.greenDown ? -1 : 1), nz = std::max(normal[2] * 2 - 1, 0.05f);
    const Vec shadingNormal = normalize(t * nx + b * ny + n * nz);
    const Vec base{albedo[0], albedo[1], albedo[2]};
    const Vec f0 = mix(Vec{0.04f, 0.04f, 0.04f}, base, metal);
    const Vec diffuse = base * (1 - metal);
    const float alpha = std::max(rough * rough, 0.002f), alpha2 = alpha * alpha;
    const float nv = std::max(dot(shadingNormal, view), 1e-3f);
    const float k = (rough + 1) * (rough + 1) / 8;
    Vec colour;
    for (const Light& light : lights) {
        const float nl = dot(shadingNormal, light.direction);
        if (nl <= 0 || dot(n, light.direction) <= 0) continue;
        const Vec h = normalize(light.direction + view);
        const float nh = std::max(dot(shadingNormal, h), 0.0f), vh = std::max(dot(view, h), 0.0f);
        const float denominator = nh * nh * (alpha2 - 1) + 1;
        const float d = alpha2 / (static_cast<float>(M_PI) * denominator * denominator);
        const float g = (nl / (nl * (1 - k) + k)) * (nv / (nv * (1 - k) + k));
        const float fresnel = std::pow(1 - vh, 5.0f);
        const Vec f = f0 + (Vec{1, 1, 1} - f0) * fresnel;
        const Vec specular = f * (d * g / (4 * nl * nv));
        colour = colour + (diffuse * (1 / static_cast<float>(M_PI)) + specular) * light.colour * nl;
    }
    // Sky above, ground below; occlusion applies to this ambient term only.
    const float up = shadingNormal.y * 0.5f + 0.5f;
    const Vec sky = mix(Vec{0.10f, 0.09f, 0.08f}, Vec{0.42f, 0.46f, 0.52f}, up);
    const Vec ambientSpecular = (f0 + (Vec{1, 1, 1} - f0) * std::pow(1 - nv, 5.0f) * (1 - rough)) * (1 - 0.7f * rough);
    colour = colour + (diffuse + ambientSpecular * 0.6f) * sky * ao;
    return colour;
}

float tonemap(float v) { // Narkowicz ACES fit.
    return std::clamp(v * (2.51f * v + 0.03f) / (v * (2.43f * v + 0.59f) + 0.14f), 0.0f, 1.0f);
}

} // namespace

int preview(const fs::path& bundle, const fs::path& output) {
    const auto bytes = readFile(bundle / "manifest.json");
    id root = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes.data() length:bytes.size()] options:0 error:nil];
    if (![root isKindOfClass:[NSDictionary class]]) throw std::runtime_error("manifest is not a JSON object");
    NSDictionary* manifest = root;
    NSDictionary* recipe = [manifest[@"recipe"] isKindOfClass:[NSDictionary class]] ? manifest[@"recipe"] : @{};
    Material m;
    m.albedo = texture(loadMap(bundle, "albedo"), 3, 0, true);
    m.normal = texture(loadMap(bundle, "normal"), 3, 0, false);
    m.roughness = texture(loadMap(bundle, "roughness"), 1, 0, false);
    m.ao = texture(loadMap(bundle, "ao"), 1, 0, false);
    m.greenDown = [manifest[@"normal_convention"] isEqual:@"-Y"];
    if ([manifest[@"maps"] isKindOfClass:[NSDictionary class]] && manifest[@"maps"][@"orm"]) {
        m.metal = texture(loadMap(bundle, "orm"), 1, 2, false);
        m.hasMetalMap = true;
    } else if ([recipe[@"assigned_metalness_enabled"] isKindOfClass:[NSNumber class]] && [recipe[@"assigned_metalness_enabled"] boolValue]) {
        m.metalness = [recipe[@"assigned_metalness"] isKindOfClass:[NSNumber class]] ? [recipe[@"assigned_metalness"] floatValue] : 0;
    }

    const int panel = 640, gap = 24, width = gap * 3 + panel * 2, height = gap * 2 + panel, samples = 3;
    const std::array<Light, 2> sphereLights{{{normalize({-0.55f, 0.6f, 0.6f}), {3.2f, 3.05f, 2.9f}},
                                             {normalize({0.75f, -0.1f, 0.35f}), {0.45f, 0.55f, 0.7f}}}};
    const std::array<Light, 2> planeLights{{{normalize({-0.7f, 0.6f, 0.38f}), {3.6f, 3.45f, 3.3f}},
                                            {normalize({0.5f, -0.4f, 0.75f}), {0.35f, 0.4f, 0.5f}}}};
    const Vec view{0, 0, 1};
    std::vector<uint8_t> pixels(static_cast<size_t>(width) * height * 4);
    uint8_t* out = pixels.data();
    const Material* material = &m;
    dispatch_apply(static_cast<size_t>(height), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t row) {
        for (int column = 0; column < width; ++column) {
            Vec sum;
            for (int sy = 0; sy < samples; ++sy) for (int sx = 0; sx < samples; ++sx) {
                const float px = column + (sx + 0.5f) / samples, py = static_cast<float>(row) + (sy + 0.5f) / samples;
                const float shadeOfBackground = 0.012f + 0.02f * (1 - py / height);
                Vec colour{shadeOfBackground, shadeOfBackground, shadeOfBackground * 1.1f};
                bool lit = false;
                if (px >= gap && px < gap + panel && py >= gap && py < gap + panel) {
                    // Sphere, seen orthographically.
                    const float x = ((px - gap) / panel * 2 - 1) / 0.96f, y = -(((py - gap) / panel) * 2 - 1) / 0.96f;
                    const float r2 = x * x + y * y;
                    if (r2 < 1) {
                        const Vec n{x, y, std::sqrt(1 - r2)};
                        const float phi = std::atan2(n.x, n.z), theta = std::acos(std::clamp(n.y, -1.0f, 1.0f));
                        const Vec t{std::cos(phi), 0, -std::sin(phi)};
                        const Vec b{-std::cos(theta) * std::sin(phi), std::sin(theta), -std::cos(theta) * std::cos(phi)};
                        colour = shade(*material, phi / (2 * static_cast<float>(M_PI)) * 4, theta / static_cast<float>(M_PI) * 2,
                                       t, b, n, view, sphereLights);
                        lit = true;
                    }
                } else if (px >= gap * 2 + panel && px < gap * 2 + panel * 2 && py >= gap && py < gap + panel) {
                    colour = shade(*material, (px - gap * 2 - panel) / panel * 2, (py - gap) / panel * 2,
                                   {1, 0, 0}, {0, 1, 0}, {0, 0, 1}, view, planeLights);
                    lit = true;
                }
                if (lit) colour = {tonemap(colour.x), tonemap(colour.y), tonemap(colour.z)};
                sum = sum + colour;
            }
            uint8_t* pixel = out + (row * width + column) * 4;
            const float scale = 1.0f / (samples * samples);
            pixel[0] = static_cast<uint8_t>(std::lround(linearToSRGB(sum.x * scale) * 255));
            pixel[1] = static_cast<uint8_t>(std::lround(linearToSRGB(sum.y * scale) * 255));
            pixel[2] = static_cast<uint8_t>(std::lround(linearToSRGB(sum.z * scale) * 255));
            pixel[3] = 255;
        }
    });
    writeFile(output, encodeRGBA8(width, height, pixels, true));
    std::cout << output.string() << '\n';
    return 0;
}

} // namespace mltools
