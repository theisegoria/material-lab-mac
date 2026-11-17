import XCTest
@testable import MaterialCapture

final class LibraryCatalogTests: XCTestCase {
    private func entry(_ label: String, category: String = "wall", preset: MaterialPreset = .stone,
                       capturedDaysAgo: Double = 0, editedDaysAgo: Double = 0, now: Date) -> CaptureLibrary.Entry {
        CaptureLibrary.Entry(id: UUID(), label: label, category: category,
                             capturedAt: now.addingTimeInterval(-capturedDaysAgo * 86_400),
                             modified: now.addingTimeInterval(-editedDaysAgo * 86_400),
                             thumbnailURL: nil, recipe: MaterialRecipe(preset: preset))
    }

    func testTagsAreTrimmedDeduplicatedAndRankedByUse() {
        let a = UUID(), b = UUID()
        var catalog = LibraryCatalog()
        catalog.setTags(["  Outdoor ", "worn", "outdoor", "", "two   words"], for: a)
        XCTAssertEqual(catalog.tags(for: a), ["Outdoor", "worn", "two words"])
        catalog.addTag("WORN", to: b)
        catalog.addTag("client x", to: b)
        // "worn" is used twice and comes first; the first spelling wins.
        XCTAssertEqual(catalog.allTags.first, "worn")
        XCTAssertEqual(Set(catalog.allTags.map { $0.lowercased() }), ["outdoor", "worn", "two words", "client x"])
        catalog.removeTag("outdoor", from: a)
        XCTAssertEqual(catalog.tags(for: a), ["worn", "two words"])
        catalog.setTags([], for: b)
        XCTAssertTrue(catalog.tags(for: b).isEmpty)
        XCTAssertNil(catalog.tagsByCapture[b.uuidString])
    }

    func testCollectionsCreateReuseRenameMembershipAndDelete() throws {
        let a = UUID(), b = UUID()
        var catalog = LibraryCatalog()
        XCTAssertNil(catalog.createCollection(named: "   "))
        let kitchen = try XCTUnwrap(catalog.createCollection(named: "Kitchen", with: [a]))
        // Same name, other case: the existing collection is reused.
        XCTAssertEqual(catalog.createCollection(named: "kitchen", with: [b, a]), kitchen)
        XCTAssertEqual(catalog.collections.count, 1)
        XCTAssertEqual(catalog.collection(kitchen)?.members, [a, b])
        let client = try XCTUnwrap(catalog.createCollection(named: "Client"))
        catalog.add(a, to: client)
        XCTAssertEqual(catalog.collections(containing: a).map(\.name), ["Kitchen", "Client"])
        catalog.renameCollection(client, to: "  Client A ")
        XCTAssertEqual(catalog.collection(client)?.name, "Client A")
        catalog.renameCollection(client, to: "")
        XCTAssertEqual(catalog.collection(client)?.name, "Client A")
        catalog.remove(a, from: kitchen)
        XCTAssertEqual(catalog.collection(kitchen)?.members, [b])
        catalog.deleteCollection(kitchen)
        XCTAssertNil(catalog.collection(kitchen))
        XCTAssertEqual(catalog.collections(containing: a).map(\.id), [client])
    }

    func testFiltersSearchAndSorting() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let brick = entry("Red brick", category: "wall", capturedDaysAgo: 30, editedDaysAgo: 20, now: now)
        let oak = entry("Oak floor", category: "floor", preset: .organic, capturedDaysAgo: 2, editedDaysAgo: 1, now: now)
        let slate = entry("slate tile", category: "floor", capturedDaysAgo: 10, editedDaysAgo: 3, now: now)
        let untitled = entry("  ", category: "", capturedDaysAgo: 40, editedDaysAgo: 40, now: now)
        let entries = [brick, oak, slate, untitled]
        var catalog = LibraryCatalog()
        catalog.setFavourite(brick.id, true)
        catalog.toggleFavourite(slate.id)
        catalog.toggleFavourite(slate.id)
        catalog.setTags(["weathered", "outdoor"], for: brick.id)
        let project = try XCTUnwrap(catalog.createCollection(named: "Cabin project", with: [oak.id, slate.id]))

        func ids(_ query: LibraryQuery) -> [UUID] { query.apply(to: entries, catalog: catalog, now: now).map(\.id) }
        XCTAssertEqual(ids(LibraryQuery()), [oak.id, slate.id, brick.id, untitled.id])
        XCTAssertEqual(ids(LibraryQuery(filter: .favourites)), [brick.id])
        XCTAssertEqual(ids(LibraryQuery(filter: .recent)), [oak.id, slate.id])
        XCTAssertEqual(ids(LibraryQuery(filter: .category("FLOOR"))), [oak.id, slate.id])
        XCTAssertEqual(ids(LibraryQuery(filter: .category(LibraryQuery.uncategorized))), [untitled.id])
        XCTAssertEqual(ids(LibraryQuery(filter: .collection(project))), [oak.id, slate.id])
        XCTAssertEqual(ids(LibraryQuery(filter: .collection(UUID()))), [])
        XCTAssertEqual(ids(LibraryQuery(filter: .tag("Outdoor"))), [brick.id])
        // Search covers names, categories, tags and collection names; every word must match.
        XCTAssertEqual(ids(LibraryQuery(search: "weathered")), [brick.id])
        XCTAssertEqual(ids(LibraryQuery(search: "cabin")), [oak.id, slate.id])
        XCTAssertEqual(ids(LibraryQuery(search: "floor slate")), [slate.id])
        XCTAssertEqual(ids(LibraryQuery(search: "cabin", filter: .recent, sort: .name)), [oak.id, slate.id])
        XCTAssertEqual(ids(LibraryQuery(search: "nothing like this")), [])
        // Sorting.
        XCTAssertEqual(ids(LibraryQuery(sort: .captured)), [oak.id, slate.id, brick.id, untitled.id])
        XCTAssertEqual(ids(LibraryQuery(sort: .name)), [oak.id, brick.id, slate.id, untitled.id])
        XCTAssertEqual(ids(LibraryQuery(sort: .category)), [oak.id, slate.id, untitled.id, brick.id])
        XCTAssertEqual(LibraryQuery.categories(in: entries), ["floor", "wall", LibraryQuery.uncategorized])
    }

    @MainActor
    func testCatalogPersistsBesideCapturesAndForgetsDeletedCaptures() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "catalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = CaptureLibrary(root: root)
        XCTAssertEqual(library.loadCatalog(), LibraryCatalog())

        let store = CaptureStore(libraryDirectory: root)
        await store.receive(origin: .files, data: try XCTUnwrap(Self.swatch(.red)))
        let first = try XCTUnwrap(store.source?.id)
        await store.receive(origin: .files, data: try XCTUnwrap(Self.swatch(.blue)))
        let second = try XCTUnwrap(store.source?.id)
        store.updateCatalog { catalog in
            catalog.setFavourite(first, true)
            catalog.setTags(["brick", "red"], for: first)
            catalog.addTag("blue", to: second)
            catalog.createCollection(named: "Set", with: [first, second])
        }
        // Round trip through disk.
        let reloaded = CaptureLibrary(root: root).loadCatalog()
        XCTAssertEqual(reloaded, store.catalog)
        XCTAssertTrue(reloaded.isFavourite(first))
        XCTAssertEqual(reloaded.tags(for: first), ["brick", "red"])
        XCTAssertEqual(reloaded.collections.first?.members, [first, second])

        // Deleting a capture removes it from favourites, tags and collections, on disk too.
        await store.delete(first)
        for catalog in [store.catalog, CaptureLibrary(root: root).loadCatalog()] {
            XCTAssertFalse(catalog.isFavourite(first))
            XCTAssertTrue(catalog.tags(for: first).isEmpty)
            XCTAssertEqual(catalog.collections.first?.members, [second])
            XCTAssertEqual(catalog.tags(for: second), ["blue"])
        }

        // A capture folder removed behind the app's back is pruned on refresh.
        try FileManager.default.removeItem(at: library.directory(for: second))
        let fresh = CaptureStore(libraryDirectory: root)
        await fresh.refreshLibrary()
        XCTAssertTrue(fresh.catalog.tags(for: second).isEmpty)
        XCTAssertEqual(fresh.catalog.collections.first?.members, [])
        XCTAssertEqual(CaptureLibrary(root: root).loadCatalog(), fresh.catalog)

        // An unreadable catalog loses only the organisation (a library no store is using, so nothing rewrites it).
        let other = CaptureLibrary(root: root.appending(path: "unreadable"))
        try FileManager.default.createDirectory(at: other.root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: other.catalogURL)
        XCTAssertEqual(other.loadCatalog(), LibraryCatalog())
    }

    private static func swatch(_ color: UIColor) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96), format: format).pngData { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
            UIColor.white.setFill()
            context.fill(CGRect(x: 20, y: 20, width: 30, height: 12))
        }
    }
}
