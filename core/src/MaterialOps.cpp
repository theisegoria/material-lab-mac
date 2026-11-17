// Material operations on derived materials: layering, seeded variants, larger non-repeating tiles, and measured
// guides (PBRMaterialLab.h, "Material operations"; docs/DERIVATION.md). Every operation works on the stored maps of a
// bundle, then re-derives the geometry-dependent maps through PBRLabDerive with the new height as an authored height,
// so normals, AO and the diagnostics agree with it. Nothing here changes PBRLabDerive itself.
#include "PBRMaterialLab.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstring>
#include <numbers>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {

// PBRLabDerive maps authored height 0..1 onto kNormalDepthPixels x (size / kReferenceSize) x normal_strength pixels of
// depth (PBRMaterialLab.cpp), i.e. 8 / 1024 tile widths per unit normal_strength, whatever the size.
constexpr float kSpanPerNormalStrength = 8.0f / 1024.0f;
constexpr float kMaxNormalStrength = 16.0f;
constexpr uint32_t kMaxSize = 8192;

void setError(char *error, size_t capacity, const std::string &message) {
    if (!error || capacity == 0) return;
    std::strncpy(error, message.c_str(), capacity - 1);
    error[capacity - 1] = '\0';
}

// Rows split over the hardware threads (no progress or cancellation: these passes are short).
template <typename Body> void parallelRows(int rows, Body &&body) {
    const unsigned hardware = std::max(1u, std::min(std::thread::hardware_concurrency(), 16u));
    const int workers = std::max(1, std::min(static_cast<int>(hardware), rows / 16));
    if (workers == 1) { body(0, rows); return; }
    std::atomic<int> next{0};
    auto drain = [&] {
        for (;;) {
            const int y0 = next.fetch_add(8);
            if (y0 >= rows) break;
            body(y0, std::min(rows, y0 + 8));
        }
    };
    std::vector<std::thread> threads;
    for (int i = 1; i < workers; ++i) threads.emplace_back(drain);
    drain();
    for (auto &t : threads) t.join();
}

// splitmix64: the only random source, so every operation is deterministic per seed on every platform.
struct Random {
    uint64_t state;
    explicit Random(uint64_t seed) : state(seed * 0x9E3779B97F4A7C15ull + 0x632BE59BD9B4E019ull) {}
    uint64_t next() {
        uint64_t z = (state += 0x9E3779B97F4A7C15ull);
        z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
        z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
        return z ^ (z >> 31);
    }
    double unit() { return static_cast<double>(next() >> 11) * (1.0 / 9007199254740992.0); }  // [0,1)
    float symmetric() { return static_cast<float>(unit() * 2.0 - 1.0); }                        // [-1,1)
};
uint64_t hash3(uint64_t seed, uint64_t a, uint64_t b) {
    Random r(seed ^ (a * 0xD6E8FEB86659FD93ull) ^ (b * 0xA0761D6478BD642Full));
    return r.next();
}

float clamp01(float v) { return std::clamp(v, 0.0f, 1.0f); }
float smoothstep(float e0, float e1, float v) {
    if (e1 <= e0) return v < e0 ? 0.0f : 1.0f;
    const float t = clamp01((v - e0) / (e1 - e0));
    return t * t * (3 - 2 * t);
}
float srgbToLinear(float c) { return c <= 0.04045f ? c / 12.92f : std::pow((c + 0.055f) / 1.055f, 2.4f); }
uint8_t linearToSRGB(float c) {
    c = clamp01(c);
    const float s = c <= 0.0031308f ? c * 12.92f : 1.055f * std::pow(c, 1 / 2.4f) - 0.055f;
    return static_cast<uint8_t>(std::lround(clamp01(s) * 255.0f));
}
const std::array<float, 256> &linearLUT() {
    static const std::array<float, 256> lut = [] {
        std::array<float, 256> t{};
        for (int i = 0; i < 256; ++i) t[i] = srgbToLinear(static_cast<float>(i) / 255.0f);
        return t;
    }();
    return lut;
}
uint8_t byteOf(float v) { return static_cast<uint8_t>(std::lround(clamp01(v) * 255.0f)); }

// A decoded material in working form: depth in tile widths, the rest as stored.
struct Material {
    int size = 0;
    std::vector<uint8_t> albedo;     // sRGB RGBA8
    std::vector<float> depth;        // tile widths
    std::vector<uint8_t> roughness;  // R8
    std::vector<uint8_t> metalness;  // R8, empty = none
    std::vector<float> normals;      // +Y unit xyz, empty = none
};

Material load(const PBRLabMaterialMaps *m, bool wantNormals) {
    if (!m || !m->albedo_rgba8 || !m->height_r16 || !m->roughness_r8)
        throw std::runtime_error("a material needs albedo, height and roughness");
    if (m->size < 2 || m->size > kMaxSize) throw std::runtime_error("material size must be 2..8192");
    const size_t n = m->size;
    if (m->albedo_row_bytes < n * 4 || m->height_row_bytes < n * 2 || m->roughness_row_bytes < n ||
        (m->metalness_r8 && m->metalness_row_bytes < n) || (m->normal_rgba8 && m->normal_row_bytes < n * 4))
        throw std::runtime_error("material row stride is too short");
    if (!std::isfinite(m->height_span_tile_widths) || m->height_span_tile_widths < 0 || m->height_span_tile_widths > 64)
        throw std::runtime_error("height span must be 0..64 tile widths");
    Material out;
    out.size = static_cast<int>(n);
    out.albedo.resize(n * n * 4);
    out.depth.resize(n * n);
    out.roughness.resize(n * n);
    if (m->metalness_r8) out.metalness.resize(n * n);
    if (wantNormals && m->normal_rgba8) out.normals.resize(n * n * 3);
    for (size_t y = 0; y < n; ++y) {
        std::memcpy(&out.albedo[y * n * 4], m->albedo_rgba8 + y * m->albedo_row_bytes, n * 4);
        std::memcpy(&out.roughness[y * n], m->roughness_r8 + y * m->roughness_row_bytes, n);
        if (m->metalness_r8) std::memcpy(&out.metalness[y * n], m->metalness_r8 + y * m->metalness_row_bytes, n);
        const uint8_t *h = m->height_r16 + y * m->height_row_bytes;
        for (size_t x = 0; x < n; ++x)
            out.depth[y * n + x] = static_cast<float>(h[x * 2] | (h[x * 2 + 1] << 8)) / 65535.0f * m->height_span_tile_widths;
        if (!out.normals.empty()) {
            const uint8_t *p = m->normal_rgba8 + y * m->normal_row_bytes;
            for (size_t x = 0; x < n; ++x) {
                float v[3] = {p[x * 4] / 127.5f - 1, p[x * 4 + 1] / 127.5f - 1, p[x * 4 + 2] / 127.5f - 1};
                if (m->normal_y_down) v[1] = -v[1];
                const float len = std::max(1e-6f, std::sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]));
                for (int c = 0; c < 3; ++c) out.normals[(y * n + x) * 3 + c] = v[c] / len;
            }
        }
    }
    return out;
}

// Bilinear, wrapped resample of an interleaved float image.
std::vector<float> resample(const std::vector<float> &src, int from, int to, int channels) {
    std::vector<float> out(static_cast<size_t>(to) * to * channels);
    const float scale = static_cast<float>(from) / static_cast<float>(to);
    for (int y = 0; y < to; ++y) {
        const float fy = (static_cast<float>(y) + 0.5f) * scale - 0.5f;
        const int y0 = static_cast<int>(std::floor(fy));
        const float ty = fy - static_cast<float>(y0);
        const int ya = ((y0 % from) + from) % from, yb = (ya + 1) % from;
        for (int x = 0; x < to; ++x) {
            const float fx = (static_cast<float>(x) + 0.5f) * scale - 0.5f;
            const int x0 = static_cast<int>(std::floor(fx));
            const float tx = fx - static_cast<float>(x0);
            const int xa = ((x0 % from) + from) % from, xb = (xa + 1) % from;
            for (int c = 0; c < channels; ++c) {
                auto at = [&](int xx, int yy) { return src[(static_cast<size_t>(yy) * from + xx) * channels + c]; };
                out[(static_cast<size_t>(y) * to + x) * channels + c] =
                    (at(xa, ya) * (1 - tx) + at(xb, ya) * tx) * (1 - ty) + (at(xa, yb) * (1 - tx) + at(xb, yb) * tx) * ty;
            }
        }
    }
    return out;
}
template <typename T> std::vector<float> toFloat(const std::vector<T> &v) { return std::vector<float>(v.begin(), v.end()); }
std::vector<uint8_t> toBytes(const std::vector<float> &v) {
    std::vector<uint8_t> out(v.size());
    for (size_t i = 0; i < v.size(); ++i) out[i] = static_cast<uint8_t>(std::lround(std::clamp(v[i], 0.0f, 255.0f)));
    return out;
}
Material resampled(const Material &m, int to) {
    if (m.size == to) return m;
    Material out;
    out.size = to;
    out.albedo = toBytes(resample(toFloat(m.albedo), m.size, to, 4));
    out.depth = resample(m.depth, m.size, to, 1);
    out.roughness = toBytes(resample(toFloat(m.roughness), m.size, to, 1));
    if (!m.metalness.empty()) out.metalness = toBytes(resample(toFloat(m.metalness), m.size, to, 1));
    if (!m.normals.empty()) {
        out.normals = resample(m.normals, m.size, to, 3);
        for (size_t i = 0; i < out.normals.size(); i += 3) {
            float *v = &out.normals[i];
            const float len = std::max(1e-6f, std::sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]));
            v[0] /= len; v[1] /= len; v[2] /= len;
        }
    }
    return out;
}

void checkShading(const PBRLabRecipe *shading) {
    if (!shading) throw std::runtime_error("a shading recipe is required");
}

// Re-derives every map from a material with PBRLabDerive: the depth (re-normalised to the full 16-bit range) as
// authored height, roughness and metalness as authored maps, optional normals as an authored normal map.
PBRLabResult *rederive(const Material &m, const PBRLabRecipe &shading, PBRLabRecipe *outRecipe) {
    const size_t n = static_cast<size_t>(m.size), count = n * n;
    float lowest = m.depth[0], highest = m.depth[0];
    for (float d : m.depth) { lowest = std::min(lowest, d); highest = std::max(highest, d); }
    const float span = highest - lowest;
    PBRLabRecipe recipe = shading;
    recipe.normal_strength = span > 1e-9f ? span / kSpanPerNormalStrength : 0.0f;
    if (recipe.normal_strength > kMaxNormalStrength)
        throw std::runtime_error("the combined relief is deeper than 1/8 of the tile; reduce the relief");
    recipe.guide_normal_weight = 0;
    recipe.albedo_equalize = 0;
    recipe.seamless_blend = 0;
    recipe.albedo_repair = 0;
    if (!m.metalness.empty()) recipe.assigned_metalness_enabled = 1;
    std::vector<uint8_t> height(count * 2);
    for (size_t i = 0; i < count; ++i) {
        const uint16_t h = span > 1e-9f ? static_cast<uint16_t>(std::lround(clamp01((m.depth[i] - lowest) / span) * 65535.0f)) : 0;
        height[i * 2] = static_cast<uint8_t>(h & 0xff);
        height[i * 2 + 1] = static_cast<uint8_t>(h >> 8);
    }
    std::vector<uint8_t> normals;
    if (!m.normals.empty()) {
        normals.resize(count * 4);
        for (size_t i = 0; i < count; ++i) {
            for (int c = 0; c < 3; ++c) normals[i * 4 + c] = static_cast<uint8_t>(std::lround(std::clamp((m.normals[i * 3 + c] + 1) * 127.5f, 0.0f, 255.0f)));
            normals[i * 4 + 3] = 255;
        }
    }
    PBRLabInput input{};
    input.rgba8 = m.albedo.data();
    input.rgba_row_bytes = n * 4;
    input.height_override_r16 = height.data();
    input.height_override_row_bytes = n * 2;
    input.width = input.height = static_cast<uint32_t>(n);
    input.authored_roughness_r8 = m.roughness.data();
    input.authored_roughness_row_bytes = n;
    if (!m.metalness.empty()) { input.authored_metalness_r8 = m.metalness.data(); input.authored_metalness_row_bytes = n; }
    if (!normals.empty()) { input.authored_normal_rgba8 = normals.data(); input.authored_normal_row_bytes = n * 4; }
    char error[256]{};
    PBRLabResult *result = PBRLabDerive(&input, &recipe, nullptr, nullptr, error, sizeof(error));
    if (!result) throw std::runtime_error(std::string("re-derivation failed: ") + error);
    if (outRecipe) *outRecipe = recipe;
    return result;
}

// Periodic value-noise fBm in [0,1]: integer cells per tile on every octave, so the mask tiles.
std::vector<float> fbm(int size, uint32_t seed, int cells, int octaves) {
    std::vector<float> out(static_cast<size_t>(size) * size, 0.0f);
    float amplitude = 1, total = 0;
    for (int o = 0; o < octaves; ++o, cells *= 2, amplitude *= 0.5f) {
        total += amplitude;
        const uint64_t octaveSeed = (static_cast<uint64_t>(seed) << 8) + static_cast<uint64_t>(o);
        std::vector<float> lattice(static_cast<size_t>(cells) * cells);
        for (int j = 0; j < cells; ++j)
            for (int i = 0; i < cells; ++i)
                lattice[static_cast<size_t>(j) * cells + i] = static_cast<float>(hash3(octaveSeed, static_cast<uint64_t>(i), static_cast<uint64_t>(j)) >> 40) / 16777216.0f;
        auto fade = [](float t) { return t * t * t * (t * (t * 6 - 15) + 10); };
        parallelRows(size, [&](int y0, int y1) {
            for (int y = y0; y < y1; ++y) {
                const float v = (static_cast<float>(y) + 0.5f) * static_cast<float>(cells) / static_cast<float>(size);
                const int j = static_cast<int>(v) % cells, j1 = (j + 1) % cells;
                const float ty = fade(v - std::floor(v));
                for (int x = 0; x < size; ++x) {
                    const float u = (static_cast<float>(x) + 0.5f) * static_cast<float>(cells) / static_cast<float>(size);
                    const int i = static_cast<int>(u) % cells, i1 = (i + 1) % cells;
                    const float tx = fade(u - std::floor(u));
                    auto L = [&](int a, int b) { return lattice[static_cast<size_t>(b) * cells + a]; };
                    const float s = (L(i, j) * (1 - tx) + L(i1, j) * tx) * (1 - ty) + (L(i, j1) * (1 - tx) + L(i1, j1) * tx) * ty;
                    out[static_cast<size_t>(y) * size + x] += amplitude * s;
                }
            }
        });
    }
    for (auto &v : out) v /= total;
    return out;
}

void checkLayerParams(const PBRLabLayerParams *p) {
    if (!p) throw std::runtime_error("layer parameters are required");
    auto in = [](float v, float lo, float hi) { return std::isfinite(v) && v >= lo && v <= hi; };
    if (p->mask < PBRLabLayerMaskHeight || p->mask > PBRLabLayerMaskImage) throw std::runtime_error("unknown layer mask");
    if (!in(p->threshold, 0, 1)) throw std::runtime_error("layer threshold must be 0..1");
    if (!in(p->softness, 0, 0.5f)) throw std::runtime_error("layer softness must be 0..0.5");
    if (!in(p->height_blend, 0, 0.95f)) throw std::runtime_error("layer height blend must be 0..0.95");
    if (p->normal_blend > 1) throw std::runtime_error("layer normal blend must be 0 or 1");
    if (p->mask == PBRLabLayerMaskNoise && (!in(p->noise_scale, 1, 64) || !in(p->noise_contrast, 0.1f, 8)))
        throw std::runtime_error("noise scale must be 1..64 and contrast 0.1..8");
    if (p->mask == PBRLabLayerMaskImage &&
        (!p->mask_r8 || p->mask_size < 2 || p->mask_size > kMaxSize || p->mask_row_bytes < p->mask_size))
        throw std::runtime_error("an image mask needs mask pixels (2..8192 square)");
}

// The mask (before the height-aware term), in [0,1], at the base size.
std::vector<float> layerMask(const Material &base, const PBRLabLayerParams &p) {
    const int n = base.size;
    const size_t count = static_cast<size_t>(n) * n;
    std::vector<float> value(count);
    switch (p.mask) {
    case PBRLabLayerMaskHeight: {
        float lo = base.depth[0], hi = base.depth[0];
        for (float d : base.depth) { lo = std::min(lo, d); hi = std::max(hi, d); }
        const float span = hi - lo;
        for (size_t i = 0; i < count; ++i) value[i] = span > 1e-9f ? (base.depth[i] - lo) / span : 0.0f;
        break;
    }
    case PBRLabLayerMaskSlope: {
        // Slope angle / 90 degrees of the base surface (depth in pixels: tile widths x size). Wrapped differences.
        const float toPixels = static_cast<float>(n) * 0.5f;
        for (int y = 0; y < n; ++y)
            for (int x = 0; x < n; ++x) {
                auto d = [&](int xx, int yy) { return base.depth[static_cast<size_t>((yy + n) % n) * n + (xx + n) % n]; };
                const float gx = (d(x + 1, y) - d(x - 1, y)) * toPixels, gy = (d(x, y + 1) - d(x, y - 1)) * toPixels;
                value[static_cast<size_t>(y) * n + x] = std::atan(std::sqrt(gx * gx + gy * gy)) / (std::numbers::pi_v<float> / 2);
            }
        break;
    }
    case PBRLabLayerMaskNoise: {
        value = fbm(n, p.seed, static_cast<int>(std::lround(p.noise_scale)), 5);
        // Value-noise fBm clusters around 0.5 (standard deviation about 0.12); scale it to about 0.25 before contrast.
        for (auto &v : value) v = clamp01(0.5f + (v - 0.5f) * 2.0f * p.noise_contrast);
        break;
    }
    case PBRLabLayerMaskImage: {
        std::vector<float> painted(static_cast<size_t>(p.mask_size) * p.mask_size);
        for (uint32_t y = 0; y < p.mask_size; ++y)
            for (uint32_t x = 0; x < p.mask_size; ++x)
                painted[static_cast<size_t>(y) * p.mask_size + x] = p.mask_r8[y * p.mask_row_bytes + x] / 255.0f;
        value = resample(painted, static_cast<int>(p.mask_size), n, 1);
        break;
    }
    }
    const float e0 = p.threshold - p.softness, e1 = p.threshold + p.softness;
    for (auto &v : value) {
        float m = p.mask == PBRLabLayerMaskImage ? (e1 > e0 ? clamp01((v - e0) / (e1 - e0)) : (v < e0 ? 0.0f : 1.0f))
                                                 : smoothstep(e0, e1, v);
        v = p.invert ? 1 - m : m;
    }
    return value;
}

// Final top weight: the mask, with the height-aware term inside the transition (zero where the mask is 0 or 1).
std::vector<float> layerWeights(const Material &base, const Material *top, const PBRLabLayerParams &p) {
    std::vector<float> w = layerMask(base, p);
    if (!top || p.height_blend <= 0) return w;
    auto normalised = [](const std::vector<float> &d) {
        float lo = d[0], hi = d[0];
        for (float v : d) { lo = std::min(lo, v); hi = std::max(hi, v); }
        std::vector<float> out(d.size());
        for (size_t i = 0; i < d.size(); ++i) out[i] = hi - lo > 1e-9f ? (d[i] - lo) / (hi - lo) : 0.5f;
        return out;
    };
    const auto hb = normalised(base.depth), ht = normalised(top->depth);
    const float d = p.height_blend, gain = 1.0f / std::max(1.0f - d, 0.05f);
    for (size_t i = 0; i < w.size(); ++i) {
        const float m = w[i];
        const float biased = m + d * 4 * m * (1 - m) * (ht[i] - hb[i]);
        w[i] = clamp01(0.5f + (biased - 0.5f) * gain);
        if (m <= 0) w[i] = 0;
        if (m >= 1) w[i] = 1;
    }
    return w;
}

void reorientedBlend(const float *base, const float *detail, float *out) {
    // Reoriented normal mapping (Barré-Brisebois and Hill 2012): detail rotated onto the base normal.
    const float t[3] = {base[0], base[1], base[2] + 1};
    const float u[3] = {-detail[0], -detail[1], detail[2]};
    const float k = (t[0] * u[0] + t[1] * u[1] + t[2] * u[2]) / std::max(t[2], 1e-6f);
    float r[3] = {t[0] * k - u[0], t[1] * k - u[1], t[2] * k - u[2]};
    const float len = std::max(1e-6f, std::sqrt(r[0] * r[0] + r[1] * r[1] + r[2] * r[2]));
    for (int c = 0; c < 3; ++c) out[c] = r[c] / len;
}

// Histogram-preserving tiling and blending (Heitz and Neyret 2018). Each channel is Gaussianised through its own
// histogram (rank -> inverse normal CDF); blended Gaussians are re-normalised by the weights' L2 norm so the variance,
// and through the inverse transform the histogram, is kept; then mapped back through the inverse CDF table.
double normalCDF(double g) { return 0.5 * std::erfc(-g / std::numbers::sqrt2); }
double inverseNormalCDF(double p) {
    // Acklam's rational approximation (relative error < 1.2e-9), refined by one Halley step.
    p = std::clamp(p, 1e-12, 1 - 1e-12);
    static constexpr double a[] = {-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02, 1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00};
    static constexpr double b[] = {-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02, 6.680131188771972e+01, -1.328068155288572e+01};
    static constexpr double c[] = {-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00, -2.549671010166190e+00, 4.374664141464968e+00, 2.938163982698783e+00};
    static constexpr double d[] = {7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00, 3.754408661907416e+00};
    double x;
    if (p < 0.02425) {
        const double q = std::sqrt(-2 * std::log(p));
        x = (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1);
    } else if (p > 1 - 0.02425) {
        const double q = std::sqrt(-2 * std::log(1 - p));
        x = -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1);
    } else {
        const double q = p - 0.5, r = q * q;
        x = (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q /
            (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1);
    }
    const double e = normalCDF(x) - p;
    const double u = e * std::sqrt(2 * std::numbers::pi) * std::exp(x * x / 2);
    return x - u / (1 + x * u / 2);
}
// A channel of `levels` discrete values: forward table level -> Gaussian, inverse table quantile -> level.
struct Gaussianizer {
    std::vector<float> forward;
    std::vector<uint32_t> inverse;
    Gaussianizer(const std::vector<uint32_t> &values, uint32_t levels, uint32_t inverseSize) {
        std::vector<double> histogram(levels, 0.0);
        for (uint32_t v : values) histogram[v] += 1;
        const double total = static_cast<double>(values.size());
        forward.assign(levels, 0.0f);
        std::vector<double> upper(levels);
        double below = 0;
        for (uint32_t v = 0; v < levels; ++v) {
            forward[v] = static_cast<float>(inverseNormalCDF((below + histogram[v] * 0.5) / total));
            below += histogram[v];
            upper[v] = below / total;
        }
        inverse.resize(inverseSize);
        uint32_t level = 0;
        for (uint32_t k = 0; k < inverseSize; ++k) {
            const double p = (static_cast<double>(k) + 0.5) / inverseSize;
            while (level + 1 < levels && upper[level] < p) ++level;
            inverse[k] = level;
        }
    }
    uint32_t invert(float g) const {
        const double p = normalCDF(g);
        const size_t k = std::min(inverse.size() - 1, static_cast<size_t>(p * static_cast<double>(inverse.size())));
        return inverse[k];
    }
};

Material largeTile(const Material &src, const PBRLabLargeTileParams &p) {
    const int s = src.size, tiles = static_cast<int>(p.tiles), n = s * tiles;
    const size_t srcCount = static_cast<size_t>(s) * s, count = static_cast<size_t>(n) * n;
    // Lattice: `cells` squares per output axis, each split along its diagonal into two triangles; vertices wrap, so
    // the output tiles. Every vertex owns a random integer offset into the (periodic) source.
    const int cellsPerSource = std::max(1, static_cast<int>(std::lround(1.0f / p.patch)));
    const int cells = cellsPerSource * tiles;
    std::vector<std::array<int, 2>> offsets(static_cast<size_t>(cells) * cells);
    for (int j = 0; j < cells; ++j)
        for (int i = 0; i < cells; ++i) {
            const uint64_t h = hash3(p.seed, static_cast<uint64_t>(i), static_cast<uint64_t>(j));
            offsets[static_cast<size_t>(j) * cells + i] = {static_cast<int>(h % static_cast<uint64_t>(s)),
                                                           static_cast<int>((h >> 32) % static_cast<uint64_t>(s))};
        }
    // Channels: albedo R, G, B and roughness (8-bit), height (16-bit), metalness (8-bit, optional).
    float lo = src.depth[0], hi = src.depth[0];
    for (float d : src.depth) { lo = std::min(lo, d); hi = std::max(hi, d); }
    const float span = hi - lo;
    std::vector<std::vector<uint32_t>> channels;
    std::vector<uint32_t> levels;
    for (int c = 0; c < 3; ++c) {
        std::vector<uint32_t> v(srcCount);
        for (size_t i = 0; i < srcCount; ++i) v[i] = src.albedo[i * 4 + c];
        channels.push_back(std::move(v)); levels.push_back(256);
    }
    channels.emplace_back(src.roughness.begin(), src.roughness.end()); levels.push_back(256);
    {
        std::vector<uint32_t> v(srcCount);
        for (size_t i = 0; i < srcCount; ++i) v[i] = span > 1e-9f ? static_cast<uint32_t>(std::lround(clamp01((src.depth[i] - lo) / span) * 65535.0f)) : 0;
        channels.push_back(std::move(v)); levels.push_back(65536);
    }
    const bool metal = !src.metalness.empty();
    if (metal) { channels.emplace_back(src.metalness.begin(), src.metalness.end()); levels.push_back(256); }
    std::vector<Gaussianizer> gauss;
    for (size_t c = 0; c < channels.size(); ++c) gauss.emplace_back(channels[c], levels[c], levels[c] == 65536 ? 65536u : 4096u);

    Material out;
    out.size = n;
    out.albedo.resize(count * 4);
    out.depth.resize(count);
    out.roughness.resize(count);
    if (metal) out.metalness.resize(count);
    const float cellSize = static_cast<float>(n) / static_cast<float>(cells);
    parallelRows(n, [&](int y0, int y1) {
        for (int y = y0; y < y1; ++y) {
            const float v = (static_cast<float>(y) + 0.5f) / cellSize;
            const int cj = static_cast<int>(v);
            const float fy = v - static_cast<float>(cj);
            for (int x = 0; x < n; ++x) {
                const float u = (static_cast<float>(x) + 0.5f) / cellSize;
                const int ci = static_cast<int>(u);
                const float fx = u - static_cast<float>(ci);
                int vi[3][2];
                float w[3];
                vi[0][0] = ci; vi[0][1] = cj; vi[2][0] = ci + 1; vi[2][1] = cj + 1;
                if (fx > fy) { vi[1][0] = ci + 1; vi[1][1] = cj; w[0] = 1 - fx; w[1] = fx - fy; w[2] = fy; }
                else { vi[1][0] = ci; vi[1][1] = cj + 1; w[0] = 1 - fy; w[1] = fy - fx; w[2] = fx; }
                float wsum = 0;
                for (float &k : w) { k = std::pow(std::max(k, 0.0f), p.sharpness); wsum += k; }
                float l2 = 0;
                for (float &k : w) { k /= wsum; l2 += k * k; }
                const float norm = 1.0f / std::sqrt(l2);
                size_t sample[3];
                for (int k = 0; k < 3; ++k) {
                    const auto &o = offsets[static_cast<size_t>(vi[k][1] % cells) * cells + vi[k][0] % cells];
                    sample[k] = static_cast<size_t>((y + o[1]) % s) * s + static_cast<size_t>((x + o[0]) % s);
                }
                const size_t i = static_cast<size_t>(y) * n + x;
                for (size_t c = 0; c < channels.size(); ++c) {
                    float g = 0;
                    for (int k = 0; k < 3; ++k) g += w[k] * gauss[c].forward[channels[c][sample[k]]];
                    const uint32_t level = gauss[c].invert(g * norm);
                    if (c < 3) out.albedo[i * 4 + c] = static_cast<uint8_t>(level);
                    else if (c == 3) out.roughness[i] = static_cast<uint8_t>(level);
                    else if (c == 4) out.depth[i] = lo + static_cast<float>(level) / 65535.0f * span;
                    else out.metalness[i] = static_cast<uint8_t>(level);
                }
                float alpha = 0;
                for (int k = 0; k < 3; ++k) alpha += w[k] * static_cast<float>(src.albedo[sample[k] * 4 + 3]);
                out.albedo[i * 4 + 3] = static_cast<uint8_t>(std::lround(std::clamp(alpha, 0.0f, 255.0f)));
            }
        }
    });
    return out;
}

template <typename F> PBRLabResult *guarded(char *error, size_t capacity, F &&body) {
    setError(error, capacity, "");
    try { return body(); }
    catch (const std::bad_alloc &) { setError(error, capacity, "out of memory"); }
    catch (const std::exception &e) { setError(error, capacity, e.what()); }
    return nullptr;
}

} // namespace

extern "C" PBRLabLayerParams PBRLabDefaultLayerParams(PBRLabLayerMaskKind mask) {
    PBRLabLayerParams p{};
    p.mask = mask;
    p.threshold = mask == PBRLabLayerMaskSlope ? 0.25f : 0.5f;
    p.softness = mask == PBRLabLayerMaskImage ? 0.5f : 0.1f;
    p.seed = 1;
    p.noise_scale = 4;
    p.noise_contrast = 1;
    p.height_blend = 0.5f;
    return p;
}

extern "C" int PBRLabLayerWeights(const PBRLabMaterialMaps *base, const PBRLabMaterialMaps *top,
                                  const PBRLabLayerParams *params, uint8_t *out_r8, size_t out_row_bytes,
                                  char *error, size_t error_capacity) {
    setError(error, error_capacity, "");
    try {
        checkLayerParams(params);
        const Material b = load(base, false);
        if (!out_r8 || out_row_bytes < static_cast<size_t>(b.size)) throw std::runtime_error("output buffer is too small");
        Material t;
        if (top) t = resampled(load(top, false), b.size);
        const auto w = layerWeights(b, top ? &t : nullptr, *params);
        for (int y = 0; y < b.size; ++y)
            for (int x = 0; x < b.size; ++x) out_r8[static_cast<size_t>(y) * out_row_bytes + x] = byteOf(w[static_cast<size_t>(y) * b.size + x]);
        return 1;
    } catch (const std::exception &e) {
        setError(error, error_capacity, e.what());
        return 0;
    }
}

extern "C" PBRLabResult *PBRLabLayerMaterials(const PBRLabMaterialMaps *base, const PBRLabMaterialMaps *top,
                                              const PBRLabLayerParams *params, const PBRLabRecipe *shading,
                                              PBRLabRecipe *out_recipe, char *error, size_t error_capacity) {
    return guarded(error, error_capacity, [&]() -> PBRLabResult * {
        checkLayerParams(params);
        checkShading(shading);
        const bool rnb = params->normal_blend == 1;
        const Material b = load(base, rnb);
        const Material t = resampled(load(top, rnb), b.size);
        if (rnb && (b.normals.empty() || t.normals.empty()))
            throw std::runtime_error("the reoriented-normal blend needs the normal maps of both materials");
        const auto w = layerWeights(b, &t, *params);
        const size_t count = static_cast<size_t>(b.size) * b.size;
        const auto &lut = linearLUT();
        float bLow = b.depth[0], tLow = t.depth[0];
        for (float d : b.depth) bLow = std::min(bLow, d);
        for (float d : t.depth) tLow = std::min(tLow, d);
        Material out;
        out.size = b.size;
        out.albedo.resize(count * 4);
        out.depth.resize(count);
        out.roughness.resize(count);
        const bool metal = !b.metalness.empty() || !t.metalness.empty();
        if (metal) out.metalness.resize(count);
        if (rnb) out.normals.resize(count * 3);
        for (size_t i = 0; i < count; ++i) {
            const float k = w[i];
            for (int c = 0; c < 3; ++c)
                out.albedo[i * 4 + c] = linearToSRGB(lut[b.albedo[i * 4 + c]] * (1 - k) + lut[t.albedo[i * 4 + c]] * k);
            out.albedo[i * 4 + 3] = byteOf((b.albedo[i * 4 + 3] * (1 - k) + t.albedo[i * 4 + 3] * k) / 255.0f);
            out.roughness[i] = byteOf((b.roughness[i] * (1 - k) + t.roughness[i] * k) / 255.0f);
            if (metal) {
                const float mb = b.metalness.empty() ? 0.0f : b.metalness[i], mt = t.metalness.empty() ? 0.0f : t.metalness[i];
                out.metalness[i] = byteOf((mb * (1 - k) + mt * k) / 255.0f);
            }
            out.depth[i] = (b.depth[i] - bLow) * (1 - k) + (t.depth[i] - tLow) * k;
            if (rnb) {
                float r[3];
                reorientedBlend(&b.normals[i * 3], &t.normals[i * 3], r);
                float v[3];
                for (int c = 0; c < 3; ++c) v[c] = b.normals[i * 3 + c] * (1 - k) + r[c] * k;
                const float len = std::max(1e-6f, std::sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]));
                for (int c = 0; c < 3; ++c) out.normals[i * 3 + c] = v[c] / len;
            }
        }
        return rederive(out, *shading, out_recipe);
    });
}

extern "C" PBRLabVariantParams PBRLabDefaultVariantParams(uint32_t seed) {
    PBRLabVariantParams p{};
    p.seed = seed;
    p.hue_degrees = 6;
    p.saturation = 0.08f;
    p.value = 0.06f;
    p.roughness = 0.05f;
    p.relief = 0.15f;
    p.offset = 1;
    p.rotation = 0;
    return p;
}

extern "C" PBRLabResult *PBRLabMakeVariant(const PBRLabMaterialMaps *material, const PBRLabVariantParams *params,
                                           const PBRLabRecipe *shading, PBRLabVariantInfo *out_info,
                                           PBRLabRecipe *out_recipe, char *error, size_t error_capacity) {
    return guarded(error, error_capacity, [&]() -> PBRLabResult * {
        checkShading(shading);
        if (!params) throw std::runtime_error("variant parameters are required");
        auto in = [](float v, float hi) { return std::isfinite(v) && v >= 0 && v <= hi; };
        if (!in(params->hue_degrees, 180) || !in(params->saturation, 0.5f) || !in(params->value, 0.5f) ||
            !in(params->roughness, 0.5f) || !in(params->relief, 0.9f))
            throw std::runtime_error("variant amounts out of range (hue 0..180, saturation/value/roughness 0..0.5, relief 0..0.9)");
        const Material src = load(material, false);
        const int n = src.size;
        const size_t count = static_cast<size_t>(n) * n;
        // Fixed draw order, so a seed means the same variant whichever options are enabled.
        Random random(params->seed);
        PBRLabVariantInfo info{};
        info.hue_degrees = random.symmetric() * params->hue_degrees;
        info.saturation_scale = 1 + random.symmetric() * params->saturation;
        info.value_scale = 1 + random.symmetric() * params->value;
        info.roughness_offset = random.symmetric() * params->roughness;
        info.relief_scale = 1 + random.symmetric() * params->relief;
        const uint32_t ox = static_cast<uint32_t>(random.next() % static_cast<uint64_t>(n));
        const uint32_t oy = static_cast<uint32_t>(random.next() % static_cast<uint64_t>(n));
        const uint32_t turns = static_cast<uint32_t>(random.next() % 4), mirror = static_cast<uint32_t>(random.next() % 2);
        if (params->offset && shading->tile_wrap) { info.offset_x = ox; info.offset_y = oy; }
        if (params->rotation) { info.quarter_turns = turns; info.mirrored = mirror; }
        // Hue: rotation of the chroma about the grey axis (Rodrigues), in linear light; then chroma and value scales.
        const float angle = info.hue_degrees * std::numbers::pi_v<float> / 180.0f;
        const float cs = std::cos(angle), sn = std::sin(angle), k = (1 - cs) / 3, r3 = sn / std::sqrt(3.0f);
        const float rot[3][3] = {{cs + k, k - r3, k + r3}, {k + r3, cs + k, k - r3}, {k - r3, k + r3, cs + k}};
        const auto &lut = linearLUT();
        Material shifted = src;
        for (size_t i = 0; i < count; ++i) {
            float rgb[3] = {lut[src.albedo[i * 4]], lut[src.albedo[i * 4 + 1]], lut[src.albedo[i * 4 + 2]]};
            const float grey = (rgb[0] + rgb[1] + rgb[2]) / 3;
            float rotated[3];
            for (int r = 0; r < 3; ++r) rotated[r] = rot[r][0] * rgb[0] + rot[r][1] * rgb[1] + rot[r][2] * rgb[2];
            for (int c = 0; c < 3; ++c)
                shifted.albedo[i * 4 + c] = linearToSRGB((grey + (rotated[c] - grey) * info.saturation_scale) * info.value_scale);
            shifted.roughness[i] = byteOf(src.roughness[i] / 255.0f + info.roughness_offset);
            shifted.depth[i] = src.depth[i] * info.relief_scale;
        }
        // Spatial transform, the same for every map: mirror, quarter turns, then offset.
        Material out = shifted;
        if (info.offset_x || info.offset_y || info.quarter_turns || info.mirrored) {
            for (int y = 0; y < n; ++y)
                for (int x = 0; x < n; ++x) {
                    int sx = (x + static_cast<int>(info.offset_x)) % n, sy = (y + static_cast<int>(info.offset_y)) % n;
                    for (uint32_t t = 0; t < info.quarter_turns; ++t) { const int tx = sy, ty = n - 1 - sx; sx = tx; sy = ty; }
                    if (info.mirrored) sx = n - 1 - sx;
                    const size_t d = static_cast<size_t>(y) * n + x, s = static_cast<size_t>(sy) * n + sx;
                    std::memcpy(&out.albedo[d * 4], &shifted.albedo[s * 4], 4);
                    out.depth[d] = shifted.depth[s];
                    out.roughness[d] = shifted.roughness[s];
                    if (!out.metalness.empty()) out.metalness[d] = shifted.metalness[s];
                }
        }
        if (out_info) *out_info = info;
        return rederive(out, *shading, out_recipe);
    });
}

extern "C" PBRLabLargeTileParams PBRLabDefaultLargeTileParams(uint32_t tiles, uint32_t seed) {
    PBRLabLargeTileParams p{};
    p.tiles = tiles;
    p.seed = seed;
    p.patch = 0.5f;
    p.sharpness = 4;
    return p;
}

extern "C" PBRLabResult *PBRLabMakeLargeTile(const PBRLabMaterialMaps *material, const PBRLabLargeTileParams *params,
                                             const PBRLabRecipe *shading, PBRLabRecipe *out_recipe,
                                             char *error, size_t error_capacity) {
    return guarded(error, error_capacity, [&]() -> PBRLabResult * {
        checkShading(shading);
        if (!params || (params->tiles != 2 && params->tiles != 4)) throw std::runtime_error("large tiles are 2 or 4 tiles across");
        if (!std::isfinite(params->patch) || params->patch < 0.125f || params->patch > 1 ||
            !std::isfinite(params->sharpness) || params->sharpness < 1 || params->sharpness > 16)
            throw std::runtime_error("patch must be 0.125..1 and sharpness 1..16");
        if (!shading->tile_wrap) throw std::runtime_error("a larger tile needs a tileable material (tile_wrap)");
        if (!material || material->size * params->tiles > kMaxSize)
            throw std::runtime_error("the larger tile would exceed 8192 pixels");
        Material big = largeTile(load(material, false), *params);
        // Depth stays physical: in tile widths of the larger tile it is `tiles` times smaller.
        for (auto &d : big.depth) d /= static_cast<float>(params->tiles);
        PBRLabRecipe recipe = *shading;
        recipe.ao_radius_pixels = shading->ao_radius_pixels / static_cast<float>(params->tiles);
        recipe.tile_metres = std::min(64.0f, shading->tile_metres * static_cast<float>(params->tiles));
        return rederive(big, recipe, out_recipe);
    });
}

extern "C" int PBRLabMeasuredDepthToGuideNormals(const uint8_t *depth_r16, size_t depth_row_bytes, uint32_t size,
                                                 float depth_span_tile_widths, uint8_t *out_rgba8, size_t out_row_bytes,
                                                 char *error, size_t error_capacity) {
    setError(error, error_capacity, "");
    if (!depth_r16 || !out_rgba8 || size < 3 || size > kMaxSize || depth_row_bytes < static_cast<size_t>(size) * 2 ||
        out_row_bytes < static_cast<size_t>(size) * 4 || !std::isfinite(depth_span_tile_widths) || depth_span_tile_widths <= 0 ||
        depth_span_tile_widths > 64) {
        setError(error, error_capacity, "depth map must be 3..8192 square with a positive depth span");
        return 0;
    }
    const int n = static_cast<int>(size);
    const size_t count = static_cast<size_t>(n) * n;
    // Depth in pixels of the tile, centred coordinates for a well-conditioned plane fit.
    std::vector<double> d(count);
    const double toPixels = static_cast<double>(depth_span_tile_widths) * n / 65535.0;
    for (int y = 0; y < n; ++y) {
        const uint8_t *row = depth_r16 + static_cast<size_t>(y) * depth_row_bytes;
        for (int x = 0; x < n; ++x) d[static_cast<size_t>(y) * n + x] = static_cast<double>(row[x * 2] | (row[x * 2 + 1] << 8)) * toPixels;
    }
    // Least-squares plane d = a x + b y + c over a symmetric grid: x and y are uncorrelated, so a and b separate.
    const double mid = (n - 1) / 2.0;
    double sxd = 0, syd = 0, sxx = 0;
    for (int y = 0; y < n; ++y)
        for (int x = 0; x < n; ++x) {
            const double v = d[static_cast<size_t>(y) * n + x];
            sxd += (x - mid) * v; syd += (y - mid) * v; sxx += (x - mid) * (x - mid);
        }
    const double a = sxd / sxx, b = syd / sxx;
    for (int y = 0; y < n; ++y)
        for (int x = 0; x < n; ++x) d[static_cast<size_t>(y) * n + x] -= a * (x - mid) + b * (y - mid);
    for (int y = 0; y < n; ++y)
        for (int x = 0; x < n; ++x) {
            auto at = [&](int xx, int yy) { return d[static_cast<size_t>(std::clamp(yy, 0, n - 1)) * n + std::clamp(xx, 0, n - 1)]; };
            const int xl = std::max(x - 1, 0), xr = std::min(x + 1, n - 1), yt = std::max(y - 1, 0), yb = std::min(y + 1, n - 1);
            const double gx = (at(xr, y) - at(xl, y)) / (xr - xl), gy = (at(x, yb) - at(x, yt)) / (yb - yt);
            // +Y (green-up): a surface rising towards the bottom of the image faces up.
            const double nx = -gx, ny = gy, len = std::sqrt(nx * nx + ny * ny + 1);
            uint8_t *p = out_rgba8 + static_cast<size_t>(y) * out_row_bytes + static_cast<size_t>(x) * 4;
            p[0] = static_cast<uint8_t>(std::lround(std::clamp((nx / len + 1) * 127.5, 0.0, 255.0)));
            p[1] = static_cast<uint8_t>(std::lround(std::clamp((ny / len + 1) * 127.5, 0.0, 255.0)));
            p[2] = static_cast<uint8_t>(std::lround(std::clamp((1 / len + 1) * 127.5, 0.0, 255.0)));
            p[3] = 255;
        }
    return 1;
}

extern "C" int PBRLabSplitGuideBands(const uint8_t *measured_rgba8, const uint8_t *learned_rgba8, size_t row_bytes,
                                     uint32_t size, uint32_t cutoff_pixels, uint8_t *out_rgba8, size_t out_row_bytes) {
    if (!measured_rgba8 || !learned_rgba8 || !out_rgba8 || size < 2 || size > kMaxSize ||
        row_bytes < static_cast<size_t>(size) * 4 || out_row_bytes < static_cast<size_t>(size) * 4)
        return 0;
    // A port of Material Capture's DepthStack.splitBands (apps/ios), so CLI and iPhone combine guides alike.
    const int n = static_cast<int>(size);
    const int radius = cutoff_pixels ? static_cast<int>(cutoff_pixels) : std::max(2, n / 64);
    const size_t count = static_cast<size_t>(n) * n;
    auto slopes = [&](const uint8_t *rgba, std::vector<float> &gx, std::vector<float> &gy) {
        gx.resize(count); gy.resize(count);
        for (int y = 0; y < n; ++y)
            for (int x = 0; x < n; ++x) {
                const uint8_t *p = rgba + static_cast<size_t>(y) * row_bytes + static_cast<size_t>(x) * 4;
                const float nx = p[0] / 127.5f - 1, ny = p[1] / 127.5f - 1, nz = std::max(p[2] / 127.5f - 1, 0.15f);
                gx[static_cast<size_t>(y) * n + x] = -nx / nz;
                gy[static_cast<size_t>(y) * n + x] = ny / nz;
            }
    };
    auto blur = [&](const std::vector<float> &values) {
        // Three passes of a separable box blur, clamped at the edges (as DepthStack.blur).
        std::vector<float> current = values, temp = values;
        for (int pass = 0; pass < 3; ++pass) {
            for (int y = 0; y < n; ++y) {
                float sum = 0;
                for (int k = -radius; k <= radius; ++k) sum += current[static_cast<size_t>(y) * n + std::clamp(k, 0, n - 1)];
                for (int x = 0; x < n; ++x) {
                    temp[static_cast<size_t>(y) * n + x] = sum / static_cast<float>(2 * radius + 1);
                    sum += current[static_cast<size_t>(y) * n + std::min(n - 1, x + radius + 1)] - current[static_cast<size_t>(y) * n + std::max(0, x - radius)];
                }
            }
            for (int x = 0; x < n; ++x) {
                float sum = 0;
                for (int k = -radius; k <= radius; ++k) sum += temp[static_cast<size_t>(std::clamp(k, 0, n - 1)) * n + x];
                for (int y = 0; y < n; ++y) {
                    current[static_cast<size_t>(y) * n + x] = sum / static_cast<float>(2 * radius + 1);
                    sum += temp[static_cast<size_t>(std::min(n - 1, y + radius + 1)) * n + x] - temp[static_cast<size_t>(std::max(0, y - radius)) * n + x];
                }
            }
        }
        return current;
    };
    std::vector<float> mx, my, lx, ly;
    slopes(measured_rgba8, mx, my);
    slopes(learned_rgba8, lx, ly);
    const auto lowX = blur(lx), lowY = blur(ly);
    for (int y = 0; y < n; ++y)
        for (int x = 0; x < n; ++x) {
            const size_t i = static_cast<size_t>(y) * n + x;
            const float gx = mx[i] + lx[i] - lowX[i], gy = my[i] + ly[i] - lowY[i];
            const float len = std::sqrt(gx * gx + gy * gy + 1);
            uint8_t *p = out_rgba8 + static_cast<size_t>(y) * out_row_bytes + static_cast<size_t>(x) * 4;
            auto encode = [](float v) { return static_cast<uint8_t>(std::max(0.0f, std::min(255.0f, std::round((v + 1) * 127.5f)))); };
            p[0] = encode(-gx / len); p[1] = encode(gy / len); p[2] = encode(1 / len); p[3] = 255;
        }
    return 1;
}
