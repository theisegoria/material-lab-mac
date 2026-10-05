import SwiftUI

/// Every saved capture as a thumbnail grid. Tap to open, long-press to delete.
struct LibraryView: View {
    @Bindable var store: CaptureStore
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDelete: CaptureLibrary.Entry?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    var body: some View {
        NavigationStack {
            Group {
                if store.libraryEntries.isEmpty {
                    ContentUnavailableView {
                        Label("No Saved Captures", systemImage: "square.stack.3d.up.slash")
                    } description: {
                        Text("Every photo you capture or import is kept here, with its crop and recipe.")
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(store.libraryEntries) { entry in
                                Button {
                                    Task {
                                        await store.open(entry.id)
                                        dismiss()
                                    }
                                } label: {
                                    LibraryCell(entry: entry, isCurrent: entry.id == store.source?.id)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = entry }
                                }
                                .accessibilityIdentifier("library-entry")
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                        .accessibilityIdentifier("library-done")
                }
            }
            .confirmationDialog("Delete this capture?", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
            ), titleVisibility: .visible, presenting: pendingDelete) { entry in
                Button("Delete Capture", role: .destructive) {
                    Task { await store.delete(entry.id) }
                }
            } message: { _ in
                Text("The photo, crop and recipe are removed from this iPhone. Exported bundles are not affected.")
            }
            .task { await store.refreshLibrary() }
        }
    }
}

private struct LibraryCell: View {
    let entry: CaptureLibrary.Entry
    let isCurrent: Bool

    private var title: String {
        let trimmed = entry.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled material" : trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let url = entry.thumbnailURL, let image = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(.quaternary)
                            .overlay { Image(systemName: "photo").font(.title2).foregroundStyle(.secondary) }
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 16))
                if isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .tint)
                        .padding(8)
                        .accessibilityLabel("Open now")
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(entry.recipe.preset.title) · \(entry.modified.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this capture")
    }
}
