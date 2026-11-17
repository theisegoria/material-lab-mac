import Foundation

/// A user-made group of captures (a capture can be in several).
struct LibraryCollection: Codable, Identifiable, Equatable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var members: [UUID] = []
    var created = Date()
}

/// Library organisation kept beside the captures (`<library root>/library.json`): favourites, tags and collections.
/// Captures themselves are untouched, so a missing or unreadable catalog only loses the organisation, never a photo.
struct LibraryCatalog: Codable, Equatable, Sendable {
    var version = 1
    var favourites: Set<UUID> = []
    /// Tags per capture, keyed by the capture ID's uuidString (readable JSON), in the order the user added them.
    var tagsByCapture: [String: [String]] = [:]
    var collections: [LibraryCollection] = []

    // MARK: Favourites

    func isFavourite(_ id: UUID) -> Bool { favourites.contains(id) }

    mutating func setFavourite(_ id: UUID, _ on: Bool) {
        if on { favourites.insert(id) } else { favourites.remove(id) }
    }

    mutating func toggleFavourite(_ id: UUID) { setFavourite(id, !isFavourite(id)) }

    // MARK: Tags

    func tags(for id: UUID) -> [String] { tagsByCapture[id.uuidString] ?? [] }

    /// Trims, drops empties and case-insensitive duplicates (the first spelling wins), keeping the order given.
    static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in tags {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(String(trimmed.prefix(40)))
        }
        return result
    }

    mutating func setTags(_ tags: [String], for id: UUID) {
        let normalized = Self.normalizedTags(tags)
        tagsByCapture[id.uuidString] = normalized.isEmpty ? nil : normalized
    }

    mutating func addTag(_ tag: String, to id: UUID) { setTags(tags(for: id) + [tag], for: id) }

    mutating func removeTag(_ tag: String, from id: UUID) {
        setTags(tags(for: id).filter { $0.caseInsensitiveCompare(tag) != .orderedSame }, for: id)
    }

    /// Every tag in use, most used first, then alphabetically. Each tag appears once, in its most used spelling
    /// (ties prefer lower case, so the result does not depend on dictionary order).
    var allTags: [String] {
        var spellings: [String: [String: Int]] = [:]
        for tags in tagsByCapture.values {
            for tag in tags { spellings[tag.lowercased(), default: [:]][tag, default: 0] += 1 }
        }
        let ranked = spellings.values.map { variants -> (spelling: String, count: Int) in
            let best = variants.max { a, b in a.value != b.value ? a.value < b.value : a.key < b.key }!
            return (best.key, variants.values.reduce(0, +))
        }
        return ranked.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            let order = $0.spelling.localizedStandardCompare($1.spelling)
            return order != .orderedSame ? order == .orderedAscending : $0.spelling > $1.spelling
        }.map(\.spelling)
    }

    // MARK: Collections

    func collection(_ id: UUID) -> LibraryCollection? { collections.first { $0.id == id } }

    func collections(containing capture: UUID) -> [LibraryCollection] {
        collections.filter { $0.members.contains(capture) }
    }

    /// Creates a collection (an existing one with the same name, ignoring case, is reused) and returns its ID;
    /// nil for an empty name.
    @discardableResult
    mutating func createCollection(named name: String, with members: [UUID] = []) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let id: UUID
        if let existing = collections.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            id = existing.id
        } else {
            id = UUID()
            collections.append(LibraryCollection(id: id, name: String(trimmed.prefix(60))))
        }
        for member in members { add(member, to: id) }
        return id
    }

    mutating func renameCollection(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[index].name = String(trimmed.prefix(60))
    }

    mutating func deleteCollection(_ id: UUID) { collections.removeAll { $0.id == id } }

    mutating func add(_ capture: UUID, to collection: UUID) {
        guard let index = collections.firstIndex(where: { $0.id == collection }),
              !collections[index].members.contains(capture) else { return }
        collections[index].members.append(capture)
    }

    mutating func remove(_ capture: UUID, from collection: UUID) {
        guard let index = collections.firstIndex(where: { $0.id == collection }) else { return }
        collections[index].members.removeAll { $0 == capture }
    }

    // MARK: Housekeeping

    /// Removes everything recorded about a deleted capture (collections themselves stay, even when emptied).
    mutating func forget(_ capture: UUID) {
        favourites.remove(capture)
        tagsByCapture[capture.uuidString] = nil
        for index in collections.indices { collections[index].members.removeAll { $0 == capture } }
    }

    /// Drops captures that no longer exist on disk; returns true when anything changed.
    @discardableResult
    mutating func prune(keeping existing: Set<UUID>) -> Bool {
        let before = self
        favourites.formIntersection(existing)
        tagsByCapture = tagsByCapture.filter { key, _ in UUID(uuidString: key).map(existing.contains) ?? false }
        for index in collections.indices { collections[index].members.removeAll { !existing.contains($0) } }
        return before != self
    }
}

/// A smart filter in the library's filter bar.
enum LibrarySmartFilter: Hashable, Sendable {
    case all, favourites, recent
    case category(String)
    case collection(UUID)
    case tag(String)

    /// "Recent" means edited within this many days.
    static let recentDays = 7
}

enum LibrarySort: String, CaseIterable, Identifiable, Sendable {
    case modified, captured, name, category
    var id: String { rawValue }
    var title: String { L(englishTitle) }
    var englishTitle: String {
        switch self {
        case .modified: "Last Edited"
        case .captured: "Date Captured"
        case .name: "Name"
        case .category: "Category"
        }
    }
    var symbol: String {
        switch self {
        case .modified: "clock"
        case .captured: "camera"
        case .name: "textformat"
        case .category: "folder"
        }
    }
}

/// Search text, smart filter and sort order applied to the library's entries.
struct LibraryQuery: Equatable, Sendable {
    var search = ""
    var filter: LibrarySmartFilter = .all
    var sort: LibrarySort = .modified

    func apply(to entries: [CaptureLibrary.Entry], catalog: LibraryCatalog, now: Date = Date()) -> [CaptureLibrary.Entry] {
        let recentCutoff = now.addingTimeInterval(-Double(LibrarySmartFilter.recentDays) * 86_400)
        let terms = search.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return entries.filter { entry in
            switch filter {
            case .all: break
            case .favourites: guard catalog.isFavourite(entry.id) else { return false }
            case .recent: guard entry.modified >= recentCutoff else { return false }
            case .category(let category):
                guard Self.normalizedCategory(entry.category).caseInsensitiveCompare(category) == .orderedSame
                else { return false }
            case .collection(let id): guard catalog.collection(id)?.members.contains(entry.id) == true else { return false }
            case .tag(let tag):
                guard catalog.tags(for: entry.id).contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame })
                else { return false }
            }
            guard !terms.isEmpty else { return true }
            let haystack = ([entry.label, entry.category, entry.recipe.preset.title, entry.recipe.preset.englishTitle]
                + catalog.tags(for: entry.id) + catalog.collections(containing: entry.id).map(\.name))
                .joined(separator: " ").lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
        .sorted { a, b in
            switch sort {
            case .modified: return a.modified > b.modified
            case .captured: return a.capturedAt != b.capturedAt ? a.capturedAt > b.capturedAt : a.modified > b.modified
            case .name:
                let order = Self.displayName(a.label).localizedStandardCompare(Self.displayName(b.label))
                return order != .orderedSame ? order == .orderedAscending : a.modified > b.modified
            case .category:
                let order = Self.normalizedCategory(a.category).localizedStandardCompare(Self.normalizedCategory(b.category))
                return order != .orderedSame ? order == .orderedAscending : a.modified > b.modified
            }
        }
    }

    /// Distinct categories in use, alphabetically ("uncategorized" last).
    static func categories(in entries: [CaptureLibrary.Entry]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in entries {
            let category = normalizedCategory(entry.category)
            if seen.insert(category.lowercased()).inserted { result.append(category) }
        }
        return result.sorted { a, b in
            if a == uncategorized { return false }
            if b == uncategorized { return true }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    static let uncategorized = "uncategorized"

    static func normalizedCategory(_ category: String) -> String {
        let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? uncategorized : trimmed
    }

    static func displayName(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L("Untitled material") : trimmed
    }
}
