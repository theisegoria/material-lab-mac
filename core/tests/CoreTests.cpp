#include "PBRMaterialLab.h"
#undef NDEBUG
#include <algorithm>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <string>
#include <vector>

static std::vector<uint8_t> solid(unsigned n, uint8_t value) {
    std::vector<uint8_t> p(n * n * 4, 255);
    for (size_t i = 0; i < n * n; ++i) p[i * 4] = p[i * 4 + 1] = p[i * 4 + 2] = value;
    return p;
}
static PBRLabMap map(const PBRLabResult* result, PBRLabMapKind kind) {
    PBRLabMap m{};
    assert(PBRLabGetMap(result, kind, &m));
    return m;
}
static uint16_t h(const PBRLabMap& m, unsigned x, unsigned y) {
    size_t i = (static_cast<size_t>(y) * m.width + x) * 2;
    return static_cast<uint16_t>(m.pixels[i] | (m.pixels[i + 1] << 8));
}
static uint8_t v(const PBRLabMap& m, unsigned x, unsigned y, unsigned c = 0) {
    return m.pixels[(static_cast<size_t>(y) * m.width + x) * 4 + c];
}
static PBRLabResult* derive(const std::vector<uint8_t>& source, unsigned n, PBRLabRecipe recipe,
                          const std::vector<uint8_t>* overrideHeight = nullptr,
                          const std::vector<uint8_t>* mask = nullptr) {
    PBRLabInput in{source.data(), n * 4, mask ? mask->data() : nullptr,
                 mask ? n : 0, overrideHeight ? overrideHeight->data() : nullptr,
                 overrideHeight ? n * 2 : 0, n, n, nullptr, 0};
    char error[256]{};
    auto* result = PBRLabDerive(&in, &recipe, nullptr, nullptr, error, sizeof(error));
    if (!result) std::cerr << error << '\n';
    assert(result);
    return result;
}
static int stop(float, void*) { return 0; }
int main() {
    constexpr unsigned n = 32;
    auto source = solid(n, 128);
    auto recipe = PBRLabDefaultRecipe(PBRLabPresetFlat);
    assert(std::strcmp(PBRLabVersion(), "1.5.0") == 0);
    auto* flat = derive(source, n, recipe);
    auto a = map(flat, PBRLabMapAlbedo), hm = map(flat, PBRLabMapHeight);
    auto no = map(flat, PBRLabMapNormal), ro = map(flat, PBRLabMapRoughness);
    auto ao = map(flat, PBRLabMapAO);
    assert(a.format == PBRLabPixelFormatRGBA8SRGB && hm.format == PBRLabPixelFormatR16UNormLE);
    assert(no.format == PBRLabPixelFormatRGBA8Linear && hm.byte_count == n * n * 2);
    assert(h(hm, 5, 5) >= 32767 && h(hm, 5, 5) <= 32768);
    assert(v(no, 5, 5, 0) == 128 && v(no, 5, 5, 1) == 128 && v(no, 5, 5, 2) == 255);
    assert(v(ro, 5, 5, 0) == v(ro, 5, 5, 1) && v(ro, 5, 5, 1) == v(ro, 5, 5, 2));
    assert(v(ao, 5, 5) == 255);
    PBRLabMap missing{};
    assert(!PBRLabGetMap(flat, PBRLabMapORM, &missing));
    assert(PBRLabGetSeamMetrics(flat).height_value_delta == 0);
    PBRLabFreeResult(flat);

    // Painted contrast remains paint with the flat preset.
    for (unsigned y = 0; y < n; ++y) for (unsigned x = 0; x < n; ++x) {
        uint8_t val = (x + y) & 1 ? 0 : 255;
        size_t i = (y * n + x) * 4;
        source[i] = source[i + 1] = source[i + 2] = val;
    }
    flat = derive(source, n, recipe);
    hm = map(flat, PBRLabMapHeight); no = map(flat, PBRLabMapNormal);
    assert(h(hm, 3, 3) == h(hm, 4, 4));
    assert(v(no, 2, 2, 2) == 255);
    PBRLabFreeResult(flat);

    std::vector<uint8_t> relief(n * n * 2, 128);
    for (size_t i = 0; i < n * n; ++i) { relief[i * 2] = 0; relief[i * 2 + 1] = 128; }
    relief[(16 * n + 16) * 2] = 255;
    relief[(16 * n + 16) * 2 + 1] = 255;
    recipe.height_strength = .4f;
    // Spatial scales are defined at 1024 px and scale with the tile: at 32 px, a full-range authored step is
    // 8 * 32/1024 = 0.25 px deep. Deepen it and widen the horizon so the tiny fixtures stay meaningful.
    recipe.normal_strength = 16;
    recipe.ao_radius_pixels = 64;
    recipe.assigned_metalness_enabled = 1;
    recipe.assigned_metalness = .7f;
    recipe.bent_normal_enabled = 1;
    auto* bump = derive(source, n, recipe, &relief);
    hm = map(bump, PBRLabMapHeight); no = map(bump, PBRLabMapNormal);
    auto orm = map(bump, PBRLabMapORM);
    auto bn = map(bump, PBRLabMapBentNormal);
    assert(h(hm, 16, 16) > h(hm, 15, 16));
    assert(v(orm, 16, 16, 2) == static_cast<uint8_t>(std::lround(.7f * 255)));
    assert(v(bn, 0, 0, 2) == 255);
    assert(v(no, 15, 16, 0) < 128); // rising to the right: tangent X normal points left.
    for (unsigned y = 0; y < n; ++y) for (unsigned x = 0; x < n; ++x) {
        float nx = 2.0f * v(no, x, y, 0) / 255.0f - 1.0f;
        float ny = 2.0f * v(no, x, y, 1) / 255.0f - 1.0f;
        float nz = 2.0f * v(no, x, y, 2) / 255.0f - 1.0f;
        float len = std::sqrt(nx * nx + ny * ny + nz * nz);
        assert(nz >= 0 && len >= .98f && len <= 1.02f);
    }
    PBRLabFreeResult(bump);

    // An authored pit yields inward-facing gradients and heightfield occlusion.
    relief[(16 * n + 16) * 2] = 0;
    relief[(16 * n + 16) * 2 + 1] = 0;
    auto* pit = derive(source, n, recipe, &relief);
    hm = map(pit, PBRLabMapHeight); no = map(pit, PBRLabMapNormal);
    ao = map(pit, PBRLabMapAO);
    assert(h(hm, 16, 16) < h(hm, 15, 16));
    assert(v(no, 15, 16, 0) > 128);
    assert(v(ao, 16, 16) < 255);
    // A pit is darker at its floor than on the open plane far from it.
    assert(v(ao, 16, 16) < v(ao, 2, 2));
    assert(v(ao, 2, 2) >= 254);
    assert(PBRLabGetSeamMetrics(pit).height_value_delta < .001f);
    PBRLabFreeResult(pit);

    recipe = PBRLabDefaultRecipe(PBRLabPresetStone);
    recipe.tile_wrap = 0;
    auto* stone = derive(source, n, recipe);
    assert(map(stone, PBRLabMapHeight).byte_count == n * n * 2);
    PBRLabFreeResult(stone);

    // A zero relief mask suppresses RGB-derived geometry while preserving albedo.
    std::vector<uint8_t> zeroMask(n * n, 0);
    stone = derive(source, n, recipe, nullptr, &zeroMask);
    assert(h(map(stone, PBRLabMapHeight), 8, 8) == h(map(stone, PBRLabMapHeight), 15, 15));
    assert(v(map(stone, PBRLabMapNormal), 8, 8, 2) == 255);
    PBRLabFreeResult(stone);

    // Authored height has priority over the mask and rotates normal direction with the ramp.
    std::vector<uint8_t> ramp(n * n * 2);
    for (unsigned y = 0; y < n; ++y) for (unsigned x = 0; x < n; ++x) {
        uint16_t q = static_cast<uint16_t>(x * 65535u / (n - 1));
        ramp[(y * n + x) * 2] = static_cast<uint8_t>(q);
        ramp[(y * n + x) * 2 + 1] = static_cast<uint8_t>(q >> 8);
    }
    stone = derive(source, n, recipe, &ramp, &zeroMask);
    assert(v(map(stone, PBRLabMapNormal), 12, 12, 0) < 128);
    assert(v(map(stone, PBRLabMapNormal), 12, 12, 1) == 128);
    assert(PBRLabGetSeamMetrics(stone).height_value_delta > .2f);
    PBRLabFreeResult(stone);
    for (unsigned y = 0; y < n; ++y) for (unsigned x = 0; x < n; ++x) {
        uint16_t q = static_cast<uint16_t>(y * 65535u / (n - 1));
        ramp[(y * n + x) * 2] = static_cast<uint8_t>(q);
        ramp[(y * n + x) * 2 + 1] = static_cast<uint8_t>(q >> 8);
    }
    stone = derive(source, n, recipe, &ramp);
    // Height rising toward the image bottom faces the image top: +Y / green-up encodes green > 128.
    assert(v(map(stone, PBRLabMapNormal), 12, 12, 0) == 128);
    assert(v(map(stone, PBRLabMapNormal), 12, 12, 1) > 128);
    // A tilted plane is fully open to the sky: GTAO must not self-occlude on slopes.
    assert(v(map(stone, PBRLabMapAO), 12, 12) >= 253);
    PBRLabFreeResult(stone);
    recipe.normal_y_down = 1;
    stone = derive(source, n, recipe, &ramp);
    assert(v(map(stone, PBRLabMapNormal), 12, 12, 1) < 128); // DirectX export flips green only.
    PBRLabFreeResult(stone);
    recipe.normal_y_down = 0;
    recipe.normal_strength = 0;
    stone = derive(source, n, recipe, &ramp);
    assert(v(map(stone, PBRLabMapNormal), 12, 12, 1) == 128 && v(map(stone, PBRLabMapNormal), 12, 12, 2) == 255);
    PBRLabFreeResult(stone);
    recipe.normal_strength = 1;

    // Seamless blend removes an opposite-edge albedo seam; equalize removes a lighting gradient.
    {
        constexpr unsigned m = 64;
        std::vector<uint8_t> gradientSource(m * m * 4, 255);
        for (unsigned y = 0; y < m; ++y) for (unsigned x = 0; x < m; ++x) {
            size_t i = (y * m + x) * 4;
            gradientSource[i] = gradientSource[i + 1] = gradientSource[i + 2] = static_cast<uint8_t>(40 + x * 3);
        }
        auto flatRecipe = PBRLabDefaultRecipe(PBRLabPresetFlat);
        auto* plain = derive(gradientSource, m, flatRecipe);
        float plainSeam = PBRLabGetSeamMetrics(plain).albedo_value_delta;
        assert(std::memcmp(map(plain, PBRLabMapAlbedo).pixels, gradientSource.data(), gradientSource.size()) == 0);
        PBRLabFreeResult(plain);
        flatRecipe.seamless_blend = .25f;
        flatRecipe.seamless_mode = 0;
        auto* blended = derive(gradientSource, m, flatRecipe);
        assert(PBRLabGetSeamMetrics(blended).albedo_value_delta < plainSeam * .2f);
        PBRLabFreeResult(blended);
        flatRecipe.seamless_blend = 0;
        flatRecipe.albedo_equalize = 1;
        auto* even = derive(gradientSource, m, flatRecipe);
        auto evenAlbedo = map(even, PBRLabMapAlbedo);
        int spreadBefore = gradientSource[(32 * m + 44) * 4] - gradientSource[(32 * m + 20) * 4];
        int spreadAfter = std::abs(int(v(evenAlbedo, 44, 32)) - int(v(evenAlbedo, 20, 32)));
        assert(spreadAfter * 3 < spreadBefore);
        PBRLabFreeResult(even);
    }

    // Histogram-preserving tiling keeps blend-zone contrast and leaves the interior byte-exact.
    {
        constexpr unsigned m = 128;
        std::vector<uint8_t> noiseSource(m * m * 4, 255);
        uint32_t seed = 777;
        for (size_t i = 0; i < m * m; ++i) {
            seed = seed * 1664525u + 1013904223u;
            noiseSource[i * 4] = noiseSource[i * 4 + 1] = noiseSource[i * 4 + 2] = static_cast<uint8_t>(seed >> 24);
        }
        auto tileRecipe = PBRLabDefaultRecipe(PBRLabPresetFlat);
        tileRecipe.seamless_blend = .2f;
        tileRecipe.seamless_mode = 0;
        auto* tiled = derive(noiseSource, m, tileRecipe);
        auto out = map(tiled, PBRLabMapAlbedo);
        auto deviation = [&](const uint8_t* px, unsigned x0, unsigned x1) {
            double sum = 0, sq = 0; unsigned k = 0;
            for (unsigned y = 40; y < 88; ++y) for (unsigned x = x0; x < x1; ++x, ++k) {
                double val = px[(y * m + x) * 4]; sum += val; sq += val * val;
            }
            double mean = sum / k; return std::sqrt(sq / k - mean * mean);
        };
        // Column 12 of 128 with a 26 px zone has weight ~0.5, where a linear cross-fade of independent
        // noise loses ~30% of its standard deviation.
        double before = deviation(noiseSource.data(), 10, 15), after = deviation(out.pixels, 10, 15);
        assert(after > before * .85 && after < before * 1.15);
        for (unsigned y = 40; y < 88; ++y) for (unsigned x = 40; x < 88; ++x)
            assert(out.pixels[(y * m + x) * 4] == noiseSource[(y * m + x) * 4]);
        PBRLabFreeResult(tiled);
    }

    // Roughness variation: grainy regions read rougher than smooth ones around the artist's prior.
    {
        constexpr unsigned m = 64;
        std::vector<uint8_t> split(m * m * 4, 255);
        uint32_t seed = 99;
        for (unsigned y = 0; y < m; ++y) for (unsigned x = 0; x < m; ++x) {
            seed = seed * 1664525u + 1013904223u;
            uint8_t val = x < m / 2 ? static_cast<uint8_t>(96 + ((seed >> 24) & 63)) : 128;
            size_t i = (y * m + x) * 4;
            split[i] = split[i + 1] = split[i + 2] = val;
        }
        auto roughRecipe = PBRLabDefaultRecipe(PBRLabPresetStone);
        roughRecipe.roughness_variation = 1;
        auto* result = derive(split, m, roughRecipe);
        auto ro2 = map(result, PBRLabMapRoughness);
        int base = static_cast<int>(std::lround(roughRecipe.roughness_base * 255));
        assert(v(ro2, 16, 32) > base && v(ro2, 48, 32) < base);
        PBRLabFreeResult(result);
    }

    // Guide normals (the learned-estimator path) integrate back to the height that produced them.
    {
        constexpr unsigned m = 128;
        std::vector<uint8_t> gray(m * m * 4, 255), authored(m * m * 2);
        for (size_t i = 0; i < m * m; ++i) gray[i * 4] = gray[i * 4 + 1] = gray[i * 4 + 2] = 128;
        std::vector<float> truth(m * m, 0.5f);
        const int bumps[][3] = {{30, 30, 1}, {90, 40, -1}, {60, 95, 1}, {100, 100, -1}, {20, 80, 1}};
        for (unsigned y = 0; y < m; ++y) for (unsigned x = 0; x < m; ++x) {
            float h = .5f;
            for (auto& b : bumps) {
                float dx = float(x) - b[0], dy = float(y) - b[1];
                h += .12f * b[2] * std::exp(-(dx * dx + dy * dy) / (2 * 3.5f * 3.5f));
            }
            truth[y * m + x] = h;
            uint16_t q = static_cast<uint16_t>(std::lround(h * 65535));
            authored[(y * m + x) * 2] = q & 255; authored[(y * m + x) * 2 + 1] = q >> 8;
        }
        auto flatRecipe = PBRLabDefaultRecipe(PBRLabPresetFlat);
        auto* source = derive(gray, m, flatRecipe, &authored);
        auto sourceNormal = map(source, PBRLabMapNormal);
        std::vector<uint8_t> guide(sourceNormal.pixels, sourceNormal.pixels + sourceNormal.byte_count);
        PBRLabFreeResult(source);

        flatRecipe.guide_normal_weight = 1;
        PBRLabInput in{gray.data(), m * 4, nullptr, 0, nullptr, 0, m, m, guide.data(), m * 4};
        char err[256]{};
        auto* guided = PBRLabDerive(&in, &flatRecipe, nullptr, nullptr, err, sizeof(err));
        assert(guided);
        auto guidedNormal = map(guided, PBRLabMapNormal), guidedHeight = map(guided, PBRLabMapHeight);
        double normalError = 0, meanTruth = 0, meanOut = 0;
        for (size_t i = 0; i < m * m; ++i) {
            for (int c = 0; c < 3; ++c) normalError += std::abs(int(guidedNormal.pixels[i * 4 + c]) - int(guide[i * 4 + c]));
            meanTruth += truth[i]; meanOut += h(guidedHeight, i % m, i / m) / 65535.0;
        }
        normalError /= m * m * 3.0; meanTruth /= m * m; meanOut /= m * m;
        double cov = 0, varA = 0, varB = 0;
        for (size_t i = 0; i < m * m; ++i) {
            double a = truth[i] - meanTruth, b = h(guidedHeight, i % m, i / m) / 65535.0 - meanOut;
            cov += a * b; varA += a * a; varB += b * b;
        }
        double correlation = cov / std::sqrt(varA * varB);
        std::cout << "guide round trip: mean normal error " << normalError << " levels, height correlation " << correlation << "\n";
        assert(normalError < 2.5 && correlation > .85); // High-pass tilt removal drops the lowest frequencies by design.
        // A bump reads as a bump and a pit as a pit (no sign flip through the +Y decode).
        assert(h(guidedHeight, 30, 30) > h(guidedHeight, 45, 30) && h(guidedHeight, 90, 40) < h(guidedHeight, 75, 40));
        PBRLabFreeResult(guided);

        flatRecipe.guide_normal_weight = 0; // Weight 0 ignores the guide entirely.
        auto* ignored = PBRLabDerive(&in, &flatRecipe, nullptr, nullptr, err, sizeof(err));
        assert(ignored && v(map(ignored, PBRLabMapNormal), 30, 26, 1) == 128);
        PBRLabFreeResult(ignored);
    }

    // Seam-cut tiling (the default mode).
    {
        constexpr unsigned m = 96;
        auto cutRecipe = PBRLabDefaultRecipe(PBRLabPresetFlat);
        assert(cutRecipe.seamless_mode == 1);
        // 1. A smooth, non-periodic pattern: the wrap mismatch drops to the level of neighbouring pixels.
        std::vector<uint8_t> smooth(m * m * 4, 255);
        for (unsigned y = 0; y < m; ++y) for (unsigned x = 0; x < m; ++x) {
            double val = 128 + 55 * std::sin(6.2831853 * x / 37.0) + 35 * std::sin(6.2831853 * y / 29.0 + .7);
            size_t i = (y * m + x) * 4;
            smooth[i] = smooth[i + 1] = smooth[i + 2] = static_cast<uint8_t>(std::lround(val));
        }
        auto* plain = derive(smooth, m, cutRecipe);
        float before = PBRLabGetSeamMetrics(plain).albedo_value_delta;
        PBRLabFreeResult(plain);
        cutRecipe.seamless_blend = .2f;
        auto* cut = derive(smooth, m, cutRecipe);
        float after = PBRLabGetSeamMetrics(cut).albedo_value_delta;
        auto cutAlbedo = map(cut, PBRLabMapAlbedo);
        // 2. Pixels outside both edge bands are untouched.
        for (unsigned y = 24; y < 72; ++y) for (unsigned x = 24; x < 72; ++x)
            assert(cutAlbedo.pixels[(y * m + x) * 4] == smooth[(y * m + x) * 4]);
        std::cout << "seam cut: smooth-pattern wrap mismatch " << before << " -> " << after << "\n";
        assert(after < before * .3f);
        PBRLabFreeResult(cut);
        // 3. Stripes whose period does not fit the tile: the cut hides the unavoidable defect in one place
        //    and leaves only feathered pixels along its path; a cross-fade ghosts whole bands.
        std::vector<uint8_t> stripes(m * m * 4, 255);
        for (unsigned y = 0; y < m; ++y) for (unsigned x = 0; x < m; ++x) {
            uint8_t val = ((x / 5) % 2 ? 40 : 220);
            size_t i = (y * m + x) * 4;
            stripes[i] = stripes[i + 1] = stripes[i + 2] = val;
        }
        auto countMixed = [&](const PBRLabMap& albedoMap) {
            size_t count = 0;
            for (size_t i = 0; i < m * m; ++i) if (albedoMap.pixels[i * 4] != 40 && albedoMap.pixels[i * 4] != 220) ++count;
            return count;
        };
        auto* stripeCut = derive(stripes, m, cutRecipe);
        size_t mixed = countMixed(map(stripeCut, PBRLabMapAlbedo));
        PBRLabFreeResult(stripeCut);
        cutRecipe.seamless_mode = 0;
        auto* stripeBlend = derive(stripes, m, cutRecipe);
        size_t blendedMixed = countMixed(map(stripeBlend, PBRLabMapAlbedo));
        PBRLabFreeResult(stripeBlend);
        std::cout << "seam cut: intermediate pixels " << mixed << " (blend " << blendedMixed << ")\n";
        assert(mixed < m * m / 20 && blendedMixed > mixed * 2);
        // 4. An axis that already tiles (period 8 fits 96) is left untouched; the other axis is still cut.
        std::vector<uint8_t> fitting(m * m * 4, 255);
        for (unsigned y = 0; y < m; ++y) for (unsigned x = 0; x < m; ++x) {
            // x-periodic; a slow ramp in y makes the vertical wrap far rougher than any interior row pair.
            uint8_t val = static_cast<uint8_t>(((x / 4) % 2 ? 40 : 180) + y * 60 / (m - 1));
            size_t i = (y * m + x) * 4;
            fitting[i] = fitting[i + 1] = fitting[i + 2] = val;
        }
        cutRecipe.seamless_mode = 1;
        auto* fit = derive(fitting, m, cutRecipe);
        auto fitAlbedo = map(fit, PBRLabMapAlbedo);
        size_t xTouched = 0, yTouched = 0;
        for (unsigned y = 24; y < 72; ++y) for (unsigned x = 0; x < 19; ++x)
            if (fitAlbedo.pixels[(y * m + x) * 4] != fitting[(y * m + x) * 4]) ++xTouched;
        for (unsigned y = 0; y < 19; ++y) for (unsigned x = 24; x < 72; ++x)
            if (fitAlbedo.pixels[(y * m + x) * 4] != fitting[(y * m + x) * 4]) ++yTouched;
        std::cout << "seam cut: already-tiling axis touched " << xTouched << " px, non-tiling axis " << yTouched << " px\n";
        assert(xTouched == 0 && yTouched > 0);
        PBRLabFreeResult(fit);
        cutRecipe.seamless_mode = 2;
        PBRLabInput bad{stripes.data(), m * 4, nullptr, 0, nullptr, 0, m, m, nullptr, 0};
        char err[128]{};
        assert(!PBRLabDerive(&bad, &cutRecipe, nullptr, nullptr, err, sizeof(err)));
    }

    // 1.3.0 geometry: periodic learned integration, range-normalized height, frequency-split fusion,
    // learned detail polarity, normal strength in every mode, varied roughness, resolution invariance.
    {
        constexpr unsigned m = 256;
        auto meanNxy = [&](const PBRLabMap& nm) {
            double sum = 0;
            for (size_t i = 0; i < size_t(nm.width) * nm.width; ++i) {
                double x = nm.pixels[i * 4] / 127.5 - 1, y = nm.pixels[i * 4 + 1] / 127.5 - 1;
                sum += std::sqrt(x * x + y * y);
            }
            return sum / (double(nm.width) * nm.width);
        };
        auto heightAt = [&](const PBRLabMap& hmap, unsigned x, unsigned y) { return h(hmap, x, y) / 65535.0; };
        // Periodic bumps, including ones straddling both wrap lines: wrap distance on the torus.
        struct Bump { float x, y, sign; };
        const Bump bumps[] = {{3, 128, 1}, {128, 2, -1}, {250, 250, 1}, {70, 60, 1}, {180, 110, -1}, {100, 200, 1}, {220, 40, -1}};
        std::vector<uint8_t> authored(m * m * 2);
        for (unsigned y = 0; y < m; ++y) for (unsigned x = 0; x < m; ++x) {
            double v = .5;
            for (auto& b : bumps) {
                double dx = std::fabs(double(x) - b.x), dy = std::fabs(double(y) - b.y);
                dx = std::min(dx, m - dx); dy = std::min(dy, m - dy);
                v += .3 * b.sign * std::exp(-(dx * dx + dy * dy) / (2 * 9.0 * 9.0));
            }
            uint16_t q = static_cast<uint16_t>(std::lround(std::clamp(v, 0.0, 1.0) * 65535));
            authored[(y * m + x) * 2] = q & 255; authored[(y * m + x) * 2 + 1] = q >> 8;
        }
        std::vector<uint8_t> gray(m * m * 4, 255);
        for (size_t i = 0; i < m * m; ++i) gray[i * 4] = gray[i * 4 + 1] = gray[i * 4 + 2] = 128;
        auto makeGuide = [&](float strength) {
            auto r = PBRLabDefaultRecipe(PBRLabPresetFlat);
            r.normal_strength = strength;
            auto* source = derive(gray, m, r, &authored);
            auto nm = map(source, PBRLabMapNormal);
            std::vector<uint8_t> guide(nm.pixels, nm.pixels + nm.byte_count);
            PBRLabFreeResult(source);
            return guide;
        };
        auto guided = [&](const std::vector<uint8_t>& albedo, const std::vector<uint8_t>& guide, PBRLabRecipe r) {
            PBRLabInput in{albedo.data(), m * 4, nullptr, 0, nullptr, 0, m, m, guide.data(), m * 4};
            char err[256]{};
            auto* result = PBRLabDerive(&in, &r, nullptr, nullptr, err, sizeof(err));
            if (!result) std::cerr << err << '\n';
            assert(result);
            return result;
        };
        // 1. Tiled learned integration is periodic: no frame falling off to the border and no wrap seam.
        auto guide = makeGuide(16);
        auto flatGuided = PBRLabDefaultRecipe(PBRLabPresetFlat);
        flatGuided.guide_normal_weight = 1;
        auto* lg = guided(gray, guide, flatGuided);
        auto lh = map(lg, PBRLabMapHeight);
        double border = 0, interior = 0, seam = 0, neighbour = 0; unsigned nb = 0, ni = 0;
        for (unsigned y = 0; y < m; ++y) for (unsigned x = 0; x < m; ++x) {
            bool edge = x < 13 || y < 13 || x >= m - 13 || y >= m - 13;
            (edge ? border : interior) += heightAt(lh, x, y); ++(edge ? nb : ni);
        }
        // Compare the wrap step with the steps beside it (a bump straddles the seam, so the global mean is too low).
        for (unsigned y = 0; y < m; ++y)
            neighbour += .5 * (std::fabs(heightAt(lh, 1, y) - heightAt(lh, 0, y)) + std::fabs(heightAt(lh, m - 1, y) - heightAt(lh, m - 2, y)));
        for (unsigned y = 0; y < m; ++y) seam += std::fabs(heightAt(lh, 0, y) - heightAt(lh, m - 1, y));
        double borderOffset = border / nb - interior / ni, seamRatio = seam / neighbour;
        std::cout << "learned periodic: border offset " << borderOffset << ", wrap seam ratio " << seamRatio << "\n";
        assert(std::fabs(borderOffset) < .03 && seamRatio < 1.5);
        // 2. Estimated height is rescaled to the full 16-bit range, never clamped into plateaus.
        size_t atLimits = 0;
        for (unsigned y = 0; y < m; ++y) for (unsigned x = 0; x < m; ++x) atLimits += h(lh, x, y) == 0 || h(lh, x, y) == 65535;
        assert(atLimits <= 4);
        auto info = PBRLabGetDerivationInfo(lg);
        assert(info.height_span_tile_widths > 0 && info.learned_form_share == 1);
        PBRLabFreeResult(lg);

        // Albedo: fine noise plus dark spots exactly where the guide has bumps (either sign).
        std::vector<uint8_t> spotted(m * m * 4, 255);
        uint32_t seed = 4242;
        for (unsigned y = 0; y < m; ++y) for (unsigned x = 0; x < m; ++x) {
            seed = seed * 1664525u + 1013904223u;
            double v = 150 + ((seed >> 24) & 7) - 4;
            for (auto& b : bumps) {
                double dx = std::fabs(double(x) - b.x), dy = std::fabs(double(y) - b.y);
                dx = std::min(dx, m - dx); dy = std::min(dy, m - dy);
                v -= 90 * b.sign * std::exp(-(dx * dx + dy * dy) / (2 * 9.0 * 9.0));
            }
            size_t i = (y * m + x) * 4;
            spotted[i] = spotted[i + 1] = spotted[i + 2] = static_cast<uint8_t>(std::clamp(v, 0.0, 255.0));
        }
        auto stoneGuided = PBRLabDefaultRecipe(PBRLabPresetStone);
        stoneGuided.guide_normal_weight = 1;
        // 3. The learned field orients albedo detail: dark-where-raised flips the default polarity.
        auto* fused = guided(spotted, guide, stoneGuided);
        info = PBRLabGetDerivationInfo(fused);
        std::cout << "learned polarity: correlation " << info.learned_detail_correlation << ", polarity " << info.detail_polarity
                  << ", form share " << info.learned_form_share << "\n";
        assert(info.learned_detail_correlation < -.1f && info.detail_polarity == -1);
        auto fh = map(fused, PBRLabMapHeight);
        assert(h(fh, 70, 60) > h(fh, 85, 60) && h(fh, 180, 110) < h(fh, 195, 110)); // Bumps up, pits down.
        // height_polarity -1 inverts the learned relief as well (1.4.0).
        {
            auto flipped = stoneGuided;
            flipped.height_polarity = -1;
            auto* inverse = guided(spotted, guide, flipped);
            auto ih = map(inverse, PBRLabMapHeight);
            assert(h(ih, 70, 60) < h(ih, 85, 60) && h(ih, 180, 110) > h(ih, 195, 110));
            assert(PBRLabGetDerivationInfo(inverse).detail_polarity == 1);
            PBRLabFreeResult(inverse);
        }
        // 4. Detail preservation: fused normals keep the albedo's fine grain, which the smooth guide lacks.
        auto fineEnergy = [&](const PBRLabMap& nm) {
            double sum = 0;
            for (unsigned y = 0; y < m; ++y) for (unsigned x = 0; x + 1 < m; ++x)
                sum += std::abs(int(nm.pixels[(y * m + x + 1) * 4]) - int(nm.pixels[(y * m + x) * 4]));
            return sum / (m * (m - 1.0));
        };
        auto* learnedOnly = guided(gray, guide, flatGuided);
        double fusedFine = fineEnergy(map(fused, PBRLabMapNormal)), learnedFine = fineEnergy(map(learnedOnly, PBRLabMapNormal));
        std::cout << "fused fine-normal energy " << fusedFine << " vs learned-only " << learnedFine << "\n";
        assert(fusedFine > 2 * learnedFine);
        PBRLabFreeResult(learnedOnly);
        // 5. normal_strength scales the final normals in learned mode too (and AO follows the geometry).
        const double nxy1 = meanNxy(map(fused, PBRLabMapNormal));
        stoneGuided.normal_strength = 4;
        auto* strong = guided(spotted, guide, stoneGuided);
        const double nxy4 = meanNxy(map(strong, PBRLabMapNormal));
        std::cout << "learned normal strength 1 -> 4: mean |xy| " << nxy1 << " -> " << nxy4 << "\n";
        assert(nxy4 > 2.2 * nxy1);
        auto meanAO = [&](const PBRLabResult* r) {
            auto a = map(r, PBRLabMapAO); double s = 0;
            for (size_t i = 0; i < m * m; ++i) s += a.pixels[i * 4];
            return s / (m * m * 255.0);
        };
        assert(meanAO(strong) < meanAO(fused));
        PBRLabFreeResult(strong);
        PBRLabFreeResult(fused);
        // 6. Threaded guided derivation is deterministic.
        stoneGuided.normal_strength = 1;
        auto* g1 = guided(spotted, guide, stoneGuided);
        auto* g2 = guided(spotted, guide, stoneGuided);
        for (auto kind : {PBRLabMapNormal, PBRLabMapAO, PBRLabMapHeight, PBRLabMapRoughness}) {
            auto a1 = map(g1, kind), a2 = map(g2, kind);
            assert(std::memcmp(a1.pixels, a2.pixels, a1.byte_count) == 0);
        }
        PBRLabFreeResult(g1); PBRLabFreeResult(g2);

        // 7. Relief amplitude is the preset prior (rms slope), whatever the albedo's brightness or contrast,
        //    and the same at 256 and 512 for the same surface.
        auto sines = [&](unsigned size, double gain, double offset) {
            std::vector<uint8_t> px(size * size * 4, 255);
            for (unsigned y = 0; y < size; ++y) for (unsigned x = 0; x < size; ++x) {
                double u = double(x) / size, v = double(y) / size;
                double val = offset * (1 + gain * (std::sin(6.2831853 * 7 * u) * std::sin(6.2831853 * 5 * v) +
                                                   .5 * std::sin(6.2831853 * (19 * u + 11 * v))));
                size_t i = (y * size + x) * 4;
                px[i] = px[i + 1] = px[i + 2] = static_cast<uint8_t>(std::clamp(std::lround(val), 0L, 255L));
            }
            return px;
        };
        auto stone = PBRLabDefaultRecipe(PBRLabPresetStone);
        auto* dark = derive(sines(256, .3, 40), 256, stone);
        auto* pale = derive(sines(256, .1, 200), 256, stone);
        auto* big = derive(sines(512, .3, 40), 512, stone);
        auto di = PBRLabGetDerivationInfo(dark), pi = PBRLabGetDerivationInfo(pale), bi = PBRLabGetDerivationInfo(big);
        std::cout << "rms slope dark " << di.rms_slope << ", pale " << pi.rms_slope << ", 512 " << bi.rms_slope
                  << "\n";
        assert(std::fabs(di.rms_slope - .3f) < .01f && std::fabs(pi.rms_slope - .3f) < .01f && std::fabs(bi.rms_slope - .3f) < .01f);
        assert(std::fabs(di.height_span_tile_widths - bi.height_span_tile_widths) < .15f * di.height_span_tile_widths);
        auto meanAOAt = [&](const PBRLabResult* r, unsigned size) {
            auto a = map(r, PBRLabMapAO); double sum = 0;
            for (size_t i = 0; i < size_t(size) * size; ++i) sum += a.pixels[i * 4];
            return sum / (double(size) * size * 255.0);
        };
        std::cout << "AO mean 256 " << meanAOAt(dark, 256) << " vs 512 " << meanAOAt(big, 512) << "\n";
        assert(std::fabs(meanAOAt(dark, 256) - meanAOAt(big, 512)) < .03); // AO radius scales with the tile.
        PBRLabFreeResult(pale); PBRLabFreeResult(big);
        // 8. Roughness varies within the preset's physical range and follows roughness_variation.
        auto roughStats = [&](const PBRLabResult* r, unsigned size, double& mean, double& deviation, int& lo, int& hi) {
            auto rm = map(r, PBRLabMapRoughness); double s = 0, q = 0; lo = 255; hi = 0;
            for (size_t i = 0; i < size_t(size) * size; ++i) {
                int v = rm.pixels[i * 4]; s += v; q += double(v) * v; lo = std::min(lo, v); hi = std::max(hi, v);
            }
            mean = s / (double(size) * size * 255); deviation = std::sqrt(q / (double(size) * size) - std::pow(s / (double(size) * size), 2)) / 255;
        };
        double mean1, dev1, mean2, dev2; int lo1, hi1, lo2, hi2;
        roughStats(dark, 256, mean1, dev1, lo1, hi1);
        PBRLabFreeResult(dark);
        stone.roughness_variation = 1;
        auto* varied = derive(sines(256, .3, 40), 256, stone);
        roughStats(varied, 256, mean2, dev2, lo2, hi2);
        PBRLabFreeResult(varied);
        std::cout << "roughness variation .3: " << mean1 << " +/- " << dev1 << "; 1.0: " << mean2 << " +/- " << dev2 << "\n";
        assert(dev1 > .04 && dev2 > 2 * dev1 && std::fabs(mean1 - .78) < .02);
        assert(lo2 >= std::lround(.45 * 255) && hi2 <= std::lround(.98 * 255));
    }

    // Guide tiler contract: a fake estimator that reads slopes from the tile it is shown, plus a bias fixed in its
    // own view (tilt and a bowl), must give back the source's slope field, periodic, with the bias removed.
    {
        constexpr unsigned m = 518;
        constexpr double kSlope = 1.0 / 400.0;
        std::vector<uint8_t> src(m * m * 4, 255);
        auto value = [&](double x, double y) {
            return 128 + 60 * std::sin(6.283185307 * 7 * x / m) * std::sin(6.283185307 * 5 * y / m) +
                   30 * std::sin(6.283185307 * (11 * x + 3 * y) / m);
        };
        for (unsigned y = 0; y < m; ++y) for (unsigned x = 0; x < m; ++x) {
            size_t i = (y * m + x) * 4;
            src[i] = src[i + 1] = src[i + 2] = static_cast<uint8_t>(std::lround(value(x, y)));
        }
        auto* tiler = PBRLabGuideTilerCreate(src.data(), m * 4, m, 1);
        assert(tiler && PBRLabGuideTilerWorkResolution(tiler) == m && PBRLabGuideTilerPassCount(tiler) == 18);
        assert(std::string(PBRLabGuideTilerContract(tiler)) == "wrap_padded_rot180_detilted_v2");
        constexpr int T = PBRLAB_GUIDE_TILE;
        std::vector<uint8_t> input(T * T * 4);
        std::vector<float> prediction(3 * T * T);
        for (uint32_t pass = 0; pass < PBRLabGuideTilerPassCount(tiler); ++pass) {
            assert(PBRLabGuideTilerFillInput(tiler, pass, input.data(), T * 4));
            for (int y = 0; y < T; ++y) for (int x = 0; x < T; ++x) {
                auto R = [&](int xx, int yy) { return double(input[(std::clamp(yy, 0, T - 1) * T + std::clamp(xx, 0, T - 1)) * 4 + 2]); };
                double u = (x + .5) / T - .5, v = (y + .5) / T - .5;
                double nx = (R(x + 1, y) - R(x - 1, y)) * .5 * kSlope + .2 + .3 * u;
                double ny = (R(x, y + 1) - R(x, y - 1)) * .5 * kSlope - .1 + .2 * v;
                double len = std::sqrt(nx * nx + ny * ny + 1);
                prediction[(0 * T + y) * T + x] = float(nx / len);
                prediction[(1 * T + y) * T + x] = float(ny / len);
                prediction[(2 * T + y) * T + x] = float(1 / len);
            }
            assert(PBRLabGuideTilerAddPrediction(tiler, pass, prediction.data(), T * T, T, 1));
        }
        std::vector<uint8_t> guide(m * m * 4);
        assert(PBRLabGuideTilerFinish(tiler, m, guide.data(), m * 4));
        PBRLabGuideTilerFree(tiler);
        // The source is flattened only at very low frequency, so its slopes are unchanged in this band.
        double error = 0, seam = 0, inner = 0;
        for (unsigned y = 0; y < m; ++y) for (unsigned x = 0; x < m; ++x) {
            double gx = (value(x + 1, y) - value(x - 1.0, y)) * .5 * kSlope, gy = (value(x, y + 1) - value(x, y - 1.0)) * .5 * kSlope;
            double len = std::sqrt(gx * gx + gy * gy + 1);
            error += std::fabs(guide[(y * m + x) * 4] - (gx / len * .5 + .5) * 255) + std::fabs(guide[(y * m + x) * 4 + 1] - (gy / len * .5 + .5) * 255);
        }
        for (unsigned y = 0; y < m; ++y) {
            seam += std::abs(int(guide[(y * m) * 4]) - int(guide[(y * m + m - 1) * 4]));
            inner += std::abs(int(guide[(y * m + 1) * 4]) - int(guide[(y * m) * 4]));
        }
        error /= 2.0 * m * m;
        std::cout << "guide tiler: mean error " << error << " levels (bias 0.2 tilt + bowl removed), wrap step " << seam / m
                  << " vs neighbour " << inner / m << "\n";
        assert(error < 3 && seam < 1.5 * inner + m);
    }

    // 1.4.0 albedo repair: a non-tileable albedo becomes tileable; ConditionAlbedo matches Derive byte for byte.
    {
        constexpr unsigned m = 256;
        // Litter-like: random oriented strokes over a lighting ramp, plus a smeared, darker strip along both wraps.
        std::vector<uint8_t> src(m * m * 4, 255);
        std::vector<float> field(m * m);
        uint32_t seed = 31337;
        auto rnd = [&]() { seed = seed * 1664525u + 1013904223u; return (seed >> 8) / 16777216.0f; };
        for (unsigned y = 0; y < m; ++y) for (unsigned x = 0; x < m; ++x) field[y * m + x] = .35f + .25f * x / m;
        for (int s = 0; s < 900; ++s) {
            float cx = rnd() * m, cy = rnd() * m, a = rnd() * 3.14159f, len = 6 + rnd() * 18, v = .3f + .6f * rnd();
            for (float t = -len; t <= len; t += .5f) {
                int px = int(cx + t * std::cos(a)), py = int(cy + t * std::sin(a));
                if (px >= 0 && py >= 0 && px < int(m) && py < int(m)) field[py * m + px] = v;
            }
        }
        for (unsigned y = 0; y < m; ++y) for (unsigned x = 0; x < m; ++x) {
            unsigned d = std::min(std::min(x, m - 1 - x), std::min(y, m - 1 - y));
            float v = field[y * m + x];
            if (d < 6) v = .5f * v + .5f * .3f;  // Smeared, darker wrap strip.
            size_t i = (y * m + x) * 4;
            src[i] = static_cast<uint8_t>(std::lround(255 * v)); src[i + 1] = static_cast<uint8_t>(std::lround(230 * v));
            src[i + 2] = static_cast<uint8_t>(std::lround(200 * v));
        }
        for (uint32_t mode : {1u, 2u, 3u}) {
            auto r = PBRLabDefaultRecipe(PBRLabPresetOrganic);
            r.albedo_repair = mode;
            PBRLabInput in{src.data(), m * 4, nullptr, 0, nullptr, 0, m, m, nullptr, 0};
            std::vector<uint8_t> repaired(m * m * 4);
            PBRLabAlbedoRepairInfo info{};
            char err[128]{};
            assert(PBRLabConditionAlbedo(&in, &r, repaired.data(), m * 4, &info, err, sizeof(err)));
            std::cout << "albedo repair mode " << mode << ": method " << info.method << ", tone seam " << info.before.tone_x
                      << "/" << info.before.tone_y << " -> " << info.after.tone_x << "/" << info.after.tone_y << ", pixel "
                      << info.before.pixel_x << " -> " << info.after.pixel_x << ", detail " << info.before.detail << " -> "
                      << info.after.detail << ", cut ratio " << info.cut_cost_ratio << "\n";
            assert(info.method == (mode == 3 ? (info.cut_cost_ratio <= 4.0f ? 2u : 1u) : mode));
            assert(std::fabs(info.band_fraction - .12f) < 1e-6f);
            assert(info.before.tone_x > 1.0f && info.before.detail < .5f); // Ramp step in x, smeared strip on both.
            assert(info.after.tone_x < 1.3f && info.after.tone_y < 1.3f && info.after.detail > .85f);
            assert(info.after.pixel_x < 1.5f && info.after.pixel_y < 1.5f);
            // Derive with the same recipe exports exactly this albedo and reports the same repair.
            auto* result = PBRLabDerive(&in, &r, nullptr, nullptr, err, sizeof(err));
            assert(result);
            auto am = map(result, PBRLabMapAlbedo);
            assert(std::memcmp(am.pixels, repaired.data(), repaired.size()) == 0);
            assert(PBRLabGetAlbedoRepairInfo(result).method == info.method);
            PBRLabFreeResult(result);
        }
        auto bad = PBRLabDefaultRecipe(PBRLabPresetOrganic);
        bad.albedo_repair = 4;
        PBRLabInput in{src.data(), m * 4, nullptr, 0, nullptr, 0, m, m, nullptr, 0};
        char err[128]{};
        assert(!PBRLabDerive(&in, &bad, nullptr, nullptr, err, sizeof(err)));
        // Off: the albedo stays a byte-exact copy of the source.
        auto off = PBRLabDefaultRecipe(PBRLabPresetOrganic);
        auto* plain = PBRLabDerive(&in, &off, nullptr, nullptr, err, sizeof(err));
        assert(plain && std::memcmp(map(plain, PBRLabMapAlbedo).pixels, src.data(), src.size()) == 0);
        assert(PBRLabGetAlbedoRepairInfo(plain).method == 0);
        PBRLabFreeResult(plain);
    }

    // Coated metal: dark panel seams on a flat plate occlude visibly (1.3.0 left them almost unoccluded).
    {
        constexpr unsigned m = 256;
        std::vector<uint8_t> plate(m * m * 4, 255);
        for (unsigned y = 0; y < m; ++y) for (unsigned x = 0; x < m; ++x) {
            const bool seam = x % 64 < 2 || y % 64 < 2;
            size_t i = (y * m + x) * 4;
            plate[i] = plate[i + 1] = plate[i + 2] = seam ? 40 : 120;
        }
        auto r = PBRLabDefaultRecipe(PBRLabPresetCoatedMetal);
        auto* result = derive(plate, m, r);
        auto aoMap = map(result, PBRLabMapAO);
        std::cout << "coated-metal seam AO " << int(v(aoMap, 32, 0)) << " vs panel " << int(v(aoMap, 32, 32)) << "\n";
        assert(v(aoMap, 32, 0) < 200 && v(aoMap, 32, 32) >= 250);
        PBRLabFreeResult(result);
    }

    // Threaded derivation is deterministic, and a 1K derivation finishes promptly.
    {
        constexpr unsigned big = 1024;
        std::vector<uint8_t> noise(big * big * 4, 255);
        uint32_t seed = 12345;
        for (size_t i = 0; i < big * big; ++i) {
            seed = seed * 1664525u + 1013904223u;
            noise[i * 4] = noise[i * 4 + 1] = noise[i * 4 + 2] = static_cast<uint8_t>(seed >> 24);
        }
        auto stoneRecipe = PBRLabDefaultRecipe(PBRLabPresetStone);
        stoneRecipe.bent_normal_enabled = 1;
        auto t0 = std::chrono::steady_clock::now();
        auto* first = derive(noise, big, stoneRecipe);
        auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
        std::cout << "1024^2 stone derivation with bent normals: " << ms << " ms\n";
        auto* second = derive(noise, big, stoneRecipe);
        for (auto kind : {PBRLabMapNormal, PBRLabMapAO, PBRLabMapBentNormal, PBRLabMapHeight}) {
            auto a1 = map(first, kind), a2 = map(second, kind);
            assert(a1.byte_count == a2.byte_count && std::memcmp(a1.pixels, a2.pixels, a1.byte_count) == 0);
        }
        PBRLabFreeResult(first);
        PBRLabFreeResult(second);
    }

    {
        // 1.5.0. A grain-dominated photo gets a 4-30 mm relief floor at the same rms slope; roughness is kept within the
        // albedo-correlation limit; the flat preset gains a small substrate relief only when asked.
        constexpr unsigned size = 256;
        std::vector<uint8_t> photo(size * size * 4, 255);
        uint32_t state = 2463534242u;
        for (unsigned y = 0; y < size; ++y)
            for (unsigned x = 0; x < size; ++x) {
                state ^= state << 13; state ^= state >> 17; state ^= state << 5;
                const double grain = (state >> 8) / double(1u << 24) - .5;
                const double patch = ((x / 32 + y / 32) % 2) ? 70 : -70;  // Large paint patches drive the roughness cue.
                const double mid = 6 * std::sin(6.2831853 * x / 12.0) * std::sin(6.2831853 * y / 12.0);
                const size_t i = (size_t(y) * size + x) * 4;
                photo[i] = photo[i + 1] = photo[i + 2] = static_cast<uint8_t>(std::clamp(std::lround(128 + patch + mid + 90 * grain), 0L, 255L));
            }
        auto stone = PBRLabDefaultRecipe(PBRLabPresetStone);
        assert(stone.mid_relief_share > .3f && stone.roughness_albedo_limit < 1 && stone.tile_metres == 0);
        auto* floored = derive(photo, size, stone);
        auto fi = PBRLabGetDerivationInfo(floored);
        auto plain = stone; plain.mid_relief_share = 0; plain.roughness_albedo_limit = 1;
        auto* unfloored = derive(photo, size, plain);
        auto ui = PBRLabGetDerivationInfo(unfloored);
        std::cout << "mid relief share " << fi.mid_relief_share_before << " -> " << fi.mid_relief_share_after
                  << ", rms slope " << ui.rms_slope << " vs " << fi.rms_slope << "; roughness/albedo correlation "
                  << fi.roughness_albedo_correlation_before << " -> " << fi.roughness_albedo_correlation_after << "\n";
        assert(fi.mid_relief_share_before < stone.mid_relief_share && fi.mid_relief_share_after > fi.mid_relief_share_before);
        assert(fi.mid_relief_share_after > stone.mid_relief_share - .03f);
        assert(std::fabs(fi.rms_slope - ui.rms_slope) < .02f * ui.rms_slope);  // Same amplitude, redistributed over scales.
        assert(ui.mid_relief_share_after == ui.mid_relief_share_before);
        assert(std::fabs(ui.roughness_albedo_correlation_after - ui.roughness_albedo_correlation_before) < 1e-6f);
        if (std::fabs(fi.roughness_albedo_correlation_before) > stone.roughness_albedo_limit)
            assert(std::fabs(fi.roughness_albedo_correlation_after) < stone.roughness_albedo_limit + .02f);
        assert(std::fabs(ui.roughness_albedo_correlation_before) > stone.roughness_albedo_limit);  // The branch is exercised.
        // A physical tile width moves the band: on a 4 m tile 4-30 mm is 1-8 reference pixels, mostly grain already.
        auto wide = stone; wide.tile_metres = 4;
        auto* wideTile = derive(photo, size, wide);
        assert(PBRLabGetDerivationInfo(wideTile).mid_relief_share_before != fi.mid_relief_share_before);
        PBRLabFreeResult(floored); PBRLabFreeResult(unfloored); PBRLabFreeResult(wideTile);
        // Flat substrate relief: none by default; a small, deterministic, artwork-independent rms slope when asked.
        auto flatRecipe = PBRLabDefaultRecipe(PBRLabPresetFlat);
        assert(flatRecipe.mid_relief_share == 0 && flatRecipe.substrate_relief == 0);
        auto* bare = derive(photo, size, flatRecipe);
        assert(PBRLabGetDerivationInfo(bare).rms_slope == 0);
        flatRecipe.substrate_relief = 1;
        auto* film = derive(photo, size, flatRecipe);
        auto* film2 = derive(photo, size, flatRecipe);
        const float filmSlope = PBRLabGetDerivationInfo(film).rms_slope;
        std::cout << "flat substrate rms slope " << filmSlope << "\n";
        assert(filmSlope > .02f && filmSlope < .05f);
        auto n1 = map(film, PBRLabMapNormal), n2 = map(film2, PBRLabMapNormal);
        assert(std::memcmp(n1.pixels, n2.pixels, n1.byte_count) == 0);
        bool varied = false;
        for (size_t i = 0; i < size_t(size) * size && !varied; ++i) varied = n1.pixels[i * 4] != n1.pixels[0];
        assert(varied);
        PBRLabFreeResult(bare); PBRLabFreeResult(film); PBRLabFreeResult(film2);
        // Out-of-range 1.5.0 fields are rejected.
        PBRLabInput pin{photo.data(), size * 4, nullptr, 0, nullptr, 0, size, size, nullptr, 0};
        char why[128]{};
        for (int k = 0; k < 4; ++k) {
            auto bad = stone;
            if (k == 0) bad.mid_relief_share = .9f; else if (k == 1) bad.tile_metres = -1;
            else if (k == 2) bad.roughness_albedo_limit = 1.5f; else bad.substrate_relief = NAN;
            assert(!PBRLabDerive(&pin, &bad, nullptr, nullptr, why, sizeof(why)));
        }
    }
    // Measured guide form (LiDAR): keeps its real slope whatever the preset target; a learned guide follows the target.
    {
        constexpr unsigned m = 256;
        constexpr double wavelength = 64, slope = .12;              // rms gradient magnitude of the measured surface
        const double amplitude = slope * wavelength / (2 * M_PI);    // pixels of depth
        std::vector<uint8_t> guide(m * m * 4, 255), grain(m * m * 4, 255);
        uint32_t seed = 99;
        for (unsigned y = 0; y < m; ++y) for (unsigned x = 0; x < m; ++x) {
            const double k = 2 * M_PI / wavelength;
            const double hx = amplitude * k * std::cos(k * x), hy = amplitude * k * std::cos(k * y);
            // Core contract: dh/dx = -nx/nz, dh/dy = ny/nz (+Y green-up, image y down).
            double nx = -hx, ny = hy, nz = 1, len = std::sqrt(nx * nx + ny * ny + nz * nz);
            size_t i = (y * m + x) * 4;
            guide[i] = static_cast<uint8_t>(std::lround((nx / len + 1) * 127.5));
            guide[i + 1] = static_cast<uint8_t>(std::lround((ny / len + 1) * 127.5));
            guide[i + 2] = static_cast<uint8_t>(std::lround((nz / len + 1) * 127.5));
            seed = seed * 1664525u + 1013904223u;
            grain[i] = grain[i + 1] = grain[i + 2] = static_cast<uint8_t>(120 + ((seed >> 24) & 31));
        }
        auto run = [&](bool measured, float strengthScale) {
            auto r = PBRLabDefaultRecipe(PBRLabPresetStone);
            r.guide_normal_weight = 1;
            r.height_strength *= strengthScale;
            PBRLabInput in{grain.data(), m * 4, nullptr, 0, nullptr, 0, m, m, guide.data(), m * 4};
            in.guide_normals_measured = measured ? 1 : 0;
            char err[256]{};
            auto* result = PBRLabDerive(&in, &r, nullptr, nullptr, err, sizeof(err));
            if (!result) std::cerr << err << '\n';
            assert(result);
            auto info = PBRLabGetDerivationInfo(result);
            PBRLabFreeResult(result);
            return info;
        };
        auto measuredFull = run(true, 1), measuredLow = run(true, .25f), learnedFull = run(false, 1), learnedLow = run(false, .25f);
        std::cout << "measured form: rms " << measuredFull.measured_form_rms_slope << " (true " << slope << "), surface "
                  << measuredFull.rms_slope << " / " << measuredLow.rms_slope << " at 1x / 0.25x strength; learned "
                  << learnedFull.rms_slope << " / " << learnedLow.rms_slope << "\n";
        assert(measuredFull.measured_form_rms_slope > .09f && measuredFull.measured_form_rms_slope < .14f);
        assert(std::fabs(measuredLow.measured_form_rms_slope - measuredFull.measured_form_rms_slope) < 1e-4f);
        assert(learnedFull.measured_form_rms_slope == 0);
        // At a quarter of the target the measured surface still carries its real slope; the learned one shrinks.
        assert(measuredLow.rms_slope > .9f * measuredFull.measured_form_rms_slope);
        assert(learnedLow.rms_slope < .4f * learnedFull.rms_slope);
        assert(measuredLow.rms_slope > 1.3f * learnedLow.rms_slope);
    }
    PBRLabInput in{source.data(), n * 4, nullptr, 0, nullptr, 0, n, n, nullptr, 0};
    char error[64]{};
    assert(!PBRLabDerive(&in, &recipe, stop, nullptr, error, sizeof(error)));
    assert(std::string(error) == "cancelled");
    auto bad = recipe;
    bad.seamless_blend = .9f;
    assert(!PBRLabDerive(&in, &bad, nullptr, nullptr, error, sizeof(error)));
    bad = recipe;
    bad.normal_strength = NAN;
    assert(!PBRLabDerive(&in, &bad, nullptr, nullptr, error, sizeof(error)));
    in.width = 0;
    assert(!PBRLabDerive(&in, &recipe, nullptr, nullptr, error, sizeof(error)));
    std::cout << "Material Lab core tests passed\n";
}
