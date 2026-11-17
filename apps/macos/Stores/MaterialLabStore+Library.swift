import AppKit
import Foundation

/// The library home: tags, favourites, collections, smart filters, thumbnails and batch actions on a selection.
extension MaterialLabStore {
    // MARK: Queries

    /// Sources shown for a filter (after the search text), sorted.
    func libraryItems(_ filter: LibraryFilter, sort: LibrarySort) -> [MaterialSource] {
        let recentCutoff = Date().addingTimeInterval(-14 * 24 * 3600)
        let items = filteredSources.filter { source in
            let entry = library.entry(source.id)
            switch filter {
            case .all: return true
            case .favourites: return entry.favourite
            case .recent: return (entry.edited ?? .distantPast) >= recentCutoff
            case .category(let category): return source.category.caseInsensitiveCompare(category) == .orderedSame
            case .tag(let tag): return entry.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
            case .collection(let id): return collection(id)?.members.contains(source.id) ?? false
            }
        }
        let byName: (MaterialSource, MaterialSource) -> Bool = {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        switch filter == .recent ? .recent : sort {
        case .name:
            return items.sorted(by: byName)
        case .category:
            return items.sorted {
                let order = $0.category.localizedStandardCompare($1.category)
                return order == .orderedSame ? byName($0, $1) : order == .orderedAscending
            }
        case .recent:
            return items.sorted {
                let a = library.entry($0.id).edited ?? .distantPast, b = library.entry($1.id).edited ?? .distantPast
                return a == b ? byName($0, $1) : a > b
            }
        case .kind:
            return items.sorted {
                $0.origin == $1.origin ? byName($0, $1) : $0.origin.rawValue < $1.origin.rawValue
            }
        }
    }

    /// Categories in use, for the filter chips.
    var libraryCategories: [String] {
        var seen = Set<String>()
        return sources.map(\.category)
            .filter { seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func collection(_ id: UUID) -> LibraryCollection? { library.collections.first { $0.id == id } }

    func libraryTitle(_ filter: LibraryFilter) -> String {
        switch filter {
        case .all: String(localized: "All Materials")
        case .favourites: String(localized: "Favourites")
        case .recent: String(localized: "Recently Edited")
        case .category(let category): category.capitalized
        case .tag(let tag): "#\(tag)"
        case .collection(let id): collection(id)?.name ?? String(localized: "Collection")
        }
    }

    // MARK: Entries

    func touchLibraryEntry(_ id: String) {
        guard !Self.isTransient(id) else { return }
        library.entries[id, default: LibraryEntry()].edited = Date()
        scheduleLibrarySave()
    }

    func setFavourite(_ favourite: Bool, for ids: Set<String>) {
        for id in ids where !Self.isTransient(id) { library.entries[id, default: LibraryEntry()].favourite = favourite }
        scheduleLibrarySave()
    }

    func toggleFavourite(_ id: String) {
        setFavourite(!library.entry(id).favourite, for: [id])
    }

    /// Adds comma-separated tags (trimmed, case-insensitively unique) to each material.
    func addTags(_ text: String, to ids: Set<String>) {
        let tags = Self.parseTags(text)
        guard !tags.isEmpty else { return }
        for id in ids where !Self.isTransient(id) {
            var entry = library.entry(id)
            for tag in tags where !entry.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                entry.tags.append(tag)
            }
            library.entries[id] = entry
        }
        scheduleLibrarySave()
        status = "Tagged \(ids.count) material\(ids.count == 1 ? "" : "s")."
    }

    func removeTag(_ tag: String, from ids: Set<String>) {
        for id in ids {
            library.entries[id]?.tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }
        scheduleLibrarySave()
    }

    static func parseTags(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
            .filter { !$0.isEmpty && $0.count <= 60 && seen.insert($0.lowercased()).inserted }
    }

    // MARK: Collections

    @discardableResult
    func createCollection(named name: String, with ids: Set<String> = []) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let collection = LibraryCollection(name: String(trimmed.prefix(80)), members: ids.sorted())
        library.collections.append(collection)
        scheduleLibrarySave()
        return collection.id
    }

    func renameCollection(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = library.collections.firstIndex(where: { $0.id == id }) else { return }
        library.collections[index].name = String(trimmed.prefix(80))
        scheduleLibrarySave()
    }

    func deleteCollection(_ id: UUID) {
        library.collections.removeAll { $0.id == id }
        if destination == .library(.collection(id)) { destination = .library(.all) }
        scheduleLibrarySave()
    }

    func addToCollection(_ id: UUID, ids: Set<String>) {
        guard let index = library.collections.firstIndex(where: { $0.id == id }) else { return }
        let existing = Set(library.collections[index].members)
        library.collections[index].members += ids.subtracting(existing).sorted()
        scheduleLibrarySave()
        status = "Added \(ids.count) material\(ids.count == 1 ? "" : "s") to “\(library.collections[index].name)”."
    }

    func removeFromCollection(_ id: UUID, ids: Set<String>) {
        guard let index = library.collections.firstIndex(where: { $0.id == id }) else { return }
        library.collections[index].members.removeAll { ids.contains($0) }
        scheduleLibrarySave()
    }

    // MARK: Delete

    /// Removes materials from the library. Imported copies and camera captures move to the Trash; catalog entries
    /// are hidden (the catalog's own files are never touched). Recipes stay so a restored file keeps its tuning.
    func deleteFromLibrary(_ ids: Set<String>) {
        var failures: [String] = []
        var removed = Set<String>()
        for source in sources where ids.contains(source.id) {
            do {
                try MaterialLibrary.trashFiles(of: source)
                if source.origin == .catalog { library.hiddenCatalogIDs.append(source.id) }
                removed.insert(source.id)
            } catch {
                failures.append("\(source.displayName): \(error.localizedDescription)")
            }
        }
        guard !removed.isEmpty || !failures.isEmpty else { return }
        sources.removeAll { removed.contains($0.id) }
        for id in removed {
            library.entries[id] = nil
            MaterialLibrary.removeThumbnail(for: id)
        }
        for index in library.collections.indices {
            library.collections[index].members.removeAll { removed.contains($0) }
        }
        librarySelection.subtract(removed)
        if let selected = selectedSourceID, removed.contains(selected) {
            selectSource(nil)
            destination = .library(.all)
        }
        do { try MaterialLibrary.saveImportedSources(sources) }
        catch { failures.append("Could not save the source list: \(error.localizedDescription)") }
        scheduleLibrarySave()
        status = "Removed \(removed.count) material\(removed.count == 1 ? "" : "s") from the library."
        if !failures.isEmpty {
            alert = MaterialAlert(title: "Some Materials Were Not Removed", message: failures.prefix(6).joined(separator: "\n"))
        }
    }

    /// Brings back catalog entries removed from the library by re-reading the saved catalog.
    func restoreHiddenCatalogEntries() {
        library.hiddenCatalogIDs = []
        scheduleLibrarySave()
        if let path = UserDefaults.standard.string(forKey: "materialLab.catalogPath"),
           FileManager.default.fileExists(atPath: path) {
            importCatalog(URL(fileURLWithPath: path))
        }
    }

    // MARK: Batch export of a selection

    /// Exports each selected material with its own recipe and the chosen formats, through the Batch Queue.
    func exportLibrarySelection(_ ids: Set<String>) {
        let chosen = sources.filter { ids.contains($0.id) }
        guard !chosen.isEmpty else { return }
        if isBatching || isExporting {
            status = "Wait for the current batch to finish before exporting."
            NSSound.beep()
            return
        }
        guard let destination = chooseDestination() else { return }
        let formats = ExportTarget.named(exportTargets)
        beginBatch(chosen.map {
            BatchItem(source: $0, recipe: recipe(for: $0), destination: destination, formats: formats, origin: .library)
        })
    }

    // MARK: Persistence and thumbnails

    func scheduleLibrarySave() {
        librarySaveTask?.cancel()
        librarySaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            do { try MaterialLibrary.saveLibraryMetadata(self.library) }
            catch { self.status = "Could not save the library: \(error.localizedDescription)" }
        }
    }

    /// Renders the material on a sphere for the library grid once edits settle (falls back to the albedo).
    func scheduleLibraryThumbnail(for material: DerivedMaterial) {
        let id = material.source.id
        guard !Self.isTransient(id) else { return }
        thumbnailTask?.cancel()
        thumbnailTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled, let self, !self.isDeriving,
                  self.currentMaterial?.previews[.albedo] === material.previews[.albedo] else { return }
            var image = await PreviewScene.renderSnapshot(material, shape: .sphere, side: 320,
                                                          background: CGColor(gray: 0.14, alpha: 1))
            if image == nil, let albedo = material.previews[.albedo] {
                image = librarySquareThumbnail(albedo, side: 320)
            }
            guard !Task.isCancelled, let image else { return }
            let written = await Task.detached(priority: .utility) {
                (try? MaterialLibrary.writeThumbnail(image, for: id)) != nil
            }.value
            if written { self.library.entries[id, default: LibraryEntry()].thumbnailVersion += 1 }
        }
    }

    /// Verification sources (SnapshotHarness, UI tests) and watch-folder photos never enter library metadata.
    static func isTransient(_ id: String) -> Bool {
        id.hasPrefix("snapshot:") || id.hasPrefix("uitest:") || id.hasPrefix("watch:")
    }
}
