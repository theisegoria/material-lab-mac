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
// Pixel-space height of a unit normalized height step as seen by the AO horizon search at ao_strength 1.
constexpr float kAODepthPixels = 32.0f;
constexpr int kAOSlices = 8;        // Two-sided slices: 16 horizon directions.
constexpr int kAOStepsPerSide = 8;

float clamp01(float v) { return std::clamp(v, 0.0f, 1.0f); }
int wrap(int x, int n) { x %= n; return x < 0 ? x + n : x; }
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
    case PBRLabPresetStone: return high * 1.2f + mid * 1.1f + coarse * 0.35f;
    case PBRLabPresetFabric: return high * 1.75f + mid * 0.45f;
    case PBRLabPresetOrganic: return high * 1.0f + mid * 1.2f + coarse * 0.8f;
    case PBRLabPresetCoatedMetal: return high * 0.65f + mid * 0.25f;
    case PBRLabPresetBareMetal: return high * 0.9f + mid * 0.6f;
    case PBRLabPresetFlat: return 0;
    }
    return 0;
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
    auto in01 = [](float v, float hi) { return std::isfinite(v) && v >= 0 && v <= hi; };
    if (r->preset < PBRLabPresetFlat || r->preset > PBRLabPresetBareMetal ||
        !in01(r->height_strength, .5f) ||
        (r->height_polarity != 1 && r->height_polarity != -1) ||
        !in01(r->roughness_base, 1) || !in01(r->roughness_variation, 1) ||
        !in01(r->ao_radius_pixels, 64) || !in01(r->assigned_metalness, 1) ||
        !in01(r->normal_strength, 16) || !in01(r->ao_strength, 4) ||
        !in01(r->albedo_equalize, 1) || !in01(r->seamless_blend, .45f) ||
        !in01(r->guide_normal_weight, 1) || r->seamless_mode > 1) {
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

// Guide normals -> pixel-space pseudo-height. Normals from scene-trained estimators carry global tilt and
// low-frequency bias on flat texture photos, so only the high-pass part of their slopes is integrated.
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
    const int highPass = std::max(4, width / 16);
    auto lowX = smoothBlur(gx, width, height, highPass, tiled), lowY = smoothBlur(gy, width, height, highPass, tiled);
    for (size_t i = 0; i < count; ++i) { gx[i] -= lowX[i]; gy[i] -= lowY[i]; }
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
int bestCopyOffset(const std::vector<float> &rgb, int n, int band, bool vertical) {
    const int lo = std::max(band + 2, n / 4), hi = std::min(n - band - 2, n - n / 4);
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

void seamCutAxis(std::vector<float> &rgb, std::vector<uint8_t> &alpha, int n, int band, bool vertical) {
    band = std::clamp(band, 4, n / 2 - 4);
    const int half = bestCopyOffset(rgb, n, band, vertical);
    auto index = [&](int across, int along) {
        return vertical ? at(along, across, n) : at(across, along, n); // vertical: cut runs along x.
    };
    const std::vector<float> original(rgb);
    const std::vector<uint8_t> originalAlpha(alpha);
    auto difference = [&](int across, int along) {
        size_t i = index(across, along), j = index((across + half) % n, along);
        float sum = 0;
        for (int c = 0; c < 3; ++c) { float d = original[i * 3 + c] - original[j * 3 + c]; sum += d * d; }
        float da = (static_cast<float>(originalAlpha[i]) - static_cast<float>(originalAlpha[j])) / 255.0f;
        return sum + da * da;
    };
    constexpr float kFeather = 2.0f;
    std::vector<float> weight(static_cast<size_t>(n) * n, 0.0f); // Weight of the offset copy, indexed by index().
    for (int zone = 0; zone < 2; ++zone) {
        const int lo = zone == 0 ? 0 : n - band;
        std::vector<float> cost(static_cast<size_t>(n) * band);
        for (int v = 0; v < n; ++v) for (int u = 0; u < band; ++u) cost[static_cast<size_t>(v) * band + u] = difference(lo + u, v);
        // Start at the band column with the least total difference; end at the same column.
        int start = 1;
        double best = std::numeric_limits<double>::max();
        for (int u = 1; u < band - 1; ++u) {
            double total = 0;
            for (int v = 0; v < n; ++v) total += cost[static_cast<size_t>(v) * band + u];
            if (total < best) { best = total; start = u; }
        }
        const float inf = std::numeric_limits<float>::infinity();
        std::vector<float> energy(static_cast<size_t>(n) * band, inf);
        std::vector<int8_t> step(static_cast<size_t>(n) * band, 0);
        energy[start] = cost[start];
        for (int v = 1; v < n; ++v) for (int u = 1; u < band - 1; ++u) {
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
            for (int k = 1; k < band - 1; ++k) if (energy[static_cast<size_t>(n - 1) * band + k] < e) { e = energy[static_cast<size_t>(n - 1) * band + k]; u = k; }
        }
        for (int v = n - 1; v >= 0; --v) { path[v] = u; u += step[static_cast<size_t>(v) * band + u]; }
        for (int v = 0; v < n; ++v) for (int k = 0; k < band; ++k) {
            // Signed distance toward the image edge, where the offset copy is used.
            float d = zone == 0 ? static_cast<float>(path[v] - k) : static_cast<float>(k - path[v]);
            weight[index(lo + k, v)] = smoothstep01((d + kFeather) / (2.0f * kFeather));
        }
    }
    for (int across = 0; across < n; ++across) for (int along = 0; along < n; ++along) {
        size_t i = index(across, along);
        float w = weight[i];
        if (w <= 0) continue;
        size_t j = index((across + half) % n, along);
        for (int c = 0; c < 3; ++c) rgb[i * 3 + c] = original[i * 3 + c] + (original[j * 3 + c] - original[i * 3 + c]) * w;
        alpha[i] = static_cast<uint8_t>(std::lround(originalAlpha[i] + (static_cast<float>(originalAlpha[j]) - originalAlpha[i]) * w));
    }
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
};

extern "C" const char *PBRLabVersion(void) { return "1.2.0"; }

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
    r.roughness_variation = r.preset == PBRLabPresetFlat ? 0.0f : .15f;
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
    return r;
}

extern "C" PBRLabResult *PBRLabDerive(const PBRLabInput *input, const PBRLabRecipe *recipe,
                                  PBRLabProgressCallback progress, void *context,
                                  char *error, size_t error_capacity) {
    setError(error, error_capacity, "");
    std::string why;
    if (!valid(input, recipe, why)) { setError(error, error_capacity, why.c_str()); return nullptr; }
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

        // Optional source conditioning. Both steps work in linear light and re-encode sRGB albedo;
        // with both disabled the albedo stays a byte-exact copy of the source.
        const int blendWidth = static_cast<int>(std::lround(recipe->seamless_blend * static_cast<float>(width)));
        const bool seamless = blendWidth >= 1 && width >= 8;
        const bool equalize = recipe->albedo_equalize > 0.0f;
        std::vector<float> luminance(count);
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
                auto lowFrequency = smoothBlur(lum, width, height, std::max(2, width / 8), tiled && !seamless);
                const float target = static_cast<float>(mean);
                for (size_t i = 0; i < count; ++i) {
                    float gain = std::pow(target / std::max(lowFrequency[i], 1e-4f), recipe->albedo_equalize);
                    gain = std::clamp(gain, .25f, 4.0f);
                    for (int c = 0; c < 3; ++c) rgb[i * 3 + c] = std::min(rgb[i * 3 + c] * gain, 1.0f);
                }
            }
            if (seamless && recipe->seamless_mode == 1) {
                seamCutAxis(rgb, alpha, width, blendWidth, false);
                seamCutAxis(rgb, alpha, width, blendWidth, true);
            } else if (seamless) {
                // Histogram-preserving half-period offset blend (Heitz & Neyret 2018). The offset copy
                // is continuous across the wrap and its own seam sits where the weight is zero, so one
                // pass per axis removes that axis' seam while the other stays continuous. Blending in
                // Gaussianized space with variance renormalization keeps the texture's contrast and
                // value distribution instead of washing out the blend zone like a linear cross-fade.
                auto weight = [&](int p) {
                    int d = std::min(p, width - 1 - p);
                    return 1.0f - smoothstep01(static_cast<float>(d) / static_cast<float>(blendWidth));
                };
                const int half = width / 2;
                std::vector<float> gauss(count);
                for (int c = 0; c < 3; ++c) {
                    HistogramTransform transform;
                    transform.build(rgb, c, count);
                    for (size_t i = 0; i < count; ++i) gauss[i] = transform.forward(rgb[i * 3 + c]);
                    auto blendAxis = [&](bool vertical) {
                        std::vector<float> source(gauss);
                        for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
                            float w = weight(vertical ? y : x);
                            if (w <= 0) continue;
                            size_t i = at(x, y, width);
                            size_t j = vertical ? at(x, (y + half) % height, width) : at((x + half) % width, y, width);
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
                for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
                    float w = weight(x);
                    if (w <= 0) continue;
                    size_t i = at(x, y, width), j = at((x + half) % width, y, width);
                    alpha[i] = static_cast<uint8_t>(std::lround(alphaCopy[i] + (alphaCopy[j] - alphaCopy[i]) * w));
                }
                alphaCopy = alpha;
                for (int y = 0; y < height; ++y) {
                    float w = weight(y);
                    if (w <= 0) continue;
                    for (int x = 0; x < width; ++x) {
                        size_t i = at(x, y, width), j = at(x, (y + half) % height, width);
                        alpha[i] = static_cast<uint8_t>(std::lround(alphaCopy[i] + (alphaCopy[j] - alphaCopy[i]) * w));
                    }
                }
            }
            parallelRows(height, [&](int y0, int y1) {
                for (int y = y0; y < y1; ++y) for (int x = 0; x < width; ++x) {
                    size_t i = at(x, y, width);
                    for (int c = 0; c < 3; ++c) albedo[i * 4 + c] = srgbByte(rgb[i * 3 + c]);
                    albedo[i * 4 + 3] = alpha[i];
                }
            }, nullptr, nullptr, 0, 0);
        }
        for (size_t i = 0; i < count; ++i)
            luminance[i] = kLinearLuminance[0] * lut[albedo[i * 4]] +
                           kLinearLuminance[1] * lut[albedo[i * 4 + 1]] +
                           kLinearLuminance[2] * lut[albedo[i * 4 + 2]];
        checkpoint(progress, context, .08f);

        const bool inferHeight = !input->height_override_r16 && recipe->preset != PBRLabPresetFlat;
        std::vector<float> small, medium, large, heights(count);
        if (inferHeight) {
            small = smoothBlur(luminance, width, height, 2, tiled);
            checkpoint(progress, context, .14f);
            medium = smoothBlur(luminance, width, height, 8, tiled);
            checkpoint(progress, context, .20f);
            large = smoothBlur(luminance, width, height, 24, tiled);
        }
        const bool useGuide = !input->height_override_r16 && input->guide_normal_rgba8 && recipe->guide_normal_weight > 0;
        std::vector<float> guided;
        if (useGuide) {
            guided = guideHeight(input, width, height, tiled);
            checkpoint(progress, context, .26f);
        }
        const float guideWeight = recipe->guide_normal_weight;
        const float polarity = static_cast<float>(recipe->height_polarity);
        for (int y = 0; y < height; ++y) {
            const uint8_t *mask = input->relief_mask_r8
                ? input->relief_mask_r8 + static_cast<size_t>(y) * input->relief_mask_row_bytes : nullptr;
            const uint8_t *overrideHeight = input->height_override_r16
                ? input->height_override_r16 + static_cast<size_t>(y) * input->height_override_row_bytes : nullptr;
            for (int x = 0; x < width; ++x) {
                size_t i = at(x, y, width);
                float signal = 0;
                if (inferHeight) signal = presetSignal(recipe->preset,
                    luminance[i] - small[i], small[i] - medium[i], medium[i] - large[i]);
                const float maskScale = mask ? static_cast<float>(mask[x]) / 255.0f : 1.0f;
                signal *= maskScale;
                if (overrideHeight) {
                    uint16_t authored = static_cast<uint16_t>(overrideHeight[x * 2] | (overrideHeight[x * 2 + 1] << 8));
                    heights[i] = static_cast<float>(authored) / 65535.0f;
                } else {
                    float inferred = .5f + polarity * recipe->height_strength * signal;
                    // Guide height is geometric (no polarity); pixel units map through the normal depth so that
                    // at normal_strength 1 the exported normal reproduces the guide's high-pass slopes.
                    if (useGuide)
                        inferred += guideWeight * (.5f + maskScale * guided[i] / kNormalDepthPixels - inferred);
                    heights[i] = clamp01(inferred);
                }
                uint16_t q = static_cast<uint16_t>(std::lround(heights[i] * 65535.0f));
                heightMap.data[i * 2] = static_cast<uint8_t>(q & 255);
                heightMap.data[i * 2 + 1] = static_cast<uint8_t>(q >> 8);
            }
        }
        checkpoint(progress, context, .28f);
        const auto localAverage = smoothBlur(heights, width, height, 2, tiled);
        // Roughness variation cue: local micro-contrast of the (delit) luminance relative to the image's
        // mean micro-contrast. Fine-grained areas read rougher and smooth areas glossier, while the
        // image mean stays at the artist's prior. Luminance is used even for authored height or the
        // flat preset because it describes surface finish, not relief.
        std::vector<float> microContrast;
        if (recipe->roughness_variation > 0) {
            auto fine = smoothBlur(luminance, width, height, 2, tiled);
            for (size_t i = 0; i < count; ++i) { float d = luminance[i] - fine[i]; fine[i] = d * d; }
            microContrast = smoothBlur(fine, width, height, 4, tiled);
            double mean = 0;
            for (size_t i = 0; i < count; ++i) { microContrast[i] = std::sqrt(std::max(microContrast[i], 0.0f)); mean += microContrast[i]; }
            const float inverseMean = 1.0f / std::max(static_cast<float>(mean / static_cast<double>(count)), 1e-5f);
            for (auto &m : microContrast) m = std::clamp(m * inverseMean - 1.0f, -1.0f, 1.0f);
        }
        checkpoint(progress, context, .32f);

        const auto slices = makeSlices(recipe->ao_radius_pixels);
        const int reach = static_cast<int>(std::ceil(recipe->ao_radius_pixels)) + 2;
        const float normalDepth = kNormalDepthPixels * recipe->normal_strength;
        const float aoDepth = kAODepthPixels * recipe->ao_strength;
        const bool aoEnabled = aoDepth > 0 && recipe->ao_radius_pixels >= .5f;
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
                    auto H = [&](int xx, int yy) { return heights[at(border(xx, width, tiled), border(yy, height, tiled), width)]; };
                    // Scharr derivative (per pixel): better rotational symmetry than central differences.
                    float a = H(x - 1, y - 1), b = H(x, y - 1), c = H(x + 1, y - 1);
                    float d = H(x - 1, y),                      f = H(x + 1, y);
                    float g = H(x - 1, y + 1), hh = H(x, y + 1), k = H(x + 1, y + 1);
                    float hx = (3.0f * (c + k) + 10.0f * f - 3.0f * (a + g) - 10.0f * d) / 32.0f;
                    float hy = (3.0f * (g + k) + 10.0f * hh - 3.0f * (a + c) - 10.0f * b) / 32.0f;
                    // Image-space surface normal of z = height * depth (x right, y down, z toward viewer).
                    float nxImage = -hx * normalDepth, nyImage = -hy * normalDepth;
                    putNormal(normal, i, nxImage, tangentYSign * nyImage, 1.0f);

                    float localCurvature = heights[i] - localAverage[i];
                    float gradient = std::sqrt(hx * hx + hy * hy);
                    putGray(cavity, i, clamp01(-localCurvature * 12.0f));
                    putGray(convexity, i, clamp01(localCurvature * 12.0f));
                    putGray(slope, i, clamp01(gradient * 16.0f));
                    putGray(edge, i, clamp01(std::abs(localCurvature) * 18.0f));
                    float rough = recipe->roughness_base;
                    if (!microContrast.empty())
                        rough += recipe->roughness_variation * .25f * microContrast[i];
                    rough = clamp01(rough);
                    putGray(roughness, i, rough);

                    // GTAO (Jimenez et al. 2016) cosine-weighted slice integral on the heightfield, viewed
                    // from +Z. The AO geometry uses its own depth scale so AO and normal response are
                    // independently art-directable.
                    float visibility = 1.0f, bentX = 0, bentY = 0, bentZ = 1;
                    if (aoEnabled) {
                        const bool interior = interiorRow && x >= reach && x < width - reach;
                        const float center = heights[i] * aoDepth;
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
                                        const float *row = &heights[i + static_cast<ptrdiff_t>(t.y0) * width + t.x0];
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
extern "C" void PBRLabFreeResult(PBRLabResult *result) { delete result; }
