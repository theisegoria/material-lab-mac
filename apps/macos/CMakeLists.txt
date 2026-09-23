cmake_minimum_required(VERSION 3.28)
set(CMAKE_OSX_DEPLOYMENT_TARGET "27.0" CACHE STRING "Material Lab minimum macOS version")
set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "Apple Silicon only")
if(NOT CMAKE_Swift_FLAGS)
    set(CMAKE_Swift_FLAGS "-module-cache-path \"${CMAKE_BINARY_DIR}/swift-module-cache\"" CACHE STRING "Local Swift module cache" FORCE)
endif()
project(MaterialLab VERSION 0.1.0 LANGUAGES C CXX Swift)
if(NOT APPLE OR NOT CMAKE_OSX_ARCHITECTURES STREQUAL "arm64")
    message(FATAL_ERROR "Material Lab requires Apple Silicon macOS")
endif()
set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(MATERIAL_CORE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../core")
add_library(pbr_material_core STATIC "${MATERIAL_CORE_DIR}/src/PBRMaterialLab.cpp")
target_include_directories(pbr_material_core PUBLIC "${MATERIAL_CORE_DIR}/include")
target_compile_options(pbr_material_core PRIVATE -Wall -Wextra -Wpedantic)

set(MATERIAL_LAB_SWIFT
    App/MaterialLabApp.swift
    Models/MaterialModels.swift
    Services/MaterialEngine.swift
    Services/MaterialLibrary.swift
    Services/MaterialBundle.swift
    Services/LocalLinkIdentity.swift
    Services/LocalLinkService.swift
    Stores/MaterialLabStore.swift
    Views/ContentView.swift
    Views/SourceSidebar.swift
    Views/MaterialDetail.swift
    Views/RecipeInspector.swift
    Views/MapPreview.swift
    Views/CameraInboxView.swift
    Views/PairingView.swift
    Views/SourceMetadataEditor.swift
)
add_executable(MaterialLab MACOSX_BUNDLE ${MATERIAL_LAB_SWIFT})
target_compile_options(MaterialLab PRIVATE -parse-as-library
    -import-objc-header "${MATERIAL_CORE_DIR}/include/PBRMaterialLab.h")
target_link_libraries(MaterialLab PRIVATE pbr_material_core
    "-framework SwiftUI" "-framework AppKit" "-framework ImageIO"
    "-framework CoreGraphics" "-framework UniformTypeIdentifiers"
    "-framework Security" "-framework Network")
set_target_properties(MaterialLab PROPERTIES
    Swift_LANGUAGE_VERSION 5
    MACOSX_BUNDLE_GUI_IDENTIFIER "io.materiallab.desktop"
    MACOSX_BUNDLE_BUNDLE_NAME "Material Lab"
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist")
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/Resources/AppIcon.icns")
    add_custom_command(TARGET MaterialLab POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${CMAKE_CURRENT_SOURCE_DIR}/Resources/AppIcon.icns"
        "$<TARGET_BUNDLE_DIR:MaterialLab>/Contents/Resources/AppIcon.icns")
endif()
