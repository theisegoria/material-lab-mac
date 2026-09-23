import AppKit
import SwiftUI

/// The per-source workspace: canvas, map shelf and the recipe inspector.
struct MaterialWorkspace: View {
    @Bindable var store: MaterialLabStore
    let source: MaterialSource

    var body: some View {
        VStack(spacing: 0) {
            MaterialCanvas(store: store, source: source)
            Divider()
            MapShelf(store: store)
        }
        .navigationTitle(source.displayName)
        .navigationSubtitle("\(source.category) · \(source.reviewStatus)")
        .inspector(isPresented: $store.showInspector) {
            RecipeInspector(store: store, source: source)
                .inspectorColumnWidth(min: 290, ideal: 320, max: 420)
        }
        .toolbar { toolbarContent }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $store.canvasMode) {
                ForEach(CanvasMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol)
                        .tag(mode)
                        .help("\(mode.title) view")
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .labelStyle(.iconOnly)
            .accessibilityLabel("Canvas view")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if store.isDeriving || store.isBatching || store.isExporting || store.isImporting {
                ProgressView(value: Double(store.isBatching ? store.batchProgress : store.progress))
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .help(store.status)
                    .accessibilityLabel("Processing progress")
            }
            Button {
                store.deriveSelected()
            } label: {
                Label("Derive", systemImage: "arrow.trianglehead.2.clockwise")
            }
            .disabled(!store.canDerive)
            .help("Derive maps now (⌘R)")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button {
                store.exportSelected()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.glassProminent)
            .disabled(!store.canExport)
            .help(store.exportBlocker ?? "Export a validated .pbrmaterial bundle (⌘E)")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button {
                withAnimation { store.showInspector.toggle() }
            } label: {
                Label("Recipe", systemImage: "sidebar.trailing")
            }
            .help(store.showInspector ? "Hide recipe inspector" : "Show recipe inspector")
        }
    }
}

// MARK: - Map shelf

private struct MapShelf: View {
    @Bindable var store: MaterialLabStore
    @Namespace private var selection

    private var kinds: [MaterialMapKind] {
        store.availableMaps.isEmpty
            ? [.albedo, .height, .normal, .roughness, .ao, .cavity, .convexity, .slope, .edge]
            : store.availableMaps
    }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Maps").font(.headline)
                    Text(store.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                    Spacer(minLength: 0)
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in
                            MapCard(
                                kind: kind,
                                image: store.currentMaterial?.previews[kind],
                                shortcut: index < 9 ? "⌘\(index + 1)" : nil,
                                isSelected: store.selectedMap == kind && store.currentMaterial != nil,
                                namespace: selection
                            ) {
                                withAnimation(.snappy(duration: 0.25)) { store.selectMap(kind) }
                            }
                            .disabled(store.currentMaterial == nil)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 2)
                }
                .scrollIndicators(.never)
            }
            if let material = store.currentMaterial {
                DiagnosticsCard(material: material, isCurrent: store.derivedIsCurrent)
                    .frame(width: 300)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .animation(.easeOut(duration: 0.2), value: store.currentMaterial == nil)
    }
}

private struct MapCard: View {
    let kind: MaterialMapKind
    let image: CGImage?
    let shortcut: String?
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.medium)
                            .aspectRatio(1, contentMode: .fill)
                    } else {
                        Rectangle().fill(.quaternary.opacity(0.6))
                            .overlay {
                                Image(systemName: kind.symbol)
                                    .font(.title3)
                                    .foregroundStyle(.tertiary)
                            }
                    }
                }
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.separator.opacity(0.7), lineWidth: 0.5)
                }
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2.5)
                            .padding(-4)
                            .matchedGeometryEffect(id: "selection", in: namespace)
                    }
                }
                .scaleEffect(hovering && !isSelected ? 1.04 : 1)
                .shadow(color: .black.opacity(hovering ? 0.18 : 0), radius: 6, y: 3)
                VStack(spacing: 0) {
                    Text(kind.shortTitle)
                        .font(.caption.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .lineLimit(1)
                    Text(shortcut ?? " ")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 84)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
        }
        .help(kind.explanation)
        .accessibilityLabel(kind.title)
        .accessibilityHint(kind.explanation)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Diagnostics

private struct DiagnosticsCard: View {
    let material: DerivedMaterial
    let isCurrent: Bool
    @State private var showNotes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Tiling Quality", systemImage: "square.grid.3x3.topleft.filled")
                    .font(.subheadline.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                Spacer()
                Button {
                    showNotes.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .help("Provenance and review notes")
                .accessibilityLabel("Provenance and review notes")
                .popover(isPresented: $showNotes, arrowEdge: .top) {
                    NotesPopover(material: material)
                }
            }
            SeamRow(label: "Color across edges", value: material.seams.albedoValue, threshold: 0.03)
            SeamRow(label: "Height across edges", value: material.seams.heightValue, threshold: 0.02)
            SeamRow(label: "Slope across edges", value: material.seams.heightGradient, threshold: 0.02)
        }
        .padding(12)
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        }
        .opacity(isCurrent ? 1 : 0.55)
        .accessibilityElement(children: .contain)
    }
}

private struct SeamRow: View {
    let label: String
    let value: Float
    let threshold: Float

    private var ratio: Float { value / threshold }

    private var rating: (String, Color) {
        switch ratio {
        case ..<0.5: ("Seamless", .green)
        case ..<1: ("Minor", .yellow)
        default: ("Visible", .orange)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 118, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(rating.1.gradient)
                        .frame(width: max(4, geometry.size.width * CGFloat(min(1, ratio / 2))))
                }
            }
            .frame(height: 5)
            Text(rating.0)
                .font(.caption.weight(.medium))
                .foregroundStyle(rating.1)
                .frame(width: 58, alignment: .trailing)
        }
        .help("Mean opposite-edge difference: \(value.formatted(.number.precision(.fractionLength(4))))")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(rating.0)")
        .accessibilityValue(value.formatted(.number.precision(.fractionLength(4))))
    }
}

private struct NotesPopover: View {
    let material: DerivedMaterial

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review Notes").font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(material.warnings, id: \.self) { message in
                    Label(message, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                row("Algorithm", material.algorithmVersion)
                row("Source", "\(material.working.sourceWidth) × \(material.working.sourceHeight) px")
                row("Working image", "\(material.working.size) px\(material.working.wasCropped ? ", center crop" : "")")
                row("Normals", material.recipe.normalYDown ? "DirectX (−Y)" : "OpenGL (+Y)")
                if let guide = material.guide {
                    row("Learned geometry", "\(Int((material.recipe.guideNormalWeight * 100).rounded())) % · \(guide.model.modelFile)")
                    row("Learned run", "\(guide.tiles) tiles at \(guide.workResolution) px · \(guide.computeUnits == .all ? "Neural Engine" : "CPU only")")
                    row("Guide SHA-256", String(guide.sha256.prefix(16)) + "…")
                }
                row("Derived in", "\(Int((material.duration * 1000).rounded())) ms")
                row("Source SHA-256", String(material.sourceSHA256.prefix(16)) + "…")
            }
            .font(.caption)
        }
        .padding(18)
        .frame(width: 360)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit().textSelection(.enabled)
        }
    }
}
