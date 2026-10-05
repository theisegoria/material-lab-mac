import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Every capture the user has made, one directory each (`<root>/<capture id>/`), laid out exactly as
/// `CapturePersistence` writes it, plus a small thumbnail. A `current` file names the capture that was open
/// when the app last ran. Photos never leave the app sandbox and are protected while the device is locked.
final class CaptureLibrary: Sendable {
    struct Entry: Identifiable, Sendable, Equatable {
        let id: UUID
        let label: String
        let category: String
        let capturedAt: Date
        let modified: Date
        let thumbnailURL: URL?
        let recipe: MaterialRecipe
    }

    let root: URL
    init(root: URL) { self.root = root }

    static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "Captures", directoryHint: .isDirectory)
    }
    /// Where builds before the library kept their single capture.
    static var legacyDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "CurrentCapture", directoryHint: .isDirectory)
    }

    private var currentURL: URL { root.appending(path: "current") }

    func directory(for id: UUID) -> URL { root.appending(path: id.uuidString, directoryHint: .isDirectory) }
    func persistence(for id: UUID) -> CapturePersistence { CapturePersistence(directory: directory(for: id)) }
    func thumbnailURL(for id: UUID) -> URL { directory(for: id).appending(path: "thumbnail.jpg") }

    var currentID: UUID? {
        get {
            (try? String(contentsOf: currentURL, encoding: .utf8))
                .flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }

    func setCurrent(_ id: UUID?) {
        guard let id else { try? FileManager.default.removeItem(at: currentURL); return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? Data(id.uuidString.utf8).write(to: currentURL, options: .atomic)
    }

    /// Captures with a readable state, most recently edited first.
    func entries() -> [Entry] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return children.compactMap { folder -> Entry? in
            guard let id = UUID(uuidString: folder.lastPathComponent) else { return nil }
            let stateURL = folder.appending(path: "state.json")
            guard let data = try? Data(contentsOf: stateURL),
                  let state = try? decoder.decode(CapturePersistence.State.self, from: data) else { return nil }
            let modified = (try? stateURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? state.capturedAt
            let thumbnail = thumbnailURL(for: id)
            return Entry(id: id, label: state.semanticLabel, category: state.category, capturedAt: state.capturedAt,
                         modified: modified, thumbnailURL: fm.fileExists(atPath: thumbnail.path) ? thumbnail : nil,
                         recipe: state.recipe)
        }
        .sorted { $0.modified > $1.modified }
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory(for: id))
        if currentID == id { setCurrent(nil) }
    }

    /// Writes a small square JPEG preview of the capture (from its albedo).
    func saveThumbnail(_ image: CGImage, for id: UUID) {
        let side = 320
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side),
                                               format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        let data = renderer.jpegData(withCompressionQuality: 0.82) { _ in
            UIImage(cgImage: image).draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        let folder = directory(for: id)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try? data.write(to: thumbnailURL(for: id), options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    /// Moves a capture saved by a pre-library build into the library and makes it current.
    func migrateLegacy(from legacy: URL = CaptureLibrary.legacyDirectory) {
        let fm = FileManager.default
        let stateURL = legacy.appending(path: "state.json")
        guard let data = try? Data(contentsOf: stateURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(CapturePersistence.State.self, from: data) else {
            try? fm.removeItem(at: legacy)
            return
        }
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = directory(for: state.id)
        if !fm.fileExists(atPath: destination.path) { try? fm.moveItem(at: legacy, to: destination) }
        try? fm.removeItem(at: legacy)
        if currentID == nil { setCurrent(state.id) }
    }
}
