// The named material library: tuned starting recipes built on the six relief priors. Presets only choose recipe
// values, so the derivation (and algorithm_version) is unchanged; manifests record the choice as
// recipe.material_preset. The CLI (--preset), the Mac app and the iOS app all read this one table.
#include "PBRMaterialLab.h"
#include <cstring>
#include <vector>

namespace {

struct Spec {
    const char *identifier, *title, *category;
    PBRLabPreset prior;
    float height, roughness, variation, aoRadius, aoStrength;
    int32_t polarity = 1;
    float metalness = -1;     // >= 0 assigns metalness
    float normalStrength = 1;
    float equalize = 0;
};

// height: relief amplitude (0.22 = the prior's target slope); roughness: perceptual base; variation: spread.
const Spec kSpecs[] = {
    // Masonry and stone
    {"red-brick", "Red brick", "Masonry", PBRLabPresetStone, .28f, .82f, .35f, 12, 1.2f, 1, -1, 1, .25f},
    {"painted-brick", "Painted brick", "Masonry", PBRLabPresetStone, .22f, .7f, .25f, 12, 1.1f, 1, -1, 1, .2f},
    {"cinder-block", "Cinder block", "Masonry", PBRLabPresetStone, .24f, .88f, .3f, 12, 1.1f, 1, -1, 1, .25f},
    {"rubble-wall", "Rubble stone wall", "Masonry", PBRLabPresetStone, .36f, .86f, .4f, 16, 1.35f, 1, -1, 1, .3f},
    {"cobblestone", "Cobblestones", "Masonry", PBRLabPresetStone, .34f, .8f, .35f, 14, 1.3f, 1, -1, 1, .25f},
    {"slate", "Slate", "Masonry", PBRLabPresetStone, .2f, .62f, .3f, 10, 1.1f},
    {"sandstone", "Sandstone", "Masonry", PBRLabPresetStone, .24f, .9f, .25f, 10, 1.1f},
    {"polished-marble", "Polished marble", "Masonry", PBRLabPresetStone, .02f, .16f, .12f, 6, .5f},
    {"terracotta-roof", "Terracotta roof tiles", "Masonry", PBRLabPresetStone, .32f, .72f, .3f, 16, 1.3f},
    {"roof-shingles", "Asphalt shingles", "Masonry", PBRLabPresetStone, .26f, .9f, .25f, 12, 1.2f},
    // Concrete and plaster
    {"concrete", "Concrete", "Concrete & plaster", PBRLabPresetStone, .12f, .86f, .3f, 6, .9f, 1, -1, 1, .35f},
    {"polished-concrete", "Polished concrete", "Concrete & plaster", PBRLabPresetStone, .05f, .35f, .25f, 6, .6f, 1, -1, 1, .35f},
    {"plaster", "Painted plaster", "Concrete & plaster", PBRLabPresetStone, .08f, .8f, .15f, 8, .7f, 1, -1, 1, .5f},
    {"stucco", "Stucco", "Concrete & plaster", PBRLabPresetStone, .18f, .9f, .2f, 8, 1.0f, 1, -1, 1, .4f},
    {"asphalt", "Asphalt", "Concrete & plaster", PBRLabPresetStone, .16f, .9f, .2f, 6, 1.0f, 1, -1, 1, .3f},
    // Tile
    {"ceramic-tile", "Glazed ceramic tile", "Tile", PBRLabPresetCoatedMetal, .2f, .22f, .2f, 10, 1.1f},
    {"floor-tile", "Matte floor tile", "Tile", PBRLabPresetStone, .16f, .6f, .25f, 10, 1.0f},
    // Wood
    {"wood-planks", "Wood planks", "Wood", PBRLabPresetOrganic, .2f, .66f, .3f, 10, 1.1f},
    {"varnished-wood", "Varnished wood", "Wood", PBRLabPresetOrganic, .1f, .38f, .2f, 8, .8f},
    {"raw-wood", "Raw timber", "Wood", PBRLabPresetOrganic, .16f, .78f, .3f, 8, 1.0f},
    {"bark", "Tree bark", "Wood", PBRLabPresetOrganic, .42f, .9f, .3f, 16, 1.4f},
    // Ground and nature
    {"soil", "Soil", "Ground", PBRLabPresetOrganic, .26f, .94f, .2f, 10, 1.1f, 1, -1, 1, .3f},
    {"sand", "Sand", "Ground", PBRLabPresetStone, .14f, .92f, .15f, 6, .9f, 1, -1, 1, .3f},
    {"gravel", "Gravel", "Ground", PBRLabPresetStone, .36f, .88f, .3f, 12, 1.35f, 1, -1, 1, .25f},
    {"grass", "Grass", "Ground", PBRLabPresetOrganic, .3f, .8f, .3f, 10, 1.2f, 1, -1, 1, .3f},
    {"moss", "Moss", "Ground", PBRLabPresetOrganic, .24f, .92f, .2f, 8, 1.1f},
    // Fabric and leather
    {"canvas", "Canvas", "Fabric", PBRLabPresetFabric, .16f, .9f, .2f, 6, .9f},
    {"denim", "Denim", "Fabric", PBRLabPresetFabric, .2f, .88f, .2f, 6, 1.0f},
    {"carpet", "Carpet", "Fabric", PBRLabPresetFabric, .3f, .97f, .15f, 8, 1.2f},
    {"leather", "Leather", "Fabric", PBRLabPresetOrganic, .12f, .55f, .3f, 6, .9f},
    // Metal
    {"brushed-steel", "Brushed steel", "Metal", PBRLabPresetBareMetal, .05f, .34f, .2f, 6, .6f, 1, 1.0f},
    {"galvanized-steel", "Galvanized steel", "Metal", PBRLabPresetBareMetal, .08f, .42f, .35f, 6, .7f, 1, 1.0f},
    {"diamond-plate", "Diamond plate", "Metal", PBRLabPresetBareMetal, .3f, .4f, .25f, 10, 1.2f, 1, 1.0f},
    {"copper", "Copper", "Metal", PBRLabPresetBareMetal, .06f, .36f, .3f, 6, .7f, 1, 1.0f},
    {"rusted-steel", "Rusted steel", "Metal", PBRLabPresetStone, .2f, .84f, .35f, 10, 1.1f, 1, .3f},
    {"painted-metal", "Painted metal", "Metal", PBRLabPresetCoatedMetal, .08f, .4f, .25f, 8, .8f},
    // Synthetic
    {"plastic", "Plastic", "Synthetic", PBRLabPresetCoatedMetal, .04f, .36f, .15f, 6, .6f},
    {"rubber", "Rubber", "Synthetic", PBRLabPresetOrganic, .1f, .9f, .15f, 6, .9f},
    {"cardboard", "Cardboard", "Synthetic", PBRLabPresetFabric, .08f, .92f, .2f, 6, .8f},
};

std::vector<PBRLabMaterialPreset> build() {
    std::vector<PBRLabMaterialPreset> presets;
    for (const Spec &s : kSpecs) {
        PBRLabRecipe r = PBRLabDefaultRecipe(s.prior);
        r.height_strength = s.height;
        r.height_polarity = s.polarity;
        r.roughness_base = s.roughness;
        r.roughness_variation = s.variation;
        r.ao_radius_pixels = s.aoRadius;
        r.ao_strength = s.aoStrength;
        r.normal_strength = s.normalStrength;
        r.albedo_equalize = s.equalize;
        if (s.metalness >= 0) {
            r.assigned_metalness_enabled = 1;
            r.assigned_metalness = s.metalness;
        }
        presets.push_back({s.identifier, s.title, s.category, r});
    }
    return presets;
}

const std::vector<PBRLabMaterialPreset> &library() {
    static const std::vector<PBRLabMaterialPreset> presets = build();
    return presets;
}

} // namespace

extern "C" uint32_t PBRLabMaterialPresetCount(void) { return static_cast<uint32_t>(library().size()); }

extern "C" const PBRLabMaterialPreset *PBRLabMaterialPresetAt(uint32_t index) {
    return index < library().size() ? &library()[index] : nullptr;
}

extern "C" const PBRLabMaterialPreset *PBRLabFindMaterialPreset(const char *identifier) {
    if (!identifier) return nullptr;
    for (const auto &preset : library())
        if (std::strcmp(preset.identifier, identifier) == 0) return &preset;
    return nullptr;
}
