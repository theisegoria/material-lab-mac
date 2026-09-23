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
                    .help("Treat the image as tiling when filtering and sampling occlusion.")
                ParameterRow(title: "Make tileable", value: $store.recipe.seamlessBlend,
                             range: MaterialRecipe.Range.seamlessBlend, digits: 2,
                             help: "Cross-fades opposite edges; the value is the blend width per edge.")
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
