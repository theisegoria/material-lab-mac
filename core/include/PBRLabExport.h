#ifndef PBRLAB_EXPORT_H
#define PBRLAB_EXPORT_H
// Engine and interchange exports of a .pbrmaterial bundle (glTF, USDZ, MaterialX, Unreal, Unity, Godot, Blender,
// Substance, Roblox, Minecraft LabPBR). One implementation (core/src/tools/Export.mm) serves the CLI's --export and
// both apps. The bundle is read, never modified; exports are derived files plus a material-lab-export.json note.
#include <stddef.h>
#include <stdint.h>

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

#ifdef __cplusplus
}
#endif

#endif
