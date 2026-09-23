#ifndef PBR_MATERIAL_LAB_H
#define PBR_MATERIAL_LAB_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Version 1 ABI. All buffers in an PBRLabResult remain owned by the result.
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
} PBRLabInput;

typedef struct PBRLabRecipe {
    PBRLabPreset preset;
    float height_strength;           // Height amplitude around neutral 0.5, in normalized units.
    int32_t height_polarity;          // +1 raised bright detail; -1 inverted.
    float roughness_base;            // Perceptual roughness prior, [0,1].
    float roughness_variation;       // Restrained height-derived variation, [0,1].
    float ao_radius_pixels;          // Heightfield horizon radius in source pixels.
    uint32_t tile_wrap;              // Nonzero wraps all spatial filters and horizon samples.
    uint32_t assigned_metalness_enabled;
    float assigned_metalness;        // Artist assignment only, [0,1].
    uint32_t bent_normal_enabled;    // Nonzero emits PBRLabMapBentNormal.
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

typedef struct PBRLabResult PBRLabResult;
typedef int (*PBRLabProgressCallback)(float progress, void *context); // Return zero to cancel.

const char *PBRLabVersion(void);
PBRLabRecipe PBRLabDefaultRecipe(PBRLabPreset preset);
PBRLabResult *PBRLabDerive(const PBRLabInput *input, const PBRLabRecipe *recipe,
                     PBRLabProgressCallback progress, void *context,
                     char *error, size_t error_capacity);
int PBRLabGetMap(const PBRLabResult *result, PBRLabMapKind kind, PBRLabMap *out_map);
PBRLabSeamMetrics PBRLabGetSeamMetrics(const PBRLabResult *result);
void PBRLabFreeResult(PBRLabResult *result);

#ifdef __cplusplus
}
#endif

#endif
