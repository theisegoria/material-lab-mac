#include "PBRMaterialLab.h"
#include <algorithm>
#include <cassert>
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
                 overrideHeight ? n * 2 : 0, n, n};
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
    assert(std::strcmp(PBRLabVersion(), "1.0.0") == 0);
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
    // Independent dense horizon integration on the same authored pit.
    // The production 8x6 sampler should track a 64-direction, 40-step reference.
    float referenceAO = 0;
    for (int direction = 0; direction < 64; ++direction) {
        float radians = 6.283185307179586f * direction / 64.0f;
        float horizon = 0;
        for (int sample = 1; sample <= 40; ++sample) {
            float distance = recipe.ao_radius_pixels * sample / 40.0f;
            if (distance < .5f) continue;
            int xx = (16 + static_cast<int>(std::lround(std::cos(radians) * distance))) % int(n);
            int yy = (16 + static_cast<int>(std::lround(std::sin(radians) * distance))) % int(n);
            auto authored = [&](int x, int y) {
                size_t index = (static_cast<size_t>(y) * n + x) * 2;
                return float(relief[index] | (relief[index + 1] << 8)) / 65535.0f;
            };
            horizon = std::max(horizon, (authored(xx, yy) - authored(16, 16)) * 4.0f / distance);
        }
        referenceAO += 1.0f / (1.0f + horizon * 3.0f);
    }
    referenceAO /= 64.0f;
    assert(std::abs(float(v(ao, 16, 16)) / 255.0f - referenceAO) < .18f);
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
    assert(v(map(stone, PBRLabMapNormal), 12, 12, 0) == 128);
    assert(v(map(stone, PBRLabMapNormal), 12, 12, 1) < 128);
    PBRLabFreeResult(stone);

    PBRLabInput in{source.data(), n * 4, nullptr, 0, nullptr, 0, n, n};
    char error[64]{};
    assert(!PBRLabDerive(&in, &recipe, stop, nullptr, error, sizeof(error)));
    assert(std::string(error) == "cancelled");
    in.width = 0;
    assert(!PBRLabDerive(&in, &recipe, nullptr, nullptr, error, sizeof(error)));
    std::cout << "Material Lab core tests passed\n";
}
