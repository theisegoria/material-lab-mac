import SwiftUI

struct RecipeInspector: View {
    @Bindable var store: MaterialLabStore
    let source: MaterialSource
    /// Basic shows the controls most materials need; Advanced shows every parameter.
    @AppStorage("materialLab.inspectorAdvanced") private var advanced = false
    /// Advanced groups the user opened while in Basic mode (comma-separated group IDs).
    @AppStorage("materialLab.inspectorExpanded") private var expandedGroups = ""

    private var base: MaterialRecipe { store.baselineRecipe }

    var body: some View {
        Form {
            Section {
                header
                Picker("Controls", selection: Binding(
                    get: { advanced },
                    set: { advanced = $0; if !$0 { expandedGroups = "" } }
                )) {
                    Text("Basic").tag(false)
                    Text("Advanced").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Basic shows the controls most materials need; Advanced shows every parameter.")
                LabeledContent("Material") {
                    Menu {
                        ForEach(LibraryPreset.byCategory, id: \.category) { group in
                            Section(group.category) {
                                ForEach(group.presets) { preset in
                                    Button {
                                        store.chooseLibraryPreset(preset)
                                    } label: {
                                        if store.recipe.materialPreset == preset.id {
                                            Label(preset.title, systemImage: "checkmark")
                                        } else {
                                            Text(preset.title)
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        Label(LibraryPreset.named(store.recipe.materialPreset)?.title ?? "Choose…",
                              systemImage: LibraryPreset.named(store.recipe.materialPreset)?.symbol ?? "square.stack.3d.up")
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .accessibilityIdentifier("material-preset-menu")
                    .popoverTip(MaterialMenuTip(), arrowEdge: .leading)
                    .help("Start from a tuned material: brick, concrete, wood, metal and more")
                }
                Picker("Relief prior", selection: Binding(
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
                Text("A material sets the relief prior plus tuned relief, roughness and AO. Flat is the safe default for painted or unknown surfaces.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ParameterRow(title: String(localized: "Height strength"), value: $store.recipe.heightStrength,
                             range: MaterialRecipe.Range.heightStrength, digits: 2, baseline: base.heightStrength,
                             help: String(localized: "Amplitude of the estimated relief."))
                Picker("Bright details", selection: $store.recipe.heightPolarity) {
                    Text("Raised").tag(Int32(1))
                    Text("Recessed").tag(Int32(-1))
                }
                .pickerStyle(.segmented)
                AdvancedGroup(isExpanded: expanded("relief")) {
                    ParameterRow(title: String(localized: "Normal strength"), value: $store.recipe.normalStrength,
                                 range: MaterialRecipe.Range.normalStrength, digits: 2, baseline: base.normalStrength,
                                 sliderRange: 0...4,
                                 help: String(localized: "Multiplies the tangent normal gradient; 1 is neutral. Type up to 16."))
                    ParameterRow(title: String(localized: "Tile size"), value: $store.recipe.tileMetres,
                                 range: MaterialRecipe.Range.tileMetres, digits: 2, baseline: base.tileMetres,
                                 sliderRange: 0...8, unit: "m",
                                 help: String(localized: "Real width of the tile in metres, so relief is sized physically. 0 means unknown (treated as 1 m). Type up to 64."))
                    if store.recipe.preset == .flat {
                        ParameterRow(title: String(localized: "Surface unevenness"), value: $store.recipe.substrateRelief,
                                     range: MaterialRecipe.Range.unit, digits: 2, baseline: base.substrateRelief,
                                     help: String(localized: "Adds the fine unevenness of a painted or coated surface. Flat prior only; off with learned geometry."))
                    } else {
                        ParameterRow(title: String(localized: "Mid-scale relief"), value: $store.recipe.midReliefShare,
                                     range: MaterialRecipe.Range.midReliefShare, digits: 2, baseline: base.midReliefShare,
                                     help: String(localized: "Minimum share of the relief carried by 4–30 mm features (seams, chips, fasteners), so it still reads from a few metres away. 0 turns the floor off."))
                    }
                    AttachmentRow(
                        title: String(localized: "Relief mask"),
                        systemImage: "circle.lefthalf.striped.horizontal",
                        url: store.recipe.reliefMaskURL,
                        choose: { store.showReliefImporter = true },
                        clear: { store.recipe.reliefMaskURL = nil },
                        help: String(localized: "Grayscale mask: black flattens inferred relief, white keeps it.")
                    )
                }
                LearnedGeometryRow(store: store, learned: store.learned)
            } header: {
                SectionHeader(title: String(localized: "Relief"), symbol: "mountain.2",
                              modified: modified(\.heightStrength, \.normalStrength, \.tileMetres,
                                                 \.midReliefShare, \.substrateRelief) ||
                              store.recipe.heightPolarity != base.heightPolarity) {
                    reset(\.heightStrength, \.normalStrength, \.tileMetres, \.midReliefShare, \.substrateRelief) {
                        $0.heightPolarity = base.heightPolarity
                    }
                }
            }

            Section {
                Toggle("Hand-made albedo", isOn: $store.recipe.authoredAlbedo)
                    .help("The source is painted or drawn, not photographed. It is recorded as authored; leave Remove baked lighting and Repair albedo off to keep it untouched.")
                AttachmentRow(
                    title: String(localized: "Height map"),
                    systemImage: "mountain.2",
                    url: store.recipe.heightOverrideURL,
                    choose: { store.showHeightImporter = true },
                    clear: { store.recipe.heightOverrideURL = nil },
                    help: String(localized: "A 16-bit grayscale height map replaces the estimate.")
                )
                ForEach(AuthoredSlot.allCases) { slot in
                    AttachmentRow(
                        title: slot.title,
                        systemImage: slot.symbol,
                        url: slot.url(in: store.recipe),
                        choose: { store.authoredImporter = slot },
                        clear: { slot.set(nil, in: &store.recipe) },
                        help: slot.help
                    )
                    if slot == .normal, store.recipe.normalMapURL != nil {
                        Toggle("DirectX normal map (green down)", isOn: $store.recipe.normalMapDirectX)
                            .controlSize(.small)
                    }
                }
            } header: {
                SectionHeader(title: String(localized: "Your maps"), symbol: "photo.stack", modified: false)
            } footer: {
                Text("Bring your own artwork: anything you add replaces the estimate, and the bundle records it as authored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ParameterRow(title: String(localized: "Roughness"), value: $store.recipe.roughnessBase,
                             range: MaterialRecipe.Range.roughness, digits: 2, baseline: base.roughnessBase,
                             help: String(localized: "Perceptual roughness prior: 0 glossy, 1 matte."))
                AdvancedGroup(isExpanded: expanded("surface")) {
                    ParameterRow(title: String(localized: "Roughness variation"), value: $store.recipe.roughnessVariation,
                                 range: MaterialRecipe.Range.roughness, digits: 2, baseline: base.roughnessVariation,
                                 help: String(localized: "Restrained height-driven variation."))
                    ParameterRow(title: String(localized: "Follow colour"), value: $store.recipe.roughnessAlbedoLimit,
                                 range: MaterialRecipe.Range.unit, digits: 2, baseline: base.roughnessAlbedoLimit,
                                 help: String(localized: "How far roughness may follow the albedo's brightness. Lower values stop dark paint reading as rough; 1 removes the limit."))
                }
                ParameterRow(title: String(localized: "Remove baked lighting"), value: $store.recipe.albedoEqualize,
                             range: MaterialRecipe.Range.albedoEqualize, digits: 2, baseline: base.albedoEqualize,
                             help: String(localized: "Flattens low-frequency shading in the albedo (delighting)."))
                Toggle("Assign metalness", isOn: $store.recipe.assignedMetalnessEnabled.animation())
                if store.recipe.assignedMetalnessEnabled {
                    ParameterRow(title: String(localized: "Metalness"), value: $store.recipe.assignedMetalness,
                                 range: MaterialRecipe.Range.metalness, digits: 2, baseline: base.assignedMetalness,
                                 help: String(localized: "An artist decision, never inferred from color."))
                }
            } header: {
                SectionHeader(title: String(localized: "Surface"), symbol: "circle.lefthalf.filled",
                              modified: modified(\.roughnessBase, \.roughnessVariation, \.roughnessAlbedoLimit, \.albedoEqualize,
                                                 \.assignedMetalness) ||
                              store.recipe.assignedMetalnessEnabled != base.assignedMetalnessEnabled) {
                    reset(\.roughnessBase, \.roughnessVariation, \.roughnessAlbedoLimit, \.albedoEqualize, \.assignedMetalness) {
                        $0.assignedMetalnessEnabled = base.assignedMetalnessEnabled
                    }
                }
            }

            Section {
                AdvancedGroup(isExpanded: expanded("lighting")) {
                    ParameterRow(title: String(localized: "AO radius"), value: $store.recipe.aoRadiusPixels,
                                 range: MaterialRecipe.Range.aoRadius, digits: 0, baseline: base.aoRadiusPixels, unit: "px",
                                 help: String(localized: "Horizon search radius in source pixels."))
                    ParameterRow(title: String(localized: "AO depth"), value: $store.recipe.aoStrength,
                                 range: MaterialRecipe.Range.aoStrength, digits: 2, baseline: base.aoStrength,
                                 help: String(localized: "Relief exaggeration seen by the occlusion search; 0 disables AO."))
                    Toggle("Bent normal map", isOn: $store.recipe.bentNormalEnabled)
                    Toggle("Wrap filters at edges", isOn: $store.recipe.tileWrap)
                        .help(store.recipe.albedoRepair == .off
                              ? "Treat the image as tiling when filtering and sampling occlusion."
                              : "Always on while Repair albedo is on: a repaired albedo tiles.")
                        .disabled(store.recipe.albedoRepair != .off)
                }
                TileableRows(store: store)
            } header: {
                SectionHeader(title: String(localized: "Lighting & Tiling"), symbol: "square.grid.3x3.topleft.filled",
                              modified: modified(\.aoRadiusPixels, \.aoStrength, \.seamlessBlend) ||
                              store.recipe.albedoRepair != base.albedoRepair ||
                              store.recipe.bentNormalEnabled != base.bentNormalEnabled) {
                    reset(\.aoRadiusPixels, \.aoStrength, \.seamlessBlend) {
                        $0.albedoRepair = base.albedoRepair
                        $0.bentNormalEnabled = base.bentNormalEnabled
                    }
                }
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
                SectionHeader(title: String(localized: "Export"), symbol: "square.and.arrow.up", modified: false)
            } footer: {
                Text("OpenGL (+Y, green up) suits glTF, Blender and Unity; DirectX (−Y) suits Unreal. Batch applies this recipe to eligible sources in the sidebar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .accessibilityLabel("Material recipe inspector")
    }

    /// An advanced group is open in Advanced mode, or when the user opened it in Basic mode. Collapsing one in
    /// Advanced mode switches to Basic with the other groups left open.
    private func expanded(_ id: String) -> Binding<Bool> {
        Binding(
            get: { advanced || openGroups.contains(id) },
            set: { open in
                var groups = openGroups
                if open {
                    groups.insert(id)
                } else if advanced {
                    advanced = false
                    groups = Set(Self.advancedGroupIDs).subtracting([id])
                } else {
                    groups.remove(id)
                }
                expandedGroups = groups.sorted().joined(separator: ",")
            }
        )
    }

    private static let advancedGroupIDs = ["relief", "surface", "lighting"]

    private var openGroups: Set<String> {
        Set(expandedGroups.split(separator: ",").map(String.init))
    }

    /// Resets a section's values to the baseline in one undoable step.
    private func reset(_ keys: WritableKeyPath<MaterialRecipe, Float>..., also: (inout MaterialRecipe) -> Void = { _ in }) {
        var next = store.recipe
        for key in keys { next[keyPath: key] = base[keyPath: key] }
        also(&next)
        store.resetUndoCoalescing()
        withAnimation(.snappy) { store.recipe = next }
    }

    /// Whether any of these values differs from the baseline (the material or prior defaults).
    private func modified(_ keys: KeyPath<MaterialRecipe, Float>...) -> Bool {
        keys.contains { abs(store.recipe[keyPath: $0] - base[keyPath: $0]) > 1e-4 }
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

/// A section title with its symbol, a dot when any value in it differs from the material's defaults, and a reset
/// button for the section's values.
private struct SectionHeader: View {
    let title: String
    var symbol: String? = nil
    let modified: Bool
    var reset: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
            }
            Text(title)
            if modified {
                Circle().fill(.tint).frame(width: 6, height: 6)
                    .accessibilityLabel("Modified")
                    .help("Changed from the material's defaults")
            }
            Spacer(minLength: 4)
            if modified, let reset {
                Button("Reset", action: reset)
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("Reset this section to the material's defaults")
                    .accessibilityLabel("Reset \(title)")
            }
        }
        .frame(minHeight: 18)
    }
}

/// Parameters most materials leave alone, folded under a disclosure that remembers whether it is open.
private struct AdvancedGroup<Content: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded.animation(.snappy(duration: 0.2))) {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(.top, 4)
        } label: {
            Text("Advanced")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// Slider plus an editable numeric field; values are clamped to the core's accepted range. With a baseline, a dot
/// marks a changed value and double-clicking the name resets it.
private struct ParameterRow: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var digits: Int = 2
    var baseline: Float? = nil
    var sliderRange: ClosedRange<Float>? = nil
    var unit: String? = nil
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 5) {
                    Text(title)
                    if isModified {
                        Circle().fill(.tint).frame(width: 5, height: 5)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if let baseline { value = baseline } }
                .accessibilityAction(named: "Reset to default") { if let baseline { value = baseline } }
                Spacer()
                if isModified, let baseline {
                    Button {
                        value = baseline
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Reset to \(baseline.formatted(.number.precision(.fractionLength(digits))))")
                    .accessibilityLabel("Reset \(title)")
                    .transition(.opacity)
                }
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
        .help((help ?? title) + (baseline == nil ? "" : String(localized: " Double-click the name to reset.")))
        .animation(.easeOut(duration: 0.15), value: isModified)
    }

    private var isModified: Bool { baseline.map { abs($0 - value) > 1e-4 } ?? false }

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
                title: String(localized: "Learned geometry"), value: $store.recipe.guideNormalWeight,
                range: MaterialRecipe.Range.guideNormalWeight, digits: 2,
                help: String(localized: "Weight of MoGe-2 learned geometry: large-scale form and which way the fine detail points. 0 analytic only; at 1 the fine grain still comes from the photo, oriented by the learned surface.")
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
            ParameterRow(title: repairing ? String(localized: "Repair band") : String(localized: "Make tileable"), value: $store.recipe.seamlessBlend,
                         range: MaterialRecipe.Range.seamlessBlend, digits: 2,
                         help: repairing
                            ? String(localized: "Band per edge used by the repair, as a fraction of the image. 0 uses the default 0.12.")
                            : String(localized: "Width of the edge band, per edge, as a fraction of the image. 0 leaves the edges untouched."))
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
