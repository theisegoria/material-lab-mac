import SwiftUI

/// The material library (brick, concrete, wood, metal...) grouped by category, with search.
struct MaterialPresetPicker: View {
    @Bindable var store: CaptureStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var groups: [(category: String, presets: [LibraryPreset])] {
        guard !query.isEmpty else { return LibraryPreset.byCategory }
        return LibraryPreset.byCategory.compactMap { group in
            let matches = group.presets.filter {
                $0.title.localizedCaseInsensitiveContains(query) || group.category.localizedCaseInsensitiveContains(query)
            }
            return matches.isEmpty ? nil : (group.category, matches)
        }
    }

    var body: some View {
        List {
            ForEach(groups, id: \.category) { group in
                Section(group.category) {
                    ForEach(group.presets) { preset in
                        Button {
                            store.applyLibraryPreset(preset)
                            dismiss()
                        } label: {
                            HStack {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(preset.title).foregroundStyle(.primary)
                                        Text(summary(preset))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: preset.symbol)
                                }
                                Spacer()
                                if store.recipe.materialPreset == preset.id {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .accessibilityIdentifier("material-preset-\(preset.id)")
                    }
                }
            }
        }
        .navigationTitle("Material")
        .searchable(text: $query, prompt: "Brick, oak, steel…")
    }

    private func summary(_ preset: LibraryPreset) -> String {
        let r = preset.recipe
        var text = "\(MaterialPreset(r.preset).title) · roughness \(String(format: "%.2f", r.roughness_base))"
        if r.assigned_metalness_enabled != 0 { text += " · metal \(String(format: "%.1f", r.assigned_metalness))" }
        return text
    }
}
