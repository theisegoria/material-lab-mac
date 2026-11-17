import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Per-material library facts the user owns: tags, favourite and when it was last edited.
struct LibraryEntry: Codable, Equatable, Sendable {
    var tags: [String] = []
    var favourite = false
    var edited: Date?
    /// Bumped whenever a new thumbnail is written, so views reload it.
    var thumbnailVersion = 0
}

/// A user-defined group of materials (a material may belong to several).
struct LibraryCollection: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var members: [String] = []
}

/// Everything the library home stores beside the existing sources, recipes and metadata files.
struct LibraryMetadata: Codable, Equatable, Sendable {
    var entries: [String: LibraryEntry] = [:]
    var collections: [LibraryCollection] = []
    /// Catalog entries removed from the library (their files belong to the catalog and are never touched).
    var hiddenCatalogIDs: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = (try? c.decode([String: LibraryEntry].self, forKey: .entries)) ?? [:]
        collections = (try? c.decode([LibraryCollection].self, forKey: .collections)) ?? []
        hiddenCatalogIDs = (try? c.decode([String].self, forKey: .hiddenCatalogIDs)) ?? []
    }

    func entry(_ id: String) -> LibraryEntry { entries[id] ?? LibraryEntry() }

    /// Every tag in use, sorted for menus.
    var allTags: [String] {
        Set(entries.values.flatMap(\.tags)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// Smart filters and collections shown by the library home (and as sidebar rows).
enum LibraryFilter: Hashable, Sendable {
    case all
    case favourites
    case recent
    case category(String)
    case tag(String)
    case collection(UUID)

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .favourites: "star"
        case .recent: "clock"
        case .category: "folder"
        case .tag: "tag"
        case .collection: "rectangle.stack"
        }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case name, category, recent, kind
    var id: String { rawValue }
    var title: String { L(englishTitle) }
    var englishTitle: String {
        switch self {
        case .name: "Name"
        case .category: "Category"
        case .recent: "Recently Edited"
        case .kind: "Kind"
        }
    }
}

extension MaterialLibrary {
    private static var libraryURL: URL { appSupport.appendingPathComponent("library.json") }
    static var thumbnailFolder: URL { appSupport.appendingPathComponent("Thumbnails", isDirectory: true) }

    static func loadLibraryMetadata() -> LibraryMetadata {
        guard let data = try? Data(contentsOf: libraryURL),
              let metadata = try? JSONDecoder().decode(LibraryMetadata.self, from: data) else { return LibraryMetadata() }
        return metadata
    }

    static func saveLibraryMetadata(_ metadata: LibraryMetadata) throws {
        try prepareDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: libraryURL, options: .atomic)
    }

    /// The rendered library thumbnail for a source (it may not exist yet).
    static func thumbnailURL(for sourceID: String) -> URL {
        let name = MaterialEngine.sha256Hex(Data(sourceID.utf8)).prefix(24)
        return thumbnailFolder.appendingPathComponent("\(name).png")
    }

    static func writeThumbnail(_ image: CGImage, for sourceID: String) throws {
        try FileManager.default.createDirectory(at: thumbnailFolder, withIntermediateDirectories: true)
        let url = thumbnailURL(for: sourceID)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw MaterialBundleError.exportFailed("thumbnail encoder") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MaterialBundleError.exportFailed("thumbnail encoder") }
    }

    static func removeThumbnail(for sourceID: String) {
        try? FileManager.default.removeItem(at: thumbnailURL(for: sourceID))
    }

    /// Moves a source's own files to the Trash: imported copies and camera captures. Catalog files are never touched.
    static func trashFiles(of source: MaterialSource) throws {
        let fm = FileManager.default
        switch source.origin {
        case .imported:
            try fm.trashItem(at: source.url, resultingItemURL: nil)
        case .cameraInbox:
            let folder = source.url.deletingLastPathComponent()
            if folder.standardizedFileURL != inbox.standardizedFileURL,
               folder.deletingLastPathComponent().standardizedFileURL == inbox.standardizedFileURL {
                try fm.trashItem(at: folder, resultingItemURL: nil)
            } else {
                // Legacy flat layout: <id>.png beside <id>.pbrcapture.
                try fm.trashItem(at: source.url, resultingItemURL: nil)
                if let envelope = source.originalEnvelopeURL, fm.fileExists(atPath: envelope.path) {
                    try fm.trashItem(at: envelope, resultingItemURL: nil)
                }
            }
        case .catalog:
            break
        }
    }
}

/// Downscales an image for the library grid (aspect-fill crop to a square).
func librarySquareThumbnail(_ image: CGImage, side: Int) -> CGImage? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.interpolationQuality = .high
    let scale = CGFloat(side) / CGFloat(min(image.width, image.height))
    let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
    context.draw(image, in: CGRect(x: (CGFloat(side) - width) / 2, y: (CGFloat(side) - height) / 2, width: width, height: height))
    return context.makeImage()
}
