import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Chooses the engine and interchange formats saved beside the .pbrmaterial bundle, then saves the folder to Files
/// or hands the bundle and formats to the share sheet (AirDrop, Mail, Messages, other apps).
struct ExportTargetsSheet: View {
    @Bindable var store: CaptureStore
    /// Called with the finished folder; the caller presents the Files exporter.
    let onExport: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isWriting = false
    @State private var share: ShareRequest?

    /// Files handed to the share sheet, and the staging folder removed when it closes.
    struct ShareRequest: Identifiable {
        let id = UUID()
        let items: [URL]
        let staging: URL
    }

    private var chosenTargets: [ExportTarget] { ExportTarget.named(store.exportTargets) }

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
                    .accessibilityElement(children: .combine)
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
                Section {
                    Text("Sharing sends folders, such as the .pbrmaterial bundle, as .zip archives. Save to Files keeps them as folders.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .safeAreaInset(edge: .bottom) { actionBar }
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
            .sheet(item: $share) { request in
                ActivityView(items: request.items) {
                    try? FileManager.default.removeItem(at: request.staging)
                    share = nil
                }
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
            }
        }
    }

    /// Share and Save side by side on glass, always reachable above the list.
    private var actionBar: some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Menu {
                    Button("Bundle and Chosen Formats", systemImage: "square.stack.3d.up") {
                        Task { await shareExport(.everything) }
                    }
                    Button("Material Bundle Only", systemImage: "shippingbox") {
                        Task { await shareExport(.bundleOnly) }
                    }
                    Section("One Format") {
                        ForEach(ExportTarget.all) { target in
                            Button {
                                Task { await shareExport(.target(target.id)) }
                            } label: {
                                Label(target.title, systemImage: target.symbol)
                            }
                        }
                    }
                } label: {
                    Label("Share…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glass)
                .disabled(isWriting)
                .accessibilityIdentifier("export-share")
                .accessibilityHint("Shares the bundle or one format with AirDrop, Mail, Messages or another app")

                Button {
                    Task { await export() }
                } label: {
                    Label(isWriting ? "Preparing…" : "Save to Files", systemImage: "folder")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glassProminent)
                .disabled(isWriting)
                .accessibilityIdentifier("export-save-files")
                .accessibilityValue(chosenTargets.isEmpty
                                    ? String(localized: "Bundle only")
                                    : String(localized: "Bundle and \(chosenTargets.count) formats"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
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

    private func shareExport(_ selection: MaterialSharing.Selection) async {
        isWriting = true
        defer { isWriting = false }
        do {
            let folder = try await store.makeMaterialExport(targets: selection.exportTargets)
            let items = try await Task.detached(priority: .userInitiated) {
                try MaterialSharing.items(forExportFolder: folder, selection: selection)
            }.value
            share = ShareRequest(items: items, staging: folder.deletingLastPathComponent())
        } catch {
            store.errorMessage = error.localizedDescription
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

/// The system share sheet for files.
struct ActivityView: UIViewControllerRepresentable {
    let items: [URL]
    let completion: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in completion() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
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
