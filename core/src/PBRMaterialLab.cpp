#include "PBRMaterialLab.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstring>
#include <limits>
#include <memory>
#include <new>
#include <numbers>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {
constexpr unsigned kMapCount = 11;
constexpr std::array<float, 3> kLinearLuminance{0.2126f, 0.7152f, 0.0722f};
// Pixel-space height of a unit normalized height step as seen by the tangent normal (1.0.0 response).
constexpr float kNormalDepthPixels = 8.0f;
// Spatial scales are defined at this reference size and scaled with the tile (1.3.0).
constexpr float kReferenceSize = 1024.0f;
constexpr float kLogLuminanceFloor = 0.01f;   // Linear luminance floor of the log relief cue (about sRGB 25/255).
constexpr float kDefaultHeightStrength = 0.22f;
constexpr float kDefaultRepairBand = 0.12f;     // Albedo repair band per edge (fraction of the tile) when unset.
constexpr float kAutoCutCostRatio = 4.0f;      // Auto repair: keep the quilt unless its cut is this many times more
                                                // visible than ordinary neighbouring pixels, else blend.
// Learned-geometry frequency split, in reference pixels of box-equivalent radius (Gaussian sigma = radius/sqrt 3).
constexpr float kCrossoverPixels = 5.2f;       // sigma 3 px: below it detail comes from the albedo bands.
constexpr float kFormCutFraction = 0.0866f;    // sigma = tile/20: longer wavelengths are estimator bias (bowls, tilt)
                                               // or composition, and would repeat visibly when tiled.
constexpr float kCorrelationLow = 5.2f, kCorrelationHigh = 13.9f; // sigma 3..8 px band used to orient detail.
constexpr double kPolarityConfidence = 0.1;    // |correlation| needed before the learned field sets the detail sign.
constexpr double kFormGain = 3.0;              // Learned form share = gain x learned rms slope / target, capped.
constexpr double kMaxFormShare = 0.7;
constexpr float kAOExaggeration = 3.0f;        // GTAO depth relative to the normal-map surface at ao_strength 1.
constexpr float kCavityGain = 1.5f;            // Curvature (reference pixels of depth) to cavity/convexity.
constexpr float kRoughnessSpread = 0.25f;      // Roughness standard deviation at roughness_variation 1.
constexpr float kRoughnessCavityWeight = 0.45f, kRoughnessContrastWeight = 0.35f, kRoughnessFacetWeight = 0.3f;
constexpr int kAOSlices = 8;        // Two-sided slices: 16 horizon directions.
constexpr int kAOStepsPerSide = 8;

float clamp01(float v) { return std::clamp(v, 0.0f, 1.0f); }
int wrap(int x, int n) { x %= n; return x < 0 ? x + n : x; }
int wrap_index(int x, int n) { return wrap(x, n); }
int border(int x, int n, bool tiled) { return tiled ? wrap(x, n) : std::clamp(x, 0, n - 1); }
size_t at(int x, int y, int width) { return static_cast<size_t>(y) * width + x; }
uint8_t byte(float v) { return static_cast<uint8_t>(std::lround(clamp01(v) * 255.0f)); }
float linear(uint8_t s) {
    float v = static_cast<float>(s) / 255.0f;
    return v <= 0.04045f ? v / 12.92f : std::pow((v + 0.055f) / 1.055f, 2.4f);
}
uint8_t srgbByte(float linearValue) {
    float v = clamp01(linearValue);
    v = v <= 0.0031308f ? v * 12.92f : 1.055f * std::pow(v, 1.0f / 2.4f) - 0.055f;
    return byte(v);
}
// Polynomial acos (Abramowitz & Stegun 4.4.45), |error| < 7e-5 rad. Only used for the angle-linear term
// of the GTAO integral; every cosine/sine is derived exactly with angle-addition identities.
float fastAcos(float x) {
    float a = std::abs(x);
    float r = std::sqrt(std::max(0.0f, 1.0f - a)) * (1.5707288f + a * (-0.2121144f + a * (0.0742610f - 0.0187293f * a)));
    return x < 0 ? std::numbers::pi_v<float> - r : r;
}
float smoothstep01(float t) { t = clamp01(t); return t * t * (3.0f - 2.0f * t); }
void setError(char *error, size_t capacity, const char *message) {
    if (!error || !capacity) return;
    std::strncpy(error, message, capacity - 1);
    error[capacity - 1] = '\0';
}
void checkpoint(PBRLabProgressCallback callback, void *context, float progress) {
    if (callback && !callback(progress, context)) throw std::runtime_error("cancelled");
}

// Runs body(y0, y1) over row bands on worker threads plus the calling thread. Only the calling thread
// reports progress, so the public callback contract is unchanged. Bodies must not throw; each row is
// written by exactly one thread and results are identical to a serial run.
template <typename Body>
void parallelRows(int rows, Body &&body, PBRLabProgressCallback callback, void *context,
                  float progressBegin, float progressEnd) {
    const int kBand = rows >= 256 ? 8 : 1;
    std::atomic<int> next{0}, done{0};
    std::atomic<bool> cancelled{false};
    auto drain = [&](bool reports) {
        while (!cancelled.load(std::memory_order_relaxed)) {
            int y0 = next.fetch_add(kBand, std::memory_order_relaxed);
            if (y0 >= rows) break;
            int y1 = std::min(rows, y0 + kBand);
            body(y0, y1);
            int finished = done.fetch_add(y1 - y0, std::memory_order_relaxed) + (y1 - y0);
            if (reports && callback) {
                float t = static_cast<float>(finished) / static_cast<float>(rows);
                if (!callback(progressBegin + (progressEnd - progressBegin) * t, context))
                    cancelled.store(true, std::memory_order_relaxed);
            }
        }
    };
    unsigned hardware = std::max(1u, std::thread::hardware_concurrency());
    int helpers = std::min(static_cast<int>(std::min(hardware, 16u)) - 1, rows / (kBand * 2));
    std::vector<std::thread> workers;
    workers.reserve(static_cast<size_t>(std::max(helpers, 0)));
    for (int t = 0; t < helpers; ++t) {
        try { workers.emplace_back(drain, false); } catch (...) { break; } // Fewer threads is still correct.
    }
    drain(true);
    for (auto &worker : workers) worker.join();
    if (cancelled.load()) throw std::runtime_error("cancelled");
}

struct StoredMap {
    std::vector<uint8_t> data;
    PBRLabPixelFormat format = PBRLabPixelFormatRGBA8Linear;
    size_t rowBytes = 0;
};

// One sliding-window box pass per axis; exact for any radius, including radius >= size. The vertical
// pass walks rows with per-column running sums so memory access stays sequential. Columns and rows
// are summed in a fixed order, so threaded results are identical to a serial run.
std::vector<float> boxBlur(const std::vector<float> &src, int width, int height, int radius, bool tiled) {
    if (radius <= 0) return src;
    std::vector<float> horizontal(src.size()), output(src.size());
    const float divisor = 1.0f / static_cast<float>(2 * radius + 1);
    parallelRows(height, [&](int y0, int y1) {
        for (int y = y0; y < y1; ++y) {
            const float *row = &src[at(0, y, width)];
            float *out = &horizontal[at(0, y, width)];
            double sum = 0;
            for (int d = -radius; d <= radius; ++d) sum += row[border(d, width, tiled)];
            for (int x = 0; x < width; ++x) {
                out[x] = static_cast<float>(sum) * divisor;
                sum += row[border(x + radius + 1, width, tiled)] - row[border(x - radius, width, tiled)];
            }
        }
    }, nullptr, nullptr, 0, 0);
    constexpr int kColumnBlock = 64;
    const int blocks = (width + kColumnBlock - 1) / kColumnBlock;
    parallelRows(blocks, [&](int b0, int b1) {
        std::vector<double> sums(kColumnBlock);
        for (int b = b0; b < b1; ++b) {
            const int x0 = b * kColumnBlock, x1 = std::min(width, x0 + kColumnBlock), span = x1 - x0;
            std::fill(sums.begin(), sums.end(), 0.0);
            for (int d = -radius; d <= radius; ++d) {
                const float *row = &horizontal[at(x0, border(d, height, tiled), width)];
                for (int c = 0; c < span; ++c) sums[c] += row[c];
            }
            for (int y = 0; y < height; ++y) {
                float *out = &output[at(x0, y, width)];
                const float *add = &horizontal[at(x0, border(y + radius + 1, height, tiled), width)];
                const float *sub = &horizontal[at(x0, border(y - radius, height, tiled), width)];
                for (int c = 0; c < span; ++c) {
                    out[c] = static_cast<float>(sums[c]) * divisor;
                    sums[c] += add[c] - sub[c];
                }
            }
        }
    }, nullptr, nullptr, 0, 0);
    return output;
}
// Three box passes approximate a Gaussian with the same variance as a single box of `radius`, which
// removes the ringing and square artifacts a single box band-pass leaves in pseudo-height.
std::vector<float> smoothBlur(const std::vector<float> &src, int width, int height, int radius, bool tiled) {
    if (radius <= 0) return src;
    int pass = std::max(1, static_cast<int>(std::lround(static_cast<float>(radius) / std::numbers::sqrt3_v<float>)));
    auto out = boxBlur(src, width, height, pass, tiled);
    out = boxBlur(out, width, height, pass, tiled);
    return boxBlur(out, width, height, pass, tiled);
}
void putGray(std::vector<uint8_t> &target, size_t i, float value) {
    auto v = byte(value);
    target[i * 4] = v; target[i * 4 + 1] = v; target[i * 4 + 2] = v; target[i * 4 + 3] = 255;
}
void putNormal(std::vector<uint8_t> &target, size_t i, float x, float y, float z) {
    float inv = 1.0f / std::sqrt(x * x + y * y + z * z);
    target[i * 4] = byte(0.5f * (x * inv + 1));
    target[i * 4 + 1] = byte(0.5f * (y * inv + 1));
    target[i * 4 + 2] = byte(0.5f * (z * inv + 1));
    target[i * 4 + 3] = 255;
}
float presetSignal(PBRLabPreset preset, float high, float mid, float coarse) {
    switch (preset) {
    case PBRLabPresetStone: return high * 1.0f + mid * 1.2f + coarse * 0.7f;
    case PBRLabPresetFabric: return high * 1.75f + mid * 0.45f;
    case PBRLabPresetOrganic: return high * 1.0f + mid * 1.2f + coarse * 0.8f;
    case PBRLabPresetCoatedMetal: return high * 0.6f + mid * 0.5f + coarse * 0.15f;
    case PBRLabPresetBareMetal: return high * 0.9f + mid * 0.6f;
    case PBRLabPresetFlat: return 0;
    }
    return 0;
}
// Target rms surface slope (tangent) of inferred relief at the default height strength. Stone at 0.3 reads as
// weathered rock at texel scale; coatings and bare metal stay near flat.
float reliefTarget(PBRLabPreset preset) {
    switch (preset) {
    case PBRLabPresetStone: return .3f;
    case PBRLabPresetFabric: return .2f;
    case PBRLabPresetOrganic: return .26f;
    case PBRLabPresetCoatedMetal: return .12f;
    case PBRLabPresetBareMetal: return .09f;
    case PBRLabPresetFlat: return 0;
    }
    return 0;
}
// Physical perceptual-roughness range a preset's variation may reach (the prior itself is always allowed).
std::array<float, 2> roughnessRange(PBRLabPreset preset) {
    switch (preset) {
    case PBRLabPresetStone: return {.45f, .98f};
    case PBRLabPresetFabric: return {.6f, 1.0f};
    case PBRLabPresetOrganic: return {.35f, .95f};
    case PBRLabPresetCoatedMetal: return {.15f, .75f};
    case PBRLabPresetBareMetal: return {.08f, .6f};
    case PBRLabPresetFlat: return {0.0f, 1.0f};
    }
    return {0.0f, 1.0f};
}
// Root-mean-square Scharr gradient magnitude, summed in a fixed order (deterministic).
double rmsSlope(const std::vector<float> &h, int width, int height, bool tiled) {
    double sum = 0;
    for (int y = 0; y < height; ++y) {
        double row = 0;
        for (int x = 0; x < width; ++x) {
            auto H = [&](int xx, int yy) { return h[at(border(xx, width, tiled), border(yy, height, tiled), width)]; };
            float hx = (3.0f * (H(x + 1, y - 1) + H(x + 1, y + 1)) + 10.0f * H(x + 1, y) - 3.0f * (H(x - 1, y - 1) + H(x - 1, y + 1)) - 10.0f * H(x - 1, y)) / 32.0f;
            float hy = (3.0f * (H(x - 1, y + 1) + H(x + 1, y + 1)) + 10.0f * H(x, y + 1) - 3.0f * (H(x - 1, y - 1) + H(x + 1, y - 1)) - 10.0f * H(x, y - 1)) / 32.0f;
            row += static_cast<double>(hx) * hx + static_cast<double>(hy) * hy;
        }
        sum += row;
    }
    return std::sqrt(sum / (static_cast<double>(width) * height));
}
bool valid(const PBRLabInput *in, const PBRLabRecipe *r, std::string &why) {
    if (!in || !r || !in->rgba8) { why = "input, recipe, and RGBA buffer are required"; return false; }
    if (in->width < 2 || in->width > 4096 || in->height != in->width) {
        why = "input must be square, 2..4096 pixels"; return false;
    }
    if (in->rgba_row_bytes < static_cast<size_t>(in->width) * 4 ||
        (in->relief_mask_r8 && in->relief_mask_row_bytes < in->width) ||
        (in->height_override_r16 && in->height_override_row_bytes < static_cast<size_t>(in->width) * 2)) {
        why = "input row stride is too short"; return false;
    }
    if (in->guide_normal_rgba8 && in->guide_normal_row_bytes < static_cast<size_t>(in->width) * 4) {
        why = "guide normal row stride is too short"; return false;
    }
    if ((in->authored_normal_rgba8 && in->authored_normal_row_bytes < static_cast<size_t>(in->width) * 4) ||
        (in->authored_roughness_r8 && in->authored_roughness_row_bytes < in->width) ||
        (in->authored_ao_r8 && in->authored_ao_row_bytes < in->width) ||
        (in->authored_metalness_r8 && in->authored_metalness_row_bytes < in->width)) {
        why = "authored map row stride is too short"; return false;
    }
    if (in->authored_metalness_r8 && r && !r->assigned_metalness_enabled) {
        why = "an authored metalness map needs assigned metalness enabled"; return false;
    }
    auto in01 = [](float v, float hi) { return std::isfinite(v) && v >= 0 && v <= hi; };
    if (r->preset < PBRLabPresetFlat || r->preset > PBRLabPresetBareMetal ||
        !in01(r->height_strength, .5f) ||
        (r->height_polarity != 1 && r->height_polarity != -1) ||
        !in01(r->roughness_base, 1) || !in01(r->roughness_variation, 1) ||
        !in01(r->ao_radius_pixels, 64) || !in01(r->assigned_metalness, 1) ||
        !in01(r->normal_strength, 16) || !in01(r->ao_strength, 4) ||
        !in01(r->albedo_equalize, 1) || !in01(r->seamless_blend, .45f) ||
        !in01(r->guide_normal_weight, 1) || r->seamless_mode > 1 || r->albedo_repair > 3) {
        why = "recipe contains an invalid preset or out-of-range parameter"; return false;
    }
    return true;
}

// Per-channel transform between linear values and a standard normal variable, from the empirical CDF.
// 16384 bins store their mean value, so unblended values round-trip exactly when a bin holds one level.
float inverseNormalCDF(double p) {
    // Acklam's rational approximation, |relative error| < 1.2e-9.
    static constexpr double a[] = {-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02,
                                   1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00};
    static constexpr double b[] = {-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02,
                                   6.680131188771972e+01, -1.328068155288572e+01};
    static constexpr double c[] = {-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00,
                                   -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00};
    static constexpr double d[] = {7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00,
                                   3.754408661907416e+00};
    constexpr double low = 0.02425;
    if (p < low) {
        double q = std::sqrt(-2 * std::log(p));
        return static_cast<float>((((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
                                  ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1));
    }
    if (p > 1 - low) {
        double q = std::sqrt(-2 * std::log(1 - p));
        return static_cast<float>(-(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5]) /
                                  ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1));
    }
    double q = p - 0.5, r = q * q;
    return static_cast<float>((((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q /
                              (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1));
}
struct HistogramTransform {
    static constexpr int kBins = 16384;
    std::vector<float> gaussOfBin = std::vector<float>(kBins);
    std::vector<float> knotGauss, knotValue;           // Monotonic knots over occupied bins.
    static int bin(float v) { return std::clamp(static_cast<int>(v * kBins), 0, kBins - 1); }
    void build(const std::vector<float> &rgb, int channel, size_t count) {
        std::vector<uint32_t> counts(kBins);
        std::vector<double> sums(kBins);
        for (size_t i = 0; i < count; ++i) {
            float v = rgb[i * 3 + channel];
            int k = bin(v);
            ++counts[k]; sums[k] += v;
        }
        double before = 0;
        for (int k = 0; k < kBins; ++k) {
            if (!counts[k]) continue;
            double center = (before + counts[k] * 0.5) / static_cast<double>(count);
            gaussOfBin[k] = inverseNormalCDF(center);
            knotGauss.push_back(gaussOfBin[k]);
            knotValue.push_back(static_cast<float>(sums[k] / counts[k]));
            before += counts[k];
        }
    }
    float forward(float v) const { return gaussOfBin[bin(v)]; }
    float inverse(float g) const {
        auto upper = std::lower_bound(knotGauss.begin(), knotGauss.end(), g);
        if (upper == knotGauss.begin()) return knotValue.front();
        if (upper == knotGauss.end()) return knotValue.back();
        size_t k = static_cast<size_t>(upper - knotGauss.begin());
        float t = (g - knotGauss[k - 1]) / std::max(knotGauss[k] - knotGauss[k - 1], 1e-12f);
        return knotValue[k - 1] + (knotValue[k] - knotValue[k - 1]) * t;
    }
};

// Deterministic multigrid Poisson solver for L h = f on a cell-centered grid (5-point Laplacian).
// Periodic boundaries when tiled, Neumann (mirrored ghost cells) otherwise. The right-hand side must
// have zero mean; the solution is returned with zero mean. Damped Jacobi keeps results independent
// of thread scheduling.
class PoissonSolver {
public:
    PoissonSolver(bool tiled) : tiled_(tiled) {}
    std::vector<float> solve(const std::vector<float> &f, int width, int height, int cycles) {
        std::vector<float> h(f.size(), 0.0f);
        for (int c = 0; c < cycles; ++c) vCycle(h, f, width, height, 1.0f);
        double mean = 0;
        for (float v : h) mean += v;
        mean /= static_cast<double>(h.size());
        for (auto &v : h) v -= static_cast<float>(mean);
        return h;
    }
private:
    bool tiled_;
    template <typename Body> void rows(int count, int width, Body &&body) {
        if (static_cast<size_t>(count) * width >= 65536) parallelRows(count, body, nullptr, nullptr, 0, 0);
        else body(0, count);
    }
    float sample(const std::vector<float> &g, int x, int y, int w, int h) const {
        return g[at(border(x, w, tiled_), border(y, h, tiled_), w)];
    }
    void smooth(std::vector<float> &h, const std::vector<float> &f, int w, int ht, float spacing2, int sweeps) {
        std::vector<float> next(h.size());
        for (int s = 0; s < sweeps; ++s) {
            rows(ht, w, [&](int y0, int y1) {
                for (int y = y0; y < y1; ++y) for (int x = 0; x < w; ++x) {
                    size_t i = at(x, y, w);
                    float neighbors = sample(h, x - 1, y, w, ht) + sample(h, x + 1, y, w, ht) +
                                      sample(h, x, y - 1, w, ht) + sample(h, x, y + 1, w, ht);
                    // Neumann edges have fewer distinct neighbors; the mirrored ghost keeps the 4-point form.
                    float jacobi = (neighbors - spacing2 * f[i]) * .25f;
                    next[i] = h[i] + .8f * (jacobi - h[i]);
                }
            });
            h.swap(next);
        }
    }
    std::vector<float> residual(const std::vector<float> &h, const std::vector<float> &f, int w, int ht, float spacing2) {
        std::vector<float> r(h.size());
        rows(ht, w, [&](int y0, int y1) {
            for (int y = y0; y < y1; ++y) for (int x = 0; x < w; ++x) {
                size_t i = at(x, y, w);
                float lap = (sample(h, x - 1, y, w, ht) + sample(h, x + 1, y, w, ht) + sample(h, x, y - 1, w, ht) +
                             sample(h, x, y + 1, w, ht) - 4.0f * h[i]) / spacing2;
                r[i] = f[i] - lap;
            }
        });
        return r;
    }
    void vCycle(std::vector<float> &h, const std::vector<float> &f, int w, int ht, float spacing) {
        const float spacing2 = spacing * spacing;
        if (w <= 4 || ht <= 4) { smooth(h, f, w, ht, spacing2, 64); return; }
        smooth(h, f, w, ht, spacing2, 3);
        auto r = residual(h, f, w, ht, spacing2);
        const int cw = (w + 1) / 2, ch = (ht + 1) / 2;
        std::vector<float> coarseF(static_cast<size_t>(cw) * ch), coarseE(coarseF.size(), 0.0f);
        double mean = 0;
        for (int y = 0; y < ch; ++y) for (int x = 0; x < cw; ++x) {
            float sum = 0; int n = 0;
            for (int dy = 0; dy < 2; ++dy) for (int dx = 0; dx < 2; ++dx) {
                int fx = 2 * x + dx, fy = 2 * y + dy;
                if (fx < w && fy < ht) { sum += r[at(fx, fy, w)]; ++n; }
            }
            coarseF[at(x, y, cw)] = sum / static_cast<float>(n);
            mean += coarseF[at(x, y, cw)];
        }
        mean /= static_cast<double>(coarseF.size());
        for (auto &v : coarseF) v -= static_cast<float>(mean); // Keep the singular system consistent.
        vCycle(coarseE, coarseF, cw, ch, spacing * 2.0f);
        // Bilinear prolongation between cell centers.
        rows(ht, w, [&](int y0, int y1) {
            for (int y = y0; y < y1; ++y) for (int x = 0; x < w; ++x) {
                float cx = (static_cast<float>(x) - .5f) * .5f, cy = (static_cast<float>(y) - .5f) * .5f;
                int x0 = static_cast<int>(std::floor(cx)), y0c = static_cast<int>(std::floor(cy));
                float tx = cx - static_cast<float>(x0), ty = cy - static_cast<float>(y0c);
                float a = sample(coarseE, x0, y0c, cw, ch), b = sample(coarseE, x0 + 1, y0c, cw, ch);
                float c = sample(coarseE, x0, y0c + 1, cw, ch), d = sample(coarseE, x0 + 1, y0c + 1, cw, ch);
                h[at(x, y, w)] += (a + (b - a) * tx) + ((c + (d - c) * tx) - (a + (b - a) * tx)) * ty;
            }
        });
        smooth(h, f, w, ht, spacing2, 3);
    }
};

// Guide normals -> pixel-space height (depth in pixels). Periodic when tiled; the caller band-limits it.
std::vector<float> guideHeight(const PBRLabInput *input, int width, int height, bool tiled) {
    const size_t count = static_cast<size_t>(width) * height;
    std::vector<float> gx(count), gy(count);
    for (int y = 0; y < height; ++y) {
        const uint8_t *row = input->guide_normal_rgba8 + static_cast<size_t>(y) * input->guide_normal_row_bytes;
        for (int x = 0; x < width; ++x) {
            float nx = row[x * 4] / 127.5f - 1.0f, ny = row[x * 4 + 1] / 127.5f - 1.0f, nz = row[x * 4 + 2] / 127.5f - 1.0f;
            nz = std::max(nz, .15f);
            size_t i = at(x, y, width);
            // +Y tangent: green-up faces decreasing image y, i.e. height increases toward the image bottom.
            gx[i] = std::clamp(-nx / nz, -4.0f, 4.0f);
            gy[i] = std::clamp(ny / nz, -4.0f, 4.0f);
        }
    }
    std::vector<float> divergence(count);
    double mean = 0;
    for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
        auto G = [&](const std::vector<float> &g, int xx, int yy) {
            return g[at(border(xx, width, tiled), border(yy, height, tiled), width)];
        };
        float d = (G(gx, x + 1, y) - G(gx, x - 1, y)) * .5f + (G(gy, x, y + 1) - G(gy, x, y - 1)) * .5f;
        divergence[at(x, y, width)] = d;
        mean += d;
    }
    mean /= static_cast<double>(count);
    for (auto &d : divergence) d -= static_cast<float>(mean);
    PoissonSolver solver(tiled);
    return solver.solve(divergence, width, height, 10);
}

// Structure-aware tiling (image-quilting style minimum-error boundary cut). For one axis, the output takes
// the half-period offset copy near both opposite edges (it is continuous across the wrap) and the original
// in the interior. Each transition follows the lowest-difference path between the two images through its
// edge band, found by dynamic programming, with a few pixels of feathering. Paths start and end at the same
// offset so the result stays continuous across the other axis' wrap. Structured textures (brick, tiles,
// planks) keep crisp features instead of the ghosted double edges a cross-fade produces.
// Offset of the copy along the cut axis. Any offset keeps the copy continuous across the wrap; its own seam
// (at n - offset) must stay outside both edge bands. The offset that best aligns the texture with itself in
// the bands (e.g. a whole number of brick courses) makes the cut nearly invisible. Coarse search on a
// subsampled grid, then refinement at full resolution.
// Repair searches only 3/8..5/8 of the tile: the copy duplicates content at the offset, and the nearer the offset is
// to half a tile the farther any duplicated element sits from its twin.
int bestCopyOffset(const std::vector<float> &rgb, int n, int band, bool vertical, bool repair = false) {
    const int lo = std::max(band + 2, repair ? 3 * n / 8 : n / 4), hi = std::min(n - band - 2, repair ? n - 3 * n / 8 : n - n / 4);
    if (lo >= hi) return n / 2;
    auto lum = [&](int across, int along) {
        size_t i = vertical ? at(along, across, n) : at(across, along, n);
        return kLinearLuminance[0] * rgb[i * 3] + kLinearLuminance[1] * rgb[i * 3 + 1] + kLinearLuminance[2] * rgb[i * 3 + 2];
    };
    auto score = [&](int offset, int stride) {
        double sum = 0;
        for (int along = 0; along < n; along += stride)
            for (int k = 0; k < band; k += stride) {
                for (int across : {k, n - 1 - k}) {
                    float d = lum(across, along) - lum((across + offset) % n, along);
                    sum += d * d;
                }
            }
        return sum;
    };
    const int coarse = std::max(1, n / 256);
    int best = n / 2;
    double bestScore = score(best, coarse);
    for (int offset = lo; offset <= hi; offset += coarse) {
        double value = score(offset, coarse);
        if (value < bestScore) { bestScore = value; best = offset; }
    }
    const int center = best;
    bestScore = score(center, std::max(1, coarse / 2));
    for (int offset = std::max(lo, center - coarse); offset <= std::min(hi, center + coarse); ++offset) {
        double value = score(offset, std::max(1, coarse / 2));
        if (value < bestScore) { bestScore = value; best = offset; }
    }
    return best;
}

// `repair` (explicit albedo repair, 1.4.0): the axis is always repaired; the cut stays in the inner half of the band,
// so a smeared or low-contrast strip along the old wrap is replaced rather than threaded by the cut; and the image is
// split into bands: detail (above sigma = max(4 reference px, band / 8)) follows the cut sharply while the low band
// follows it feathered at its own scale, so lighting or tone differences never form a step along the cut.
// Returns the copy offset (0 when the axis was left alone).
int seamCutAxis(std::vector<float> &rgb, std::vector<uint8_t> &alpha, int n, int band, bool vertical,
                bool repair = false, float scale = 1.0f, float *cutCostRatio = nullptr) {
    band = std::clamp(band, 4, n / 2 - 4);
    const int half = bestCopyOffset(rgb, n, band, vertical, repair);
    auto index = [&](int across, int along) {
        return vertical ? at(along, across, n) : at(across, along, n); // vertical: cut runs along x.
    };
    const std::vector<float> original(rgb);
    const std::vector<uint8_t> originalAlpha(alpha);
    std::vector<float> low, detail, contrast;         // Repair only: low band, detail and local contrast of the original.
    const float lowSigma = std::max(4.0f * scale, static_cast<float>(band) / 8.0f);
    const int lowRadius = std::max(1, static_cast<int>(std::lround(lowSigma * std::numbers::sqrt3_v<float>)));
    if (repair) {
        const int radius = lowRadius;
        low.resize(original.size());
        std::vector<float> channel(static_cast<size_t>(n) * n);
        for (int c = 0; c < 3; ++c) {
            for (size_t i = 0; i < channel.size(); ++i) channel[i] = original[i * 3 + c];
            auto blurred = smoothBlur(channel, n, n, radius, true);
            for (size_t i = 0; i < channel.size(); ++i) low[i * 3 + c] = blurred[i];
        }
        detail.resize(original.size());
        for (size_t i = 0; i < original.size(); ++i) detail[i] = original[i] - low[i];
        // Local contrast (mean |detail| over ~4 reference px): the cut avoids joining a sharp region to a soft or
        // smeared one, which reads as an edge even where the pixels themselves match.
        std::vector<float> magnitude(static_cast<size_t>(n) * n);
        for (size_t i = 0; i < magnitude.size(); ++i)
            magnitude[i] = std::abs(detail[i * 3]) + std::abs(detail[i * 3 + 1]) + std::abs(detail[i * 3 + 2]);
        contrast = smoothBlur(magnitude, n, n, std::max(1, static_cast<int>(std::lround(4.0f * scale * std::numbers::sqrt3_v<float>))), true);
    }
    const std::vector<float> &matched = repair ? detail : original;
    auto difference = [&](int across, int along) {
        size_t i = index(across, along), j = index((across + half) % n, along);
        float sum = 0;
        for (int c = 0; c < 3; ++c) { float d = matched[i * 3 + c] - matched[j * 3 + c]; sum += d * d; }
        if (repair) { float dc = contrast[i] - contrast[j]; sum += dc * dc; }
        float da = (static_cast<float>(originalAlpha[i]) - static_cast<float>(originalAlpha[j])) / 255.0f;
        return sum + da * da;
    };
    // Repair feathers the detail cut over +/- 3 reference px (12 px at 4K) so contrast changes across it read as
    // texture, not as an edge; legacy tiling keeps +/- 2 px.
    const float kFeather = repair ? std::max(2.0f, 3.0f * scale) : 2.0f;
    // Cost of leaving this axis alone: the source's own mismatch across the wrap, compared with the mean
    // mismatch between ordinary adjacent columns. A wrap no rougher than the texture's interior already
    // tiles, and cutting it would only add a defect where none exists.
    auto adjacentCost = [&](int a, int b) {
        double sum = 0;
        for (int v = 0; v < n; ++v) {
            size_t i = index(a, v), j = index(b, v);
            for (int c = 0; c < 3; ++c) { float d = original[i * 3 + c] - original[j * 3 + c]; sum += d * d; }
            float da = (static_cast<float>(originalAlpha[i]) - static_cast<float>(originalAlpha[j])) / 255.0f;
            sum += da * da;
        }
        return sum;
    };
    const double wrapCost = adjacentCost(n - 1, 0);
    double interiorCost = 0;
    for (int k = 0; k + 1 < n; ++k) interiorCost += adjacentCost(k, k + 1);
    if (!repair && wrapCost <= 1.5 * interiorCost / static_cast<double>(n - 1)) return 0;
    // Zone 0 spans [0, band) with the copy toward the image edge (u < path); zone 1 mirrors it. Repair keeps the
    // cut out of the outer half, next to the old wrap.
    const int innerMin = repair ? band / 2 : 1;
    std::vector<float> weight(static_cast<size_t>(n) * n, 0.0f); // Weight of the offset copy, indexed by index().
    double pathCost = 0, bandCost = 0;
    for (int zone = 0; zone < 2; ++zone) {
        const int lo = zone == 0 ? 0 : n - band;
        std::vector<float> cost(static_cast<size_t>(n) * band);
        for (int v = 0; v < n; ++v) for (int u = 0; u < band; ++u) cost[static_cast<size_t>(v) * band + u] = difference(lo + u, v);
        // Start at the band column with the least total difference; end at the same column.
        const int uLo = zone == 0 ? innerMin : 1, uHi = zone == 0 ? band - 1 : band - innerMin;
        int start = uLo;
        double best = std::numeric_limits<double>::max();
        for (int u = uLo; u < uHi; ++u) {
            double total = 0;
            for (int v = 0; v < n; ++v) total += cost[static_cast<size_t>(v) * band + u];
            if (total < best) { best = total; start = u; }
        }
        const float inf = std::numeric_limits<float>::infinity();
        std::vector<float> energy(static_cast<size_t>(n) * band, inf);
        std::vector<int8_t> step(static_cast<size_t>(n) * band, 0);
        energy[start] = cost[start];
        for (int v = 1; v < n; ++v) for (int u = uLo; u < uHi; ++u) {
            float bestPrev = inf; int8_t move = 0;
            for (int8_t d = -1; d <= 1; ++d) {
                float e = energy[static_cast<size_t>(v - 1) * band + u + d];
                if (e < bestPrev) { bestPrev = e; move = d; }
            }
            if (bestPrev == inf) continue;
            energy[static_cast<size_t>(v) * band + u] = bestPrev + cost[static_cast<size_t>(v) * band + u];
            step[static_cast<size_t>(v) * band + u] = move;
        }
        std::vector<int> path(n);
        int u = start;
        if (energy[static_cast<size_t>(n - 1) * band + u] == inf) { // Unreachable only for tiny images.
            float e = inf;
            for (int k = uLo; k < uHi; ++k) if (energy[static_cast<size_t>(n - 1) * band + k] < e) { e = energy[static_cast<size_t>(n - 1) * band + k]; u = k; }
        }
        for (int v = n - 1; v >= 0; --v) { path[v] = u; u += step[static_cast<size_t>(v) * band + u]; }
        // Visibility of the cut: its mean mismatch against the mismatch of ordinary neighbouring pixels (across the
        // cut direction) in the same band. Near or below 1 the join reads like any other pair of neighbours.
        for (int v = 0; v < n; ++v) {
            pathCost += cost[static_cast<size_t>(v) * band + path[v]];
            for (int k = uLo; k < uHi; ++k) {
                size_t i = index(lo + k, v), j = index(lo + k + 1, v);
                float sum = 0;
                for (int c = 0; c < 3; ++c) { float d = matched[i * 3 + c] - matched[j * 3 + c]; sum += d * d; }
                bandCost += sum / (uHi - uLo);
            }
        }
        for (int v = 0; v < n; ++v) for (int k = 0; k < band; ++k) {
            // Signed distance toward the image edge, where the offset copy is used.
            float d = zone == 0 ? static_cast<float>(path[v] - k) : static_cast<float>(k - path[v]);
            weight[index(lo + k, v)] = smoothstep01((d + kFeather) / (2.0f * kFeather));
        }
    }
    // Multi-band join (repair): the low band follows the same cut, feathered by the low band's own scale, so each
    // region keeps its own low band and detail together (mixing one image's low band with another's detail reads as
    // a milky haze) while tone still changes smoothly across the cut.
    if (cutCostRatio) *cutCostRatio = bandCost > 0 ? static_cast<float>(pathCost / bandCost) : 0.0f;
    std::vector<float> lowWeight;
    if (repair) lowWeight = smoothBlur(weight, n, n, lowRadius, true);
    for (int across = 0; across < n; ++across) {
        for (int along = 0; along < n; ++along) {
            size_t i = index(across, along);
            float w = weight[i];
            const float lw = repair ? lowWeight[i] : 0.0f;
            if (w <= 0 && lw <= 1e-6f) continue;
            size_t j = index((across + half) % n, along);
            if (repair) {
                for (int c = 0; c < 3; ++c)
                    rgb[i * 3 + c] = low[i * 3 + c] + (low[j * 3 + c] - low[i * 3 + c]) * lw +
                                     detail[i * 3 + c] + (detail[j * 3 + c] - detail[i * 3 + c]) * w;
            } else {
                for (int c = 0; c < 3; ++c) rgb[i * 3 + c] = original[i * 3 + c] + (original[j * 3 + c] - original[i * 3 + c]) * w;
            }
            alpha[i] = static_cast<uint8_t>(std::lround(originalAlpha[i] + (static_cast<float>(originalAlpha[j]) - originalAlpha[i]) * w));
        }
    }
    return half;
}

// Wrap-seam measures of a linear-light luminance image (1.4.0). Pixel: mean opposite-edge step / mean adjacent step.
// Tone: the same on a Gaussian (sigma 8 reference px) blur, which shows lighting or colour steps that an edge-blended
// seam hides at pixel scale. Detail: fine contrast within 24 reference px of either wrap line / elsewhere (a
// smeared band reads below 1).
PBRLabWrapSeam wrapSeam(const std::vector<uint8_t> &rgba, int n, const std::array<float, 256> &lut) {
    const size_t count = static_cast<size_t>(n) * n;
    std::vector<float> lum(count);
    for (size_t i = 0; i < count; ++i)
        lum[i] = kLinearLuminance[0] * lut[rgba[i * 4]] + kLinearLuminance[1] * lut[rgba[i * 4 + 1]] + kLinearLuminance[2] * lut[rgba[i * 4 + 2]];
    const float scale = static_cast<float>(n) / kReferenceSize;
    auto ratios = [&](const std::vector<float> &f, float &rx, float &ry) {
        double sx = 0, sy = 0, ax = 0, ay = 0;
        for (int k = 0; k < n; ++k) {
            sx += std::abs(f[at(0, k, n)] - f[at(n - 1, k, n)]);
            sy += std::abs(f[at(k, 0, n)] - f[at(k, n - 1, n)]);
        }
        for (int y = 0; y < n; ++y) for (int x = 0; x + 1 < n; ++x) {
            ax += std::abs(f[at(x + 1, y, n)] - f[at(x, y, n)]);
            ay += std::abs(f[at(y, x + 1, n)] - f[at(y, x, n)]);
        }
        rx = ax > 0 ? static_cast<float>((sx / n) / (ax / (static_cast<double>(n) * (n - 1)))) : 0.0f;
        ry = ay > 0 ? static_cast<float>((sy / n) / (ay / (static_cast<double>(n) * (n - 1)))) : 0.0f;
    };
    PBRLabWrapSeam seam{};
    ratios(lum, seam.pixel_x, seam.pixel_y);
    const int toneRadius = std::max(1, static_cast<int>(std::lround(8.0f * scale * std::numbers::sqrt3_v<float>)));
    ratios(smoothBlur(lum, n, n, toneRadius, true), seam.tone_x, seam.tone_y);
    auto fine = smoothBlur(lum, n, n, std::max(1, static_cast<int>(std::lround(2.0f * scale))), true);
    const int reach = std::max(1, static_cast<int>(std::lround(24.0f * scale)));
    double nearSum = 0, farSum = 0; size_t nearCount = 0, farCount = 0;
    for (int y = 0; y < n; ++y) for (int x = 0; x < n; ++x) {
        const float d = std::abs(lum[at(x, y, n)] - fine[at(x, y, n)]);
        const bool near = std::min(x, n - 1 - x) < reach || std::min(y, n - 1 - y) < reach;
        (near ? nearSum : farSum) += d; ++(near ? nearCount : farCount);
    }
    seam.detail = farSum > 0 && nearCount ? static_cast<float>((nearSum / nearCount) / (farSum / farCount)) : 1.0f;
    return seam;
}

// Optional source conditioning (delighting, then tiling or explicit albedo repair), shared by PBRLabDerive and
// PBRLabConditionAlbedo. Both steps work in linear light and re-encode sRGB albedo; with both disabled the albedo
// stays a byte-exact copy of the source.
void conditionAlbedo(std::vector<uint8_t> &albedo, int width, const PBRLabRecipe *recipe, bool tiled,
                     const std::array<float, 256> &lut, PBRLabAlbedoRepairInfo &info) {
    const size_t count = static_cast<size_t>(width) * width;
    const bool repair = recipe->albedo_repair != 0;
    const float bandFraction = repair && recipe->seamless_blend <= 0 ? kDefaultRepairBand : recipe->seamless_blend;
    const int blendWidth = static_cast<int>(std::lround(bandFraction * static_cast<float>(width)));
    const bool seamless = blendWidth >= 1 && width >= 8;
    const float scale = static_cast<float>(width) / kReferenceSize;
    info.band_fraction = seamless ? bandFraction : 0.0f;
    const bool equalize = recipe->albedo_equalize > 0.0f;
    if (repair) info.before = wrapSeam(albedo, width, lut);
    if (seamless || equalize) {
        std::vector<float> rgb(count * 3);
        for (size_t i = 0; i < count; ++i)
            for (int c = 0; c < 3; ++c) rgb[i * 3 + c] = lut[albedo[i * 4 + c]];
        std::vector<uint8_t> alpha(count);
        for (size_t i = 0; i < count; ++i) alpha[i] = albedo[i * 4 + 3];
        if (equalize) {
            // Divide out low-frequency illumination (a smooth luminance field ~1/8 of the tile)
            // toward the mean, preserving hue. Wraps when tiled so the correction is tileable.
            std::vector<float> lum(count);
            double mean = 0;
            for (size_t i = 0; i < count; ++i) {
                lum[i] = kLinearLuminance[0] * rgb[i * 3] + kLinearLuminance[1] * rgb[i * 3 + 1] +
                         kLinearLuminance[2] * rgb[i * 3 + 2];
                mean += lum[i];
            }
            mean /= static_cast<double>(count);
            // Clamp rather than wrap when the source is about to be made tileable: its edges do not match yet.
            auto lowFrequency = smoothBlur(lum, width, width, std::max(2, width / 8), tiled && !seamless);
            const float target = static_cast<float>(mean);
            for (size_t i = 0; i < count; ++i) {
                float gain = std::pow(target / std::max(lowFrequency[i], 1e-4f), recipe->albedo_equalize);
                gain = std::clamp(gain, .25f, 4.0f);
                for (int c = 0; c < 3; ++c) rgb[i * 3 + c] = std::min(rgb[i * 3 + c] * gain, 1.0f);
            }
        }
        // Legacy tiling follows seamless_mode; explicit repair uses the requested method, or auto (below).
        // Auto quilts first and keeps the quilt unless a cut is far more visible than ordinary neighbouring pixels
        // (its mean mismatch over 4x that of adjacent pixels in the band); then it falls back to the
        // histogram-preserving blend, which cannot leave an edge but ghosts large discrete elements (leaves, twigs,
        // pebbles). On nine seamed 4K terrain albedos the quilt looked as good or better in every case.
        uint32_t method = recipe->seamless_mode == 1 ? 2u : 1u;
        if (repair) method = recipe->albedo_repair == 3 ? 2u : recipe->albedo_repair;
        if (seamless && method == 2) {
            const std::vector<float> rgbBefore = recipe->albedo_repair == 3 ? rgb : std::vector<float>{};
            const std::vector<uint8_t> alphaBefore = recipe->albedo_repair == 3 ? alpha : std::vector<uint8_t>{};
            float ratioX = 0, ratioY = 0;
            info.offset_x = static_cast<uint32_t>(seamCutAxis(rgb, alpha, width, blendWidth, false, repair, scale, &ratioX));
            info.offset_y = static_cast<uint32_t>(seamCutAxis(rgb, alpha, width, blendWidth, true, repair, scale, &ratioY));
            info.cut_cost_ratio = std::max(ratioX, ratioY);
            if (recipe->albedo_repair == 3 && info.cut_cost_ratio > kAutoCutCostRatio) {
                rgb = rgbBefore; alpha = alphaBefore; method = 1;
            }
        }
        if (seamless) info.method = method;
        if (seamless && method == 1) {
            info.offset_x = info.offset_y = static_cast<uint32_t>(width / 2);
            // Histogram-preserving half-period offset blend (Heitz & Neyret 2018). The offset copy
            // is continuous across the wrap and its own seam sits where the weight is zero, so one
            // pass per axis removes that axis' seam while the other stays continuous. Blending in
            // Gaussianized space with variance renormalization keeps the texture's contrast and
            // value distribution instead of washing out the blend zone like a linear cross-fade.
            // Repair uses the copy alone over the outer half of the band (replacing any smeared strip along the old
            // wrap) and blends only across the inner half, which also halves the width that can ghost.
            auto weight = [&](int p) {
                const float d = static_cast<float>(std::min(p, width - 1 - p));
                if (repair) return 1.0f - smoothstep01((d - .5f * blendWidth) / (.5f * static_cast<float>(blendWidth)));
                return 1.0f - smoothstep01(d / static_cast<float>(blendWidth));
            };
            const int half = width / 2;
            std::vector<float> gauss(count);
            for (int c = 0; c < 3; ++c) {
                HistogramTransform transform;
                transform.build(rgb, c, count);
                for (size_t i = 0; i < count; ++i) gauss[i] = transform.forward(rgb[i * 3 + c]);
                auto blendAxis = [&](bool vertical) {
                    std::vector<float> source(gauss);
                    for (int y = 0; y < width; ++y) for (int x = 0; x < width; ++x) {
                        float w = weight(vertical ? y : x);
                        if (w <= 0) continue;
                        size_t i = at(x, y, width);
                        size_t j = vertical ? at(x, (y + half) % width, width) : at((x + half) % width, y, width);
                        gauss[i] = ((1.0f - w) * source[i] + w * source[j]) /
                                   std::sqrt((1.0f - w) * (1.0f - w) + w * w);
                    }
                };
                blendAxis(false);
                blendAxis(true);
                for (size_t i = 0; i < count; ++i) rgb[i * 3 + c] = transform.inverse(gauss[i]);
            }
            // Coverage is not a stochastic texture: cross-fade alpha linearly.
            std::vector<uint8_t> alphaCopy(alpha);
            for (int y = 0; y < width; ++y) for (int x = 0; x < width; ++x) {
                float w = weight(x);
                if (w <= 0) continue;
                size_t i = at(x, y, width), j = at((x + half) % width, y, width);
                alpha[i] = static_cast<uint8_t>(std::lround(alphaCopy[i] + (alphaCopy[j] - alphaCopy[i]) * w));
            }
            alphaCopy = alpha;
            for (int y = 0; y < width; ++y) {
                float w = weight(y);
                if (w <= 0) continue;
                for (int x = 0; x < width; ++x) {
                    size_t i = at(x, y, width), j = at(x, (y + half) % width, width);
                    alpha[i] = static_cast<uint8_t>(std::lround(alphaCopy[i] + (alphaCopy[j] - alphaCopy[i]) * w));
                }
            }
        }
        parallelRows(width, [&](int y0, int y1) {
            for (int y = y0; y < y1; ++y) for (int x = 0; x < width; ++x) {
                size_t i = at(x, y, width);
                for (int c = 0; c < 3; ++c) albedo[i * 4 + c] = srgbByte(rgb[i * 3 + c]);
                albedo[i * 4 + 3] = alpha[i];
            }
        }, nullptr, nullptr, 0, 0);
    }
    if (repair) info.after = wrapSeam(albedo, width, lut);
}

// Precomputed horizon sample for one side of one GTAO slice. Samples lie exactly on the slice line and
// are read bilinearly, so planar surfaces of any orientation produce exact horizons.
struct AOSample { int x0, y0; float fx, fy, distanceSquared; };
struct AOSlice {
    float dirX, dirY;                                  // Image-space slice direction (x right, y down).
    std::array<AOSample, kAOStepsPerSide> positive{}, negative{};
    int count = 0;
};
AOSample makeSample(float ox, float oy) {
    float fx0 = std::floor(ox), fy0 = std::floor(oy);
    return {static_cast<int>(fx0), static_cast<int>(fy0), ox - fx0, oy - fy0, ox * ox + oy * oy};
}
std::array<AOSlice, kAOSlices> makeSlices(float radius) {
    std::array<AOSlice, kAOSlices> slices{};
    for (int s = 0; s < kAOSlices; ++s) {
        float phi = std::numbers::pi_v<float> * static_cast<float>(s) / kAOSlices;
        auto &slice = slices[s];
        slice.dirX = std::cos(phi); slice.dirY = std::sin(phi);
        if (std::abs(slice.dirX) < 1e-6f) slice.dirX = 0;
        if (std::abs(slice.dirY) < 1e-6f) slice.dirY = 0;
        for (int step = 1; step <= kAOStepsPerSide; ++step) {
            float distance = radius * static_cast<float>(step) / kAOStepsPerSide;
            if (distance < .5f) continue;
            float ox = slice.dirX * distance, oy = slice.dirY * distance;
            slice.positive[slice.count] = makeSample(ox, oy);
            slice.negative[slice.count] = makeSample(-ox, -oy);
            ++slice.count;
        }
    }
    return slices;
}
} // namespace

struct PBRLabResult {
    std::array<StoredMap, kMapCount> maps;
    std::array<bool, kMapCount> present{};
    uint32_t width = 0;
    PBRLabSeamMetrics seam{};
    PBRLabDerivationInfo info{};
    PBRLabAlbedoRepairInfo repair{};
};

extern "C" const char *PBRLabVersion(void) { return "1.4.0"; }

extern "C" PBRLabRecipe PBRLabDefaultRecipe(PBRLabPreset preset) {
    PBRLabRecipe r{};
    r.preset = preset >= PBRLabPresetFlat && preset <= PBRLabPresetBareMetal ? preset : PBRLabPresetFlat;
    r.height_strength = r.preset == PBRLabPresetFlat ? 0.0f : 0.22f;
    r.height_polarity = 1;
    r.roughness_base = .55f;
    if (r.preset == PBRLabPresetStone) r.roughness_base = .78f;
    if (r.preset == PBRLabPresetFabric) r.roughness_base = .85f;
    if (r.preset == PBRLabPresetOrganic) r.roughness_base = .72f;
    if (r.preset == PBRLabPresetCoatedMetal) r.roughness_base = .38f;
    if (r.preset == PBRLabPresetBareMetal) r.roughness_base = .3f;
    r.roughness_variation = r.preset == PBRLabPresetFlat ? 0.0f : .3f;
    r.ao_radius_pixels = 10.0f;
    r.tile_wrap = 1;
    r.assigned_metalness_enabled = 0;
    r.assigned_metalness = 0;
    r.bent_normal_enabled = 0;
    r.normal_strength = 1.0f;
    r.normal_y_down = 0;
    r.ao_strength = 1.0f;
    r.albedo_equalize = 0.0f;
    r.seamless_blend = 0.0f;
    r.guide_normal_weight = 0.0f;
    r.seamless_mode = 1;
    r.albedo_repair = 0;
    return r;
}

extern "C" PBRLabResult *PBRLabDerive(const PBRLabInput *input, const PBRLabRecipe *recipe,
                                  PBRLabProgressCallback progress, void *context,
                                  char *error, size_t error_capacity) {
    setError(error, error_capacity, "");
    std::string why;
    if (!valid(input, recipe, why)) { setError(error, error_capacity, why.c_str()); return nullptr; }
    // An authored normal map is the geometry: integrate it into height at full weight in place of guide normals.
    PBRLabInput authoredInput;
    PBRLabRecipe authoredRecipe;
    if (input->authored_normal_rgba8 && !input->height_override_r16) {
        authoredInput = *input;
        authoredInput.guide_normal_rgba8 = input->authored_normal_rgba8;
        authoredInput.guide_normal_row_bytes = input->authored_normal_row_bytes;
        authoredRecipe = *recipe;
        authoredRecipe.guide_normal_weight = 1.0f;
        input = &authoredInput;
        recipe = &authoredRecipe;
    }
    try {
        const int width = static_cast<int>(input->width);
        const int height = static_cast<int>(input->height);
        const size_t count = static_cast<size_t>(width) * height;
        const bool tiled = recipe->tile_wrap != 0;
        auto result = std::make_unique<PBRLabResult>();
        result->width = input->width;
        auto addRGBA = [&](PBRLabMapKind kind, PBRLabPixelFormat format) -> std::vector<uint8_t> & {
            auto &m = result->maps[kind];
            m.format = format;
            m.rowBytes = static_cast<size_t>(width) * 4;
            m.data.resize(count * 4);
            result->present[kind] = true;
            return m.data;
        };
        auto &albedo = addRGBA(PBRLabMapAlbedo, PBRLabPixelFormatRGBA8SRGB);
        auto &normal = addRGBA(PBRLabMapNormal, PBRLabPixelFormatRGBA8Linear);
        auto &roughness = addRGBA(PBRLabMapRoughness, PBRLabPixelFormatRGBA8Linear);
        auto &ao = addRGBA(PBRLabMapAO, PBRLabPixelFormatRGBA8Linear);
        auto &cavity = addRGBA(PBRLabMapCavity, PBRLabPixelFormatRGBA8Linear);
        auto &convexity = addRGBA(PBRLabMapConvexity, PBRLabPixelFormatRGBA8Linear);
        auto &slope = addRGBA(PBRLabMapSlope, PBRLabPixelFormatRGBA8Linear);
        auto &edge = addRGBA(PBRLabMapEdge, PBRLabPixelFormatRGBA8Linear);
        std::vector<uint8_t> *bent = recipe->bent_normal_enabled
            ? &addRGBA(PBRLabMapBentNormal, PBRLabPixelFormatRGBA8Linear) : nullptr;
        std::vector<uint8_t> *orm = recipe->assigned_metalness_enabled
            ? &addRGBA(PBRLabMapORM, PBRLabPixelFormatRGBA8Linear) : nullptr;
        auto &heightMap = result->maps[PBRLabMapHeight];
        heightMap.format = PBRLabPixelFormatR16UNormLE;
        heightMap.rowBytes = static_cast<size_t>(width) * 2;
        heightMap.data.resize(count * 2);
        result->present[PBRLabMapHeight] = true;

        std::array<float, 256> lut{};
        for (unsigned i = 0; i < 256; ++i) lut[i] = linear(static_cast<uint8_t>(i));
        for (int y = 0; y < height; ++y) {
            const uint8_t *src = input->rgba8 + static_cast<size_t>(y) * input->rgba_row_bytes;
            std::memcpy(albedo.data() + static_cast<size_t>(y) * width * 4, src, static_cast<size_t>(width) * 4);
        }

        PBRLabAlbedoRepairInfo repairInfo{};
        conditionAlbedo(albedo, width, recipe, tiled, lut, repairInfo);
        std::vector<float> luminance(count);
        for (size_t i = 0; i < count; ++i)
            luminance[i] = kLinearLuminance[0] * lut[albedo[i * 4]] +
                           kLinearLuminance[1] * lut[albedo[i * 4 + 1]] +
                           kLinearLuminance[2] * lut[albedo[i * 4 + 2]];
        checkpoint(progress, context, .08f);

        // Every spatial scale is defined at a 1024-pixel reference and scaled with the tile, so a 512 preview
        // and a 4K export describe the same surface.
        const float scale = static_cast<float>(width) / kReferenceSize;
        auto radius = [&](float referencePixels) { return std::max(1, static_cast<int>(std::lround(referencePixels * scale))); };
        // Shading is multiplicative (image = albedo x irradiance), so relief cues are read from log luminance:
        // the same relief gives the same signal on dark basalt and pale limestone.
        std::vector<float> logLum(count);
        for (size_t i = 0; i < count; ++i) logLum[i] = std::log(luminance[i] + kLogLuminanceFloor);

        const bool inferHeight = !input->height_override_r16 && recipe->preset != PBRLabPresetFlat;
        const bool useGuide = !input->height_override_r16 && input->guide_normal_rgba8 && recipe->guide_normal_weight > 0;
        const float polarity = static_cast<float>(recipe->height_polarity);
        const float guideWeight = useGuide ? recipe->guide_normal_weight : 0.0f;
        // Geometry is carried in pixels of depth (so its gradient is the tangent of the surface slope) before
        // normal_strength, which scales the whole surface: normals, AO, diagnostics and the height span.
        std::vector<float> geometry(count, 0.0f);
        PBRLabDerivationInfo info{};
        info.detail_polarity = recipe->height_polarity;
        if (input->height_override_r16) {
            for (int y = 0; y < height; ++y) {
                const uint8_t *row = input->height_override_r16 + static_cast<size_t>(y) * input->height_override_row_bytes;
                for (int x = 0; x < width; ++x) {
                    uint16_t authored = static_cast<uint16_t>(row[x * 2] | (row[x * 2 + 1] << 8));
                    geometry[at(x, y, width)] = static_cast<float>(authored) / 65535.0f * kNormalDepthPixels * scale;
                }
            }
        } else {
            std::vector<float> signal;
            double signalRms = 0;
            if (inferHeight) {
                auto small = smoothBlur(logLum, width, height, radius(2), tiled);
                checkpoint(progress, context, .14f);
                auto medium = smoothBlur(logLum, width, height, radius(8), tiled);
                checkpoint(progress, context, .20f);
                auto large = smoothBlur(logLum, width, height, radius(24), tiled);
                signal.resize(count);
                for (size_t i = 0; i < count; ++i)
                    signal[i] = presetSignal(recipe->preset, logLum[i] - small[i], small[i] - medium[i], medium[i] - large[i]);
                signalRms = rmsSlope(signal, width, height, tiled);
            }
            // Relief amplitude is an explicit prior: the preset's target rms surface slope, scaled by height_strength.
            const float target = reliefTarget(recipe->preset) * recipe->height_strength / kDefaultHeightStrength;
            const bool hasSignal = inferHeight && signalRms > 1e-9;
            if (useGuide) {
                auto learned = guideHeight(input, width, height, tiled);
                checkpoint(progress, context, .24f);
                // Learned form: the band between the crossover and a fifth of the tile. Scene-trained estimators
                // add tile-scale bowls and tilt below that band and are blurred above it.
                const int formRadius = std::max(4, static_cast<int>(std::lround(static_cast<float>(width) * kFormCutFraction)));
                auto lowest = smoothBlur(learned, width, height, formRadius, tiled);
                std::vector<float> band(count);
                for (size_t i = 0; i < count; ++i) band[i] = learned[i] - lowest[i];
                const int crossover = radius(kCrossoverPixels);
                if (hasSignal) {
                    auto form = smoothBlur(band, width, height, crossover, tiled);
                    const double formRms = rmsSlope(form, width, height, tiled);
                    // The learned field orients the fine detail: correlate both in a band the estimator resolves.
                    auto learnedFine = smoothBlur(learned, width, height, radius(kCorrelationLow), tiled);
                    auto learnedCoarse = smoothBlur(learned, width, height, radius(kCorrelationHigh), tiled);
                    auto signalFine = smoothBlur(signal, width, height, radius(kCorrelationLow), tiled);
                    auto signalCoarse = smoothBlur(signal, width, height, radius(kCorrelationHigh), tiled);
                    double sab = 0, saa = 0, sbb = 0;
                    for (size_t i = 0; i < count; ++i) {
                        double la = learnedFine[i] - learnedCoarse[i], sb = signalFine[i] - signalCoarse[i];
                        sab += la * sb; saa += la * la; sbb += sb * sb;
                    }
                    const double correlation = saa > 0 && sbb > 0 ? sab / std::sqrt(saa * sbb) : 0.0;
                    const float detailSign = std::abs(correlation) >= kPolarityConfidence ? (correlation < 0 ? -1.0f : 1.0f) : 1.0f;
                    auto signalLow = smoothBlur(signal, width, height, crossover, tiled);
                    std::vector<float> detail(count);
                    for (size_t i = 0; i < count; ++i) detail[i] = signal[i] - signalLow[i];
                    const double detailRms = rmsSlope(detail, width, height, tiled);
                    // Learned form earns its share of the slope energy by its own amplitude: an estimator that sees
                    // an almost flat surface contributes little form rather than having its noise amplified.
                    double share = target > 0 ? std::clamp(kFormGain * formRms / target, 0.0, kMaxFormShare) : 0.0;
                    if (formRms <= 1e-9) share = 0;
                    if (detailRms <= 1e-9) share = formRms > 1e-9 ? 1.0 : 0.0;
                    const float formScale = share > 0 ? static_cast<float>(std::sqrt(share) / formRms) : 0.0f;
                    const float detailScale = detailRms > 1e-9 ? static_cast<float>(std::sqrt(1.0 - share) / detailRms) * detailSign : 0.0f;
                    const float heuristicScale = static_cast<float>(polarity / signalRms);
                    // height_polarity -1 inverts the learned relief too (1.4.0): the learned field decides the
                    // direction, the recipe can still flip it.
                    std::vector<float> mixed(count);
                    for (size_t i = 0; i < count; ++i)
                        mixed[i] = (1.0f - guideWeight) * heuristicScale * signal[i] +
                                   guideWeight * polarity * (formScale * form[i] + detailScale * detail[i]);
                    const double mixedRms = rmsSlope(mixed, width, height, tiled);
                    const float normalize = mixedRms > 1e-9 ? static_cast<float>(target / mixedRms) : 0.0f;
                    for (size_t i = 0; i < count; ++i) geometry[i] = mixed[i] * normalize;
                    info.learned_form_share = static_cast<float>(share) * guideWeight;
                    info.learned_detail_correlation = static_cast<float>(correlation);
                    info.detail_polarity = static_cast<int32_t>(guideWeight >= .5f ? detailSign * polarity : polarity);
                } else {
                    // No albedo relief (flat preset): the learned band alone, in the estimator's own units.
                    for (size_t i = 0; i < count; ++i) geometry[i] = guideWeight * polarity * band[i];
                    info.learned_form_share = guideWeight;
                }
            } else if (hasSignal) {
                const float gain = static_cast<float>(polarity * target / signalRms);
                for (size_t i = 0; i < count; ++i) geometry[i] = gain * signal[i];
            }
            if (input->relief_mask_r8)
                for (int y = 0; y < height; ++y) {
                    const uint8_t *mask = input->relief_mask_r8 + static_cast<size_t>(y) * input->relief_mask_row_bytes;
                    for (int x = 0; x < width; ++x) geometry[at(x, y, width)] *= static_cast<float>(mask[x]) / 255.0f;
                }
        }
        for (auto &g : geometry) g *= recipe->normal_strength;
        checkpoint(progress, context, .28f);

        // Export: authored height keeps its bytes. Estimated geometry uses the full 16-bit range (lowest point 0,
        // highest 1); the manifest records the depth that range spans, in tile widths.
        std::vector<float> heights(count);
        float lowest = std::numeric_limits<float>::max(), highest = std::numeric_limits<float>::lowest();
        for (float g : geometry) { lowest = std::min(lowest, g); highest = std::max(highest, g); }
        if (input->height_override_r16) {
            for (int y = 0; y < height; ++y) {
                const uint8_t *row = input->height_override_r16 + static_cast<size_t>(y) * input->height_override_row_bytes;
                for (int x = 0; x < width; ++x) {
                    size_t i = at(x, y, width);
                    heights[i] = static_cast<float>(static_cast<uint16_t>(row[x * 2] | (row[x * 2 + 1] << 8))) / 65535.0f;
                    heightMap.data[i * 2] = row[x * 2];
                    heightMap.data[i * 2 + 1] = row[x * 2 + 1];
                }
            }
            info.height_span_tile_widths = kNormalDepthPixels * scale * recipe->normal_strength / static_cast<float>(width);
        } else {
            const float span = highest - lowest;
            const bool relief = span > 1e-6f;
            for (size_t i = 0; i < count; ++i) {
                heights[i] = relief ? (geometry[i] - lowest) / span : .5f;
                uint16_t q = static_cast<uint16_t>(std::lround(clamp01(heights[i]) * 65535.0f));
                heightMap.data[i * 2] = static_cast<uint8_t>(q & 255);
                heightMap.data[i * 2 + 1] = static_cast<uint8_t>(q >> 8);
            }
            info.height_span_tile_widths = relief ? span / static_cast<float>(width) : 0.0f;
        }
        info.rms_slope = static_cast<float>(rmsSlope(geometry, width, height, tiled));

        // Curvature at two scales (fine grain and the size of a small pit), in reference pixels of depth.
        const auto fineAverage = smoothBlur(geometry, width, height, radius(2), tiled);
        const auto midAverage = smoothBlur(geometry, width, height, radius(8), tiled);
        std::vector<float> curvature(count);
        for (size_t i = 0; i < count; ++i)
            curvature[i] = (.5f * (geometry[i] - fineAverage[i]) + .5f * (geometry[i] - midAverage[i])) / scale;

        // Roughness: a varied map around the artist's prior within the preset's physical range. Cues, each
        // standardized over the tile: concavity (crevices hold dust and weather matte; exposed convex faces are
        // abraded smoother), luminance micro-contrast (granular, broken surfaces scatter more) and local
        // brightness relative to the surroundings (bright mineral facets and cleavage planes are glossier).
        std::vector<float> roughnessValue(count, recipe->roughness_base);
        const auto range = roughnessRange(recipe->preset);
        const float roughLo = std::min(range[0], recipe->roughness_base), roughHi = std::max(range[1], recipe->roughness_base);
        if (recipe->roughness_variation > 0) {
            auto fine = smoothBlur(logLum, width, height, radius(2), tiled);
            std::vector<float> contrast(count);
            for (size_t i = 0; i < count; ++i) { float d = logLum[i] - fine[i]; contrast[i] = d * d; }
            contrast = smoothBlur(contrast, width, height, radius(4), tiled);
            for (auto &c : contrast) c = std::sqrt(std::max(c, 0.0f));
            auto surround = smoothBlur(logLum, width, height, radius(8), tiled);
            std::vector<float> facet(count);
            for (size_t i = 0; i < count; ++i) facet[i] = fine[i] - surround[i];
            auto smoothCurvature = smoothBlur(curvature, width, height, radius(2), tiled);
            auto standardize = [&](std::vector<float> &v) {
                double sum = 0, squares = 0;
                for (float x : v) { sum += x; squares += static_cast<double>(x) * x; }
                const double mean = sum / static_cast<double>(count);
                const double deviation = std::sqrt(std::max(squares / static_cast<double>(count) - mean * mean, 0.0));
                const float inverse = deviation > 1e-9 ? static_cast<float>(1.0 / deviation) : 0.0f;
                for (auto &x : v) x = std::clamp((x - static_cast<float>(mean)) * inverse, -2.5f, 2.5f);
            };
            standardize(contrast); standardize(facet); standardize(smoothCurvature);
            std::vector<float> cue(count);
            for (size_t i = 0; i < count; ++i)
                cue[i] = -kRoughnessCavityWeight * smoothCurvature[i] + kRoughnessContrastWeight * contrast[i] -
                         kRoughnessFacetWeight * facet[i];
            standardize(cue);
            const float amplitude = recipe->roughness_variation * kRoughnessSpread;
            for (size_t i = 0; i < count; ++i)
                roughnessValue[i] = std::clamp(recipe->roughness_base + amplitude * cue[i], roughLo, roughHi);
        }
        checkpoint(progress, context, .32f);

        const float aoRadius = recipe->ao_radius_pixels * scale;
        const auto slices = makeSlices(aoRadius);
        const int reach = static_cast<int>(std::ceil(aoRadius)) + 2;
        // GTAO sees the same surface as the normals, deepened by ao_strength x kAOExaggeration: a heightfield
        // misses sub-texel occlusion and undercuts, so it underestimates occlusion at equal depth.
        const float aoDepth = kAOExaggeration * recipe->ao_strength;
        const bool aoEnabled = aoDepth > 0 && aoRadius >= .5f;
        // Image rows grow downward. +Y / green-up tangent space points to decreasing V, so the tangent
        // Y component is the negated image-space Y component; DirectX-style export keeps image Y.
        const float tangentYSign = recipe->normal_y_down ? 1.0f : -1.0f;
        const uint8_t metalByte = byte(recipe->assigned_metalness);
        constexpr float kHalfPi = std::numbers::pi_v<float> * .5f;

        parallelRows(height, [&](int y0, int y1) {
            for (int y = y0; y < y1; ++y) {
                const bool interiorRow = y >= reach && y < height - reach;
                for (int x = 0; x < width; ++x) {
                    const size_t i = at(x, y, width);
                    auto H = [&](int xx, int yy) { return geometry[at(border(xx, width, tiled), border(yy, height, tiled), width)]; };
                    // Scharr derivative (per pixel): better rotational symmetry than central differences.
                    float a = H(x - 1, y - 1), b = H(x, y - 1), c = H(x + 1, y - 1);
                    float d = H(x - 1, y),                      f = H(x + 1, y);
                    float g = H(x - 1, y + 1), hh = H(x, y + 1), k = H(x + 1, y + 1);
                    float hx = (3.0f * (c + k) + 10.0f * f - 3.0f * (a + g) - 10.0f * d) / 32.0f;
                    float hy = (3.0f * (g + k) + 10.0f * hh - 3.0f * (a + c) - 10.0f * b) / 32.0f;
                    // Image-space surface normal of z = height * depth (x right, y down, z toward viewer).
                    float nxImage = -hx, nyImage = -hy;
                    putNormal(normal, i, nxImage, tangentYSign * nyImage, 1.0f);

                    const float localCurvature = curvature[i];
                    const float gradient = std::sqrt(hx * hx + hy * hy);
                    putGray(cavity, i, clamp01(-localCurvature * kCavityGain));
                    putGray(convexity, i, clamp01(localCurvature * kCavityGain));
                    putGray(slope, i, clamp01(gradient * 2.0f));
                    putGray(edge, i, clamp01(std::abs(localCurvature) * kCavityGain * 1.5f));
                    putGray(roughness, i, clamp01(roughnessValue[i]));

                    // GTAO (Jimenez et al. 2016) cosine-weighted slice integral on the heightfield, viewed
                    // from +Z. The AO geometry uses its own depth scale so AO and normal response are
                    // independently art-directable.
                    float visibility = 1.0f, bentX = 0, bentY = 0, bentZ = 1;
                    if (aoEnabled) {
                        const bool interior = interiorRow && x >= reach && x < width - reach;
                        const float center = geometry[i] * aoDepth;
                        float aoHx = -hx * aoDepth, aoHy = -hy * aoDepth;
                        float nInv = 1.0f / std::sqrt(aoHx * aoHx + aoHy * aoHy + 1.0f);
                        const float Nx = aoHx * nInv, Ny = aoHy * nInv, Nz = nInv;
                        float sum = 0, open = 0; bentX = bentY = bentZ = 0;
                        for (const auto &slice : slices) {
                            auto horizonCos = [&](const std::array<AOSample, kAOStepsPerSide> &taps) {
                                float best = -1.0f;
                                for (int s = 0; s < slice.count; ++s) {
                                    const auto &t = taps[s];
                                    float h00, h10, h01, h11;
                                    if (interior) {
                                        const float *row = &geometry[i + static_cast<ptrdiff_t>(t.y0) * width + t.x0];
                                        h00 = row[0]; h10 = row[1]; h01 = row[width]; h11 = row[width + 1];
                                    } else {
                                        h00 = H(x + t.x0, y + t.y0); h10 = H(x + t.x0 + 1, y + t.y0);
                                        h01 = H(x + t.x0, y + t.y0 + 1); h11 = H(x + t.x0 + 1, y + t.y0 + 1);
                                    }
                                    float top = h00 + (h10 - h00) * t.fx, bottom = h01 + (h11 - h01) * t.fx;
                                    float rise = (top + (bottom - top) * t.fy) * aoDepth - center;
                                    // cos(angle from +Z) of the vector to the sample.
                                    float cosH = rise / std::sqrt(rise * rise + t.distanceSquared);
                                    best = std::max(best, cosH);
                                }
                                return best;
                            };
                            // Project the normal into the slice plane spanned by the direction and +Z.
                            float axisX = slice.dirY, axisY = -slice.dirX; // Slice plane normal.
                            float along = Nx * axisX + Ny * axisY;
                            float px = Nx - along * axisX, py = Ny - along * axisY, pz = Nz;
                            float projLength = std::sqrt(px * px + py * py + pz * pz);
                            const float cosN = std::clamp(pz / std::max(projLength, 1e-6f), 0.0f, 1.0f);
                            const float signN = (px * slice.dirX + py * slice.dirY) < 0 ? -1.0f : 1.0f;
                            const float sinN = signN * std::sqrt(std::max(0.0f, 1.0f - cosN * cosN));
                            const float n = signN * fastAcos(cosN);
                            // Horizons as (angle, cos, sin), clamped to the normal hemisphere [n-pi/2, n+pi/2].
                            const float c1 = std::clamp(horizonCos(slice.positive), -1.0f, 1.0f);
                            const float c0 = std::clamp(horizonCos(slice.negative), -1.0f, 1.0f);
                            float h1 = fastAcos(c1), ch1 = c1, sh1 = std::sqrt(std::max(0.0f, 1.0f - c1 * c1));
                            float h0 = -fastAcos(c0), ch0 = c0, sh0 = -std::sqrt(std::max(0.0f, 1.0f - c0 * c0));
                            if (h1 > n + kHalfPi) { h1 = n + kHalfPi; ch1 = -sinN; sh1 = cosN; }
                            if (h0 < n - kHalfPi) { h0 = n - kHalfPi; ch0 = sinN; sh0 = -cosN; }
                            // cos(2h - n) = cos2h cos n + sin2h sin n.
                            auto cos2hMinusN = [&](float c, float sv) { return (c * c - sv * sv) * cosN + 2.0f * sv * c * sinN; };
                            float arc0 = (cosN + 2.0f * h0 * sinN - cos2hMinusN(ch0, sh0)) * .25f;
                            float arc1 = (cosN + 2.0f * h1 * sinN - cos2hMinusN(ch1, sh1)) * .25f;
                            sum += projLength * (arc0 + arc1);
                            // Same slice fully unoccluded (h = n -/+ pi/2). Normalizing by it makes the
                            // discrete slice set exact for open planes of any slope.
                            open += projLength * (cosN + n * sinN);
                            if (bent) {
                                auto sinMinus = [&](float c, float sv) { return sv * cosN - c * sinN; };   // sin(h - n)
                                auto sinPlus = [&](float c, float sv) { return sv * cosN + c * sinN; };    // sin(h + n)
                                auto cosPlus = [&](float c, float sv) { return c * cosN - sv * sinN; };    // cos(h + n)
                                auto sin3Minus = [&](float c, float sv) {                                   // sin(3h - n)
                                    float c3 = 4.0f * c * c * c - 3.0f * c, s3 = 3.0f * sv - 4.0f * sv * sv * sv;
                                    return s3 * cosN - c3 * sinN;
                                };
                                auto cos3Minus = [&](float c, float sv) {                                   // cos(3h - n)
                                    float c3 = 4.0f * c * c * c - 3.0f * c, s3 = 3.0f * sv - 4.0f * sv * sv * sv;
                                    return c3 * cosN + s3 * sinN;
                                };
                                float t0 = (6.0f * sinMinus(ch0, sh0) - sin3Minus(ch0, sh0) +
                                            6.0f * sinMinus(ch1, sh1) - sin3Minus(ch1, sh1) +
                                            16.0f * sinN - 3.0f * (sinPlus(ch0, sh0) + sinPlus(ch1, sh1))) / 12.0f;
                                float t1 = (-cos3Minus(ch0, sh0) - cos3Minus(ch1, sh1) + 8.0f * cosN -
                                            3.0f * (cosPlus(ch0, sh0) + cosPlus(ch1, sh1))) / 12.0f;
                                bentX += slice.dirX * t0 * projLength;
                                bentY += slice.dirY * t0 * projLength;
                                bentZ += t1 * projLength;
                            }
                        }
                        visibility = clamp01(sum / std::max(open, 1e-6f));
                    }
                    putGray(ao, i, visibility); // AO convention: 1 is unoccluded.
                    if (bent) putNormal(*bent, i, bentX, tangentYSign * bentY, std::max(bentZ, 1e-4f));
                    if (orm) {
                        (*orm)[i * 4] = byte(visibility);
                        (*orm)[i * 4 + 1] = roughness[i * 4];
                        (*orm)[i * 4 + 2] = metalByte;
                        (*orm)[i * 4 + 3] = 255;
                    }
                }
            }
        }, progress, context, .34f, .95f);

        // Authored maps replace the derived ones (the ORM channels follow them).
        for (int y = 0; y < height; ++y) {
            const uint8_t *nRow = input->authored_normal_rgba8 ? input->authored_normal_rgba8 + static_cast<size_t>(y) * input->authored_normal_row_bytes : nullptr;
            const uint8_t *rRow = input->authored_roughness_r8 ? input->authored_roughness_r8 + static_cast<size_t>(y) * input->authored_roughness_row_bytes : nullptr;
            const uint8_t *aRow = input->authored_ao_r8 ? input->authored_ao_r8 + static_cast<size_t>(y) * input->authored_ao_row_bytes : nullptr;
            const uint8_t *mRow = input->authored_metalness_r8 ? input->authored_metalness_r8 + static_cast<size_t>(y) * input->authored_metalness_row_bytes : nullptr;
            for (int x = 0; x < width; ++x) {
                const size_t i = static_cast<size_t>(y) * width + x;
                if (nRow) {
                    normal[i * 4] = nRow[x * 4];
                    normal[i * 4 + 1] = recipe->normal_y_down ? static_cast<uint8_t>(255 - nRow[x * 4 + 1]) : nRow[x * 4 + 1];
                    normal[i * 4 + 2] = nRow[x * 4 + 2];
                    normal[i * 4 + 3] = 255;
                }
                auto gray = [&](std::vector<uint8_t> &map, uint8_t v) { map[i * 4] = map[i * 4 + 1] = map[i * 4 + 2] = v; map[i * 4 + 3] = 255; };
                if (rRow) { gray(roughness, rRow[x]); if (orm) (*orm)[i * 4 + 1] = rRow[x]; }
                if (aRow) { gray(ao, aRow[x]); if (orm) (*orm)[i * 4] = aRow[x]; }
                if (mRow && orm) (*orm)[i * 4 + 2] = mRow[x];
            }
        }
        checkpoint(progress, context, .97f);

        float heightDelta = 0, gradientDelta = 0, albedoSeam = 0;
        for (int i = 0; i < width; ++i) {
            heightDelta += std::abs(heights[at(0, i, width)] - heights[at(width - 1, i, width)]);
            heightDelta += std::abs(heights[at(i, 0, width)] - heights[at(i, height - 1, width)]);
            float dxLeft = heights[at(1, i, width)] - heights[at(0, i, width)];
            float dxRight = heights[at(width - 1, i, width)] - heights[at(width - 2, i, width)];
            float dyTop = heights[at(i, 1, width)] - heights[at(i, 0, width)];
            float dyBottom = heights[at(i, height - 1, width)] - heights[at(i, height - 2, width)];
            gradientDelta += std::abs(dxLeft - dxRight) + std::abs(dyTop - dyBottom);
            auto colorDiff = [&](size_t a, size_t b) {
                float sum = 0;
                for (int c = 0; c < 3; ++c) sum += std::abs(lut[albedo[a * 4 + c]] - lut[albedo[b * 4 + c]]);
                return sum / 3.0f;
            };
            albedoSeam += colorDiff(at(0, i, width), at(width - 1, i, width));
            albedoSeam += colorDiff(at(i, 0, width), at(i, height - 1, width));
        }
        double adjacent = 0;
        for (int y = 0; y < height; ++y) for (int x = 0; x + 1 < width; ++x)
            adjacent += std::abs(heights[at(x + 1, y, width)] - heights[at(x, y, width)]) +
                        std::abs(heights[at(y, x + 1, width)] - heights[at(y, x, width)]);
        adjacent /= 2.0 * width * (width - 1);
        info.height_wrap_seam_ratio = adjacent > 1e-12 ? static_cast<float>(heightDelta / (2.0 * width) / adjacent) : 0.0f;
        result->info = info;
        result->repair = repairInfo;
        result->seam = {heightDelta / (2.0f * width), gradientDelta / (2.0f * width),
                        albedoSeam / (2.0f * width)};
        checkpoint(progress, context, 1.0f);
        return result.release();
    } catch (const std::exception &e) {
        setError(error, error_capacity, e.what());
        return nullptr;
    } catch (...) {
        setError(error, error_capacity, "unknown derivation error");
        return nullptr;
    }
}

extern "C" int PBRLabGetMap(const PBRLabResult *result, PBRLabMapKind kind, PBRLabMap *out_map) {
    if (!result || !out_map || kind < PBRLabMapAlbedo || kind > PBRLabMapORM || !result->present[kind]) return 0;
    const auto &m = result->maps[kind];
    *out_map = {m.data.data(), result->width, result->width, m.rowBytes, m.data.size(), m.format};
    return 1;
}
extern "C" PBRLabSeamMetrics PBRLabGetSeamMetrics(const PBRLabResult *result) {
    return result ? result->seam : PBRLabSeamMetrics{};
}
extern "C" PBRLabDerivationInfo PBRLabGetDerivationInfo(const PBRLabResult *result) {
    return result ? result->info : PBRLabDerivationInfo{};
}
extern "C" PBRLabAlbedoRepairInfo PBRLabGetAlbedoRepairInfo(const PBRLabResult *result) {
    return result ? result->repair : PBRLabAlbedoRepairInfo{};
}
extern "C" int PBRLabConditionAlbedo(const PBRLabInput *input, const PBRLabRecipe *recipe, uint8_t *out_rgba8,
                                     size_t out_row_bytes, PBRLabAlbedoRepairInfo *out_info, char *error, size_t error_capacity) {
    setError(error, error_capacity, "");
    std::string why;
    if (!valid(input, recipe, why)) { setError(error, error_capacity, why.c_str()); return 0; }
    if (!out_rgba8 || out_row_bytes < static_cast<size_t>(input->width) * 4) { setError(error, error_capacity, "output buffer is too small"); return 0; }
    try {
        const int n = static_cast<int>(input->width);
        std::vector<uint8_t> albedo(static_cast<size_t>(n) * n * 4);
        for (int y = 0; y < n; ++y)
            std::memcpy(&albedo[static_cast<size_t>(y) * n * 4], input->rgba8 + y * input->rgba_row_bytes, static_cast<size_t>(n) * 4);
        std::array<float, 256> lut{};
        for (unsigned i = 0; i < 256; ++i) lut[i] = linear(static_cast<uint8_t>(i));
        PBRLabAlbedoRepairInfo info{};
        conditionAlbedo(albedo, n, recipe, recipe->tile_wrap != 0, lut, info);
        for (int y = 0; y < n; ++y)
            std::memcpy(out_rgba8 + y * out_row_bytes, &albedo[static_cast<size_t>(y) * n * 4], static_cast<size_t>(n) * 4);
        if (out_info) *out_info = info;
        return 1;
    } catch (const std::exception &e) {
        setError(error, error_capacity, e.what());
        return 0;
    }
}
extern "C" void PBRLabFreeResult(PBRLabResult *result) { delete result; }

// ---------------------------------------------------------------------------------------------------------------
// Learned-guide tiling contract "wrap_padded_rot180_detilted_v2" (docs/LEARNED_NORMALS.md).
namespace {
constexpr int kGuideTile = PBRLAB_GUIDE_TILE;
constexpr int kGuideStride = kGuideTile / 2;
constexpr int kGuidePad = kGuideTile / 2;     // Wrap padding when tiling: half a tile of real context everywhere.
constexpr int kGuideFold = 64;                // Half-width of the periodic fold cross-fade, working pixels.
constexpr int kGuideMargin = 48;              // Tile margin with (almost) no weight: ViT predictions bend there.
constexpr int kGuideMaxWork = 4 * kGuideTile; // 4K sources are inferred at 2072.

// Separable Lanczos-3 resample of RGBA8 (values as data). The kernel widens by the scale factor when
// downsampling; `wrap` reads across opposite edges, otherwise edges clamp.
std::vector<uint8_t> resampleRGBA(const std::vector<uint8_t> &src, int n, int m, bool wrap) {
    if (n == m) return src;
    const double scale = static_cast<double>(n) / m, support = 3.0 * std::max(1.0, scale);
    auto lanczos = [](double x) {
        x = std::abs(x);
        if (x < 1e-9) return 1.0;
        if (x >= 3.0) return 0.0;
        const double px = std::numbers::pi * x;
        return 3.0 * std::sin(px) * std::sin(px / 3.0) / (px * px);
    };
    struct Taps { int first = 0; std::vector<float> w; };
    std::vector<Taps> taps(m);
    for (int o = 0; o < m; ++o) {
        const double center = (o + .5) * scale - .5;
        const int first = static_cast<int>(std::ceil(center - support)), last = static_cast<int>(std::floor(center + support));
        taps[o].first = first;
        double sum = 0;
        for (int k = first; k <= last; ++k) { double w = lanczos((k - center) / std::max(1.0, scale)); taps[o].w.push_back(static_cast<float>(w)); sum += w; }
        for (auto &w : taps[o].w) w = static_cast<float>(w / sum);
    }
    auto index = [&](int k) { return wrap ? wrap_index(k, n) : std::clamp(k, 0, n - 1); };
    std::vector<float> horizontal(static_cast<size_t>(n) * m * 4);
    for (int y = 0; y < n; ++y) for (int o = 0; o < m; ++o) {
        float acc[4]{};
        for (size_t t = 0; t < taps[o].w.size(); ++t) {
            const uint8_t *p = &src[(static_cast<size_t>(y) * n + index(taps[o].first + static_cast<int>(t))) * 4];
            for (int c = 0; c < 4; ++c) acc[c] += taps[o].w[t] * p[c];
        }
        for (int c = 0; c < 4; ++c) horizontal[(static_cast<size_t>(y) * m + o) * 4 + c] = acc[c];
    }
    std::vector<uint8_t> out(static_cast<size_t>(m) * m * 4);
    for (int o = 0; o < m; ++o) for (int x = 0; x < m; ++x) {
        float acc[4]{};
        for (size_t t = 0; t < taps[o].w.size(); ++t) {
            const float *p = &horizontal[(static_cast<size_t>(index(taps[o].first + static_cast<int>(t))) * m + x) * 4];
            for (int c = 0; c < 4; ++c) acc[c] += taps[o].w[t] * p[c];
        }
        for (int c = 0; c < 4; ++c) out[(static_cast<size_t>(o) * m + x) * 4 + c] = static_cast<uint8_t>(std::lround(std::clamp(acc[c], 0.0f, 255.0f)));
    }
    return out;
}

// Removes luminance variation broader than about a sixteenth of the tile (hue kept, gain 0.5..2). Vignetting and
// uneven lighting are not geometry, but a monocular estimator reads them as bowls and domes.
void flattenLowFrequencyLuminance(std::vector<uint8_t> &rgba, int n, bool wrap) {
    std::array<float, 256> lut{};
    for (int i = 0; i < 256; ++i) lut[i] = linear(static_cast<uint8_t>(i));
    const size_t count = static_cast<size_t>(n) * n;
    std::vector<float> logLum(count);
    double mean = 0;
    for (size_t i = 0; i < count; ++i) {
        float l = kLinearLuminance[0] * lut[rgba[i * 4]] + kLinearLuminance[1] * lut[rgba[i * 4 + 1]] + kLinearLuminance[2] * lut[rgba[i * 4 + 2]];
        logLum[i] = std::log(l + kLogLuminanceFloor);
        mean += logLum[i];
    }
    mean /= static_cast<double>(count);
    const int radius = std::max(2, static_cast<int>(std::lround(n / 16.0))); // Three passes: sigma ~ radius.
    auto index = [&](int k) { return wrap ? wrap_index(k, n) : std::clamp(k, 0, n - 1); };
    std::vector<float> a(logLum), b(count);
    for (int pass = 0; pass < 3; ++pass) {
        for (int y = 0; y < n; ++y) {
            double sum = 0;
            for (int d = -radius; d <= radius; ++d) sum += a[static_cast<size_t>(y) * n + index(d)];
            for (int x = 0; x < n; ++x) {
                b[static_cast<size_t>(y) * n + x] = static_cast<float>(sum / (2 * radius + 1));
                sum += a[static_cast<size_t>(y) * n + index(x + radius + 1)] - a[static_cast<size_t>(y) * n + index(x - radius)];
            }
        }
        for (int x = 0; x < n; ++x) {
            double sum = 0;
            for (int d = -radius; d <= radius; ++d) sum += b[static_cast<size_t>(index(d)) * n + x];
            for (int y = 0; y < n; ++y) {
                a[static_cast<size_t>(y) * n + x] = static_cast<float>(sum / (2 * radius + 1));
                sum += b[static_cast<size_t>(index(y + radius + 1)) * n + x] - b[static_cast<size_t>(index(y - radius)) * n + x];
            }
        }
    }
    for (size_t i = 0; i < count; ++i) {
        const float gain = std::clamp(std::exp(static_cast<float>(mean) - a[i]), 0.5f, 2.0f);
        for (int c = 0; c < 3; ++c) rgba[i * 4 + c] = srgbByte(lut[rgba[i * 4 + c]] * gain);
    }
}
} // namespace

struct PBRLabGuideTiler {
    int size = 0, work = 0, pad = 0, padded = 0;
    bool wrap = false;
    std::vector<uint8_t> image;          // Working-size, flattened sRGB RGBA8.
    std::vector<int> origins;
    std::array<float, kGuideTile> window{};
    std::vector<float> accum, slopes;    // Padded field of weighted unit normals; current tile's averaged slopes.
    std::vector<float> field;            // Folded working-size field, built on the first Finish.
    uint32_t nextPass = 0;
    int source(int u) const { return wrap_index(u - pad, work); }
    uint32_t tiles() const { return static_cast<uint32_t>(origins.size() * origins.size()); }
};

extern "C" PBRLabGuideTiler *PBRLabGuideTilerCreate(const uint8_t *rgba8, size_t row_bytes, uint32_t size, uint32_t tile_wrap) {
    if (!rgba8 || size < 2 || size > 4096 || row_bytes < static_cast<size_t>(size) * 4) return nullptr;
    try {
        auto tiler = std::make_unique<PBRLabGuideTiler>();
        const int n = static_cast<int>(size);
        tiler->size = n;
        tiler->wrap = tile_wrap != 0;
        tiler->work = std::clamp(n, kGuideTile, kGuideMaxWork);
        std::vector<uint8_t> source(static_cast<size_t>(n) * n * 4);
        for (int y = 0; y < n; ++y) std::memcpy(&source[static_cast<size_t>(y) * n * 4], rgba8 + y * row_bytes, static_cast<size_t>(n) * 4);
        tiler->image = resampleRGBA(source, n, tiler->work, tiler->wrap);
        flattenLowFrequencyLuminance(tiler->image, tiler->work, tiler->wrap);
        tiler->pad = tiler->wrap ? kGuidePad : 0;
        tiler->padded = tiler->work + 2 * tiler->pad;
        for (int o = 0; o + kGuideTile <= tiler->padded; o += kGuideStride) tiler->origins.push_back(o);
        if (tiler->origins.back() != tiler->padded - kGuideTile) tiler->origins.push_back(tiler->padded - kGuideTile);
        for (int t = 0; t < kGuideTile; ++t) {
            const double u = std::clamp((t + .5 - kGuideMargin) / (kGuideTile - 2.0 * kGuideMargin), 0.0, 1.0);
            const double s = std::sin(std::numbers::pi * u);
            tiler->window[t] = std::max(static_cast<float>(s * s), 1e-6f);
        }
        tiler->accum.assign(static_cast<size_t>(tiler->padded) * tiler->padded * 3, 0.0f);
        tiler->slopes.assign(static_cast<size_t>(kGuideTile) * kGuideTile * 2, 0.0f);
        return tiler.release();
    } catch (...) { return nullptr; }
}
extern "C" uint32_t PBRLabGuideTilerWorkResolution(const PBRLabGuideTiler *t) { return t ? static_cast<uint32_t>(t->work) : 0; }
extern "C" uint32_t PBRLabGuideTilerTileCount(const PBRLabGuideTiler *t) { return t ? t->tiles() : 0; }
extern "C" uint32_t PBRLabGuideTilerPassCount(const PBRLabGuideTiler *t) { return t ? 2 * t->tiles() : 0; }
extern "C" const char *PBRLabGuideTilerContract(const PBRLabGuideTiler *t) {
    return t && t->wrap ? "wrap_padded_rot180_detilted_v2" : "clamped_rot180_detilted_v2";
}
extern "C" int PBRLabGuideTilerFillInput(const PBRLabGuideTiler *t, uint32_t pass, uint8_t *bgra8, size_t row_bytes) {
    if (!t || !bgra8 || pass >= 2 * t->tiles() || row_bytes < static_cast<size_t>(kGuideTile) * 4) return 0;
    const uint32_t index = pass / 2;
    const bool rotated = pass % 2;
    const int ox = t->origins[index % t->origins.size()], oy = t->origins[index / t->origins.size()];
    for (int y = 0; y < kGuideTile; ++y) {
        const int sy = rotated ? kGuideTile - 1 - y : y;
        const uint8_t *srcRow = &t->image[static_cast<size_t>(t->source(oy + sy)) * t->work * 4];
        uint8_t *dst = bgra8 + y * row_bytes;
        for (int x = 0; x < kGuideTile; ++x) {
            const int sx = rotated ? kGuideTile - 1 - x : x;
            const uint8_t *src = srcRow + static_cast<size_t>(t->source(ox + sx)) * 4;
            dst[x * 4] = src[2]; dst[x * 4 + 1] = src[1]; dst[x * 4 + 2] = src[0]; dst[x * 4 + 3] = 255;
        }
    }
    return 1;
}
extern "C" int PBRLabGuideTilerAddPrediction(PBRLabGuideTiler *t, uint32_t pass, const float *normals,
                                             ptrdiff_t cs, ptrdiff_t ys, ptrdiff_t xs) {
    if (!t || !normals || pass != t->nextPass || pass >= 2 * t->tiles()) return 0;
    const bool rotated = pass % 2;
    if (!rotated) std::fill(t->slopes.begin(), t->slopes.end(), 0.0f);
    // Back to the tile frame (a 180-degree turn negates the in-plane components), as slopes, averaged over both
    // orientations: bias fixed in the estimator's view (e.g. "the top recedes") cancels.
    for (int y = 0; y < kGuideTile; ++y) for (int x = 0; x < kGuideTile; ++x) {
        const int py = rotated ? kGuideTile - 1 - y : y, px = rotated ? kGuideTile - 1 - x : x;
        const float *p = normals + py * ys + px * xs;
        const float sign = rotated ? -1.0f : 1.0f, nz = std::max(p[2 * cs], .15f);
        float *sl = &t->slopes[(static_cast<size_t>(y) * kGuideTile + x) * 2];
        sl[0] += .5f * std::clamp(sign * p[0] / nz, -4.0f, 4.0f);
        sl[1] += .5f * std::clamp(sign * p[cs] / nz, -4.0f, 4.0f);
    }
    ++t->nextPass;
    if (!rotated) return 1;
    // Remove the tile's window-weighted affine slope trend (mean tilt plus a uniform bowl, dome or saddle): a
    // stationary texture has neither across one tile, while the estimator adds a per-view camera tilt and
    // curvature that would otherwise stamp the tile grid into the integrated height.
    double m[3][3]{}, rx[3]{}, ry[3]{};
    for (int y = 0; y < kGuideTile; ++y) for (int x = 0; x < kGuideTile; ++x) {
        const double w = static_cast<double>(t->window[x]) * t->window[y];
        const double basis[3] = {1.0, (x + .5) / kGuideTile - .5, (y + .5) / kGuideTile - .5};
        const float *sl = &t->slopes[(static_cast<size_t>(y) * kGuideTile + x) * 2];
        for (int r = 0; r < 3; ++r) {
            for (int c = 0; c < 3; ++c) m[r][c] += w * basis[r] * basis[c];
            rx[r] += w * basis[r] * sl[0]; ry[r] += w * basis[r] * sl[1];
        }
    }
    auto det = [](const double a[3][3]) {
        return a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0]) +
               a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0]);
    };
    auto solve = [&](const double rhs[3], double out[3]) { // Cramer's rule; m is symmetric positive definite.
        const double d = det(m);
        for (int k = 0; k < 3; ++k) {
            double a[3][3];
            for (int r = 0; r < 3; ++r) for (int c = 0; c < 3; ++c) a[r][c] = c == k ? rhs[r] : m[r][c];
            out[k] = det(a) / d;
        }
    };
    double cx[3], cy[3];
    solve(rx, cx); solve(ry, cy);
    const uint32_t index = pass / 2;
    const int ox = t->origins[index % t->origins.size()], oy = t->origins[index / t->origins.size()];
    for (int y = 0; y < kGuideTile; ++y) for (int x = 0; x < kGuideTile; ++x) {
        const double u = (x + .5) / kGuideTile - .5, v = (y + .5) / kGuideTile - .5;
        const float *sl = &t->slopes[(static_cast<size_t>(y) * kGuideTile + x) * 2];
        const float gx = sl[0] - static_cast<float>(cx[0] + cx[1] * u + cx[2] * v);
        const float gy = sl[1] - static_cast<float>(cy[0] + cy[1] * u + cy[2] * v);
        const float w = t->window[x] * t->window[y], inv = 1.0f / std::sqrt(gx * gx + gy * gy + 1.0f);
        float *a = &t->accum[(static_cast<size_t>(oy + y) * t->padded + ox + x) * 3];
        a[0] += w * gx * inv; a[1] += w * gy * inv; a[2] += w * inv;
    }
    return 1;
}
extern "C" int PBRLabGuideTilerFinish(PBRLabGuideTiler *t, uint32_t out_size, uint8_t *rgba8, size_t row_bytes) {
    if (!t || !rgba8 || t->nextPass != 2 * t->tiles() || out_size < 2 || out_size > 4096 ||
        row_bytes < static_cast<size_t>(out_size) * 4) return 0;
    try {
        const int work = t->work, pad = t->pad, padded = t->padded, n = static_cast<int>(out_size);
        // Fold the padded field onto the working tile. fold(u) rises across u = pad and falls across u = pad + work,
        // so fold(u) + fold(u +/- work) = 1 inside both cross-fades (a partition of unity): the field is periodic.
        auto fold = [&](int u) {
            if (!t->wrap) return 1.0f;
            const float c = static_cast<float>(u) + .5f;
            return smoothstep01((c - (pad - kGuideFold)) / (2.0f * kGuideFold)) *
                   (1.0f - smoothstep01((c - (pad + work - kGuideFold)) / (2.0f * kGuideFold)));
        };
        if (t->field.empty()) {
        std::vector<float> &field = t->field;
        field.assign(static_cast<size_t>(work) * work * 3, 0.0f);
        for (int y = 0; y < work; ++y) for (int x = 0; x < work; ++x) {
            float v[3]{};
            for (int ky = -1; ky <= 1; ++ky) {
                const int uy = pad + y + ky * work;
                if (uy < 0 || uy >= padded) continue;
                const float wy = fold(uy);
                if (wy <= 0) continue;
                for (int kx = -1; kx <= 1; ++kx) {
                    const int ux = pad + x + kx * work;
                    if (ux < 0 || ux >= padded) continue;
                    const float w = wy * fold(ux);
                    if (w <= 0) continue;
                    const float *a = &t->accum[(static_cast<size_t>(uy) * padded + ux) * 3];
                    const float length = std::sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]);
                    if (length < 1e-12f) continue;
                    for (int c = 0; c < 3; ++c) v[c] += w * a[c] / length;
                }
            }
            for (int c = 0; c < 3; ++c) field[(static_cast<size_t>(y) * work + x) * 3 + c] = v[c];
        }
        }
        const std::vector<float> &field = t->field;
        auto sampleAt = [&](int x, int y, float out[3]) {
            x = t->wrap ? wrap_index(x, work) : std::clamp(x, 0, work - 1);
            y = t->wrap ? wrap_index(y, work) : std::clamp(y, 0, work - 1);
            const size_t i = static_cast<size_t>(y) * work + x;
            for (int c = 0; c < 3; ++c) out[c] = field[i * 3 + c];
        };
        const float scale = static_cast<float>(work) / static_cast<float>(n);
        for (int y = 0; y < n; ++y) for (int x = 0; x < n; ++x) {
            float fx = (x + .5f) * scale - .5f, fy = (y + .5f) * scale - .5f;
            int x0 = static_cast<int>(std::floor(fx)), y0 = static_cast<int>(std::floor(fy));
            float tx = fx - x0, ty = fy - y0, a[3], b[3], c[3], d[3], v[3];
            sampleAt(x0, y0, a); sampleAt(x0 + 1, y0, b); sampleAt(x0, y0 + 1, c); sampleAt(x0 + 1, y0 + 1, d);
            for (int k = 0; k < 3; ++k) v[k] = (a[k] + (b[k] - a[k]) * tx) * (1 - ty) + (c[k] + (d[k] - c[k]) * tx) * ty;
            float length = std::sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
            if (length < 1e-6f) { v[0] = v[1] = 0; v[2] = length = 1; }
            uint8_t *out = rgba8 + y * row_bytes + static_cast<size_t>(x) * 4;
            for (int k = 0; k < 3; ++k) out[k] = static_cast<uint8_t>(std::lround(std::clamp(v[k] / length * .5f + .5f, 0.0f, 1.0f) * 255));
            out[3] = 255;
        }
        return 1;
    } catch (...) { return 0; }
}
extern "C" void PBRLabGuideTilerFree(PBRLabGuideTiler *t) { delete t; }
