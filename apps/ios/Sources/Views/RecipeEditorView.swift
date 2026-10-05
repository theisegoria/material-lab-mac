import SwiftUI
import UniformTypeIdentifiers

/// Recipe controls grouped by intent. Every edit re-derives the live preview after a short debounce.
struct RecipeEditorView: View {
    @Bindable var store: CaptureStore
    @Environment(\.dismiss) private var dismiss
    @State private var showModelImporter = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Material prior", selection: Binding(get: { store.recipe.preset },
                                                                set: { store.setPreset($0) })) {
                        ForEach(MaterialPreset.allCases) { preset in
                            Label(preset.title, systemImage: preset.symbol).tag(preset)
                        }
                    }
                    .pickerStyle(.navigationLink)
                } footer: {
                    Text("Switching the prior resets relief and surface values to that material's defaults.")
                }

                Section {
                    RecipeSlider(title: "Height", symbol: "mountain.2", value: $store.recipe.heightStrength,
                                 range: MaterialRecipe.heightStrengthRange, step: 0.01)
                    Picker(selection: $store.recipe.heightPolarity) {
                        Text("Raised").tag(Int32(1))
                        Text("Inset").tag(Int32(-1))
                    } label: {
                        Label("Bright features", systemImage: "circle.lefthalf.filled.inverse")
                    }
                    RecipeSlider(title: "Normal strength", symbol: "cube.transparent",
                                 value: $store.recipe.normalStrength,
                                 range: MaterialRecipe.normalStrengthRange, step: 0.1, format: "%.1f×")
                    Toggle(isOn: $store.recipe.bentNormal) {
                        Label("Bent normal map", systemImage: "arrow.turn.up.right")
                    }
                    LearnedGeometryRows(store: store, importModel: { showModelImporter = true })
                } header: {
                    Text("Relief")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Height, normals and AO are estimates inferred from color, not measured geometry. Learned geometry blends in surface normals predicted on this iPhone by a neural network, so recessed joints read as recessed even when they are paler than the surface.")
                        Text("MoGe-2 (Microsoft, MIT licence) with DINOv2 (Meta, Apache 2.0). Runs locally; nothing is uploaded.")
                            .font(.caption2)
                    }
                }

                Section("Surface") {
                    RecipeSlider(title: "Roughness", symbol: "circle.dotted", value: $store.recipe.roughnessBase,
                                 range: 0...1, step: 0.01)
                    RecipeSlider(title: "Roughness variation", symbol: "waveform.path",
                                 value: $store.recipe.roughnessVariation,
                                 range: MaterialRecipe.roughnessVariationRange, step: 0.01)
                    Toggle(isOn: Binding(get: { store.recipe.assignedMetalness != nil },
                                         set: { store.recipe.assignedMetalness = $0 ? 1 : nil })) {
                        Label("Assign metalness (ORM)", systemImage: "square.stack.3d.up")
                    }
                    if store.recipe.assignedMetalness != nil {
                        RecipeSlider(title: "Metalness", symbol: "gearshape",
                                     value: Binding(get: { store.recipe.assignedMetalness ?? 0 },
                                                    set: { store.recipe.assignedMetalness = $0 }),
                                     range: 0...1, step: 0.01)
                    }
                }

                Section {
                    RecipeSlider(title: "Remove lighting", symbol: "sun.max.trianglebadge.exclamationmark",
                                 value: $store.recipe.albedoEqualize,
                                 range: MaterialRecipe.albedoEqualizeRange, step: 0.01, format: "%.0f%%", percent: true)
                    RecipeSlider(title: "AO strength", symbol: "circle.lefthalf.filled",
                                 value: $store.recipe.aoStrength,
                                 range: MaterialRecipe.aoStrengthRange, step: 0.05, format: "%.2f×")
                    RecipeSlider(title: "AO radius", symbol: "circle.dashed",
                                 value: $store.recipe.aoRadiusPixels,
                                 range: MaterialRecipe.aoRadiusRange, step: 1, format: "%.0f px")
                    VStack(alignment: .leading, spacing: 6) {
                        Picker(selection: $store.recipe.albedoRepair) {
                            ForEach(AlbedoRepair.allCases) { Text($0.title).tag($0) }
                        } label: {
                            Label("Repair albedo", systemImage: "wand.and.rays")
                        }
                        .accessibilityIdentifier("albedo-repair")
                        .onChange(of: store.recipe.albedoRepair) { _, mode in
                            if mode != .off { store.recipe.tileWrap = true }
                        }
                        if store.recipe.albedoRepair != .off {
                            Text(store.recipe.albedoRepair.explanation)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        RecipeSlider(title: store.recipe.albedoRepair == .off ? "Make tileable" : "Repair band",
                                     symbol: "square.grid.3x3",
                                     value: $store.recipe.seamlessBlend,
                                     range: MaterialRecipe.seamlessBlendRange, step: 0.01, format: "%.0f%%", percent: true)
                            .accessibilityIdentifier("make-tileable")
                        Picker("Seam method", selection: $store.recipe.seamlessMode) {
                            ForEach(SeamlessMode.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .disabled(store.recipe.seamlessBlend <= 0 || store.recipe.albedoRepair != .off)
                        .accessibilityIdentifier("seamless-mode")
                        Text(store.recipe.seamlessMode == .cut
                             ? "Cuts along the least visible path. Best for brick, tiles, planks and most photos."
                             : "Cross-fades while keeping contrast. For fine noise, sand and grain.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .opacity(store.recipe.seamlessBlend > 0 ? 1 : 0.5)
                    }
                    Toggle(isOn: $store.recipe.tileWrap) {
                        Label("Wrap filters at edges", systemImage: "arrow.left.and.right.square")
                    }
                    .disabled(store.recipe.albedoRepair != .off)
                } header: {
                    Text("Lighting & Tiling")
                } footer: {
                    Text("Remove lighting evens out low-frequency shading in the photo. Repair albedo rebuilds the photo itself so it tiles on both axes; Make tileable only treats the edges. The preview switches to Tiled while you adjust either.")
                }

                Section {
                    Picker(selection: $store.recipe.normalYDown) {
                        Text("OpenGL  +Y").tag(false)
                        Text("DirectX  −Y").tag(true)
                    } label: {
                        Label("Normal map", systemImage: "arrow.up.and.down")
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("normal-convention")
                } header: {
                    Text("Export")
                } footer: {
                    Text(store.recipe.normalYDown
                         ? "Green-down normals for Unreal Engine and DirectX tools."
                         : "Green-up normals for glTF, Blender, Unity, Godot and RealityKit.")
                }
            }
            .fileImporter(isPresented: $showModelImporter, allowedContentTypes: UTType.coreMLModels) { result in
                switch result {
                case .success(let url): Task { await store.importLearnedModel(from: url) }
                case .failure(let error): store.errorMessage = error.localizedDescription
                }
            }
            .navigationTitle("Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if store.isUpdatingPreview {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Updating preview")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                        .accessibilityIdentifier("recipe-done")
                }
            }
        }
    }
}

struct RecipeSlider: View {
    let title: String
    let symbol: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var step: Float = 0.01
    var format = "%.2f"
    var percent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Text(display)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(display)
        }
    }

    private var display: String { String(format: format, percent ? value * 100 : value) }
}

/// "Learned geometry" slider, inference progress and model management inside the Relief section.
struct LearnedGeometryRows: View {
    @Bindable var store: CaptureStore
    let importModel: () -> Void

    private var available: Bool { store.learnedModel != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RecipeSlider(title: "Learned geometry", symbol: "sparkles",
                         value: $store.recipe.guideNormalWeight, range: 0...1, step: 0.05,
                         format: "%.0f%%", percent: true)
                .disabled(!available)
                .accessibilityIdentifier("learned-geometry")
            if let progress = store.learnedProgress, store.recipe.guideNormalWeight > 0 {
                HStack(spacing: 10) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                    Text(progress <= 0 ? "Loading model" : String(format: "Estimating %.0f%%", progress * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .fixedSize()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Estimating learned geometry")
                .accessibilityValue(String(format: "%.0f percent", progress * 100))
            } else if !available && store.learnedModelChecked {
                Text("Import the MoGe-2 normal model (.mlpackage) to enable learned geometry.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .animation(.snappy, value: store.learnedProgress == nil)
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Normal model")
                    Text(modelSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } icon: {
                Image(systemName: available ? "cpu" : "arrow.down.circle")
            }
            Spacer(minLength: 8)
            if store.isImportingModel {
                ProgressView().controlSize(.small)
            } else if available {
                Menu {
                    Button("Import Model…", systemImage: "square.and.arrow.down", action: importModel)
                    if store.learnedModel?.origin == .imported {
                        Button("Remove Imported Model", systemImage: "trash", role: .destructive) {
                            Task { await store.removeImportedLearnedModel() }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Model options")
            } else {
                Button("Import", systemImage: "square.and.arrow.down", action: importModel)
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .accessibilityIdentifier("import-learned-model")
            }
        }
    }

    private var modelSummary: String {
        guard let model = store.learnedModel else {
            return store.learnedModelChecked ? "Not installed" : "Checking…"
        }
        let origin = model.origin == .bundled ? "Built in" : "Imported"
        return "MoGe-2 ViT-S · \(origin) · on device"
    }
}
