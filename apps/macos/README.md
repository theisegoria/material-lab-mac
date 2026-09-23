# Material Lab for macOS

Standalone native macOS 27 app for deriving editable PBR map estimates from color
images. It links the portable C++23 core in ../../core and has no game-runtime
dependency.

Configure and build from the standalone project root:

    cmake -S apps/macos -B build/macos -G Ninja
    cmake --build build/macos --target MaterialLab

Run build/macos/MaterialLab.app as an app bundle. Import images or an optional
semantic catalog in the GUI. The separate camera inbox is stored under
~/Library/Application Support/Material Lab/Inbox. Exported .pbrmaterial folders
contain PNG maps plus a versioned manifest; export does not admit maps to any
game runtime. Inferred maps are estimates that require review.
