import AppKit
import SwiftUI

/// Large material canvas with map, relit, before/after, tiled and 3D views plus floating glass HUDs.
struct MaterialCanvas: View {
    @Bindable var store: MaterialLabStore
    let source: MaterialSource

    @State private var sourceImage: CGImage?
    @State private var relitImage: CGImage?
    @State private var zoom: CGFloat = 1
    @State private var gestureZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var dragPan: CGSize = .zero
    @State private var split: CGFloat = 0.5
    /// What Compare puts on the right of the divider: the selected map, the relit view, or the pinned version.
    @State private var compareTarget: CompareTarget = .map
    @State private var loupe: CGPoint?   // Normalized cursor position over the map (Map view).
    @State private var showSeams = true
    @State private var shape: PreviewShape = .sphere
    @State private var environment: PreviewEnvironment = .studio
    @State private var tiling: Float = 2
    @FocusState private var focused: Bool

    private var material: DerivedMaterial? { store.currentMaterial }

    private var compareRelit: Bool { compareTarget == .relit }

    private var needsRelight: Bool {
        store.canvasMode == .relit || (store.canvasMode == .compare && compareRelit)
    }

    /// The image the active mode shows (map, relit, or the source while nothing is derived).
    private var primaryImage: CGImage? {
        guard let material else { return sourceImage }
        if store.canvasMode == .relit { return relitImage ?? material.previews[.albedo] }
        return material.previews[store.selectedMap] ?? material.previews[.albedo]
    }

    private var primaryTitle: String {
        guard material != nil else { return "Source" }
        if store.canvasMode == .relit { return "Relit" }
        return store.selectedMap.title
    }

    var body: some View {
        ZStack {
            Rectangle().fill(CanvasBackground())
            content
                .padding(.horizontal, store.canvasMode == .shaded3D ? 0 : 32)
                .padding(.top, store.canvasMode == .shaded3D ? 0 : 60)
                .padding(.bottom, store.canvasMode == .shaded3D ? 0 : 76)
            VStack {
                HStack(alignment: .top) {
                    stateChip
                    Spacer()
                }
                Spacer()
                hud
            }
            .padding(16)
        }
        .overlay(alignment: .top) {
            if store.isDeriving {
                ProgressView(value: Double(store.progress))
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .frame(height: 2)
                    .transition(.opacity)
            }
        }
        .clipped()
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.space) {
            withAnimation(.snappy) { store.toggleCompare() }
            return .handled
        }
        .onTapGesture { focused = true }
        .onAppear { focused = true }
        .task(id: source.id) {
            sourceImage = nil
            let url = source.url
            let loaded = await Task.detached(priority: .userInitiated) {
                ThumbnailCache.shared.image(for: url, maxPixel: 2048)
            }.value
            if !Task.isCancelled { sourceImage = loaded }
        }
        .task(id: RelightKey(source: source.id, serial: store.derivationSerial,
                             azimuth: store.lightAzimuth, elevation: store.lightElevation,
                             active: needsRelight)) {
            guard needsRelight, let material else { return }
            let azimuth = store.lightAzimuth, elevation = store.lightElevation
            let serial = store.derivationSerial
            let image = await Task.detached(priority: .userInitiated) {
                MaterialEngine.relitImage(material, azimuth: azimuth, elevation: elevation)
            }.value
            guard !Task.isCancelled else { return }
            if store.derivationSerial == serial { relitImage = image }
        }
        .onChange(of: source.id) { _, _ in
            relitImage = nil
            resetZoom()
        }
        .onChange(of: store.canvasMode) { _, _ in resetZoom() }
        .animation(.easeInOut(duration: 0.2), value: store.canvasMode)
        .animation(.easeInOut(duration: 0.18), value: store.selectedMap)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch store.canvasMode {
        case .shaded3D:
            if let material {
                MaterialPreview3D(material: material, shape: shape, environment: environment, tiling: tiling)
                    .transition(.opacity)
            } else {
                placeholder
            }
        case .tile:
            if let image = primaryImage {
                zoomable {
                    TiledImage(image: image, showSeams: showSeams)
                }
            } else { placeholder }
        case .compare:
            if compareTarget == .pinned, let pinned = store.pinnedMaterial,
               let before = pinned.previews[store.selectedMap] ?? pinned.previews[.albedo], let after = primaryImage {
                zoomable {
                    CompareView(before: before, after: after, split: $split,
                                beforeTitle: "Pinned · \(store.selectedMap.shortTitle)",
                                afterTitle: "Now · \(store.selectedMap.shortTitle)")
                }
            } else if let material, let before = material.workingPreview,
               let after = compareRelit ? (relitImage ?? material.previews[.albedo]) : primaryImage {
                zoomable {
                    CompareView(before: before, after: after, split: $split,
                                afterTitle: compareRelit ? "Relit" : store.selectedMap.title)
                }
            } else if let image = primaryImage {
                zoomable { CanvasImage(image: image, zoom: effectiveZoom) }
            } else { placeholder }
        case .relit:
            if material != nil, let image = primaryImage {
                zoomable {
                    CanvasImage(image: image, zoom: effectiveZoom)
                        .overlay { LightDragSurface(store: store) }
                }
            } else if let image = primaryImage {
                zoomable { CanvasImage(image: image, zoom: effectiveZoom) }
            } else { placeholder }
        case .map:
            if let image = primaryImage {
                zoomable {
                    CanvasImage(image: image, zoom: effectiveZoom)
                        .id(primaryTitle)
                        .transition(.opacity)
                        .overlay {
                            GeometryReader { geometry in
                                Color.clear
                                    .contentShape(Rectangle())
                                    .onContinuousHover { phase in
                                        switch phase {
                                        case .active(let point):
                                            loupe = CGPoint(x: point.x / geometry.size.width, y: point.y / geometry.size.height)
                                        case .ended:
                                            loupe = nil
                                        }
                                    }
                                if let loupe, material != nil {
                                    Loupe(image: image, at: loupe)
                                        .position(x: loupe.x * geometry.size.width + 70,
                                                  y: loupe.y * geometry.size.height - 70)
                                        .allowsHitTesting(false)
                                }
                            }
                        }
                }
            } else { placeholder }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("Loading source…").foregroundStyle(.secondary)
        }
    }

    private var effectiveZoom: CGFloat { zoom * gestureZoom }

    private func zoomable<Content: View>(@ViewBuilder _ inner: () -> Content) -> some View {
        let view = inner()
        return GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            view
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
                .scaleEffect(effectiveZoom)
                .offset(x: pan.width + dragPan.width, y: pan.height + dragPan.height)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .contentShape(Rectangle())
        .gesture(
            MagnifyGesture()
                .onChanged { value in gestureZoom = value.magnification }
                .onEnded { value in
                    zoom = min(8, max(0.5, zoom * value.magnification))
                    gestureZoom = 1
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in if zoom > 1 { dragPan = value.translation } }
                .onEnded { value in
                    if zoom > 1 {
                        pan.width += value.translation.width
                        pan.height += value.translation.height
                    }
                    dragPan = .zero
                },
            including: store.canvasMode == .relit || store.canvasMode == .compare ? .subviews : .all
        )
        .onTapGesture(count: 2) { withAnimation(.snappy) { resetZoom() } }
    }

    private func resetZoom() {
        zoom = 1
        pan = .zero
        dragPan = .zero
    }

    // MARK: Overlays

    @ViewBuilder
    private var stateChip: some View {
        if let error = store.derivationError {
            chip(error, systemImage: "exclamationmark.triangle.fill", tint: .orange)
        } else if store.isDeriving {
            chip("Deriving \(Int(store.progress * 100))%", systemImage: "wand.and.sparkles", tint: .accentColor)
        } else if material != nil, !store.derivedIsCurrent {
            chip("Out of date · press ⌘R", systemImage: "clock.arrow.circlepath", tint: .orange)
        } else if material == nil, !store.isDeriving {
            chip("Source preview", systemImage: "photo", tint: .secondary)
        }
    }

    private func chip(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout.weight(.medium))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: Capsule())
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var hud: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                switch store.canvasMode {
                case .shaded3D:
                    Picker("Shape", selection: $shape) {
                        ForEach(PreviewShape.allCases) { shape in
                            Label(shape.title, systemImage: shape.symbol).tag(shape)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .labelStyle(.iconOnly)
                    .frame(width: 150)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: Capsule())
                    Menu {
                        Picker("Lighting", selection: $environment) {
                            ForEach(PreviewEnvironment.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                        }
                    } label: {
                        Label(environment.title, systemImage: environment.symbol)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glass)
                    .fixedSize()
                    .help("Lighting environment")
                    HStack(spacing: 6) {
                        Text("Tiling").font(.callout).foregroundStyle(.secondary)
                        Stepper(value: $tiling, in: 1...8, step: 1) {
                            Text("\(Int(tiling))×").monospacedDigit()
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: Capsule())
                    .help("How many times the material repeats across the shape")
                case .relit:
                    lightControls
                case .compare:
                    Picker("Compare with", selection: $compareTarget) {
                        Text(store.selectedMap.shortTitle).tag(CompareTarget.map)
                        Text("Relit").tag(CompareTarget.relit)
                        Text("Pinned").tag(CompareTarget.pinned)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)
                    .help("Compare with the source photo, the relit view, or a pinned earlier version of this recipe")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: Capsule())
                    zoomControls
                case .tile:
                    Toggle(isOn: $showSeams) {
                        Label("Seams", systemImage: "grid")
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.glass)
                    .help("Show tile boundaries")
                    zoomControls
                case .map:
                    if let material, let map = material.maps[store.selectedMap] {
                        if let loupe, let readout = PixelReadout(map: map, kind: store.selectedMap, at: loupe) {
                            hudLabel(readout.text).monospacedDigit()
                        } else {
                            HistogramStrip(map: map, kind: store.selectedMap)
                        }
                    }
                    pinButton
                    zoomControls
                }
            }
        }
        .controlSize(.regular)
    }

    /// Keeps the current maps so Compare can wipe between them and later edits.
    private var pinButton: some View {
        Button {
            store.pinCurrentVersion()
        } label: {
            Label(store.pinnedMaterial == nil ? "Pin" : "Re-pin", systemImage: store.pinnedMaterial == nil ? "pin" : "pin.fill")
        }
        .buttonStyle(.glass)
        .disabled(material == nil)
        .help("Pin these maps, then use Compare › Pinned to wipe between them and your later edits")
    }

    private func hudLabel(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: Capsule())
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            Button {
                withAnimation(.snappy) { zoom = max(0.5, zoom / 1.5) }
            } label: { Image(systemName: "minus.magnifyingglass") }
            .help("Zoom out")
            Button {
                withAnimation(.snappy) { resetZoom() }
            } label: {
                Text(zoom == 1 ? "Fit" : "\(Int((zoom * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(minWidth: 44)
            }
            .help("Zoom to fit (double-click the canvas)")
            Button {
                withAnimation(.snappy) { zoom = min(8, zoom * 1.5) }
            } label: { Image(systemName: "plus.magnifyingglass") }
            .help("Zoom in")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Zoom")
    }

    private var lightControls: some View {
        HStack(spacing: 14) {
            Image(systemName: "sun.max.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 0) {
                Text("Direction").font(.caption2).foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { Double(store.lightAzimuth) },
                    set: { store.lightAzimuth = Float($0) }
                ), in: -Double.pi...Double.pi)
                .frame(width: 150)
                .accessibilityLabel("Light direction")
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Height").font(.caption2).foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { Double(store.lightElevation) },
                    set: { store.lightElevation = Float($0) }
                ), in: 0.1...1.5)
                .frame(width: 110)
                .accessibilityLabel("Light elevation")
            }
            Text("or drag on the image")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
    }
}

private struct RelightKey: Hashable {
    let source: String
    let serial: Int
    let azimuth: Float
    let elevation: Float
    let active: Bool
}

/// Neutral canvas that reads well in both appearances.
private struct CanvasBackground: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        environment.colorScheme == .dark
            ? Color(white: 0.105)
            : Color(white: 0.925)
    }
}

struct CanvasImage: View {
    let image: CGImage
    var zoom: CGFloat = 1

    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(zoom >= 2 ? .none : .high)
            .aspectRatio(1, contentMode: .fit)
    }
}

private struct TiledImage: View {
    let image: CGImage
    let showSeams: Bool

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let cell = side / 3
            ZStack {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(0..<3, id: \.self) { _ in
                        GridRow {
                            ForEach(0..<3, id: \.self) { _ in
                                Image(decorative: image, scale: 1)
                                    .resizable()
                                    .interpolation(.high)
                                    .frame(width: cell, height: cell)
                            }
                        }
                    }
                }
                if showSeams {
                    Path { path in
                        for i in 1...2 {
                            let p = cell * CGFloat(i)
                            path.move(to: CGPoint(x: p, y: 0)); path.addLine(to: CGPoint(x: p, y: side))
                            path.move(to: CGPoint(x: 0, y: p)); path.addLine(to: CGPoint(x: side, y: p))
                        }
                    }
                    .stroke(Color.yellow.opacity(0.85), style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
                    .blendMode(.difference)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement()
        .accessibilityLabel("Three by three tiled preview")
    }
}

private struct CompareView: View {
    let before: CGImage
    let after: CGImage
    @Binding var split: CGFloat
    var beforeTitle = "Source"
    let afterTitle: String

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let x = width * split
            ZStack(alignment: .leading) {
                Image(decorative: after, scale: 1).resizable().interpolation(.high)
                Image(decorative: before, scale: 1).resizable().interpolation(.high)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: x)
                    }
                Rectangle()
                    .fill(.white)
                    .frame(width: 2)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .offset(x: x - 1)
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .offset(x: x - 17)
                    .frame(maxHeight: .infinity)
            }
            .overlay(alignment: .topLeading) { tag("Before · \(beforeTitle)") }
            .overlay(alignment: .topTrailing) { tag("After · \(afterTitle)") }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        split = min(1, max(0, value.location.x / max(1, width)))
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Before and after comparison")
            .accessibilityValue("\(Int(split * 100)) percent source")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: split = min(1, split + 0.1)
                case .decrement: split = max(0, split - 0.1)
                @unknown default: break
                }
            }
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: Capsule())
            .padding(10)
    }
}

/// Drag on the relit image to place the light; distance from the center lowers it.
private struct LightDragSurface: View {
    @Bindable var store: MaterialLabStore

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2
            let reach = CGFloat(cos(store.lightElevation)) * radius
            let sun = CGPoint(
                x: center.x + CGFloat(cos(store.lightAzimuth)) * reach,
                y: center.y + CGFloat(sin(store.lightAzimuth)) * reach
            )
            ZStack {
                Color.clear.contentShape(Rectangle())
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.yellow)
                    .shadow(color: .black.opacity(0.5), radius: 3)
                    .position(sun)
                    .allowsHitTesting(false)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let dx = Float(value.location.x - center.x)
                        let dy = Float(value.location.y - center.y)
                        let distance = min(1, (dx * dx + dy * dy).squareRoot() / Float(max(1, radius)))
                        store.lightAzimuth = atan2(dy, dx)
                        store.lightElevation = max(0.1, min(1.5, acos(distance)))
                    }
            )
        }
        .accessibilityHidden(true)
    }
}

enum CompareTarget: Hashable { case map, relit, pinned }

/// A magnified 11×11 pixel patch around the cursor, nearest-neighbour, for inspecting texels.
private struct Loupe: View {
    let image: CGImage
    let at: CGPoint

    var body: some View {
        let radius = 5
        let cx = Int(at.x * CGFloat(image.width)), cy = Int(at.y * CGFloat(image.height))
        let x = min(max(0, cx - radius), image.width - (2 * radius + 1))
        let y = min(max(0, cy - radius), image.height - (2 * radius + 1))
        Group {
            if let patch = image.cropping(to: CGRect(x: x, y: y, width: 2 * radius + 1, height: 2 * radius + 1)) {
                Image(decorative: patch, scale: 1)
                    .resizable()
                    .interpolation(.none)
            }
        }
        .frame(width: 110, height: 110)
        .overlay { Rectangle().stroke(.white.opacity(0.9), lineWidth: 1).frame(width: 10, height: 10) }
        .clipShape(Circle())
        .overlay { Circle().stroke(.white.opacity(0.85), lineWidth: 2) }
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .accessibilityHidden(true)
    }
}

/// The selected map's values under the cursor: RGBA bytes, a 16-bit height, or a decoded normal.
private struct PixelReadout {
    let text: String

    init?(map: MaterialMapData, kind: MaterialMapKind, at point: CGPoint) {
        let x = min(map.width - 1, max(0, Int(point.x * CGFloat(map.width))))
        let y = min(map.height - 1, max(0, Int(point.y * CGFloat(map.height))))
        guard point.x >= 0, point.x <= 1, point.y >= 0, point.y <= 1 else { return nil }
        let bytes = [UInt8](map.bytes)
        if map.format == .r16Linear {
            let i = y * map.rowBytes + x * 2
            guard i + 1 < bytes.count else { return nil }
            let value = Int(bytes[i]) | Int(bytes[i + 1]) << 8
            text = String(format: "%d, %d · height %d (%.3f)", x, y, value, Double(value) / 65535)
            return
        }
        let i = y * map.rowBytes + x * 4
        guard i + 3 < bytes.count else { return nil }
        let r = bytes[i], g = bytes[i + 1], b = bytes[i + 2], a = bytes[i + 3]
        switch kind {
        case .normal, .bentNormal, .learnedNormal:
            text = String(format: "%d, %d · n (%.2f, %.2f, %.2f)", x, y,
                          Double(r) / 127.5 - 1, Double(g) / 127.5 - 1, Double(b) / 127.5 - 1)
        case .albedo:
            text = "\(x), \(y) · R \(r) G \(g) B \(b) A \(a)"
        case .orm:
            text = String(format: "%d, %d · AO %.2f  rough %.2f  metal %.2f", x, y,
                          Double(r) / 255, Double(g) / 255, Double(b) / 255)
        default:
            text = String(format: "%d, %d · %@ %.3f", x, y, kind.title.lowercased(), Double(r) / 255)
        }
    }
}

/// A compact histogram of the selected map (luminance, or the first channel of data maps; height uses 16-bit).
private struct HistogramStrip: View {
    let map: MaterialMapData
    let kind: MaterialMapKind

    var body: some View {
        let bins = Self.bins(map)
        let peak = max(1, bins.max() ?? 1)
        Canvas { context, size in
            let step = size.width / CGFloat(bins.count)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for (index, value) in bins.enumerated() {
                let height = size.height * CGFloat((Double(value) / Double(peak)).squareRoot())
                path.addLine(to: CGPoint(x: CGFloat(index) * step, y: size.height - height))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            context.fill(path, with: .color(.accentColor.opacity(0.75)))
        }
        .frame(width: 160, height: 26)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: Capsule())
        .help("Histogram of the \(kind.title.lowercased()) map")
        .accessibilityLabel("\(kind.title) histogram")
    }

    static func bins(_ map: MaterialMapData) -> [Int] {
        var bins = [Int](repeating: 0, count: 64)
        let bytes = [UInt8](map.bytes)
        let stride = max(1, (map.width * map.height) / 65536)   // Sample at most ~64K pixels.
        var pixel = 0
        while pixel < map.width * map.height {
            let x = pixel % map.width, y = pixel / map.width
            let value: Int
            if map.format == .r16Linear {
                let i = y * map.rowBytes + x * 2
                value = (Int(bytes[i]) | Int(bytes[i + 1]) << 8) >> 10
            } else {
                let i = y * map.rowBytes + x * 4
                value = (Int(bytes[i]) * 54 + Int(bytes[i + 1]) * 183 + Int(bytes[i + 2]) * 19) >> 10
            }
            bins[min(63, value)] += 1
            pixel += stride
        }
        return bins
    }
}
