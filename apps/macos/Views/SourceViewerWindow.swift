import SwiftUI

/// A second window showing one source's maps, derived with its own recipe, for side-by-side comparison while the
/// main window edits another source.
struct SourceViewerWindow: View {
    let store: MaterialLabStore
    let sourceID: String
    @State private var material: DerivedMaterial?
    @State private var selected: MaterialMapKind = .albedo
    @State private var failure: String?

    private var source: MaterialSource? { store.sources.first { $0.id == sourceID } }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Rectangle().fill(.background.secondary)
                if let image = material?.previews[selected] {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(24)
                        .accessibilityLabel("\(selected.title) map of \(source?.displayName ?? "")")
                } else if let failure {
                    ContentUnavailableView("Cannot Derive", systemImage: "exclamationmark.triangle", description: Text(failure))
                } else {
                    ProgressView("Deriving…")
                }
            }
            Picker("Map", selection: $selected) {
                ForEach(MaterialMapKind.allCases.filter { material?.previews[$0] != nil }) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .padding(12)
        }
        .navigationTitle(source?.displayName ?? "Material")
        .frame(minWidth: 420, minHeight: 480)
        .task(id: sourceID) {
            guard let source else { failure = String(localized: "This source is no longer in the library."); return }
            let recipe = store.recipe(for: source)
            do {
                material = try await Task.detached(priority: .userInitiated) {
                    try MaterialEngine.derive(source: source, recipe: recipe, control: DerivationControl(onProgress: { _ in }))
                }.value
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
