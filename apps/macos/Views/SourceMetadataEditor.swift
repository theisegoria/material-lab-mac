import SwiftUI

struct SourceMetadataEditor: View {
    let source: MaterialSource
    let onSave: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var semanticLabel: String
    @State private var category: String

    init(source: MaterialSource, onSave: @escaping (String, String) -> Void) {
        self.source = source
        self.onSave = onSave
        _semanticLabel = State(initialValue: source.semanticLabel)
        _category = State(initialValue: source.category == "uncategorized" ? "" : source.category)
    }

    private var valid: Bool {
        let label = semanticLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = category.trimmingCharacters(in: .whitespacesAndNewlines)
        return !label.isEmpty && label.count <= 240 &&
               !kind.isEmpty && kind.count <= 120
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Describe the material")
                .font(.title2.bold())
            Text("Use a precise name and category. These labels travel with every exported map so a text parser can identify the surface.")
                .foregroundStyle(.secondary)
            Form {
                TextField("Semantic label", text: $semanticLabel,
                          prompt: Text("weathered limestone wall"))
                TextField("Category", text: $category,
                          prompt: Text("masonry"))
            }
            .formStyle(.grouped)
            HStack {
                Text(source.url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                Button("Later") { dismiss() }
                Button("Save labels") {
                    onSave(semanticLabel, category)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!valid)
            }
        }
        .padding(24)
        .frame(width: 470)
    }
}
