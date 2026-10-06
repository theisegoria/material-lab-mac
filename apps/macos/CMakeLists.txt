cmake_minimum_required(VERSION 3.28)
set(CMAKE_OSX_DEPLOYMENT_TARGET "27.0" CACHE STRING "Material Lab minimum macOS version")
set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "Apple Silicon only")
if(NOT CMAKE_Swift_FLAGS)
    set(CMAKE_Swift_FLAGS "-module-cache-path \"${CMAKE_BINARY_DIR}/swift-module-cache\"" CACHE STRING "Local Swift module cache" FORCE)
endif()
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Release" CACHE STRING "Material Lab build type (defaults to Release)" FORCE)
endif()
project(MaterialLab VERSION 0.1.0 LANGUAGES C CXX OBJCXX Swift)
if(NOT APPLE OR NOT CMAKE_OSX_ARCHITECTURES STREQUAL "arm64")
    message(FATAL_ERROR "Material Lab requires Apple Silicon macOS")
endif()
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(MATERIAL_CORE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../core")
add_library(pbr_material_core STATIC "${MATERIAL_CORE_DIR}/src/PBRMaterialLab.cpp"
            "${MATERIAL_CORE_DIR}/src/MaterialPresets.cpp")
target_include_directories(pbr_material_core PUBLIC "${MATERIAL_CORE_DIR}/include")
# The derivation core is compute-bound; always optimize it, even in Debug app builds.
target_compile_options(pbr_material_core PRIVATE -Wall -Wextra -Wpedantic -O3)
find_package(Threads REQUIRED)
target_link_libraries(pbr_material_core PUBLIC Threads::Threads)

# Engine and interchange exports (glTF, USDZ, MaterialX, Unreal, Unity, ...), shared with the CLI's --export.
find_package(ZLIB REQUIRED)
add_library(pbr_material_export STATIC "${MATERIAL_CORE_DIR}/src/PNGWriter.cpp"
            "${MATERIAL_CORE_DIR}/src/tools/Common.mm" "${MATERIAL_CORE_DIR}/src/tools/Export.mm"
            "${MATERIAL_CORE_DIR}/src/tools/ExportAPI.mm")
target_include_directories(pbr_material_export PUBLIC "${MATERIAL_CORE_DIR}/include")
target_compile_options(pbr_material_export PRIVATE -fobjc-arc -Wall -Wextra -O2)
target_link_libraries(pbr_material_export PUBLIC ZLIB::ZLIB "-framework Foundation")

set(MATERIAL_LAB_SWIFT
    App/MaterialLabApp.swift
    App/SnapshotHarness.swift
    Models/MaterialModels.swift
    Services/MaterialEngine.swift
    Services/LearnedNormalEstimator.swift
    Services/MaterialLibrary.swift
    Services/MaterialBundle.swift
    Services/LocalLinkIdentity.swift
    Services/LocalLinkService.swift
    Stores/MaterialLabStore.swift
    Stores/LearnedModelStore.swift
    Views/ContentView.swift
    Views/SourceSidebar.swift
    Views/MaterialDetail.swift
    Views/RecipeInspector.swift
    Views/MapPreview.swift
    Views/CameraInboxView.swift
    Views/PairingView.swift
    Views/SourceMetadataEditor.swift
    Views/Material3DPreview.swift
    Views/LearnedGeometrySettings.swift
    Views/ExportSheet.swift
    ../shared/ExportTargets.swift
    ../shared/MaterialPresetLibrary.swift
)
add_executable(MaterialLab MACOSX_BUNDLE ${MATERIAL_LAB_SWIFT})
target_compile_options(MaterialLab PRIVATE -parse-as-library
    -import-objc-header "${CMAKE_CURRENT_SOURCE_DIR}/Support/MaterialLab-Bridging-Header.h"
    -Xcc "-I${MATERIAL_CORE_DIR}/include")
target_link_libraries(MaterialLab PRIVATE pbr_material_core pbr_material_export
    "-framework SwiftUI" "-framework AppKit" "-framework ImageIO"
    "-framework CoreGraphics" "-framework UniformTypeIdentifiers"
    "-framework Security" "-framework Network"
    "-framework RealityKit" "-framework Metal" "-framework ScreenCaptureKit"
    "-framework CoreML" "-framework CoreVideo")
set_target_properties(MaterialLab PROPERTIES
    Swift_LANGUAGE_VERSION 5
    MACOSX_BUNDLE_GUI_IDENTIFIER "io.materiallab.desktop"
    MACOSX_BUNDLE_BUNDLE_NAME "Material Lab"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist")
# Optional: ship the learned normal model inside the app (Contents/Resources/Models). Off by default;
# pass -DMATERIAL_LAB_BUNDLE_MODEL=/path/to/MoGe2Normals.mlpackage (compiled here) or .mlmodelc (copied).
set(MATERIAL_LAB_BUNDLE_MODEL "" CACHE PATH "Core ML model (.mlpackage or .mlmodelc) to bundle; empty bundles none")
if(MATERIAL_LAB_BUNDLE_MODEL)
    if(NOT EXISTS "${MATERIAL_LAB_BUNDLE_MODEL}")
        message(FATAL_ERROR "MATERIAL_LAB_BUNDLE_MODEL does not exist: ${MATERIAL_LAB_BUNDLE_MODEL}")
    endif()
    get_filename_component(_model_ext "${MATERIAL_LAB_BUNDLE_MODEL}" LAST_EXT)
    get_filename_component(_model_stem "${MATERIAL_LAB_BUNDLE_MODEL}" NAME_WLE)
    set(_models_dir "$<TARGET_BUNDLE_DIR:MaterialLab>/Contents/Resources/Models")
    if(_model_ext STREQUAL ".mlpackage")
        add_custom_command(TARGET MaterialLab POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E rm -rf "${_models_dir}"
            COMMAND ${CMAKE_COMMAND} -E make_directory "${_models_dir}"
            COMMAND xcrun coremlcompiler compile "${MATERIAL_LAB_BUNDLE_MODEL}" "${_models_dir}"
            COMMENT "Compiling ${_model_stem}.mlpackage into the app bundle")
    elseif(_model_ext STREQUAL ".mlmodelc")
        add_custom_command(TARGET MaterialLab POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E rm -rf "${_models_dir}"
            COMMAND ${CMAKE_COMMAND} -E copy_directory "${MATERIAL_LAB_BUNDLE_MODEL}" "${_models_dir}/${_model_stem}.mlmodelc"
            COMMENT "Copying ${_model_stem}.mlmodelc into the app bundle")
    else()
        message(FATAL_ERROR "MATERIAL_LAB_BUNDLE_MODEL must be a .mlpackage or .mlmodelc")
    endif()
else()
    # Keep incremental builds honest when the option is switched off.
    add_custom_command(TARGET MaterialLab POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E rm -rf "$<TARGET_BUNDLE_DIR:MaterialLab>/Contents/Resources/Models")
endif()
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/Resources/AppIcon.icns")
    add_custom_command(TARGET MaterialLab POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${CMAKE_CURRENT_SOURCE_DIR}/Resources/AppIcon.icns"
        "$<TARGET_BUNDLE_DIR:MaterialLab>/Contents/Resources/AppIcon.icns")
endif()
