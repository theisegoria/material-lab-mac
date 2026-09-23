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
    assert(std::strcmp(PBRLabVersion(), "1.2.0") == 0);
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
