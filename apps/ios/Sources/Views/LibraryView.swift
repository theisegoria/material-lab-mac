import SwiftUI

/// The material library: every saved capture, searchable, with favourites, tags, collections, smart filters and
/// sorting. Tap to open; long-press (or swipe in the list layout) for the other actions.
struct LibraryView: View {
    @Bindable var store: CaptureStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var filter: LibrarySmartFilter = .all
    @AppStorage("library.sort") private var sortRaw = LibrarySort.modified.rawValue
    @AppStorage("library.layout") private var layoutRaw = Layout.grid.rawValue
    @AppStorage("library.hintDismissed") private var hintDismissed = false
    @State private var pendingDelete: CaptureLibrary.Entry?
    @State private var taggingEntry: CaptureLibrary.Entry?
    @State private var newCollectionMembers: [UUID]?
    @State private var newCollectionName = ""
    @State private var renamingCollection: LibraryCollection?
    @State private var renameText = ""
    @State private var pendingCollectionDelete: LibraryCollection?

    enum Layout: String { case grid, list }

    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .modified }
    private var layout: Layout { Layout(rawValue: layoutRaw) ?? .grid }
    private var query: LibraryQuery { LibraryQuery(search: search, filter: filter, sort: sort) }
    private var results: [CaptureLibrary.Entry] { query.apply(to: store.libraryEntries, catalog: store.catalog) }
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
                    library
                }
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: Text("Name, category, tag or collection"))
            .toolbar { toolbar }
            .confirmationDialog("Delete this capture?", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
            ), titleVisibility: .visible, presenting: pendingDelete) { entry in
                Button("Delete Capture", role: .destructive) {
                    Task { await store.delete(entry.id) }
                }
            } message: { _ in
                Text("The photo, crop and recipe are removed from this iPhone. Exported bundles are not affected.")
            }
            .confirmationDialog("Delete this collection?", isPresented: Binding(
                get: { pendingCollectionDelete != nil }, set: { if !$0 { pendingCollectionDelete = nil } }
            ), titleVisibility: .visible, presenting: pendingCollectionDelete) { collection in
                Button("Delete Collection", role: .destructive) {
                    store.updateCatalog { $0.deleteCollection(collection.id) }
                    if filter == .collection(collection.id) { filter = .all }
                }
            } message: { _ in
                Text("Only the collection is removed. Its captures stay in the library.")
            }
            .alert("New Collection", isPresented: Binding(
                get: { newCollectionMembers != nil }, set: { if !$0 { newCollectionMembers = nil } }
            )) {
                TextField("Collection name", text: $newCollectionName)
                Button("Cancel", role: .cancel) { newCollectionName = "" }
                Button("Create") {
                    let members = newCollectionMembers ?? []
                    var created: UUID?
                    store.updateCatalog { created = $0.createCollection(named: newCollectionName, with: members) }
                    if members.isEmpty, let created { filter = .collection(created) }
                    newCollectionName = ""
                }
            } message: {
                Text("Group materials by project, room or client. A capture can be in several collections.")
            }
            .alert("Rename Collection", isPresented: Binding(
                get: { renamingCollection != nil }, set: { if !$0 { renamingCollection = nil } }
            )) {
                TextField("Collection name", text: $renameText)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    if let collection = renamingCollection {
                        store.updateCatalog { $0.renameCollection(collection.id, to: renameText) }
                    }
                }
            }
            .sheet(item: $taggingEntry) { entry in
                TagEditorSheet(store: store, entry: entry)
                    .presentationDetents([.medium, .large])
            }
            .task { await store.refreshLibrary() }
            .onChange(of: store.catalog.collections) {
                // A deleted collection can no longer filter.
                if case .collection(let id) = filter, store.catalog.collection(id) == nil { filter = .all }
            }
        }
    }

    // MARK: Library

    private var library: some View {
        VStack(spacing: 0) {
            LibraryFilterBar(store: store, filter: $filter)
            if !hintDismissed {
                FirstRunHint(dismiss: { withAnimation(.snappy) { hintDismissed = true } })
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if results.isEmpty {
                emptyResults
                    .frame(maxHeight: .infinity)
            } else if layout == .grid {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(results) { entry in
                            Button { open(entry) } label: {
                                LibraryCell(entry: entry, isCurrent: entry.id == store.source?.id,
                                            isFavourite: store.catalog.isFavourite(entry.id),
                                            tags: store.catalog.tags(for: entry.id))
                            }
                            .buttonStyle(.plain)
                            .contextMenu { actions(for: entry) }
                            .accessibilityIdentifier("library-entry")
                            .accessibilityActions { accessibilityActions(for: entry) }
                        }
                    }
                    .padding(16)
                }
            } else {
                List {
                    ForEach(results) { entry in
                        Button { open(entry) } label: {
                            LibraryRow(entry: entry, isCurrent: entry.id == store.source?.id,
                                       isFavourite: store.catalog.isFavourite(entry.id),
                                       tags: store.catalog.tags(for: entry.id))
                        }
                        .buttonStyle(.plain)
                        .contextMenu { actions(for: entry) }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            let favourite = store.catalog.isFavourite(entry.id)
                            Button {
                                store.updateCatalog { $0.toggleFavourite(entry.id) }
                            } label: {
                                Label(favourite ? "Unfavourite" : "Favourite",
                                      systemImage: favourite ? "heart.slash" : "heart")
                            }
                            .tint(.pink)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { pendingDelete = entry } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button { taggingEntry = entry } label: {
                                Label("Tags", systemImage: "tag")
                            }
                            .tint(.indigo)
                        }
                        .accessibilityIdentifier("library-entry")
                        .accessibilityActions { accessibilityActions(for: entry) }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .animation(.snappy, value: filter)
        .animation(.snappy, value: results.map(\.id))
    }

    @ViewBuilder
    private var emptyResults: some View {
        if !search.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            switch filter {
            case .favourites:
                ContentUnavailableView {
                    Label("No Favourites Yet", systemImage: "heart")
                } description: {
                    Text("Long-press a material and choose Favourite to keep it here.")
                }
            case .recent:
                ContentUnavailableView {
                    Label("Nothing Recent", systemImage: "clock")
                } description: {
                    Text("Materials edited in the last 7 days appear here.")
                }
            case .collection:
                ContentUnavailableView {
                    Label("Empty Collection", systemImage: "rectangle.stack")
                } description: {
                    Text("Long-press a material and choose Add to Collection.")
                } actions: {
                    Button("Show All Materials") { filter = .all }
                        .buttonStyle(.glass)
                }
            default:
                ContentUnavailableView {
                    Label("No Matching Materials", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("Try another filter.")
                } actions: {
                    Button("Show All Materials") { filter = .all }
                        .buttonStyle(.glass)
                }
            }
        }
    }

    // MARK: Actions

    private func open(_ entry: CaptureLibrary.Entry) {
        Task {
            await store.open(entry.id)
            dismiss()
        }
    }

    @ViewBuilder
    private func actions(for entry: CaptureLibrary.Entry) -> some View {
        let favourite = store.catalog.isFavourite(entry.id)
        Button("Open", systemImage: "arrow.up.forward.app") { open(entry) }
        Button(favourite ? "Unfavourite" : "Favourite", systemImage: favourite ? "heart.slash" : "heart") {
            store.updateCatalog { $0.toggleFavourite(entry.id) }
        }
        Button("Edit Tags…", systemImage: "tag") { taggingEntry = entry }
        Menu("Add to Collection", systemImage: "rectangle.stack.badge.plus") {
            ForEach(store.catalog.collections) { collection in
                let member = collection.members.contains(entry.id)
                Button {
                    store.updateCatalog {
                        if member { $0.remove(entry.id, from: collection.id) } else { $0.add(entry.id, to: collection.id) }
                    }
                } label: {
                    Label { Text(verbatim: collection.name) } icon: {
                        Image(systemName: member ? "checkmark" : "rectangle.stack")
                    }
                }
            }
            Divider()
            Button("New Collection…", systemImage: "plus") {
                newCollectionName = ""
                newCollectionMembers = [entry.id]
            }
        }
        if case .collection(let id) = filter, let collection = store.catalog.collection(id) {
            Button("Remove from \(collection.name)", systemImage: "rectangle.stack.badge.minus") {
                store.updateCatalog { $0.remove(entry.id, from: id) }
            }
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = entry }
    }

    @ViewBuilder
    private func accessibilityActions(for entry: CaptureLibrary.Entry) -> some View {
        let favourite = store.catalog.isFavourite(entry.id)
        Button(favourite ? "Unfavourite" : "Favourite") { store.updateCatalog { $0.toggleFavourite(entry.id) } }
        Button("Edit Tags…") { taggingEntry = entry }
        Button("Delete") { pendingDelete = entry }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done", systemImage: "checkmark") { dismiss() }
                .accessibilityIdentifier("library-done")
        }
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("Sort By", selection: $sortRaw) {
                    ForEach(LibrarySort.allCases) { Label($0.title, systemImage: $0.symbol).tag($0.rawValue) }
                }
                Picker("Layout", selection: $layoutRaw) {
                    Label("Grid", systemImage: "square.grid.2x2").tag(Layout.grid.rawValue)
                    Label("List", systemImage: "list.bullet").tag(Layout.list.rawValue)
                }
                Divider()
                Button("New Collection…", systemImage: "rectangle.stack.badge.plus") {
                    newCollectionName = ""
                    newCollectionMembers = []
                }
                if case .collection(let id) = filter, let collection = store.catalog.collection(id) {
                    Button("Rename \(collection.name)…", systemImage: "pencil") {
                        renameText = collection.name
                        renamingCollection = collection
                    }
                    Button("Delete \(collection.name)…", systemImage: "trash", role: .destructive) {
                        pendingCollectionDelete = collection
                    }
                }
            } label: {
                Label("Sort and Organise", systemImage: "line.3.horizontal.decrease")
            }
            .accessibilityIdentifier("library-options")
        }
    }
}

// MARK: - Filter bar

private struct LibraryFilterBar: View {
    @Bindable var store: CaptureStore
    @Binding var filter: LibrarySmartFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    chip(Text("All"), symbol: "square.grid.2x2", value: .all)
                    chip(Text("Favourites"), symbol: "heart", value: .favourites)
                    chip(Text("Recent"), symbol: "clock", value: .recent)
                    ForEach(store.catalog.collections) { collection in
                        chip(Text(verbatim: collection.name), symbol: "rectangle.stack", value: .collection(collection.id))
                    }
                    ForEach(LibraryQuery.categories(in: store.libraryEntries), id: \.self) { category in
                        chip(Text(verbatim: category == LibraryQuery.uncategorized ? L("Uncategorized") : category.capitalized),
                             symbol: "folder", value: .category(category))
                    }
                    ForEach(store.catalog.allTags.prefix(12), id: \.self) { tag in
                        chip(Text(verbatim: "#\(tag)"), symbol: nil, value: .tag(tag))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filters")
    }

    private func chip(_ title: Text, symbol: String?, value: LibrarySmartFilter) -> some View {
        let selected = filter == value
        return Button {
            filter = selected && value != .all ? .all : value
        } label: {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: selected && value == .favourites ? "heart.fill" : symbol)
                        .accessibilityHidden(true)
                }
                title.lineLimit(1)
            }
            .font(.subheadline.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(minHeight: 36)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(selected ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .capsule)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("Filters the library")
    }
}

// MARK: - First-run hint

private struct FirstRunHint: View {
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.tap")
                .font(.title3)
                .foregroundStyle(.tint)
                .padding(.top, 12)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Organise your materials")
                    .font(.subheadline.weight(.semibold))
                Text("Long-press a material to favourite it, add tags or put it in a collection. Search finds names, categories and tags.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 12)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss tip")
        }
        .padding(.leading, 14)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }
}

// MARK: - Cells

private struct LibraryThumbnail: View {
    let entry: CaptureLibrary.Entry

    var body: some View {
        Group {
            if let url = entry.thumbnailURL, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
                    .overlay { Image(systemName: "photo").font(.title2).foregroundStyle(.secondary) }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct TagStrip: View {
    let tags: [String]

    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: 4) {
                ForEach(tags.prefix(2), id: \.self) { tag in
                    Text(verbatim: "#\(tag)")
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.14), in: .capsule)
                }
                if tags.count > 2 {
                    Text(verbatim: "+\(tags.count - 2)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private func entrySubtitle(_ entry: CaptureLibrary.Entry) -> String {
    "\(entry.recipe.preset.title) · \(entry.modified.formatted(.relative(presentation: .named)))"
}

private func entryAccessibilityValue(isFavourite: Bool, isCurrent: Bool, tags: [String]) -> String {
    var parts: [String] = []
    if isFavourite { parts.append(L("Favourite")) }
    if isCurrent { parts.append(L("Open now")) }
    if !tags.isEmpty { parts.append(String(format: L("Tags: %@"), tags.joined(separator: ", "))) }
    return parts.joined(separator: ", ")
}

private struct LibraryCell: View {
    let entry: CaptureLibrary.Entry
    let isCurrent: Bool
    let isFavourite: Bool
    let tags: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LibraryThumbnail(entry: entry)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 18))
                .overlay(alignment: .topTrailing) {
                    if isCurrent {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .tint)
                            .padding(8)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if isFavourite {
                        Image(systemName: "heart.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.pink)
                            .padding(7)
                            .glassEffect(.regular, in: .circle)
                            .padding(6)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(LibraryQuery.displayName(entry.label))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(entrySubtitle(entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                TagStrip(tags: tags)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityValue(entryAccessibilityValue(isFavourite: isFavourite, isCurrent: isCurrent, tags: tags))
        .accessibilityHint("Opens this capture. More actions are in the actions rotor or by long-pressing.")
    }
}

private struct LibraryRow: View {
    let entry: CaptureLibrary.Entry
    let isCurrent: Bool
    let isFavourite: Bool
    let tags: [String]
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 56

    var body: some View {
        HStack(spacing: 12) {
            LibraryThumbnail(entry: entry)
                .frame(width: side, height: side)
                .clipShape(.rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(LibraryQuery.displayName(entry.label))
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if isFavourite {
                        Image(systemName: "heart.fill").font(.caption).foregroundStyle(.pink)
                    }
                }
                Text(entrySubtitle(entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                TagStrip(tags: tags)
            }
            Spacer(minLength: 0)
            if isCurrent {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityValue(entryAccessibilityValue(isFavourite: isFavourite, isCurrent: isCurrent, tags: tags))
        .accessibilityHint("Opens this capture. Swipe for more actions.")
    }
}

// MARK: - Tag editor

private struct TagEditorSheet: View {
    @Bindable var store: CaptureStore
    let entry: CaptureLibrary.Entry
    @Environment(\.dismiss) private var dismiss
    @State private var newTag = ""
    @FocusState private var fieldFocused: Bool

    private var tags: [String] { store.catalog.tags(for: entry.id) }
    private var suggestions: [String] {
        store.catalog.allTags.filter { tag in !tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Add a tag", text: $newTag)
                            .focused($fieldFocused)
                            .submitLabel(.done)
                            .textInputAutocapitalization(.never)
                            .onSubmit(add)
                            .accessibilityIdentifier("library-tag-field")
                        Button("Add Tag", systemImage: "plus.circle.fill", action: add)
                            .labelStyle(.iconOnly)
                            .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } footer: {
                    Text("Tags are searchable and appear as filters in the library, for example “outdoor”, “worn” or a client name.")
                }
                if !tags.isEmpty {
                    Section("On This Material") {
                        ForEach(tags, id: \.self) { tag in
                            Label { Text(verbatim: tag) } icon: { Image(systemName: "tag.fill") }
                        }
                        .onDelete { offsets in
                            let removed = offsets.map { tags[$0] }
                            store.updateCatalog { catalog in
                                for tag in removed { catalog.removeTag(tag, from: entry.id) }
                            }
                        }
                    }
                }
                if !suggestions.isEmpty {
                    Section("Used Elsewhere") {
                        ForEach(suggestions, id: \.self) { tag in
                            Button {
                                store.updateCatalog { $0.addTag(tag, to: entry.id) }
                            } label: {
                                Label { Text(verbatim: tag) } icon: { Image(systemName: "plus") }
                            }
                            .accessibilityHint("Adds this tag")
                        }
                    }
                }
            }
            .navigationTitle(LibraryQuery.displayName(entry.label))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { add(); dismiss() }
                }
            }
            .onAppear { fieldFocused = tags.isEmpty }
        }
    }

    private func add() {
        let tag = newTag
        guard !tag.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.updateCatalog { $0.addTag(tag, to: entry.id) }
        newTag = ""
    }
}
