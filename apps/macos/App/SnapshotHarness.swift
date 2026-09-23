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
        }
        await waitForDerivation(store)
        if let exportPath = environment["MATERIAL_LAB_SNAPSHOT_EXPORT"], let material = store.currentMaterial {
            let folder = URL(fileURLWithPath: exportPath, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            do { print("exported:", try MaterialBundle.export(material, into: folder).path) }
            catch { print("export failed:", error.localizedDescription) }
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
                await renderStandalone(
                    RecipeInspector(store: store, source: source), size: NSSize(width: 340, height: 1500),
                    appearance: appearance,
                    to: directory.appendingPathComponent("\(prefix)-inspector-\(appearanceName).png"))
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

    private static func renderStandalone<V: View>(
        _ content: V, size: NSSize, appearance: NSAppearance.Name, to url: URL
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
        try? await Task.sleep(for: .seconds(1))
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
