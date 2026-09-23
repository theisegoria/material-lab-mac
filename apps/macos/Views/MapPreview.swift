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
    @State private var compareRelit = false
    @State private var showSeams = true
    @State private var shape: PreviewShape = .sphere
    @FocusState private var focused: Bool

    private var material: DerivedMaterial? { store.currentMaterial }

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
                MaterialPreview3D(material: material, shape: shape)
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
            if let material, let before = material.workingPreview,
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
                    hudLabel("Drag to orbit · scroll to zoom")
                case .relit:
                    lightControls
                case .compare:
                    Picker("Compare with", selection: $compareRelit) {
                        Text(store.selectedMap.shortTitle).tag(false)
                        Text("Relit").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 170)
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
                    zoomControls
                }
            }
        }
        .controlSize(.regular)
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
            .overlay(alignment: .topLeading) { tag("Before · Source") }
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
