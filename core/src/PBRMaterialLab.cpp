#include "PBRMaterialLab.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <limits>
#include <memory>
#include <new>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr unsigned kMapCount = 11;
constexpr std::array<float, 3> kLinearLuminance{0.2126f, 0.7152f, 0.0722f};

float clamp01(float v) { return std::clamp(v, 0.0f, 1.0f); }
int wrap(int x, int n) { x %= n; return x < 0 ? x + n : x; }
int border(int x, int n, bool tiled) { return tiled ? wrap(x, n) : std::clamp(x, 0, n - 1); }
size_t at(int x, int y, int width) { return static_cast<size_t>(y) * width + x; }
uint8_t byte(float v) { return static_cast<uint8_t>(std::lround(clamp01(v) * 255.0f)); }
float linear(uint8_t s) {
    float v = static_cast<float>(s) / 255.0f;
    return v <= 0.04045f ? v / 12.92f : std::pow((v + 0.055f) / 1.055f, 2.4f);
}
void setError(char *error, size_t capacity, const char *message) {
    if (!error || !capacity) return;
    std::strncpy(error, message, capacity - 1);
    error[capacity - 1] = '\0';
}
void checkpoint(PBRLabProgressCallback callback, void *context, float progress) {
    if (callback && !callback(progress, context)) throw std::runtime_error("cancelled");
}

struct StoredMap {
    std::vector<uint8_t> data;
    PBRLabPixelFormat format = PBRLabPixelFormatRGBA8Linear;
    size_t rowBytes = 0;
};

std::vector<float> blur(const std::vector<float> &src, int width, int height, int radius, bool tiled) {
    if (radius <= 0) return src;
    std::vector<float> horizontal(src.size()), output(src.size());
    const float divisor = 1.0f / static_cast<float>(2 * radius + 1);
    for (int y = 0; y < height; ++y) {
        float sum = 0;
        for (int d = -radius; d <= radius; ++d)
            sum += src[at(border(d, width, tiled), y, width)];
        for (int x = 0; x < width; ++x) {
            horizontal[at(x, y, width)] = sum * divisor;
            sum += src[at(border(x + radius + 1, width, tiled), y, width)]
                 - src[at(border(x - radius, width, tiled), y, width)];
        }
    }
    for (int x = 0; x < width; ++x) {
        float sum = 0;
        for (int d = -radius; d <= radius; ++d)
            sum += horizontal[at(x, border(d, height, tiled), width)];
        for (int y = 0; y < height; ++y) {
            output[at(x, y, width)] = sum * divisor;
            sum += horizontal[at(x, border(y + radius + 1, height, tiled), width)]
                 - horizontal[at(x, border(y - radius, height, tiled), width)];
        }
    }
    return output;
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
    if (r->preset < PBRLabPresetFlat || r->preset > PBRLabPresetBareMetal ||
        !std::isfinite(r->height_strength) || r->height_strength < 0 || r->height_strength > .5f ||
        (r->height_polarity != 1 && r->height_polarity != -1) ||
        !std::isfinite(r->roughness_base) || r->roughness_base < 0 || r->roughness_base > 1 ||
        !std::isfinite(r->roughness_variation) || r->roughness_variation < 0 || r->roughness_variation > 1 ||
        !std::isfinite(r->ao_radius_pixels) || r->ao_radius_pixels < 0 || r->ao_radius_pixels > 64 ||
        !std::isfinite(r->assigned_metalness) || r->assigned_metalness < 0 || r->assigned_metalness > 1) {
        why = "recipe contains an invalid preset or out-of-range parameter"; return false;
    }
    return true;
}
} // namespace

struct PBRLabResult {
    std::array<StoredMap, kMapCount> maps;
    std::array<bool, kMapCount> present{};
    uint32_t width = 0;
    PBRLabSeamMetrics seam{};
};

extern "C" const char *PBRLabVersion(void) { return "1.0.0"; }

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
        std::vector<float> luminance(count), heights(count);
        float albedoSeam = 0;
        for (int y = 0; y < height; ++y) {
            const uint8_t *src = input->rgba8 + static_cast<size_t>(y) * input->rgba_row_bytes;
            std::memcpy(albedo.data() + static_cast<size_t>(y) * width * 4, src, static_cast<size_t>(width) * 4);
            for (int x = 0; x < width; ++x) {
                size_t i = at(x, y, width);
                luminance[i] = kLinearLuminance[0] * lut[src[x * 4]] +
                               kLinearLuminance[1] * lut[src[x * 4 + 1]] +
                               kLinearLuminance[2] * lut[src[x * 4 + 2]];
            }
        }
        checkpoint(progress, context, .08f);
        const bool inferHeight = !input->height_override_r16 && recipe->preset != PBRLabPresetFlat;
        std::vector<float> small, medium, large;
        if (inferHeight) {
            small = blur(luminance, width, height, 2, tiled);
            checkpoint(progress, context, .16f);
            medium = blur(luminance, width, height, 8, tiled);
            checkpoint(progress, context, .24f);
            large = blur(luminance, width, height, 24, tiled);
        }
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
                if (mask) signal *= static_cast<float>(mask[x]) / 255.0f;
                if (overrideHeight) {
                    uint16_t authored = static_cast<uint16_t>(overrideHeight[x * 2] | (overrideHeight[x * 2 + 1] << 8));
                    heights[i] = static_cast<float>(authored) / 65535.0f;
                } else heights[i] = clamp01(.5f + polarity * recipe->height_strength * signal);
                uint16_t q = static_cast<uint16_t>(std::lround(heights[i] * 65535.0f));
                heightMap.data[i * 2] = static_cast<uint8_t>(q & 255);
                heightMap.data[i * 2 + 1] = static_cast<uint8_t>(q >> 8);
            }
        }
        checkpoint(progress, context, .32f);
        auto localAverage = blur(heights, width, height, 2, tiled);
        constexpr std::array<std::array<int, 2>, 8> directions{{
            {{1, 0}}, {{1, 1}}, {{0, 1}}, {{-1, 1}},
            {{-1, 0}}, {{-1, -1}}, {{0, -1}}, {{1, -1}}
        }};
        for (int y = 0; y < height; ++y) {
            for (int x = 0; x < width; ++x) {
                const size_t i = at(x, y, width);
                float hx = (heights[at(border(x + 1, width, tiled), y, width)] -
                            heights[at(border(x - 1, width, tiled), y, width)]) * .5f;
                float hy = (heights[at(x, border(y + 1, height, tiled), width)] -
                            heights[at(x, border(y - 1, height, tiled), width)]) * .5f;
                // +Y tangent convention: increasing image V tilts the encoded green channel downward.
                putNormal(normal, i, -hx * 8.0f, -hy * 8.0f, 1.0f);
                float localCurvature = heights[i] - localAverage[i];
                float gradient = std::sqrt(hx * hx + hy * hy);
                putGray(cavity, i, clamp01(-localCurvature * 12.0f));
                putGray(convexity, i, clamp01(localCurvature * 12.0f));
                putGray(slope, i, clamp01(gradient * 16.0f));
                putGray(edge, i, clamp01(std::abs(localCurvature) * 18.0f));
                float rough = clamp01(recipe->roughness_base +
                    recipe->roughness_variation * std::clamp(gradient * 4.0f - .05f, -.25f, .25f));
                putGray(roughness, i, rough);
                float visibility = 0, bentX = 0, bentY = 0;
                for (auto [dx, dy] : directions) {
                    float horizon = 0;
                    for (int step = 1; step <= 6; ++step) {
                        float distance = recipe->ao_radius_pixels * static_cast<float>(step) / 6.0f;
                        if (distance < .5f) continue;
                        int xx = border(x + static_cast<int>(std::lround(dx * distance)), width, tiled);
                        int yy = border(y + static_cast<int>(std::lround(dy * distance)), height, tiled);
                        float dxp = dx * distance, dyp = dy * distance;
                        float realDistance = std::sqrt(dxp * dxp + dyp * dyp);
                        float rise = heights[at(xx, yy, width)] - heights[i];
                        horizon = std::max(horizon, rise * 4.0f / std::max(realDistance, .5f));
                    }
                    float open = 1.0f / (1.0f + horizon * 3.0f);
                    visibility += open;
                    bentX += static_cast<float>(dx) * open;
                    bentY += static_cast<float>(dy) * open;
                }
                float occ = visibility / 8.0f;
                putGray(ao, i, occ); // AO convention: 1 is unoccluded.
                if (bent) putNormal(*bent, i, bentX * .1f, bentY * .1f, 1.0f);
                if (orm) {
                    (*orm)[i * 4] = byte(occ);
                    (*orm)[i * 4 + 1] = roughness[i * 4];
                    (*orm)[i * 4 + 2] = byte(recipe->assigned_metalness);
                    (*orm)[i * 4 + 3] = 255;
                }
            }
            if ((y & 63) == 0) checkpoint(progress, context, .34f + .61f * static_cast<float>(y) / height);
        }
        checkpoint(progress, context, .97f);
        float heightDelta = 0, gradientDelta = 0;
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
