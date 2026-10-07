import SwiftUI
import UniformTypeIdentifiers

/// Chooses the engine and interchange formats saved beside the .pbrmaterial bundle, then saves the folder to Files.
struct ExportTargetsSheet: View {
    @Bindable var store: CaptureStore
    /// Called with the finished folder; the caller presents the Files exporter.
    let onExport: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isWriting = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Material bundle (.pbrmaterial)")
                            Text("Every map plus its manifest. Always included; opens in Material Lab on the Mac.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "shippingbox")
                    }
                }
                ForEach(ExportTarget.Group.allCases, id: \.self) { group in
                    Section(group.title) {
                        ForEach(ExportTarget.all.filter { $0.group == group }) { target in
                            Toggle(isOn: binding(for: target)) {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(target.title)
                                        Text(target.detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: target.symbol)
                                }
                            }
                            .accessibilityIdentifier("export-target-\(target.id)")
                        }
                    }
                }
            }
            .navigationTitle("Export Material")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) {
                        Task { await export() }
                    } label: {
                        if isWriting { ProgressView() } else { Text("Save") }
                    }
                    .disabled(isWriting)
                    .accessibilityIdentifier("export-targets-save")
                }
            }
        }
    }

    private func export() async {
        isWriting = true
        defer { isWriting = false }
        do {
            let folder = try await store.makeMaterialExport()
            dismiss()
            onExport(folder)
        } catch {
            store.errorMessage = error.localizedDescription
            dismiss()
        }
    }

    private func binding(for target: ExportTarget) -> Binding<Bool> {
        Binding(
            get: { store.exportTargets.contains(target.id) },
            set: { on in
                if on { store.exportTargets.insert(target.id) } else { store.exportTargets.remove(target.id) }
            }
        )
    }
}

/// A finished export folder handed to the Files exporter.
struct ExportFolderDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.folder] }
    static var writableContentTypes: [UTType] { [.folder] }
    let url: URL?

    init(url: URL) { self.url = url }
    init(configuration: ReadConfiguration) throws { url = nil }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let url else { throw CocoaError(.fileWriteUnknown) }
        return try FileWrapper(url: url, options: .immediate)
    }
}
