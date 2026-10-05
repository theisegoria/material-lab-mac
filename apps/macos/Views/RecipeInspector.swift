import SwiftUI

struct RecipeInspector: View {
    @Bindable var store: MaterialLabStore
    let source: MaterialSource

    var body: some View {
        Form {
            Section {
                header
                Picker("Preset", selection: Binding(
                    get: { store.recipe.preset },
                    set: { store.choosePreset($0) }
                )) {
                    ForEach(MaterialPreset.allCases) { preset in
                        Label(preset.title, systemImage: preset.symbol).tag(preset)
                    }
                }
                SavedRecipesRow(store: store)
                Toggle("Live update", isOn: $store.autoDerive)
                    .help("Re-derive automatically ~150 ms after each change (⌥⌘R)")
            } footer: {
                Text("Flat is the safe default for painted or unknown surfaces.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Relief") {
                ParameterRow(title: "Height strength", value: $store.recipe.heightStrength,
                             range: MaterialRecipe.Range.heightStrength, digits: 2,
                             help: "Amplitude of the estimated relief.")
                Picker("Bright details", selection: $store.recipe.heightPolarity) {
                    Text("Raised").tag(Int32(1))
                    Text("Recessed").tag(Int32(-1))
                }
                .pickerStyle(.segmented)
                ParameterRow(title: "Normal strength", value: $store.recipe.normalStrength,
                             range: MaterialRecipe.Range.normalStrength, digits: 2,
                             sliderRange: 0...4,
                             help: "Multiplies the tangent normal gradient; 1 is neutral. Type up to 16.")
                LearnedGeometryRow(store: store, learned: store.learned)
                AttachmentRow(
                    title: "Relief mask",
                    systemImage: "circle.lefthalf.striped.horizontal",
                    url: store.recipe.reliefMaskURL,
                    choose: { store.showReliefImporter = true },
                    clear: { store.recipe.reliefMaskURL = nil },
                    help: "Grayscale mask: black flattens inferred relief, white keeps it."
                )
                AttachmentRow(
                    title: "Authored height",
                    systemImage: "mountain.2",
                    url: store.recipe.heightOverrideURL,
                    choose: { store.showHeightImporter = true },
                    clear: { store.recipe.heightOverrideURL = nil },
                    help: "A 16-bit grayscale height map replaces the estimate."
                )
            }

            Section("Surface") {
                ParameterRow(title: "Roughness", value: $store.recipe.roughnessBase,
                             range: MaterialRecipe.Range.roughness, digits: 2,
                             help: "Perceptual roughness prior: 0 glossy, 1 matte.")
                ParameterRow(title: "Roughness variation", value: $store.recipe.roughnessVariation,
                             range: MaterialRecipe.Range.roughness, digits: 2,
                             help: "Restrained height-driven variation.")
                ParameterRow(title: "Remove baked lighting", value: $store.recipe.albedoEqualize,
                             range: MaterialRecipe.Range.albedoEqualize, digits: 2,
                             help: "Flattens low-frequency shading in the albedo (delighting).")
                Toggle("Assign metalness", isOn: $store.recipe.assignedMetalnessEnabled.animation())
                if store.recipe.assignedMetalnessEnabled {
                    ParameterRow(title: "Metalness", value: $store.recipe.assignedMetalness,
                                 range: MaterialRecipe.Range.metalness, digits: 2,
                                 help: "An artist decision, never inferred from color.")
                }
            }

            Section("Lighting & Tiling") {
                ParameterRow(title: "AO radius", value: $store.recipe.aoRadiusPixels,
                             range: MaterialRecipe.Range.aoRadius, digits: 0, unit: "px",
                             help: "Horizon search radius in source pixels.")
                ParameterRow(title: "AO depth", value: $store.recipe.aoStrength,
                             range: MaterialRecipe.Range.aoStrength, digits: 2,
                             help: "Relief exaggeration seen by the occlusion search; 0 disables AO.")
                Toggle("Bent normal map", isOn: $store.recipe.bentNormalEnabled)
                Toggle("Wrap filters at edges", isOn: $store.recipe.tileWrap)
                    .help(store.recipe.albedoRepair == .off
                          ? "Treat the image as tiling when filtering and sampling occlusion."
                          : "Always on while Repair albedo is on: a repaired albedo tiles.")
                    .disabled(store.recipe.albedoRepair != .off)
                TileableRows(store: store)
            }

            Section {
                Picker("Normal convention", selection: Binding(
                    get: { store.recipe.normalYDown ? NormalConvention.directX : .openGL },
                    set: { store.recipe.normalYDown = $0 == .directX }
                )) {
                    ForEach(NormalConvention.allCases) { convention in
                        Text(convention.title).tag(convention)
                    }
                }
                Toggle("Include unreviewed in batch", isOn: $store.includeUnreviewedBatch)
                Button(store.eligibleBatchSources.count == 1
                       ? "Batch Export 1 Source…"
                       : "Batch Export \(store.eligibleBatchSources.count) Sources…") {
                    store.batchDeriveVisible()
                }
                .disabled(store.isBatching || store.eligibleBatchSources.isEmpty)
            } header: {
                Text("Export")
            } footer: {
                Text("OpenGL (+Y, green up) suits glTF, Blender and Unity; DirectX (−Y) suits Unreal. Batch applies this recipe to eligible sources in the sidebar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .accessibilityLabel("Material recipe inspector")
    }

    private var header: some View {
        HStack(spacing: 12) {
            SourceThumbnail(url: source.url, side: 44, cornerRadius: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Button("Edit Labels…") { store.editMetadata(for: source) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            Spacer(minLength: 0)
            Button {
                store.resetRecipe()
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help("Reset all values to the preset defaults")
            .accessibilityLabel("Reset recipe")
        }
        .padding(.vertical, 2)
    }
}

/// Slider plus an editable numeric field; values are clamped to the core's accepted range.
private struct ParameterRow: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var digits: Int = 2
    var sliderRange: ClosedRange<Float>? = nil
    var unit: String? = nil
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                TextField(
                    title,
                    value: Binding(
                        get: { Double(value) },
                        set: { value = min(range.upperBound, max(range.lowerBound, Float($0))) }
                    ),
                    format: .number.precision(.fractionLength(digits))
                )
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 54)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                if let unit {
                    Text(unit).font(.caption).foregroundStyle(.secondary)
                }
            }
            Slider(
                value: Binding(
                    get: { min(slider.upperBound, max(slider.lowerBound, value)) },
                    set: { value = $0 }
                ),
                in: slider
            )
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .controlSize(.small)
            .accessibilityLabel(title)
            .accessibilityValue(value.formatted(.number.precision(.fractionLength(digits))))
        }
        .help(help ?? title)
    }

    private var slider: ClosedRange<Float> { sliderRange ?? range }
}

private struct AttachmentRow: View {
    let title: String
    let systemImage: String
    let url: URL?
    let choose: () -> Void
    let clear: () -> Void
    let help: String

    var body: some View {
        LabeledContent {
            if let url {
                HStack(spacing: 6) {
                    Text(url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button {
                        clear()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Remove \(title.lowercased())")
                }
            } else {
                Button("Choose…", action: choose)
                    .controlSize(.small)
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
        .help(help)
    }
}

/// Blend of learned (MoGe-2) geometry over the analytic height estimate, with model status.
private struct LearnedGeometryRow: View {
    @Bindable var store: MaterialLabStore
    let learned: LearnedModelStore

    private var available: Bool { learned.isInstalled }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ParameterRow(
                title: "Learned geometry", value: $store.recipe.guideNormalWeight,
                range: MaterialRecipe.Range.guideNormalWeight, digits: 2,
                help: "Weight of MoGe-2 learned geometry: large-scale form and which way the fine detail points. 0 analytic only; at 1 the fine grain still comes from the photo, oriented by the learned surface."
            )
            .disabled(!available)
            footnote
        }
        .animation(.easeOut(duration: 0.2), value: learned.isRunning)
        .animation(.easeOut(duration: 0.2), value: available)
    }

    @ViewBuilder
    private var footnote: some View {
        if !available {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(learned.status == .installing
                         ? "Installing the learned model…"
                         : "Install the MoGe-2 normal model to read mortar, grout and seams as recessed.")
                        .fixedSize(horizontal: false, vertical: true)
                    SettingsLink {
                        Text("Open Learned Geometry Settings…")
                    }
                    .buttonStyle(.link)
                    .foregroundStyle(.tint)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let value = learned.inferenceProgress {
            HStack(spacing: 7) {
                ProgressView(value: Double(value))
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                    .tint(.purple)
                Text(learnedProgressText(value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .transition(.opacity)
            .accessibilityElement(children: .combine)
        } else if store.recipe.guideNormalWeight > 0 {
            Label {
                Text(caption)
            } icon: {
                Image(systemName: "sparkles").foregroundStyle(.purple.gradient)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .transition(.opacity)
        }
    }

    private func learnedProgressText(_ value: Float) -> String {
        guard let detail = learned.inferenceDetail, detail.passes > 0 else { return "Preparing learned model…" }
        if detail.coarse { return "Quick estimate…" }
        var text = "Refining · pass \(detail.pass) of \(detail.passes)"
        if let remaining = detail.remaining, detail.pass >= 2, remaining >= 0.5 {
            text += " · ~\(Int(remaining.rounded())) s"
        }
        return text
    }

    private var caption: String {
        let units = learned.cpuOnly ? "CPU" : "Neural Engine"
        if let seconds = learned.lastInferenceDuration {
            return "MoGe-2 · \(units) · \(Int((seconds * 1000).rounded())) ms, reused while editing"
        }
        return "MoGe-2 · \(units)"
    }
}

/// Apply, save and delete named recipes.
private struct SavedRecipesRow: View {
    @Bindable var store: MaterialLabStore
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        LabeledContent("Saved recipes") {
            Menu {
                if store.savedRecipes.isEmpty {
                    Text("No saved recipes yet")
                } else {
                    Section("Apply") {
                        ForEach(store.savedRecipes) { saved in
                            Button {
                                store.applySavedRecipe(saved)
                            } label: {
                                Label(saved.name, systemImage: saved.recipe.preset.symbol)
                            }
                        }
                    }
                    Menu("Delete", systemImage: "trash") {
                        ForEach(store.savedRecipes) { saved in
                            Button(saved.name, role: .destructive) { store.deleteSavedRecipe(saved) }
                        }
                    }
                }
                Divider()
                Button("Save Current Recipe…", systemImage: "square.and.arrow.down") {
                    name = ""
                    naming = true
                }
            } label: {
                Label(store.savedRecipes.isEmpty ? "None" : "\(store.savedRecipes.count)",
                      systemImage: "bookmark")
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .help("Apply a recipe you saved, or save this one to reuse on other sources")
        }
        .alert("Save Recipe", isPresented: $naming) {
            TextField("Name, e.g. Wet slate", text: $name)
            Button("Save") { store.saveCurrentRecipe(named: name) }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves every setting except this source's relief mask and height override. A recipe with the same name is replaced.")
        }
    }
}

/// Make tileable: edge-band width, seam method and a one-click jump to the 3×3 tile preview.
private struct TileableRows: View {
    @Bindable var store: MaterialLabStore

    private var repairing: Bool { store.recipe.albedoRepair != .off }
    private var enabled: Bool { store.recipe.seamlessBlend > 0 && !repairing }
    private var showingTiles: Bool { store.canvasMode == .tile }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Repair albedo", selection: $store.recipe.albedoRepair) {
                ForEach(AlbedoRepair.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .help("Rebuild the albedo itself so it tiles on both axes. The repaired albedo feeds every derived map and learned geometry.")
            .onChange(of: store.recipe.albedoRepair) { _, mode in
                guard mode != .off else { return }
                store.recipe.tileWrap = true
                withAnimation(.snappy) { store.canvasMode = .tile }
            }
            if repairing {
                Text(store.recipe.albedoRepair.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ParameterRow(title: repairing ? "Repair band" : "Make tileable", value: $store.recipe.seamlessBlend,
                         range: MaterialRecipe.Range.seamlessBlend, digits: 2,
                         help: repairing
                            ? "Band per edge used by the repair, as a fraction of the image. 0 uses the default 0.12."
                            : "Width of the edge band, per edge, as a fraction of the image. 0 leaves the edges untouched.")
            Picker("Method", selection: $store.recipe.seamlessMode) {
                ForEach(SeamlessMode.allCases) { mode in
                    Text(mode.title).tag(mode).help(mode.explanation)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .disabled(!enabled)
            .accessibilityLabel("Tiling method")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(repairing ? "Repair chooses its own method; the result is shown in Tiling Quality."
                     : enabled ? store.recipe.seamlessMode.explanation : "Raise Make tileable to choose a method.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button {
                    withAnimation(.snappy) { store.canvasMode = showingTiles ? .map : .tile }
                } label: {
                    Label(showingTiles ? "Single" : "Preview Tiling",
                          systemImage: showingTiles ? "square" : "square.grid.3x3")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(showingTiles ? nil : .accentColor)
                .help(showingTiles ? "Back to the single map view" : "Show the map repeated 3 × 3 to check the seams")
            }
        }
        .animation(.easeOut(duration: 0.15), value: enabled)
        .animation(.easeOut(duration: 0.15), value: repairing)
    }
}
