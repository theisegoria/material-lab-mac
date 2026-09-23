import SwiftUI
import UniformTypeIdentifiers

struct PNGDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.png] }
    static var writableContentTypes: [UTType] { [.png] }
    var bytes: Data
    init(bytes: Data) { self.bytes = bytes }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw CaptureError.invalidImage }
        self.bytes = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: bytes)
    }
}

enum PreviewMode: String, CaseIterable, Identifiable {
    case map, tiled, lit, compare
    var id: String { rawValue }
    var title: String {
        switch self {
        case .map: "Map"
        case .tiled: "Tiled"
        case .lit: "Lit"
        case .compare: "Compare"
        }
    }
    var symbol: String {
        switch self {
        case .map: "square"
        case .tiled: "square.grid.3x3"
        case .lit: "circle.lefthalf.filled"
        case .compare: "square.split.2x1"
        }
    }
}

struct MaterialReviewView: View {
    @Bindable var store: CaptureStore
    let link: MacLinkStore
    let selectTab: (AppTab) -> Void
    @State private var selectedMap: MaterialMapKind = .albedo
    @State private var previewMode: PreviewMode = .map
    @State private var showRecipe = false
    @State private var showCrop = false
    @State private var bundleDocument: MaterialBundleDocument?
    @State private var mapDocument: PNGDocument?
    @State private var exportBundle = false
    @State private var exportMap = false
    @State private var isPackaging = false
    @FocusState private var focusedField: Field?

    private enum Field { case label, category }

    var body: some View {
        Group {
            if let source = store.source {
                content(source)
            } else if store.isImporting {
                ProgressView("Preparing photo…")
            } else {
                ContentUnavailableView {
                    Label("No Material Yet", systemImage: "camera.macro")
                } description: {
                    Text("Capture a flat, evenly lit surface or import a photo to derive PBR maps on this iPhone.")
                } actions: {
                    Button("Open Camera", systemImage: "camera") { selectTab(.capture) }
                        .buttonStyle(.glassProminent)
                }
            }
        }
        .navigationTitle(store.trimmedLabel.isEmpty ? "Material" : store.trimmedLabel)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.source != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Recipe", systemImage: "slider.horizontal.3") { showRecipe = true }
                        .accessibilityIdentifier("open-recipe")
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
        .sheet(isPresented: $showRecipe) {
            RecipeEditorView(store: store)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationContentInteraction(.scrolls)
        }
        // Tiling edits are judged on repeats, so show the Tiled preview while they change.
        .onChange(of: store.recipe.seamlessBlend) { showTiledPreview() }
        .onChange(of: store.recipe.seamlessMode) { showTiledPreview() }
        .fullScreenCover(isPresented: $showCrop) {
            if let source = store.source {
                CropEditorView(store: store, image: source.displayImage)
            }
        }
        .fileExporter(isPresented: $exportBundle, document: bundleDocument,
                      contentType: .pbrCapture,
                      defaultFilename: safeFilename(store.semanticLabel) + ".pbrcapture") { result in
            if case .failure(let error) = result { store.errorMessage = error.localizedDescription }
        }
        .fileExporter(isPresented: $exportMap, document: mapDocument,
                      contentType: .png,
                      defaultFilename: safeFilename(store.semanticLabel) + "_" + selectedMap.exportedName + ".png") { result in
            if case .failure(let error) = result { store.errorMessage = error.localizedDescription }
        }
    }

    private func showTiledPreview() {
        guard previewMode != .tiled else { return }
        withAnimation(.snappy) { previewMode = .tiled }
    }

    // MARK: Layout

    private func content(_ source: SourceImage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                MaterialPreviewPane(store: store, selectedMap: selectedMap, mode: $previewMode)
                if let material = store.displayed {
                    MapChips(material: material, selection: $selectedMap)
                        .padding(.horizontal, -16)
                }
                identityCard
                cropCard(source)
                recipeCard
                deriveCard
                if store.hasExportableMaps, let material = store.derived {
                    checksCard(material)
                    exportCard(material)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemGroupedBackground))
        .animation(.snappy, value: store.hasExportableMaps)
    }

    private var identityCard: some View {
        Card(title: "Identity", symbol: "tag") {
            VStack(spacing: 0) {
                TextField("Material name, e.g. weathered basalt", text: $store.semanticLabel)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.next)
                    .focused($focusedField, equals: .label)
                    .onSubmit { focusedField = .category }
                    .padding(.vertical, 10)
                    .accessibilityIdentifier("semantic-label")
                Divider()
                TextField("Category, e.g. stone", text: $store.category)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($focusedField, equals: .category)
                    .padding(.vertical, 10)
                    .accessibilityIdentifier("material-category")
            }
        }
    }

    private func cropCard(_ source: SourceImage) -> some View {
        Card(title: "Perspective Crop", symbol: "perspective") {
            HStack(alignment: .top, spacing: 14) {
                PerspectiveCropView(image: source.displayImage, quad: .constant(store.crop),
                                    showsGrid: false, interactive: false)
                    .frame(width: 104, height: 104)
                    .background(Color.black, in: .rect(cornerRadius: 14))
                    .clipShape(.rect(cornerRadius: 14))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Label(store.cropWasAutoDetected ? "Surface auto-detected" : "Centered square",
                          systemImage: store.cropWasAutoDetected ? "viewfinder" : "square.dashed")
                        .font(.subheadline.weight(.semibold))
                    Text(captureModeText(source))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let summary = source.confidence?.score(in: store.crop), summary.sampleCount > 0 {
                        Text(String(format: "Constant Color confidence %.0f%% · low %.0f%%",
                                    summary.mean * 100, summary.lowFraction * 100))
                            .font(.caption)
                            .foregroundStyle(summary.adequate ? .green : .orange)
                    }
                    if source.shouldUseFallback(for: store.crop) {
                        Label("Using the retained fallback photo", systemImage: "arrow.uturn.backward")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if !store.crop.isValid {
                        Label("Corner order or crop area is invalid", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Button("Adjust Corners", systemImage: "crop") { showCrop = true }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .padding(.top, 2)
                        .accessibilityIdentifier("adjust-crop")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var recipeCard: some View {
        Card(title: "Recipe", symbol: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Material prior", selection: Binding(get: { store.recipe.preset },
                                                            set: { store.setPreset($0) })) {
                    ForEach(MaterialPreset.allCases) { preset in
                        Label(preset.title, systemImage: preset.symbol).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("material-prior")
                RecipeSummary(recipe: store.recipe)
                Button {
                    showRecipe = true
                } label: {
                    Label("Edit Relief, Surface & Tiling", systemImage: "slider.horizontal.below.square.and.square.filled")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
        }
    }

    private var deriveCard: some View {
        Card(title: "Derive", symbol: "cpu") {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Output resolution", selection: $store.resolution) {
                    ForEach(CaptureStore.resolutions, id: \.self) { size in
                        Text(size >= 1024 ? "\(size / 1024)K" : "\(size)").tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Output resolution")
                if store.resolution == 4096 && !Self.supports4K {
                    Label("4K needs more memory than this device has; use 2K.", systemImage: "memorychip")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if store.isDeriving {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Deriving \(String(store.resolution))² on iPhone…")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text(store.deriveProgress, format: .percent.precision(.fractionLength(0)))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: store.deriveProgress)
                            .accessibilityLabel("Derivation progress")
                        Button("Cancel", systemImage: "xmark", role: .cancel) { store.cancelDerivation() }
                            .buttonStyle(.glass)
                            .accessibilityIdentifier("cancel-derivation")
                    }
                } else if store.hasExportableMaps {
                    Label("Maps derived at \(String(store.resolution))² and ready to export", systemImage: "checkmark.seal.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.green)
                } else {
                    Button {
                        focusedField = nil
                        Task { await store.derive() }
                    } label: {
                        Label("Derive \(String(store.resolution))² Maps", systemImage: "wand.and.sparkles")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!store.crop.isValid || (store.resolution == 4096 && !Self.supports4K))
                    .accessibilityIdentifier("derive-material")
                    Text("The preview above updates live at 512². Deriving at full resolution enables export.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func checksCard(_ material: DerivedMaterial) -> some View {
        Card(title: "Checks", symbol: "checkmark.seal") {
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Albedo seam").foregroundStyle(.secondary)
                        Text(material.seam.albedoValueDelta, format: .number.precision(.fractionLength(4)))
                    }
                    GridRow {
                        Text("Height seam").foregroundStyle(.secondary)
                        Text(material.seam.heightValueDelta, format: .number.precision(.fractionLength(4)))
                    }
                    GridRow {
                        Text("Gradient seam").foregroundStyle(.secondary)
                        Text(material.seam.heightGradientDelta, format: .number.precision(.fractionLength(4)))
                    }
                }
                .font(.footnote.monospacedDigit())
                ForEach(material.quality.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("Seam checks are diagnostics, not automatic tileability approval.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func exportCard(_ material: DerivedMaterial) -> some View {
        Card(title: "Export", symbol: "square.and.arrow.up") {
            VStack(spacing: 10) {
                Button {
                    Task { await exportCapture() }
                } label: {
                    Label(isPackaging ? "Packaging…" : "Save .pbrcapture to Files", systemImage: "doc.badge.arrow.up")
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.glassProminent)
                .disabled(isPackaging)
                .accessibilityIdentifier("export-material-bundle")

                HStack(spacing: 10) {
                    Button {
                        guard let map = material.maps[selectedMap] else { return }
                        mapDocument = PNGDocument(bytes: map.png)
                        exportMap = true
                    } label: {
                        Label("\(selectedMap.shortTitle) PNG", systemImage: "photo")
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("export-map-png")

                    Button {
                        if link.pairing == nil { selectTab(.mac) } else { link.send(from: store) }
                    } label: {
                        Label(link.isSending ? link.phase.title : "Send to Mac", systemImage: "laptopcomputer.and.arrow.down")
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.glass)
                    .disabled(link.isSending)
                    .accessibilityIdentifier("send-to-mac")
                }
                Text(link.pairing == nil
                     ? "Send to Mac needs a pairing QR from Material Lab. Files and AirDrop work too."
                     : "Paired and ready. The Mac asks for approval before importing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Actions

    private func exportCapture() async {
        focusedField = nil
        isPackaging = true
        defer { isPackaging = false }
        do {
            bundleDocument = MaterialBundleDocument(bytes: try await store.makeBundle())
            exportBundle = true
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private func captureModeText(_ source: SourceImage) -> String {
        switch source.captureMode(for: store.crop) {
        case "constant-color-high-confidence": "Constant Color albedo, high confidence"
        case "estimated-albedo-constant-color-fallback": "Estimated albedo from fallback photo"
        case "estimated-albedo-ordinary-photo": "Estimated albedo from an ordinary photo"
        case "estimated-albedo-photos": "Estimated albedo, imported from Photos"
        case "estimated-albedo-files": "Estimated albedo, imported from Files"
        case let other: other
        }
    }

    private func safeFilename(_ label: String) -> String {
        let cleaned = label.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? "material" : String(cleaned.prefix(64))
    }

    /// 4096² derivation holds several full-size float planes; require a 6 GB+ device.
    static let supports4K = ProcessInfo.processInfo.physicalMemory >= 6 * 1024 * 1024 * 1024
}

// MARK: - Components

struct Card<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
    }
}

private struct RecipeSummary: View {
    let recipe: MaterialRecipe

    var body: some View {
        HStack(spacing: 8) {
            pill("Relief", String(format: "%.2f", recipe.heightStrength))
            pill("Rough", String(format: "%.2f", recipe.roughnessBase))
            if recipe.guideNormalWeight > 0 { pill("Learned", String(format: "%.0f%%", recipe.guideNormalWeight * 100)) }
            pill("Normal", recipe.normalYDown ? "DirectX" : "OpenGL")
            if recipe.seamlessBlend > 0 {
                pill(recipe.seamlessMode == .cut ? "Tile · cut" : "Tile · blend",
                     String(format: "%.0f%%", recipe.seamlessBlend * 100))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func pill(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 12))
    }
}

struct MapChips: View {
    let material: DerivedMaterial
    @Binding var selection: MaterialMapKind
    @Namespace private var namespace

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(MaterialMapKind.allCases.filter { material.maps[$0] != nil }) { kind in
                        let selected = kind == selection
                        Button {
                            withAnimation(.snappy(duration: 0.3)) { selection = kind }
                        } label: {
                            HStack(spacing: 6) {
                                if let map = material.maps[kind] {
                                    Image(decorative: map.previewImage, scale: 1)
                                        .resizable()
                                        .interpolation(.medium)
                                        .frame(width: 22, height: 22)
                                        .clipShape(.rect(cornerRadius: 6))
                                }
                                Text(kind.shortTitle)
                                    .font(.subheadline.weight(selected ? .semibold : .regular))
                            }
                            .padding(.leading, 6)
                            .padding(.trailing, 12)
                            .padding(.vertical, 6)
                            .foregroundStyle(selected ? Color.white : Color.primary)
                            .background {
                                if selected {
                                    Capsule().fill(Color.accentColor)
                                        .matchedGeometryEffect(id: "chip", in: namespace)
                                } else {
                                    Capsule().fill(Color(.tertiarySystemFill))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .id(kind)
                        .accessibilityLabel(kind.title)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            // Chips scroll under the screen edges; fade them out there so a clipped glyph never shows
            // beside a floating sheet.
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(stops: [.init(color: .clear, location: 0.4), .init(color: .black, location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: 16)
                    Color.black
                    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .clear, location: 0.6)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: 28)
                }
            }
            .onChange(of: selection) { _, kind in
                withAnimation { proxy.scrollTo(kind, anchor: .center) }
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// The hero preview: selected map, 3×3 tiling, a lit sphere, or before/after compare.
struct MaterialPreviewPane: View {
    let store: CaptureStore
    let selectedMap: MaterialMapKind
    @Binding var mode: PreviewMode

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 28)
                    .fill(Color(.secondarySystemGroupedBackground))
                if let material = store.displayed, let map = material.maps[selectedMap] ?? material.maps[.albedo] {
                    preview(material: material, map: map)
                        .clipShape(.rect(cornerRadius: 28))
                        .transition(.opacity)
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Preparing live preview…").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .topLeading) { statusBadge.padding(12) }
            .shadow(color: .black.opacity(0.12), radius: 16, y: 8)

            Picker("Preview", selection: $mode.animation(.snappy)) {
                ForEach(PreviewMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("preview-mode")
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func preview(material: DerivedMaterial, map: DerivedMap) -> some View {
        switch mode {
        case .map:
            Image(decorative: map.previewImage, scale: 1)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(1, contentMode: .fit)
                .accessibilityLabel("\(map.kind.title) map preview")
        case .tiled:
            GeometryReader { geometry in
                let tile = geometry.size.width / 3
                Image(decorative: map.previewImage, scale: CGFloat(map.width) / max(1, tile))
                    .resizable(resizingMode: .tile)
                    .accessibilityLabel("\(map.kind.title) tiled three by three")
            }
        case .lit:
            MaterialSphereView(material: material)
                .accessibilityLabel("Lit sphere preview. Drag to orbit.")
        case .compare:
            CompareView(before: material.correctedSource, after: map.previewImage, afterTitle: map.kind.shortTitle)
        }
    }

    private var statusBadge: some View {
        let text: String
        let symbol: String
        if store.isDeriving {
            text = "Deriving \(String(store.resolution))²"
            symbol = "hourglass"
        } else if store.isUpdatingPreview {
            text = "Updating"
            symbol = "arrow.triangle.2.circlepath"
        } else if store.hasExportableMaps {
            text = "\(String(store.resolution))² · Final"
            symbol = "checkmark.seal.fill"
        } else {
            text = "Live · \(MaterialProcessor.previewResolution)²"
            symbol = "bolt.fill"
        }
        return Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
            .symbolEffect(.rotate, isActive: store.isUpdatingPreview)
            .contentTransition(.opacity)
            .animation(.snappy, value: text)
    }
}

/// Draggable before/after divider between the corrected photo and a derived map.
struct CompareView: View {
    let before: CGImage
    let after: CGImage
    let afterTitle: String
    @State private var split: CGFloat = 0.5

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Image(decorative: after, scale: 1).resizable().interpolation(.medium)
                Image(decorative: before, scale: 1).resizable().interpolation(.medium)
                    .mask(alignment: .leading) { Rectangle().frame(width: width * split) }
                Rectangle()
                    .fill(.white)
                    .frame(width: 2)
                    .shadow(radius: 2)
                    .offset(x: width * split - 1)
                Image(systemName: "arrow.left.and.right")
                    .font(.footnote.weight(.bold))
                    .frame(width: 36, height: 36)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .offset(x: width * split - 18)
            }
            .overlay(alignment: .bottom) {
                HStack {
                    Text("Photo").badgeStyle()
                    Spacer()
                    Text(afterTitle).badgeStyle()
                }
                .padding(12)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                split = min(1, max(0, value.location.x / width))
            })
            .accessibilityElement()
            .accessibilityLabel("Before and after comparison")
            .accessibilityValue(String(format: "%.0f%% photo", split * 100))
            .accessibilityAdjustableAction { direction in
                split = min(1, max(0, split + (direction == .increment ? 0.1 : -0.1)))
            }
        }
    }
}

private extension Text {
    func badgeStyle() -> some View {
        self.font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
    }
}
