import SwiftUI

struct RecipeInspector: View {
    @Bindable var store: MaterialLabStore

    var body: some View {
        Form {
            Section("Source interpretation") {
                Picker("Material preset", selection: Binding(
                    get: { store.recipe.preset },
                    set: { store.choosePreset($0) }
                )) {
                    ForEach(MaterialPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                Text("Flat is the safe default for painted or unknown surfaces.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Wrap spatial filters", isOn: $store.recipe.tileWrap)
            }
            Section("Relief estimate") {
                parameter("Height strength", value: $store.recipe.heightStrength, in: 0...1)
                Picker("Bright details", selection: $store.recipe.heightPolarity) {
                    Text("Raised").tag(Int32(1))
                    Text("Recessed").tag(Int32(-1))
                }
                Button("Choose relief suppression mask…") {
                    store.showReliefImporter = true
                }
                if let url = store.recipe.reliefMaskURL {
                    Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                    Button("Clear mask") { store.recipe.reliefMaskURL = nil }
                }
                Button("Choose authored 16-bit height…") {
                    store.showHeightImporter = true
                }
                if let url = store.recipe.heightOverrideURL {
                    Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                    Button("Clear height override") { store.recipe.heightOverrideURL = nil }
                }
            }
            Section("Reflectance prior") {
                parameter("Roughness", value: $store.recipe.roughnessBase, in: 0...1)
                parameter("Roughness variation", value: $store.recipe.roughnessVariation, in: 0...1)
                Toggle("Assign metalness", isOn: $store.recipe.assignedMetalnessEnabled)
                if store.recipe.assignedMetalnessEnabled {
                    parameter("Metalness", value: $store.recipe.assignedMetalness, in: 0...1)
                    Text("Metalness is an artist decision, never inferred from RGB.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Occlusion and diagnostics") {
                parameter("AO radius (pixels)", value: $store.recipe.aoRadiusPixels, in: 1...64)
                Toggle("Bent normal", isOn: $store.recipe.bentNormalEnabled)
            }
            Section {
                Button("Derive maps") { store.deriveSelected() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isBusy || store.selectedSource == nil)
                Toggle("Include unreviewed sources in batch", isOn: $store.includeUnreviewedBatch)
                Button("Batch eligible sources…") { store.batchDeriveVisible() }
                    .disabled(store.isBusy || store.eligibleBatchSources.isEmpty)
                Text("Batch uses the current recipe for eligible visible sources. Reviewed sources are the default; including candidates requires the explicit toggle.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .accessibilityLabel("Material recipe inspector")
    }

    private func parameter(
        _ title: String, value: Binding<Float>, in range: ClosedRange<Float>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2))))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .accessibilityLabel(title)
        }
    }
}
