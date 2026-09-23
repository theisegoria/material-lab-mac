import SwiftUI
import UniformTypeIdentifiers

private struct PNGDocument: FileDocument {
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

struct MaterialReviewView: View {
    @Bindable var store: CaptureStore
    @State private var selectedMap: MaterialMapKind = .albedo
    @State private var tiledPreview = false
    @State private var bundleDocument: MaterialBundleDocument?
    @State private var mapDocument: PNGDocument?
    @State private var exportBundle = false
    @State private var exportMap = false

    var body: some View {
        ScrollView {
            if let source = store.source {
                VStack(alignment: .leading, spacing: 20) {
                    cropSection(source)
                    metadataSection(source)
                    recipeSection
                    deriveSection
                    if let material = store.derived {
                        previewSection(material)
                        diagnosticsSection(material, source: source)
                        exportSection(material)
                        MacLinkSection(store: store)
                    }
                }
                .padding()
            } else {
                ContentUnavailableView("No material yet", systemImage: "camera.macro",
                                       description: Text("Capture a surface or import a photo to begin."))
            }
        }
        .navigationTitle("Material")
        .fileExporter(isPresented: $exportBundle, document: bundleDocument,
                      contentType: .pbrCapture,
                      defaultFilename: safeFilename(store.semanticLabel) + ".pbrcapture") { result in
            if case .failure(let error) = result { store.errorMessage = error.localizedDescription }
        }
        .fileExporter(isPresented: $exportMap, document: mapDocument,
                      contentType: .png,
                      defaultFilename: safeFilename(store.semanticLabel) + "_" + selectedMap.rawValue + ".png") { result in
            if case .failure(let error) = result { store.errorMessage = error.localizedDescription }
        }
        .alert("Material Capture", isPresented: Binding(get: { store.errorMessage != nil },
                                                       set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private func cropSection(_ source: SourceImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Square material crop", icon: "crop.rotate")
            PerspectiveCropView(image: source.image, quad: $store.crop)
                .frame(height: 320)
                .background(.black, in: RoundedRectangle(cornerRadius: 14))
            Text("Drag the four yellow corners to remove perspective before deriving.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !store.crop.isValid {
                Label("Corner order or crop area is invalid", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func metadataSection(_ source: SourceImage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Semantic identity", icon: "tag")
            TextField("Material label, e.g. weathered basalt", text: $store.semanticLabel)
                .textInputAutocapitalization(.sentences)
                .accessibilityIdentifier("semantic-label")
            TextField("Category, e.g. stone", text: $store.category)
                .textInputAutocapitalization(.never)
            let summary = source.confidence?.score(in: store.crop)
            Text(source.captureMode(for: store.crop).replacingOccurrences(of: "-", with: " ").capitalized)
                .font(.caption)
                .foregroundStyle(summary?.adequate == true ? .green : .secondary)
            if let summary, summary.sampleCount > 0 {
                Text(String(format: "Constant Color crop confidence %.0f%%; low-confidence area %.0f%%",
                            summary.mean * 100, summary.lowFraction * 100))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if source.shouldUseFallback(for: store.crop) {
                Label("Low-confidence crop: derivation will use the retained fallback photo.",
                      systemImage: "arrow.uturn.backward")
                    .font(.caption)
            }
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }

    private var recipeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Derivation recipe", icon: "slider.horizontal.3")
            Picker("Material prior", selection: Binding(get: { store.recipe.preset },
                                                       set: { store.setPreset($0) })) {
                ForEach(MaterialPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            Picker("Output resolution", selection: $store.resolution) {
                Text("512²").tag(512)
                Text("1024²").tag(1024)
                Text("2048²").tag(2048)
            }
            slider("Relief strength", value: $store.recipe.heightStrength, range: 0...0.5)
            Picker("Bright features", selection: $store.recipe.heightPolarity) {
                Text("Raised").tag(Int32(1))
                Text("Inset").tag(Int32(-1))
            }
            slider("Roughness prior", value: $store.recipe.roughnessBase, range: 0...1)
            slider("Roughness variation", value: $store.recipe.roughnessVariation, range: 0...0.4)
            slider("AO radius (pixels)", value: $store.recipe.aoRadiusPixels, range: 1...32)
            Toggle("Wrap filters for tiled materials", isOn: $store.recipe.tileWrap)
            Toggle("Include bent normal", isOn: $store.recipe.bentNormal)
            Toggle("Assign metalness for ORM", isOn: Binding(
                get: { store.recipe.assignedMetalness != nil },
                set: { store.recipe.assignedMetalness = $0 ? 1 : nil }))
            if store.recipe.assignedMetalness != nil {
                slider("Assigned metalness", value: Binding(
                    get: { store.recipe.assignedMetalness ?? 0 },
                    set: { store.recipe.assignedMetalness = $0 }), range: 0...1)
            }
            Text("Height, normals, and AO are estimates from color. Roughness is an editable material prior; metalness is assigned explicitly.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }

    private var deriveSection: some View {
        Button {
            Task { await store.derive() }
        } label: {
            if store.isDeriving {
                HStack { ProgressView(); Text("Deriving on iPhone…") }
                    .frame(maxWidth: .infinity)
            } else {
                Label("Derive PBR Maps", systemImage: "square.stack.3d.up.fill")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(store.isDeriving || !store.crop.isValid)
        .accessibilityIdentifier("derive-material")
    }

    private func previewSection(_ material: DerivedMaterial) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Map preview", icon: "square.on.square")
            Picker("Map", selection: $selectedMap) {
                ForEach(MaterialMapKind.allCases.filter { material.maps[$0] != nil }) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.menu)
            Toggle("3 × 3 tile preview", isOn: $tiledPreview)
            if let image = material.maps[selectedMap]?.preview {
                if tiledPreview {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 3), spacing: 0) {
                        ForEach(0..<9, id: \.self) { _ in
                            Image(uiImage: image).resizable().aspectRatio(1, contentMode: .fit)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Text(selectedMap.provenance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func diagnosticsSection(_ material: DerivedMaterial, source: SourceImage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Checks", icon: "checkmark.seal")
            Text(String(format: "Albedo seam %.4f · height value %.4f · height gradient %.4f",
                        material.seam.albedoValueDelta, material.seam.heightValueDelta,
                        material.seam.heightGradientDelta))
                .font(.footnote.monospacedDigit())
            ForEach(material.quality.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("Seam checks are diagnostics, not automatic tileability approval.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func exportSection(_ material: DerivedMaterial) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Export", icon: "square.and.arrow.up")
            Button("Export .pbrcapture bundle to Files") {
                do {
                    bundleDocument = MaterialBundleDocument(bytes: try store.bundle())
                    exportBundle = true
                } catch { store.errorMessage = error.localizedDescription }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("export-material-bundle")
            Button("Export selected PNG map") {
                guard let map = material.maps[selectedMap] else { return }
                mapDocument = PNGDocument(bytes: map.png)
                exportMap = true
            }
            .buttonStyle(.bordered)
            Text("Files and AirDrop can move this capture to Material Lab on Mac when direct pairing is unavailable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func sectionTitle(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).font(.headline)
    }

    private func slider(_ title: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue)).monospacedDigit()
            }
            .font(.subheadline)
            Slider(value: value, in: range)
        }
    }

    private func safeFilename(_ label: String) -> String {
        let cleaned = label.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? "material" : String(cleaned.prefix(64))
    }
}
