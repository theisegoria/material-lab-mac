import AppKit
import SwiftUI

/// The library home: every material as a thumbnail grid with smart filters, tags, favourites, collections,
/// sorting and multi-select batch actions. Double-click (or Return) opens a material's workspace.
struct LibraryHomeView: View {
    @Bindable var store: MaterialLabStore
    let filter: LibraryFilter
    @AppStorage("materialLab.librarySort") private var sort: LibrarySort = .name
    @AppStorage("materialLab.libraryTileSize") private var tileSize: Double = 180
    @State private var anchor: String?
    @State private var tagEditor: SelectionRequest?
    @State private var deleteRequest: SelectionRequest?
    @State private var newCollection: SelectionRequest?
    @State private var collectionName = ""
    @FocusState private var focused: Bool
    @Environment(\.openWindow) private var openWindow

    private var items: [MaterialSource] { store.libraryItems(filter, sort: sort) }
    private var selection: Set<String> { store.librarySelection.intersection(items.map(\.id)) }

    var body: some View {
        let items = self.items
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(count: items.count)
                filterChips
                if items.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize, maximum: tileSize * 1.45), spacing: 18)],
                              alignment: .leading, spacing: 20) {
                        ForEach(items) { source in
                            tile(source, in: items)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, selection.isEmpty ? 24 : 96)
        }
        .scrollContentBackground(.hidden)
        .background(.background)
        .contentShape(Rectangle())
        .onTapGesture { store.librarySelection = [] }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.return) {
            guard selection.count == 1, let id = selection.first else { return .ignored }
            store.navigate(to: .source(id))
            return .handled
        }
        .onDeleteCommand {
            if !selection.isEmpty { deleteRequest = SelectionRequest(ids: selection) }
        }
        .onExitCommand { store.librarySelection = [] }
        .overlay(alignment: .bottom) {
            if !selection.isEmpty {
                SelectionActionBar(store: store, selection: selection,
                                   tag: { tagEditor = SelectionRequest(ids: selection) },
                                   newCollection: { collectionName = ""; newCollection = SelectionRequest(ids: selection) },
                                   delete: { deleteRequest = SelectionRequest(ids: selection) })
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22), value: selection.isEmpty)
        .navigationTitle(store.libraryTitle(filter))
        .navigationSubtitle(subtitle(count: items.count))
        .toolbar { toolbarContent }
        .sheet(item: $tagEditor) { request in
            TagEditorSheet(store: store, ids: request.ids)
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleteRequest != nil },
                                                              set: { if !$0 { deleteRequest = nil } }),
                            presenting: deleteRequest) { request in
            Button(request.ids.count == 1 ? "Remove Material" : "Remove \(request.ids.count) Materials", role: .destructive) {
                store.deleteFromLibrary(request.ids)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Imported photos and camera captures move to the Trash. Catalog entries are hidden from the library; the catalog's files are not changed.")
        }
        .alert("New Collection", isPresented: Binding(get: { newCollection != nil },
                                                      set: { if !$0 { newCollection = nil } })) {
            TextField("Name, e.g. Kitchen tiles", text: $collectionName)
            Button("Create") {
                if let id = store.createCollection(named: collectionName, with: newCollection?.ids ?? []) {
                    store.status = "Created “\(store.collection(id)?.name ?? "")”."
                }
                newCollection = nil
            }
            .disabled(collectionName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { newCollection = nil }
        } message: {
            Text("Collections group materials without moving them. A material can be in several.")
        }
        .onAppear { focused = true }
        .accessibilityIdentifier("library-home")
    }

    private var deleteTitle: String {
        let count = deleteRequest?.ids.count ?? 0
        return count == 1 ? String(localized: "Remove this material from the library?")
                          : String(localized: "Remove \(count) materials from the library?")
    }

    private func subtitle(count: Int) -> String {
        let selected = selection.count
        if selected > 0 { return String(localized: "\(selected) of \(count) selected") }
        return count == 1 ? String(localized: "1 material") : String(localized: "\(count) materials")
    }

    // MARK: Header

    private func header(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(store.libraryTitle(filter), systemImage: filter.symbol)
                .font(.title2.weight(.semibold))
                .labelStyle(.titleAndIcon)
            Text("\(count)")
                .font(.title3.monospacedDigit())
                .foregroundStyle(.secondary)
            if !store.searchText.isEmpty {
                Button {
                    store.searchText = ""
                } label: {
                    Label("“\(store.searchText)”", systemImage: "xmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Clear the search")
            }
            Spacer(minLength: 0)
        }
    }

    /// Smart filters, categories and tags as one scrolling row of chips.
    private var filterChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip(.all)
                chip(.favourites)
                chip(.recent)
                if !store.libraryCategories.isEmpty {
                    Divider().frame(height: 18)
                    ForEach(store.libraryCategories, id: \.self) { chip(.category($0)) }
                }
                if !store.library.allTags.isEmpty {
                    Divider().frame(height: 18)
                    ForEach(store.library.allTags, id: \.self) { chip(.tag($0)) }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.never)
    }

    private func chip(_ value: LibraryFilter) -> some View {
        let selected = value == filter
        return Button {
            store.navigate(to: .library(value))
        } label: {
            Label(store.libraryTitle(value), systemImage: value.symbol)
                .labelStyle(.titleAndIcon)
                .font(.callout)
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(selected ? .accentColor : nil)
        .controlSize(.regular)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.sources.isEmpty {
            ContentUnavailableView {
                Label("Your Library Is Empty", systemImage: "square.grid.2x2")
            } description: {
                Text("Drop photos or textures onto this window, or import them to derive a full PBR material.")
            } actions: {
                Button("Import Images…") { store.showSourceImporter = true }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            }
        } else if !store.searchText.isEmpty {
            ContentUnavailableView.search(text: store.searchText)
        } else {
            ContentUnavailableView {
                Label("Nothing Here Yet", systemImage: filter.symbol)
            } description: {
                switch filter {
                case .favourites: Text("Click the star on a material to add it to Favourites.")
                case .recent: Text("Materials you edit in the last two weeks appear here.")
                case .collection: Text("Select materials in All Materials, then choose Add to Collection.")
                default: Text("No materials match this filter.")
                }
            }
        }
    }

    // MARK: Tiles

    private func tile(_ source: MaterialSource, in items: [MaterialSource]) -> some View {
        let entry = store.library.entry(source.id)
        return LibraryTile(source: source, entry: entry, isSelected: selection.contains(source.id),
                           isCurrent: store.selectedSource?.id == source.id && store.currentMaterial != nil,
                           toggleFavourite: { store.toggleFavourite(source.id) })
            .modifier(LibraryTileDrag(material: store.selectedSource?.id == source.id && store.canExport
                                      ? store.currentMaterial : nil))
            .onTapGesture { click(source.id, in: items) }
            .simultaneousGesture(TapGesture(count: 2).onEnded { store.navigate(to: .source(source.id)) })
            .contextMenu { contextMenu(for: source) }
    }

    /// Click selects one, ⌘-click toggles, ⇧-click extends from the last clicked material.
    private func click(_ id: String, in items: [MaterialSource]) {
        focused = true
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if store.librarySelection.contains(id) { store.librarySelection.remove(id) } else { store.librarySelection.insert(id) }
            anchor = id
        } else if flags.contains(.shift), let anchor, let from = items.firstIndex(where: { $0.id == anchor }),
                  let to = items.firstIndex(where: { $0.id == id }) {
            store.librarySelection.formUnion(items[min(from, to)...max(from, to)].map(\.id))
        } else {
            store.librarySelection = [id]
            anchor = id
        }
    }

    @ViewBuilder
    private func contextMenu(for source: MaterialSource) -> some View {
        let targets = selection.contains(source.id) ? selection : [source.id]
        Button("Open", systemImage: "arrow.up.forward.square") { store.navigate(to: .source(source.id)) }
        Button("Open in New Window", systemImage: "macwindow.badge.plus") {
            openWindow(id: "source-viewer", value: source.id)
        }
        Divider()
        let favourite = targets.allSatisfy { store.library.entry($0).favourite }
        Button(favourite ? "Remove from Favourites" : "Add to Favourites", systemImage: favourite ? "star.slash" : "star") {
            store.setFavourite(!favourite, for: targets)
        }
        Button("Tags…", systemImage: "tag") { tagEditor = SelectionRequest(ids: targets) }
        CollectionMenu(store: store, ids: targets) {
            collectionName = ""
            newCollection = SelectionRequest(ids: targets)
        }
        if case .collection(let id) = filter {
            Button("Remove from Collection", systemImage: "rectangle.stack.badge.minus") {
                store.removeFromCollection(id, ids: targets)
            }
        }
        Divider()
        Button("Edit Labels…", systemImage: "character.cursor.ibeam") { store.editMetadata(for: source) }
        Button("Show in Finder", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([source.url])
        }
        Button("Export…", systemImage: "square.and.arrow.up") { store.exportLibrarySelection(targets) }
        Divider()
        Button(targets.count == 1 ? "Remove from Library…" : "Remove \(targets.count) from Library…",
               systemImage: "trash", role: .destructive) {
            deleteRequest = SelectionRequest(ids: targets)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Sort By", selection: $sort) {
                    ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Picker("Thumbnail Size", selection: $tileSize) {
                    Text("Small").tag(140.0)
                    Text("Medium").tag(180.0)
                    Text("Large").tag(240.0)
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort the library and choose the thumbnail size")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Select All") { store.librarySelection = Set(items.map(\.id)) }
                    .disabled(items.isEmpty)
                Button("Deselect All") { store.librarySelection = [] }
                    .disabled(selection.isEmpty)
                if !store.library.hiddenCatalogIDs.isEmpty {
                    Divider()
                    Button("Restore Removed Catalog Entries") { store.restoreHiddenCatalogEntries() }
                }
            } label: {
                Label("Selection", systemImage: "checkmark.circle")
            }
            .help("Select materials for batch actions")
        }
    }
}

/// The open, exportable material drags out of the grid as its .pbrmaterial bundle.
private struct LibraryTileDrag: ViewModifier {
    let material: DerivedMaterial?

    func body(content: Content) -> some View {
        if let material {
            content.draggable(MaterialBundleTransfer(material: material)) {
                DragPreview(image: material.previews[.albedo],
                            title: "\(MaterialBundle.exportSlug(material.source.semanticLabel)).pbrmaterial")
            }
        } else {
            content
        }
    }
}

/// A set of material IDs a sheet or dialog acts on.
struct SelectionRequest: Identifiable {
    let id = UUID()
    let ids: Set<String>
}

/// Add-to-collection submenu shared by the context menu and the action bar.
private struct CollectionMenu: View {
    let store: MaterialLabStore
    let ids: Set<String>
    let newCollection: () -> Void

    var body: some View {
        Menu("Add to Collection", systemImage: "rectangle.stack.badge.plus") {
            ForEach(store.library.collections) { collection in
                Button(collection.name) { store.addToCollection(collection.id, ids: ids) }
            }
            if !store.library.collections.isEmpty { Divider() }
            Button("New Collection…", action: newCollection)
        }
    }
}

/// Floating glass bar of batch actions for the selection.
private struct SelectionActionBar: View {
    let store: MaterialLabStore
    let selection: Set<String>
    let tag: () -> Void
    let newCollection: () -> Void
    let delete: () -> Void

    var body: some View {
        let favourite = selection.allSatisfy { store.library.entry($0).favourite }
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Text("\(selection.count) selected")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: Capsule())
                Button {
                    store.setFavourite(!favourite, for: selection)
                } label: {
                    Label(favourite ? "Unfavourite" : "Favourite", systemImage: favourite ? "star.slash" : "star")
                }
                Button(action: tag) { Label("Tag…", systemImage: "tag") }
                Menu {
                    CollectionMenu(store: store, ids: selection, newCollection: newCollection)
                } label: {
                    Label("Collection", systemImage: "rectangle.stack.badge.plus")
                }
                .menuStyle(.button)
                Button {
                    store.exportLibrarySelection(selection)
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .disabled(store.isBatching || store.isExporting)
                .help("Export each selected material with its own recipe through the Batch Queue")
                Button(role: .destructive, action: delete) {
                    Label("Remove…", systemImage: "trash")
                }
                Button {
                    store.librarySelection = []
                } label: {
                    Image(systemName: "xmark")
                }
                .help("Deselect all (Esc)")
                .accessibilityLabel("Deselect all")
            }
            .buttonStyle(.glass)
            .labelStyle(.titleAndIcon)
            .fixedSize()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selection actions")
    }
}

/// One material: rendered thumbnail (or the source photo until it is derived), name, category and tags.
private struct LibraryTile: View {
    let source: MaterialSource
    let entry: LibraryEntry
    let isSelected: Bool
    let isCurrent: Bool
    let toggleFavourite: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            LibraryThumbnail(source: source, version: entry.thumbnailVersion)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                                      lineWidth: isSelected ? 3 : 0.5)
                }
                .overlay(alignment: .topTrailing) {
                    if entry.favourite || hovering {
                        Button(action: toggleFavourite) {
                            Image(systemName: entry.favourite ? "star.fill" : "star")
                                .foregroundStyle(entry.favourite ? .yellow : .secondary)
                                .padding(7)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular, in: Circle())
                        .padding(8)
                        .help(entry.favourite ? "Remove from Favourites" : "Add to Favourites")
                        .accessibilityLabel(entry.favourite ? "Remove from Favourites" : "Add to Favourites")
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    Image(systemName: source.origin.symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .glassEffect(.regular, in: Circle())
                        .padding(8)
                        .help(source.origin.sectionTitle)
                        .accessibilityHidden(true)
                }
                .shadow(color: .black.opacity(hovering ? 0.22 : 0.1), radius: hovering ? 10 : 5, y: hovering ? 5 : 2)
                .scaleEffect(hovering && !isSelected ? 1.015 : 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(source.displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if isCurrent {
                        Circle().fill(.tint).frame(width: 6, height: 6)
                            .help("Open in the workspace")
                            .accessibilityHidden(true)
                    }
                }
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(source.displayName), \(source.category)")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint("Double-click to open")
    }

    private var caption: String {
        let tags = entry.tags.prefix(3).map { "#\($0)" }.joined(separator: " ")
        return tags.isEmpty ? source.category : "\(source.category) · \(tags)"
    }
}

/// The rendered sphere thumbnail when one exists, else the source photo.
private struct LibraryThumbnail: View {
    let source: MaterialSource
    let version: Int
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            }
        }
        .task(id: "\(source.id)#\(version)") {
            let rendered = MaterialLibrary.thumbnailURL(for: source.id)
            let url = source.url
            let loaded = await Task.detached(priority: .utility) { () -> CGImage? in
                if let source = CGImageSourceCreateWithURL(rendered as CFURL, nil),
                   let image = CGImageSourceCreateImageAtIndex(source, 0, nil) { return image }
                return ThumbnailCache.shared.image(for: url, maxPixel: 480)
            }.value
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }
}

/// Adds tags to the selected materials and removes tags they carry.
private struct TagEditorSheet: View {
    let store: MaterialLabStore
    let ids: Set<String>
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var currentTags: [String] {
        var seen = Set<String>()
        return ids.flatMap { store.library.entry($0).tags }
            .filter { seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var suggestions: [String] {
        let current = Set(currentTags.map { $0.lowercased() })
        return store.library.allTags.filter { !current.contains($0.lowercased()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tags").font(.title2.weight(.semibold))
                Text(ids.count == 1 ? "Tags make materials easy to find with search and the tag filters."
                                    : "Tags you add apply to all \(ids.count) selected materials.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                TextField("Add tags, separated by commas", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(MaterialLabStore.parseTags(text).isEmpty)
            }
            if !currentTags.isEmpty {
                Text("Current").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                FlowTags(tags: currentTags, symbol: "xmark.circle.fill") { store.removeTag($0, from: ids) }
            }
            if !suggestions.isEmpty {
                Text("Used elsewhere").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                FlowTags(tags: suggestions, symbol: "plus.circle") { store.addTags($0, to: ids) }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Done") { add(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 280)
    }

    private func add() {
        guard !MaterialLabStore.parseTags(text).isEmpty else { return }
        store.addTags(text, to: ids)
        text = ""
    }
}

/// Tags as wrapping capsule buttons.
private struct FlowTags: View {
    let tags: [String]
    let symbol: String
    let action: (String) -> Void

    var body: some View {
        TagFlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Button {
                    action(tag)
                } label: {
                    Label("#\(tag)", systemImage: symbol)
                        .labelStyle(.titleAndIcon)
                        .font(.callout)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }
        }
    }
}

/// Wraps subviews onto new lines as space runs out.
private struct TagFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(indices: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] = []
        var current: [Int] = [], x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.isEmpty, x + size.width > width {
                rows.append((current, y, x - spacing, height))
                y += height + spacing
                current = []; x = 0; height = 0
            }
            current.append(index)
            x += size.width + spacing
            height = max(height, size.height)
        }
        if !current.isEmpty { rows.append((current, y, x - spacing, height)) }
        return rows
    }
}
