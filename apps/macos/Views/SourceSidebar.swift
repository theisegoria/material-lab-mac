import AppKit
import SwiftUI

struct SourceSidebar: View {
    @Bindable var store: MaterialLabStore
    @Environment(\.openWindow) private var openWindow
    @State private var naming: CollectionNaming?
    @State private var collectionName = ""

    private struct CollectionNaming: Identifiable {
        let id = UUID()
        var renaming: UUID?
    }

    private var selection: Binding<SidebarDestination?> {
        Binding(
            get: { store.destination },
            set: { if let next = $0 { store.navigate(to: next) } }
        )
    }

    private var groups: [(MaterialSourceOrigin, [MaterialSource])] {
        let order: [MaterialSourceOrigin] = [.imported, .cameraInbox, .catalog]
        return order.compactMap { origin in
            let items = store.filteredSources.filter { $0.origin == origin }
            return items.isEmpty ? nil : (origin, items)
        }
    }

    var body: some View {
        List(selection: selection) {
            Section("Library") {
                Label("All Materials", systemImage: LibraryFilter.all.symbol)
                    .badge(store.sources.count)
                    .tag(SidebarDestination.library(.all))
                Label("Favourites", systemImage: LibraryFilter.favourites.symbol)
                    .tag(SidebarDestination.library(.favourites))
                Label("Recently Edited", systemImage: LibraryFilter.recent.symbol)
                    .tag(SidebarDestination.library(.recent))
                Label("Camera Inbox", systemImage: "camera.on.rectangle")
                    .badge(store.inboxCount)
                    .tag(SidebarDestination.inbox)
                Label("Device Link", systemImage: store.link.isListening
                      ? "antenna.radiowaves.left.and.right" : "iphone.gen3.radiowaves.left.and.right")
                    .tag(SidebarDestination.link)
            }
            Section("Collections") {
                ForEach(store.library.collections) { collection in
                    Label(collection.name, systemImage: LibraryFilter.collection(collection.id).symbol)
                        .badge(collection.members.filter { id in store.sources.contains { $0.id == id } }.count)
                        .tag(SidebarDestination.library(.collection(collection.id)))
                        .contextMenu {
                            Button("Rename…") {
                                collectionName = collection.name
                                naming = CollectionNaming(renaming: collection.id)
                            }
                            Button("Delete Collection", role: .destructive) { store.deleteCollection(collection.id) }
                        }
                }
                Button {
                    collectionName = ""
                    naming = CollectionNaming()
                } label: {
                    Label("New Collection…", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Create a collection to group materials")
            }
            ForEach(groups, id: \.0) { origin, items in
                Section(origin.sectionTitle) {
                    ForEach(items) { source in
                        SourceRow(source: source)
                            .tag(SidebarDestination.source(source.id))
                            .contextMenu {
                                Button("Open in New Window") { openWindow(id: "source-viewer", value: source.id) }
                                Button("Edit Labels…") { store.editMetadata(for: source) }
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([source.url])
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .alert(naming?.renaming == nil ? "New Collection" : "Rename Collection",
               isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $collectionName)
            Button(naming?.renaming == nil ? "Create" : "Rename") {
                if let id = naming?.renaming {
                    store.renameCollection(id, to: collectionName)
                } else if let id = store.createCollection(named: collectionName) {
                    store.navigate(to: .library(.collection(id)))
                }
                naming = nil
            }
            .disabled(collectionName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { naming = nil }
        }
        .searchable(text: $store.searchText, placement: .sidebar, prompt: "Search materials")
        .overlay {
            if store.sources.isEmpty {
                ContentUnavailableView {
                    Label("No Sources", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Import or drop images to start.")
                }
                .padding(.top, 120)
            } else if !store.searchText.isEmpty && store.filteredSources.isEmpty {
                ContentUnavailableView.search(text: store.searchText)
            }
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Images…", systemImage: "photo.badge.plus") { store.showSourceImporter = true }
                    Button("Capture File…", systemImage: "camera.badge.ellipsis") { store.showBundleImporter = true }
                    Button("Catalog…", systemImage: "list.bullet.rectangle") { store.showCatalogImporter = true }
                } label: {
                    Label("Import", systemImage: "plus")
                }
                .help("Import images, captures or a catalog")
            }
        }
        .accessibilityLabel("Material sources")
    }
}

private struct SourceRow: View {
    let source: MaterialSource

    var body: some View {
        HStack(spacing: 10) {
            SourceThumbnail(url: source.url, side: 30, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.displayName)
                    .lineLimit(1)
                Text(source.category)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(source.displayName), \(source.category)")
    }
}

/// Asynchronously loaded, cached thumbnail; decoding never runs on the main thread.
struct SourceThumbnail: View {
    let url: URL
    var side: CGFloat
    var cornerRadius: CGFloat = 8
    var maxPixel: Int? = nil
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        }
        .task(id: url) {
            let pixels = maxPixel ?? Int(side * 2)
            let loaded = await Task.detached(priority: .utility) {
                ThumbnailCache.shared.image(for: url, maxPixel: pixels)
            }.value
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
        .accessibilityHidden(true)
    }
}

extension MaterialSourceOrigin {
    var sectionTitle: String {
        switch self {
        case .imported: "Imported"
        case .cameraInbox: "Camera Captures"
        case .catalog: "Catalog"
        }
    }
}
