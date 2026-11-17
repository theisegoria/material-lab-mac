#ifndef PBRLAB_EXPORT_H
#define PBRLAB_EXPORT_H
// Engine and interchange exports of a .pbrmaterial bundle (glTF, USDZ, MaterialX, Unreal, Unity, Godot, Blender,
// Substance, Roblox, Minecraft LabPBR). One implementation (core/src/tools/Export.mm) serves the CLI's --export and
// both apps. The bundle is read, never modified; exports are derived files plus a material-lab-export.json note.
#include <stddef.h>
#include <stdint.h>
#include "PBRMaterialLab.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PBRLabExportFormat {
    const char *identifier;      // As for --export: "glb", "unity-hdrp", ...
    const char *title;           // Display name: "glTF binary (.glb)", "Unity HDRP", ...
    const char *detail;          // One line on what is written.
    const char *file_extension;  // "glb" or "usdz" for single-file formats; NULL for a folder.
} PBRLabExportFormat;

uint32_t PBRLabExportFormatCount(void);
const PBRLabExportFormat *PBRLabExportFormatAt(uint32_t index);  // NULL past the end.

// Writes `format` for the bundle at `bundle_dir` to `output_path` (a file for single-file formats, else a folder),
// which must not exist. The bundle should already be valid (the apps export bundles they just wrote). Returns 1 on
// success; 0 with a message in `error` otherwise.
int PBRLabExportBundle(const char *bundle_dir, const char *format, const char *output_path,
                       char *error, size_t error_capacity);

// Composed bundles (added with CLI 1.4.0; core/src/tools/Compose.mm, docs/BUNDLE_FORMAT.md "Composed bundles"). Each
// reads valid bundles, runs the material operation of PBRMaterialLab.h and writes a new bundle at `output_dir` (which
// must not exist) whose manifest records the operation and its sources (sections `layers`, `variant`, `large_tile`).
// `label` and `material_id` may be NULL (defaults: "<top> over <base>" etc., and the output folder's stem). Sources are
// never modified. Returns 1 on success; 0 with a message in `error` otherwise.
// Layers `top_dir` over `base_dir`. `mask_image_path` (any ImageIO image, square, grey values used as data) is read
// when params->mask is PBRLabLayerMaskImage, which then ignores params->mask_r8; it may be NULL otherwise.
int PBRLabLayerBundles(const char *base_dir, const char *top_dir, const PBRLabLayerParams *params,
                       const char *mask_image_path, const char *output_dir, const char *label, const char *material_id,
                       char *error, size_t error_capacity);
int PBRLabVariantBundle(const char *bundle_dir, const PBRLabVariantParams *params, const char *output_dir,
                        const char *label, const char *material_id, char *error, size_t error_capacity);
int PBRLabLargeTileBundle(const char *bundle_dir, const PBRLabLargeTileParams *params, const char *output_dir,
                          const char *label, const char *material_id, char *error, size_t error_capacity);

#ifdef __cplusplus
}
#endif

#endif
