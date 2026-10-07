import AppKit
import ScreenCaptureKit
import SwiftUI

/// Headless visual-verification harness. Inactive unless MATERIAL_LAB_SNAPSHOT_DIR is set.
/// It adds a transient (unsaved) source, derives it, renders the app's own window in every
/// canvas mode in light and dark appearance, writes PNGs and quits. It needs no Screen
/// Recording permission because it draws the window's view hierarchy itself.
@MainActor
enum SnapshotHarness {
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static var isActive: Bool { environment["MATERIAL_LAB_SNAPSHOT_DIR"] != nil }

    static func run(store: MaterialLabStore) async {
        guard let directoryPath = environment["MATERIAL_LAB_SNAPSHOT_DIR"] else { return }
        let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let prefix = environment["MATERIAL_LAB_SNAPSHOT_PREFIX"] ?? "macos-1.1"
        try? await Task.sleep(for: .seconds(1.5))
        if let sourcePath = environment["MATERIAL_LAB_SNAPSHOT_SOURCE"] {
            let source = MaterialSource(
                id: "snapshot:\(sourcePath)", url: URL(fileURLWithPath: sourcePath),
                semanticLabel: environment["MATERIAL_LAB_SNAPSHOT_LABEL"] ?? "weathered flagstone",
                category: "masonry", origin: .imported, reviewStatus: "reviewed",
                originalEnvelopeURL: nil
            )
            store.sources.insert(source, at: 0)
            store.selectSource(source.id)
            store.choosePreset(.stone)
            store.recipe.albedoEqualize = 0.6
            store.recipe.seamlessBlend = 0.12
            store.recipe.normalStrength = 3
            if let mode = environment["MATERIAL_LAB_SNAPSHOT_REPAIR"].flatMap(AlbedoRepair.init(rawValue:)) {
                store.recipe.albedoRepair = mode
            }
            if let library = LibraryPreset.named(environment["MATERIAL_LAB_SNAPSHOT_LIBRARY_PRESET"]) {
                store.chooseLibraryPreset(library)
            }
            // A folder with normal.png, roughness.png, ao.png and/or metalness.png: attached as authored maps.
            if let folder = environment["MATERIAL_LAB_SNAPSHOT_AUTHORED_DIR"] {
                store.recipe.authoredAlbedo = true
                for slot in AuthoredSlot.allCases {
                    let url = URL(fileURLWithPath: folder).appendingPathComponent("\(slot.rawValue).png")
                    if FileManager.default.fileExists(atPath: url.path) { slot.set(url, in: &store.recipe) }
                }
            }
        }
        if let bundlePath = environment["MATERIAL_LAB_SNAPSHOT_OPEN_BUNDLE"] {
            store.openMaterialBundle(URL(fileURLWithPath: bundlePath))
            let r = store.recipe
            print("open-bundle:", store.selectedSource?.semanticLabel ?? "-", r.materialPreset ?? "-", r.preset.rawValue,
                  r.roughnessBase, r.assignedMetalnessEnabled, r.albedoRepair.rawValue)
        }
        await waitForDerivation(store)
        if environment["MATERIAL_LAB_SNAPSHOT_UNDO_CHECK"] != nil { await undoCheck(store: store) }
        if environment["MATERIAL_LAB_SNAPSHOT_PRESET_CHECK"] != nil { await presetCheck(store: store) }
        if environment["MATERIAL_LAB_SNAPSHOT_COARSE_CHECK"] != nil { await coarseCheck(store: store) }
        for _ in 0..<600 where !store.learned.hasResolved { try? await Task.sleep(for: .milliseconds(100)) }
        print("learned model at launch:", store.learned.statusTitle, store.learned.info?.origin.rawValue ?? "-",
              store.learned.info?.modelFile ?? "-")
        if store.learned.info?.origin == .builtIn {
            let learnedPrefix = environment["MATERIAL_LAB_SNAPSHOT_LEARNED_PREFIX"] ?? "macos-1.2-learned"
            await renderStandalone(LearnedGeometrySettings(learned: store.learned), size: NSSize(width: 520, height: 620),
                                   appearance: .aqua, to: directory.appendingPathComponent("\(learnedPrefix)-settings-builtin.png"))
        }
        if environment["MATERIAL_LAB_SNAPSHOT_TILING"] != nil {
            await runTiling(store: store, directory: directory)
        }
        if let modelPath = environment[LearnedModelStore.environmentKey] {
            await runLearned(store: store, modelPath: modelPath, directory: directory, prefix: prefix)
        }
        if environment["MATERIAL_LAB_SNAPSHOT_LEARNED_ONLY"] != nil {
            NSApp.terminate(nil)
            return
        }
        if let exportPath = environment["MATERIAL_LAB_SNAPSHOT_EXPORT"], let material = store.currentMaterial {
            let folder = URL(fileURLWithPath: exportPath, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            do {
                let bundle = try MaterialBundle.export(material, into: folder)
                print("exported:", bundle.path)
                // Every engine and interchange format through the shared exporter.
                if environment["MATERIAL_LAB_SNAPSHOT_EXPORT_ALL"] != nil {
                    for target in ExportTarget.all { print("exported \(target.id):", try target.export(bundle: bundle).path) }
                }
            } catch { print("export failed:", error.localizedDescription) }
            if environment["MATERIAL_LAB_SNAPSHOT_EXPORT_ALL"] != nil {
                store.exportTargets = ["glb", "usdz", "unreal", "unity"]
                for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    await renderStandalone(ExportSheet(store: store), size: NSSize(width: 520, height: 620), appearance: appearance,
                                           to: folder.appendingPathComponent("export-sheet-\(name).png"))
                }
            }
        }
        let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
        for (appearanceName, appearance) in appearances {
            NSApp.appearance = NSAppearance(named: appearance)
            store.navigate(to: store.selectedSource.map { .source($0.id) } ?? .inbox)
            store.selectedMap = .albedo
            for mode in CanvasMode.allCases {
                store.canvasMode = mode
                if mode == .compare { store.selectedMap = .albedo }
                if mode == .tile { store.selectedMap = .albedo }
                if mode == .map { store.selectedMap = .albedo }
                try? await Task.sleep(for: .seconds(mode == .shaded3D ? 3 : 1.2))
                await capture(directory.appendingPathComponent("\(prefix)-\(mode.rawValue)-\(appearanceName).png"))
            }
            store.canvasMode = .map
            if let material = store.currentMaterial {
                let background = appearanceName == "dark"
                    ? CGColor(gray: 0.105, alpha: 1) : CGColor(gray: 0.925, alpha: 1)
                for shape in PreviewShape.allCases {
                    if let image = await PreviewScene.renderSnapshot(material, shape: shape, side: 900, background: background),
                       let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                        try? data.write(to: directory.appendingPathComponent("\(prefix)-3d-\(shape.rawValue)-\(appearanceName).png"))
                    }
                }
            }
            if let source = store.selectedSource {
                // The sidebar and inspector sit on vibrancy the fallback renderer cannot sample,
                // so also render them standalone for inspection.
                UserDefaults.standard.set(false, forKey: "materialLab.inspectorAdvanced")
                await renderStandalone(
                    RecipeInspector(store: store, source: source), size: NSSize(width: 340, height: 1500),
                    appearance: appearance,
                    to: directory.appendingPathComponent("\(prefix)-inspector-\(appearanceName).png"))
                UserDefaults.standard.set(true, forKey: "materialLab.inspectorAdvanced")
                await renderStandalone(
                    RecipeInspector(store: store, source: source), size: NSSize(width: 340, height: 1900),
                    appearance: appearance,
                    to: directory.appendingPathComponent("\(prefix)-inspector-advanced-\(appearanceName).png"))
                UserDefaults.standard.set(false, forKey: "materialLab.inspectorAdvanced")
                await renderStandalone(WelcomeSheet(), size: NSSize(width: 560, height: 470), appearance: appearance,
                                       to: directory.appendingPathComponent("\(prefix)-welcome-\(appearanceName).png"))
                await renderStandalone(
                    SourceSidebar(store: store), size: NSSize(width: 280, height: 700),
                    appearance: appearance,
                    to: directory.appendingPathComponent("\(prefix)-sidebar-\(appearanceName).png"))
            }
            store.navigate(to: .inbox)
            try? await Task.sleep(for: .seconds(1.2))
            await capture(directory.appendingPathComponent("\(prefix)-inbox-\(appearanceName).png"))
            store.navigate(to: .link)
            try? await Task.sleep(for: .seconds(1))
            await capture(directory.appendingPathComponent("\(prefix)-link-\(appearanceName).png"))
        }
        NSApp.terminate(nil)
    }

    /// Self-check for coarse-first learned geometry: time to the first learned result and to the refined one.
    private static func coarseCheck(store: MaterialLabStore) async {
        for _ in 0..<600 where !store.learned.hasResolved { try? await Task.sleep(for: .milliseconds(100)) }
        guard store.learned.info != nil else { print("coarse-check: no learned model installed"); return }
        // Warm the model on a different weight so the timings exclude first-load compilation.
        _ = try? LearnedNormalEstimator.shared.prepare()
        LearnedNormalEstimator.shared.clearCache()
        let started = Date()
        store.recipe.guideNormalWeight = 1
        var coarseAt: TimeInterval?, refinedAt: TimeInterval?, blockedWhileCoarse = false
        for _ in 0..<1200 {
            try? await Task.sleep(for: .milliseconds(25))
            guard let guide = store.currentMaterial?.guide else { continue }
            if guide.isCoarse, coarseAt == nil {
                coarseAt = Date().timeIntervalSince(started)
                blockedWhileCoarse = store.exportBlocker != nil
            }
            if !guide.isCoarse, !store.isDeriving { refinedAt = Date().timeIntervalSince(started); break }
        }
        let ok = coarseAt != nil && refinedAt != nil && blockedWhileCoarse && store.exportBlocker == nil
        print("coarse-check:", ok ? "PASS" : "FAIL",
              "first learned result", coarseAt.map { String(format: "%.2f s", $0) } ?? "none",
              "refined", refinedAt.map { String(format: "%.2f s", $0) } ?? "none",
              "export blocked while coarse", blockedWhileCoarse)
    }

    /// Self-check for saved recipes: save, edit, apply restores, file round-trips; renders the row; cleans up.
    private static func presetCheck(store: MaterialLabStore) async {
        let name = "Harness check \(UUID().uuidString.prefix(6))"
        store.recipe.heightStrength = 0.31
        store.saveCurrentRecipe(named: name)
        store.recipe.heightStrength = 0.07
        guard let saved = store.savedRecipes.first(where: { $0.name == name }) else { print("preset-check: FAIL not saved"); return }
        store.applySavedRecipe(saved)
        let onDisk = MaterialLibrary.loadSavedRecipes().first { $0.name == name }
        let ok = store.recipe.heightStrength == 0.31 && onDisk?.recipe.heightStrength == 0.31
        print("preset-check:", ok ? "PASS" : "FAIL", "applied", store.recipe.heightStrength, "on disk", onDisk?.recipe.heightStrength ?? -1)
        if let directory = environment["MATERIAL_LAB_SNAPSHOT_DIR"], let source = store.selectedSource {
            await renderStandalone(RecipeInspector(store: store, source: source), size: NSSize(width: 340, height: 420),
                                   appearance: .aqua,
                                   to: URL(fileURLWithPath: directory).appendingPathComponent("preset-row.png"))
        }
        store.deleteSavedRecipe(saved)
        print("preset-check: cleaned up", !MaterialLibrary.loadSavedRecipes().contains { $0.name == name })
    }

    /// Self-check for recipe undo: a burst of edits is one step, a later edit another; undo and redo walk them.
    private static func undoCheck(store: MaterialLabStore) async {
        guard let undo = store.undoManager else { print("undo-check: no undo manager"); return }
        // Without user events nothing closes AppKit's event groups. AppKit drops event groups that end up empty
        // (every coalesced drag event), so each gesture amounts to one group: emulate exactly that.
        undo.removeAllActions()
        store.resetUndoCoalescing()
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        let start = store.recipe.heightStrength
        undo.beginUndoGrouping()
        for value: Float in [0.05, 0.10, 0.15] {
            store.recipe.heightStrength = value
            try? await Task.sleep(for: .milliseconds(80))
        }
        undo.endUndoGrouping()
        try? await Task.sleep(for: .seconds(1))
        undo.beginUndoGrouping(); store.recipe.roughnessBase = 0.33; undo.endUndoGrouping()
        try? await Task.sleep(for: .seconds(1))
        undo.undo()
        let afterFirst = (store.recipe.heightStrength, store.recipe.roughnessBase)
        undo.undo()
        let afterSecond = store.recipe.heightStrength
        undo.redo()
        let afterRedo = store.recipe.heightStrength
        let ok = afterFirst.0 == 0.15 && afterFirst.1 != 0.33 && afterSecond == start && afterRedo == 0.15
        print("undo-check:", ok ? "PASS" : "FAIL", "start", start, "after undo 1", afterFirst, "after undo 2", afterSecond, "after redo", afterRedo)
        try? await Task.sleep(for: .seconds(1.5)) // Let the debounced recipe save land.
    }

    /// Tile view of the source with Make tileable off, Structured (seam cut) and Soft blend, plus a
    /// 3×3 repeat of the albedo and height maps for each, and the inspector's tiling controls.
    private static func runTiling(store: MaterialLabStore, directory: URL) async {
        let tilingPrefix = environment["MATERIAL_LAB_SNAPSHOT_TILING_PREFIX"] ?? "macos-1.2-tiling"
        func file(_ name: String) -> URL { directory.appendingPathComponent("\(tilingPrefix)-\(name).png") }
        NSApp.appearance = NSAppearance(named: .aqua)
        store.navigate(to: store.selectedSource.map { .source($0.id) } ?? .inbox)
        let variants: [(String, Float, SeamlessMode)] = [("off", 0, .cut), ("cut", 0.12, .cut), ("blend", 0.12, .blend)]
        for (name, width, mode) in variants {
            store.recipe.seamlessBlend = width
            store.recipe.seamlessMode = mode
            store.deriveSelected()
            await waitForDerivation(store)
            guard let material = store.currentMaterial else { continue }
            print("tiling \(name): albedo seam=\(material.seams.albedoValue) height seam=\(material.seams.heightValue)")
            for kind in [MaterialMapKind.albedo, .height] {
                if let image = material.previews[kind], let tiled = repeat3x3(image),
                   let data = NSBitmapImageRep(cgImage: tiled).representation(using: .png, properties: [:]) {
                    try? data.write(to: file("\(kind.rawValue)-3x3-\(name)"))
                }
            }
            store.selectedMap = .albedo
            store.canvasMode = .tile
            await renderStandalone(ContentView(store: store), size: NSSize(width: 1440, height: 900),
                                   appearance: .aqua, to: file("window-tile-\(name)"), settle: 1.5)
            if name == "cut", let source = store.selectedSource {
                await renderStandalone(RecipeInspector(store: store, source: source), size: NSSize(width: 340, height: 1500),
                                       appearance: .aqua, to: file("inspector"))
            }
        }
        store.canvasMode = .map
        store.recipe.seamlessBlend = 0.12
        store.recipe.seamlessMode = .cut
        store.deriveSelected()
        await waitForDerivation(store)
    }

    private static func repeat3x3(_ image: CGImage) -> CGImage? {
        let side = 900, cell = side / 3
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        for y in 0..<3 { for x in 0..<3 { context.draw(image, in: CGRect(x: x * cell, y: y * cell, width: cell, height: cell)) } }
        return context.makeImage()
    }

    /// Installs the model from MATERIAL_LAB_MOGE_MODEL, then captures the inspector, settings and the
    /// height / normal maps with learned geometry at 0 and 1, and optionally exports with weight 1.
    private static func runLearned(store: MaterialLabStore, modelPath: String, directory: URL, prefix: String) async {
        let learnedPrefix = environment["MATERIAL_LAB_SNAPSHOT_LEARNED_PREFIX"] ?? "macos-1.2-learned"
        func file(_ name: String) -> URL { directory.appendingPathComponent("\(learnedPrefix)-\(name).png") }
        NSApp.appearance = NSAppearance(named: .aqua)
        // The dev bootstrap may already have installed MATERIAL_LAB_MOGE_MODEL; start from a clean slate.
        for _ in 0..<600 where !store.learned.hasResolved { try? await Task.sleep(for: .milliseconds(100)) }
        print("learned resolved at launch:", store.learned.statusTitle, store.learned.info?.origin.rawValue ?? "-")
        store.learned.deactivateForSnapshot()
        store.recipe.guideNormalWeight = 0
        if let source = store.selectedSource {
            await renderStandalone(RecipeInspector(store: store, source: source), size: NSSize(width: 340, height: 1500),
                                   appearance: .aqua, to: file("inspector-uninstalled"))
        }
        await store.learned.install(from: URL(fileURLWithPath: modelPath))
        print("learned model:", store.learned.statusTitle, store.learned.info?.modelFile ?? "-", store.learned.lastError ?? "")
        if environment["MATERIAL_LAB_SNAPSHOT_CPU_ONLY"] != nil { store.learned.cpuOnly = true }
        await renderStandalone(LearnedGeometrySettings(learned: store.learned), size: NSSize(width: 520, height: 620),
                               appearance: .aqua, to: file("settings-light"))
        await renderStandalone(LearnedGeometrySettings(learned: store.learned), size: NSSize(width: 520, height: 620),
                               appearance: .darkAqua, to: file("settings-dark"))
        store.navigate(to: store.selectedSource.map { .source($0.id) } ?? .inbox)
        store.canvasMode = .map
        for weight: Float in [0, 1] {
            store.recipe.guideNormalWeight = weight
            store.deriveSelected()
            if weight > 0, let source = store.selectedSource {
                // Catch the inspector while inference runs (first use for this source).
                try? await Task.sleep(for: .milliseconds(60))
                await renderStandalone(RecipeInspector(store: store, source: source), size: NSSize(width: 340, height: 700),
                                       appearance: .aqua, to: file("inspector-running"), settle: 0.05)
            }
            await waitForDerivation(store)
            guard let material = store.currentMaterial else { continue }
            let tag = weight == 0 ? "w0" : "w1"
            print("learned \(tag): guide=\(material.guide != nil) inference=\(material.guide.map { Int($0.inferenceDuration * 1000) } ?? 0) ms derive=\(Int(material.duration * 1000)) ms")
            for kind in [MaterialMapKind.height, .normal, .learnedNormal] {
                if let image = material.previews[kind],
                   let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                    try? data.write(to: file("map-\(kind.rawValue)-\(tag)"))
                }
            }
            for kind in [MaterialMapKind.height, .normal] {
                store.selectedMap = kind
                try? await Task.sleep(for: .seconds(1.2))
                await capture(file("canvas-\(kind.rawValue)-\(tag)"))
                // Window capture needs an awake, unlocked display; also draw the workspace standalone.
                await renderStandalone(ContentView(store: store), size: NSSize(width: 1440, height: 900),
                                       appearance: .aqua, to: file("window-\(kind.rawValue)-\(tag)"), settle: 1.5)
            }
            if weight > 0 {
                store.selectedMap = .learnedNormal
                try? await Task.sleep(for: .seconds(1.2))
                await capture(file("canvas-learnedNormal-w1"))
                await renderStandalone(ContentView(store: store), size: NSSize(width: 1440, height: 900),
                                       appearance: .darkAqua, to: file("window-learnedNormal-w1-dark"), settle: 1.5)
                store.canvasMode = .relit
                try? await Task.sleep(for: .seconds(1.5))
                await capture(file("canvas-relit-w1"))
                store.canvasMode = .map
                if let source = store.selectedSource {
                    for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                        await renderStandalone(RecipeInspector(store: store, source: source), size: NSSize(width: 340, height: 1500),
                                               appearance: appearance, to: file("inspector-\(name)"))
                    }
                }
                // A recipe edit must reuse the cached guide normals.
                store.recipe.normalStrength += 0.5
                store.deriveSelected()
                await waitForDerivation(store)
                print("learned edit: cached=\(store.currentMaterial?.guide?.wasCached ?? false) derive=\(Int((store.currentMaterial?.duration ?? 0) * 1000)) ms")
                store.recipe.normalStrength -= 0.5
                // Warm (model already loaded) inference timing.
                LearnedNormalEstimator.shared.clearCache()
                store.deriveSelected()
                await waitForDerivation(store)
                print("learned warm: inference=\(Int((store.currentMaterial?.guide?.inferenceDuration ?? 0) * 1000)) ms derive=\(Int((store.currentMaterial?.duration ?? 0) * 1000)) ms")
                if let exportPath = environment["MATERIAL_LAB_SNAPSHOT_EXPORT"], let current = store.currentMaterial {
                    let folder = URL(fileURLWithPath: exportPath, isDirectory: true)
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    do { print("exported learned:", try MaterialBundle.export(current, into: folder).path) }
                    catch { print("learned export failed:", error.localizedDescription) }
                }
            }
        }
    }

    private static func renderStandalone<V: View>(
        _ content: V, size: NSSize, appearance: NSAppearance.Name, to url: URL, settle: Double = 1
    ) async {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: 0), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: content.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(settle))
        host.layoutSubtreeIfNeeded()
        if let representation = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: representation)
            try? representation.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.orderOut(nil)
    }

    private static func waitForDerivation(_ store: MaterialLabStore) async {
        for _ in 0..<200 {
            try? await Task.sleep(for: .milliseconds(100))
            if !store.isDeriving, store.derivedIsCurrent { break }
        }
        try? await Task.sleep(for: .seconds(0.5))
    }

    private static func capture(_ url: URL) async {
        if await captureWithScreenCaptureKit(url) { return }
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.height > 300 }),
              let view = window.contentView?.superview ?? window.contentView
        else { return }
        view.layoutSubtreeIfNeeded()
        // Render the layer tree: backdrop (vibrancy/glass) layers cannot be sampled without
        // Screen Recording, so paint the window background underneath them instead.
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        guard let layer = view.layer,
              let context = CGContext(
                data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return }
        var background = NSColor.windowBackgroundColor
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            background = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? .gray
        }
        context.setFillColor(background.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        context.scaleBy(x: scale, y: scale)
        if !view.isFlipped {
            // CALayer rendering already matches AppKit's layer geometry.
        }
        layer.render(in: context)
        guard let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return }
        try? data.write(to: url)
    }
}

extension SnapshotHarness {
    /// Pixel-exact capture including Liquid Glass and vibrancy; needs Screen Recording
    /// permission, so it falls back to drawing the view hierarchy when unavailable.
    fileprivate static func captureWithScreenCaptureKit(_ url: URL) async -> Bool {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let window = content.windows.first(where: {
                  $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier && $0.frame.height > 300
              })
        else { return false }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        else { return false }
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }
}
