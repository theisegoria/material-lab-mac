#ifndef PBR_MATERIAL_LAB_H
#define PBR_MATERIAL_LAB_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Version 1.4 ABI. All buffers in a PBRLabResult remain owned by the result.
// Derivation uses internal worker threads; the progress callback runs only on the calling thread.
typedef enum PBRLabPreset {
    PBRLabPresetFlat = 0,
    PBRLabPresetStone = 1,
    PBRLabPresetFabric = 2,
    PBRLabPresetOrganic = 3,
    PBRLabPresetCoatedMetal = 4,
    PBRLabPresetBareMetal = 5
} PBRLabPreset;

typedef enum PBRLabMapKind {
    PBRLabMapAlbedo = 0,
    PBRLabMapHeight = 1,
    PBRLabMapNormal = 2,
    PBRLabMapRoughness = 3,
    PBRLabMapAO = 4,
    PBRLabMapCavity = 5,
    PBRLabMapConvexity = 6,
    PBRLabMapSlope = 7,
    PBRLabMapEdge = 8,
    PBRLabMapBentNormal = 9,
    PBRLabMapORM = 10
} PBRLabMapKind;

typedef enum PBRLabPixelFormat {
    PBRLabPixelFormatRGBA8SRGB = 1,
    PBRLabPixelFormatRGBA8Linear = 2,
    PBRLabPixelFormatR16UNormLE = 3
} PBRLabPixelFormat;

typedef struct PBRLabInput {
    const uint8_t *rgba8;            // Straight RGBA8, tagged sRGB; alpha is retained in albedo.
    size_t rgba_row_bytes;
    const uint8_t *relief_mask_r8;    // Optional suppression mask: 0=flat, 255=keep inferred relief.
    size_t relief_mask_row_bytes;
    const uint8_t *height_override_r16; // Optional authored height, R16 UNorm little-endian. Overrides inference and mask.
    size_t height_override_row_bytes;
    uint32_t width;
    uint32_t height;
    // Added in 1.2.0. Optional guide normals (e.g. from a learned estimator), tangent space, +Y / green-up,
    // linear RGBA8, same size as the source. Integrated to height and blended by guide_normal_weight.
    const uint8_t *guide_normal_rgba8;
    size_t guide_normal_row_bytes;
} PBRLabInput;

typedef struct PBRLabRecipe {
    PBRLabPreset preset;
    float height_strength;           // Relief amplitude: scales the preset's target rms slope (0.22 = the target).
    int32_t height_polarity;          // +1 raised bright detail; -1 inverted.
    float roughness_base;            // Perceptual roughness prior, [0,1].
    float roughness_variation;       // Roughness spread, [0,1]: standard deviation 0.25 x this within the preset range.
    float ao_radius_pixels;          // Heightfield horizon radius in pixels of a 1024 reference (scales with the tile).
    uint32_t tile_wrap;              // Nonzero wraps all spatial filters and horizon samples.
    uint32_t assigned_metalness_enabled;
    float assigned_metalness;        // Artist assignment only, [0,1].
    uint32_t bent_normal_enabled;    // Nonzero emits PBRLabMapBentNormal.
    // Added in 1.1.0. PBRLabDefaultRecipe fills these with values that leave the source untouched.
    float normal_strength;           // Scales the estimated surface depth (normals, AO, diagnostics, height span), [0,16].
    uint32_t normal_y_down;          // Nonzero encodes -Y / green-down (DirectX) normals; zero is +Y / green-up (glTF, OpenGL).
    float ao_strength;               // Relief exaggeration seen by the GTAO horizon search, [0,4]; 0 disables occlusion.
    float albedo_equalize;           // Low-frequency lighting removal from albedo and inferred relief, [0,1]; 0 is off.
    float seamless_blend;            // Offset cross-fade width per edge as a fraction of the size, [0,0.45]; 0 is off.
    // Added in 1.2.0.
    float guide_normal_weight;       // Weight of learned form and detail orientation over pure albedo relief, [0,1]; needs guide normals.
    uint32_t seamless_mode;          // With seamless_blend > 0: 1 (default) = aligned minimum-error seam cut, best for
                                     // structured textures (brick, tiles, planks) and most photos; 0 = histogram-
                                     // preserving blend, for fine stochastic textures with soft lighting drift.
    // Added in 1.4.0. Explicit albedo repair: the albedo itself is rebuilt to tile (both axes, always), and the
    // repaired albedo feeds every derived map. 0 = off (legacy seamless_blend / seamless_mode behaviour), 1 = blend
    // (histogram-preserving), 2 = quilt (minimum-error cut, multi-band), 3 = auto (quilt unless its cut ratio > 4).
    // The band is seamless_blend of the tile per edge, or 0.12 when that is 0.
    uint32_t albedo_repair;
} PBRLabRecipe;

typedef struct PBRLabMap {
    const uint8_t *pixels;
    uint32_t width;
    uint32_t height;
    size_t row_bytes;
    size_t byte_count;
    PBRLabPixelFormat format;
} PBRLabMap;

typedef struct PBRLabSeamMetrics {
    float height_value_delta;        // Mean absolute opposite-edge difference, normalized [0,1].
    float height_gradient_delta;     // Mean absolute opposite-edge gradient difference.
    float albedo_value_delta;        // Mean absolute linear RGB opposite-edge difference.
} PBRLabSeamMetrics;

// Added in 1.3.0. How the exported geometry was built.
typedef struct PBRLabDerivationInfo {
    float height_span_tile_widths;   // Depth spanned by height 0..1, in tile widths (0 = no relief).
    float rms_slope;                 // Root-mean-square surface slope (tangent) of the final geometry.
    float learned_form_share;        // Share of slope energy taken from learned form (0 without a guide).
    float learned_detail_correlation;// Correlation of learned and albedo relief in the 3..8 px band (0 without a guide).
    int32_t detail_polarity;         // Sign applied to albedo-derived fine relief (+1 bright raised).
    float height_wrap_seam_ratio;    // Mean opposite-edge height step / mean adjacent step (about 1 = seamless).
} PBRLabDerivationInfo;

// Added in 1.4.0. Wrap-seam measures of linear-light luminance (see docs/DERIVATION.md).
typedef struct PBRLabWrapSeam {
    float pixel_x, pixel_y;          // Opposite-edge step / mean adjacent step (about 1 or below = no step).
    float tone_x, tone_y;            // The same at a sigma 8 reference-px blur (lighting or colour steps).
    float detail;                    // Fine contrast near the wrap lines / elsewhere (below 1 = smeared band).
} PBRLabWrapSeam;
typedef struct PBRLabAlbedoRepairInfo {
    uint32_t method;                 // 0 none, 1 blend, 2 quilt (the method actually applied).
    float cut_cost_ratio;            // Quilt: mean mismatch on the cut / mean mismatch of neighbouring pixels in the band.
    float band_fraction;             // Band per edge as a fraction of the tile.
    uint32_t offset_x, offset_y;     // Offset of the copy used on each axis (0 = axis left alone).
    PBRLabWrapSeam before, after;    // Measured when albedo_repair is set; zero otherwise.
} PBRLabAlbedoRepairInfo;

typedef struct PBRLabResult PBRLabResult;
typedef int (*PBRLabProgressCallback)(float progress, void *context); // Return zero to cancel.

const char *PBRLabVersion(void);
PBRLabRecipe PBRLabDefaultRecipe(PBRLabPreset preset);
PBRLabResult *PBRLabDerive(const PBRLabInput *input, const PBRLabRecipe *recipe,
                     PBRLabProgressCallback progress, void *context,
                     char *error, size_t error_capacity);
int PBRLabGetMap(const PBRLabResult *result, PBRLabMapKind kind, PBRLabMap *out_map);
PBRLabSeamMetrics PBRLabGetSeamMetrics(const PBRLabResult *result);
PBRLabDerivationInfo PBRLabGetDerivationInfo(const PBRLabResult *result);
PBRLabAlbedoRepairInfo PBRLabGetAlbedoRepairInfo(const PBRLabResult *result);
// Added in 1.4.0. Runs only the albedo conditioning of PBRLabDerive (delighting, tiling or repair) and writes the
// resulting sRGB RGBA8 albedo, exactly as PBRLabDerive would export it. Clients run learned inference on this
// albedo, then derive from it with conditioning turned off, so every map sees the repaired image. Returns 0 on error.
int PBRLabConditionAlbedo(const PBRLabInput *input, const PBRLabRecipe *recipe, uint8_t *out_rgba8, size_t out_row_bytes,
                          PBRLabAlbedoRepairInfo *out_info, char *error, size_t error_capacity);
void PBRLabFreeResult(PBRLabResult *result);

// Added in 1.3.0: the learned-guide tiling contract (docs/LEARNED_NORMALS.md), shared by every client so that
// identical model output gives identical guide normals. The caller only runs the model: for every pass it fills
// the model input, predicts, and adds the prediction; Finish then returns guide normals for PBRLabInput.
#define PBRLAB_GUIDE_TILE 518
typedef struct PBRLabGuideTiler PBRLabGuideTiler;
// Square straight sRGB RGBA8 source, 2..4096. tile_wrap nonzero makes the guide field periodic. NULL on error.
PBRLabGuideTiler *PBRLabGuideTilerCreate(const uint8_t *rgba8, size_t row_bytes, uint32_t size, uint32_t tile_wrap);
uint32_t PBRLabGuideTilerWorkResolution(const PBRLabGuideTiler *tiler);
uint32_t PBRLabGuideTilerTileCount(const PBRLabGuideTiler *tiler); // Tile positions; each runs twice (two passes).
uint32_t PBRLabGuideTilerPassCount(const PBRLabGuideTiler *tiler); // 2 x tile count.
const char *PBRLabGuideTilerContract(const PBRLabGuideTiler *tiler);
// Writes the 518x518 model input of `pass` as BGRA8 (alpha 255, raw sRGB values).
int PBRLabGuideTilerFillInput(const PBRLabGuideTiler *tiler, uint32_t pass, uint8_t *bgra8, size_t row_bytes);
// Adds the model's +Y tangent normals for `pass`: value (c, y, x) is at
// normals[c * channel_stride + y * row_stride + x * column_stride]. Passes must be added in order.
int PBRLabGuideTilerAddPrediction(PBRLabGuideTiler *tiler, uint32_t pass, const float *normals,
                                  ptrdiff_t channel_stride, ptrdiff_t row_stride, ptrdiff_t column_stride);
// After every pass: writes out_size x out_size linear RGBA8 guide normals (alpha 255), normally out_size = the
// source size. May be called again for other sizes (e.g. a preview and an export) without re-running the model.
int PBRLabGuideTilerFinish(PBRLabGuideTiler *tiler, uint32_t out_size, uint8_t *rgba8, size_t row_bytes);
void PBRLabGuideTilerFree(PBRLabGuideTiler *tiler);

#ifdef __cplusplus
}
#endif

#endif
