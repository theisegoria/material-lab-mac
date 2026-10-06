#import <Foundation/Foundation.h>
#include "PBRLabExport.h"
#include "Tools.hpp"
#include <cstring>
#include <stdexcept>

namespace {
// Display names for the apps' export sheets, in mltools::exportFormats() order.
const PBRLabExportFormat kFormats[] = {
    {"glb", "glTF binary (.glb)", "A textured plane with base colour, normal and ORM: three.js, Babylon, Blender, most engines.", "glb"},
    {"usdz", "USDZ", "UsdPreviewSurface material for Quick Look, AR Quick Look and Reality Composer.", "usdz"},
    {"materialx", "MaterialX", "A standard_surface .mtlx with its textures: Houdini, Maya, Blender, USD, Omniverse.", nullptr},
    {"unreal", "Unreal Engine", "BaseColor, DirectX Normal, packed ORM and Height textures.", nullptr},
    {"unity", "Unity URP / Built-in", "Base Map, Normal, Metallic with smoothness in alpha, Occlusion and Height.", nullptr},
    {"unity-hdrp", "Unity HDRP", "Base Color, Normal, Mask Map (metallic, occlusion, detail, smoothness) and Height.", nullptr},
    {"godot", "Godot", "Albedo, Normal, ORM and Height for ORMMaterial3D.", nullptr},
    {"blender", "Blender", "Separate base colour, normal, roughness, occlusion, metallic and height maps.", nullptr},
    {"substance", "Substance 3D", "Maps named for Substance 3D Painter and Designer.", nullptr},
    {"roblox", "Roblox", "SurfaceAppearance colour, normal, roughness and metalness maps (at most 1024²).", nullptr},
    {"minecraft-labpbr", "Minecraft (LabPBR)", "A resource pack with LabPBR colour, _n and _s textures for shader packs.", nullptr},
};

void setError(char *error, size_t capacity, const std::string &message) {
    if (!error || capacity == 0) return;
    std::strncpy(error, message.c_str(), capacity - 1);
    error[capacity - 1] = '\0';
}
} // namespace

extern "C" uint32_t PBRLabExportFormatCount(void) { return static_cast<uint32_t>(std::size(kFormats)); }

extern "C" const PBRLabExportFormat *PBRLabExportFormatAt(uint32_t index) {
    return index < std::size(kFormats) ? &kFormats[index] : nullptr;
}

extern "C" int PBRLabExportBundle(const char *bundle_dir, const char *format, const char *output_path,
                                  char *error, size_t error_capacity) {
    setError(error, error_capacity, "");
    if (!bundle_dir || !format || !output_path) {
        setError(error, error_capacity, "bundle, format and output are required");
        return 0;
    }
    @autoreleasepool {
        try {
            mltools::exportBundle(bundle_dir, format, output_path, false);
            return 1;
        } catch (const std::exception &e) {
            setError(error, error_capacity, e.what());
            return 0;
        }
    }
}
