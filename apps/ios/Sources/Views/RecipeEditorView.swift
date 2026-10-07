import SwiftUI
import UniformTypeIdentifiers

/// Recipe controls grouped by intent. Every edit re-derives the live preview after a short debounce.
struct RecipeEditorView: View {
    @Bindable var store: CaptureStore
    @Environment(\.dismiss) private var dismiss
    @State private var showModelImporter = false
    @State private var namingRecipe = false
    @State private var recipeName = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        MaterialPresetPicker(store: store)
                    } label: {
                        LabeledContent {
                            Text(LibraryPreset.named(store.recipe.materialPreset)?.title ?? "Choose")
                        } label: {
                            Label("Material", systemImage: LibraryPreset.named(store.recipe.materialPreset)?.symbol
                                  ?? "square.stack.3d.up")
                        }
                    }
                    .accessibilityIdentifier("material-preset")
                    Picker("Relief prior", selection: Binding(get: { store.recipe.preset },
                                                                set: { store.setPreset($0) })) {
                        ForEach(MaterialPreset.allCases) { preset in
                            Label(preset.title, systemImage: preset.symbol).tag(preset)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    Menu {
                        if !store.savedRecipes.isEmpty {
                            Section("Apply") {
                                ForEach(store.savedRecipes) { saved in
                                    Button(saved.name, systemImage: saved.recipe.preset.symbol) {
                                        store.applySavedRecipe(saved)
                                    }
                                }
                            }
                            Menu("Delete", systemImage: "trash") {
                                ForEach(store.savedRecipes) { saved in
                                    Button(saved.name, role: .destructive) { store.deleteSavedRecipe(saved) }
                                }
                            }
                        }
                        Button("Save Current Recipe…", systemImage: "square.and.arrow.down") {
                            recipeName = ""
                            namingRecipe = true
                        }
                    } label: {
                        LabeledContent {
                            Text(store.savedRecipes.isEmpty ? "None" : "\(store.savedRecipes.count)")
                        } label: {
                            Label("Saved recipes", systemImage: "bookmark")
                        }
                    }
                    .accessibilityIdentifier("saved-recipes")
                } footer: {
                    Text("Switching the prior resets relief and surface values to that material's defaults. Save a recipe to reuse it on other captures.")
                }

                AuthoredMapsSection(store: store)

                Section {
                    RecipeSlider(title: String(localized: "Height"), symbol: "mountain.2", value: $store.recipe.heightStrength,
                                 range: MaterialRecipe.heightStrengthRange, step: 0.01, baseline: store.baselineRecipe.heightStrength)
                    Picker(selection: $store.recipe.heightPolarity) {
                        Text("Raised").tag(Int32(1))
                        Text("Inset").tag(Int32(-1))
                    } label: {
                        Label("Bright features", systemImage: "circle.lefthalf.filled.inverse")
                    }
                    RecipeSlider(title: String(localized: "Normal strength"), symbol: "cube.transparent",
                                 value: $store.recipe.normalStrength,
                                 range: MaterialRecipe.normalStrengthRange, step: 0.1, format: "%.1f×", baseline: store.baselineRecipe.normalStrength)
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
                    RecipeSlider(title: String(localized: "Roughness"), symbol: "circle.dotted", value: $store.recipe.roughnessBase,
                                 range: 0...1, step: 0.01, baseline: store.baselineRecipe.roughnessBase)
                    RecipeSlider(title: String(localized: "Roughness variation"), symbol: "waveform.path",
                                 value: $store.recipe.roughnessVariation,
                                 range: MaterialRecipe.roughnessVariationRange, step: 0.01, baseline: store.baselineRecipe.roughnessVariation)
                    Toggle(isOn: Binding(get: { store.recipe.assignedMetalness != nil },
                                         set: { store.recipe.assignedMetalness = $0 ? 1 : nil })) {
                        Label("Assign metalness (ORM)", systemImage: "square.stack.3d.up")
                    }
                    if store.recipe.assignedMetalness != nil {
                        RecipeSlider(title: String(localized: "Metalness"), symbol: "gearshape",
                                     value: Binding(get: { store.recipe.assignedMetalness ?? 0 },
                                                    set: { store.recipe.assignedMetalness = $0 }),
                                     range: 0...1, step: 0.01)
                    }
                }

                Section {
                    RecipeSlider(title: String(localized: "Remove lighting"), symbol: "sun.max.trianglebadge.exclamationmark",
                                 value: $store.recipe.albedoEqualize,
                                 range: MaterialRecipe.albedoEqualizeRange, step: 0.01, format: "%.0f%%", percent: true, baseline: store.baselineRecipe.albedoEqualize)
                    RecipeSlider(title: String(localized: "AO strength"), symbol: "circle.lefthalf.filled",
                                 value: $store.recipe.aoStrength,
                                 range: MaterialRecipe.aoStrengthRange, step: 0.05, format: "%.2f×", baseline: store.baselineRecipe.aoStrength)
                    RecipeSlider(title: String(localized: "AO radius"), symbol: "circle.dashed",
                                 value: $store.recipe.aoRadiusPixels,
                                 range: MaterialRecipe.aoRadiusRange, step: 1, format: "%.0f px", baseline: store.baselineRecipe.aoRadiusPixels)
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
                                     range: MaterialRecipe.seamlessBlendRange, step: 0.01, format: "%.0f%%", percent: true, baseline: store.baselineRecipe.seamlessBlend)
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
            .alert("Save Recipe", isPresented: $namingRecipe) {
                TextField("Name, e.g. Wet slate", text: $recipeName)
                Button("Save") { store.saveCurrentRecipe(named: recipeName) }
                    .disabled(recipeName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("A recipe with the same name is replaced.")
            }
            .navigationTitle("Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button("Undo", systemImage: "arrow.uturn.backward") { store.undo() }
                        .disabled(!store.canUndo)
                        .accessibilityIdentifier("recipe-undo")
                    Button("Redo", systemImage: "arrow.uturn.forward") { store.redo() }
                        .disabled(!store.canRedo)
                        .accessibilityIdentifier("recipe-redo")
                }
                ToolbarItem(placement: .principal) {
                    if store.isUpdatingPreview {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Updating preview")
                    } else {
                        Text("Recipe").font(.headline)
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
    /// The material's default: a dot marks a changed value and the context menu resets it.
    var baseline: Float? = nil

    private var isModified: Bool { baseline.map { abs($0 - value) > 1e-4 } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: symbol)
                if isModified {
                    Circle().fill(.tint).frame(width: 6, height: 6).accessibilityHidden(true)
                }
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
        .contextMenu {
            if let baseline, isModified {
                Button("Reset to Default", systemImage: "arrow.counterclockwise") { value = baseline }
            }
        }
        .accessibilityAction(named: "Reset to default") { if let baseline { value = baseline } }
    }

    private var display: String { String(format: format, percent ? value * 100 : value) }
}

/// "Learned geometry" slider, inference progress and model management inside the Relief section.
struct LearnedGeometryRows: View {
    @Bindable var store: CaptureStore
    let importModel: () -> Void

    private var available: Bool { store.learnedModel != nil }

    /// "Quick estimate", then "Refining · pass 18 of 50 · ~6 s" once a pass time is known.
    private func progressText(_ progress: LearnedProgress) -> String {
        guard progress.passes > 0 else { return "Loading model" }
        if progress.coarse { return "Quick estimate" }
        var text = store.showsQuickLearnedEstimate ? "Refining" : "Estimating"
        text += " · pass \(progress.pass) of \(progress.passes)"
        if let remaining = progress.remaining, progress.pass >= 2, remaining >= 0.5 {
            text += " · ~\(Int(remaining.rounded())) s"
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RecipeSlider(title: String(localized: "Learned geometry"), symbol: "sparkles",
                         value: $store.recipe.guideNormalWeight, range: 0...1, step: 0.05,
                         format: "%.0f%%", percent: true, baseline: store.baselineRecipe.guideNormalWeight)
                .disabled(!available)
                .accessibilityIdentifier("learned-geometry")
            if let progress = store.learnedProgress, store.recipe.guideNormalWeight > 0 {
                HStack(spacing: 10) {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                    Text(progressText(progress))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .fixedSize()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(progress.coarse ? "Making a quick learned estimate" : "Estimating learned geometry")
                .accessibilityValue(String(format: "%.0f percent", progress.fraction * 100))
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
