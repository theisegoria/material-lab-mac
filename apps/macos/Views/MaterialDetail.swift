import SwiftUI

struct MaterialDetail: View {
    @Bindable var store: MaterialLabStore
    let source: MaterialSource

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    MapPreview(store: store, source: source)
                    if let derived = store.derived, derived.source.id == source.id {
                        seamSummary(derived)
                        warnings(derived.warnings)
                    } else {
                        ContentUnavailableView(
                            "Ready to derive",
                            systemImage: "square.3.layers.3d",
                            description: Text("Choose a material preset, then derive maps. Outputs are estimates.")
                        )
                        .frame(height: 170)
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            RecipeInspector(store: store)
                .frame(width: 300)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(source.displayName)
                    .font(.largeTitle.bold())
                    .textSelection(.enabled)
                Spacer()
                Button("Edit labels…") { store.editMetadata(for: source) }
                    .font(.caption)
                Text(source.origin.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Label(source.category, systemImage: "tag")
                Label(source.reviewStatus, systemImage: "checkmark.seal")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if let derived = store.derived, derived.recipe != store.recipe {
                Label("Parameters changed. Derive again before export.", systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func seamSummary(_ material: DerivedMaterial) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Tile seam diagnostics").font(.headline)
            HStack(spacing: 20) {
                metric("Albedo edge", material.seams.albedoValue)
                metric("Height edge", material.seams.heightValue)
                metric("Height gradient", material.seams.heightGradient)
            }
            Text("These values compare opposite edges. They do not certify a seamless tile.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func metric(_ label: String, _ value: Float) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.formatted(.number.precision(.fractionLength(4))))
                .font(.system(.body, design: .monospaced))
        }
    }

    private func warnings(_ messages: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Provenance and review").font(.headline)
            ForEach(messages, id: \.self) { message in
                Label(message, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
