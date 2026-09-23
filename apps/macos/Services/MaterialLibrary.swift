import Foundation

enum MaterialLibraryError: LocalizedError {
    case invalidCatalog
    case noUsableSources

    var errorDescription: String? {
        switch self {
        case .invalidCatalog: "The selected catalog is not a supported material catalog."
        case .noUsableSources: "No source images referenced by this catalog are available."
        }
    }
}

enum MaterialLibrary {
    private struct StoredSource: Codable {
        let path: String
        let label: String
        let category: String
    }

    private struct StoredMetadata: Codable {
        let label: String
        let category: String
    }

    static var appSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Material Lab", isDirectory: true)
    }

    static var inbox: URL { appSupport.appendingPathComponent("Inbox", isDirectory: true) }
    private static var importedFolder: URL { appSupport.appendingPathComponent("Sources", isDirectory: true) }
    private static var savedSourcesURL: URL { appSupport.appendingPathComponent("sources.json") }
    private static var metadataURL: URL { appSupport.appendingPathComponent("source-metadata.json") }

    static func prepareDirectories() throws {
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: importedFolder, withIntermediateDirectories: true)
    }

    static func copyImportedSource(_ input: URL) throws -> MaterialSource {
        try prepareDirectories()
        let name = "\(UUID().uuidString.lowercased())-\(input.lastPathComponent)"
        let destination = importedFolder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: input, to: destination)
        return MaterialSource(
            id: "imported:\(destination.path)",
            url: destination,
            semanticLabel: input.deletingPathExtension().lastPathComponent,
            category: "uncategorized",
            origin: .imported,
            reviewStatus: "unreviewed",
            originalEnvelopeURL: nil
        )
    }

    static func loadSavedSources() -> [MaterialSource] {
        guard let data = try? Data(contentsOf: savedSourcesURL),
              let stored = try? JSONDecoder().decode([StoredSource].self, from: data)
        else { return [] }
        return stored.compactMap { item in
            let url = URL(fileURLWithPath: item.path)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return MaterialSource(
                id: "imported:\(url.standardizedFileURL.path)",
                url: url, semanticLabel: item.label, category: item.category,
                origin: .imported, reviewStatus: "unreviewed",
                originalEnvelopeURL: nil
            )
        }
    }

    static func saveImportedSources(_ sources: [MaterialSource]) throws {
        try prepareDirectories()
        let stored = sources.filter { $0.origin == .imported }.map {
            StoredSource(path: $0.url.path, label: $0.semanticLabel, category: $0.category)
        }
        try JSONEncoder().encode(stored).write(to: savedSourcesURL, options: .atomic)
    }

    static func applyMetadataOverrides(_ sources: [MaterialSource]) -> [MaterialSource] {
        guard let data = try? Data(contentsOf: metadataURL),
              let records = try? JSONDecoder().decode([String: StoredMetadata].self, from: data)
        else { return sources }
        return sources.map { source in
            guard let item = records[source.id] else { return source }
            return MaterialSource(
                id: source.id, url: source.url,
                semanticLabel: item.label, category: item.category,
                origin: source.origin, reviewStatus: source.reviewStatus,
                originalEnvelopeURL: source.originalEnvelopeURL
            )
        }
    }

    static func saveMetadataOverride(_ source: MaterialSource) throws {
        try prepareDirectories()
        let existing = (try? Data(contentsOf: metadataURL)).flatMap {
            try? JSONDecoder().decode([String: StoredMetadata].self, from: $0)
        } ?? [:]
        var records = existing
        records[source.id] = StoredMetadata(label: source.semanticLabel, category: source.category)
        try JSONEncoder().encode(records).write(to: metadataURL, options: .atomic)
    }

    static func importCatalog(_ catalogURL: URL) throws -> [MaterialSource] {
        let data = try Data(contentsOf: catalogURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = (root["items"] as? [[String: Any]]) ??
                            (root["materials"] as? [[String: Any]]) ??
                            (root["assets"] as? [[String: Any]])
        else { throw MaterialLibraryError.invalidCatalog }
        let folder = catalogURL.deletingLastPathComponent()
        let declaredRoot = root["asset_root"] as? String
        let projectRoot: URL? = declaredRoot.flatMap { assetRoot in
            let parts = assetRoot.split(separator: "/")
            var cursor = folder
            for _ in parts { cursor.deleteLastPathComponent() }
            return cursor
        }
        let fm = FileManager.default
        let sources: [MaterialSource] = entries.compactMap { entry in
            let identifier = (entry["id"] as? String) ??
                             (entry["material_id"] as? String) ??
                             (entry["semantic_label"] as? String) ?? ""
            guard !identifier.isEmpty else { return nil }
            let candidates = [
                entry["project_relative_path"] as? String,
                entry["project_path"] as? String,
                entry["relative_path"] as? String,
                entry["file"] as? String,
                entry["path"] as? String
            ].compactMap { $0 }
            let url = candidates.flatMap { path -> [URL] in
                if path.hasPrefix("/") { return [URL(fileURLWithPath: path)] }
                return [folder.appendingPathComponent(path),
                        projectRoot?.appendingPathComponent(path)].compactMap { $0 }
            }.first(where: { fm.fileExists(atPath: $0.path) })
            guard let url else { return nil }
            return MaterialSource(
                id: "catalog:\(identifier)", url: url,
                semanticLabel: (entry["material_label"] as? String) ??
                               (entry["semantic_label"] as? String) ?? identifier,
                category: (entry["category"] as? String) ?? "uncategorized",
                origin: .catalog,
                reviewStatus: (entry["review_status"] as? String) ??
                              (entry["qa_status"] as? String) ?? "unreviewed",
                originalEnvelopeURL: nil
            )
        }
        guard !sources.isEmpty else { throw MaterialLibraryError.noUsableSources }
        return sources
    }

    static func loadInbox() -> [MaterialSource] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: inbox, includingPropertiesForKeys: nil
        ) else { return [] }
        return files.filter { $0.pathExtension.lowercased() == "png" }.map { url in
            let envelope = url.deletingPathExtension().appendingPathExtension("pbrcapture")
            let metadata = (try? Data(contentsOf: envelope)).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            let label = (metadata?["semanticLabel"] as? String) ?? url.deletingPathExtension().lastPathComponent
            let category = (metadata?["category"] as? String) ?? "captured"
            return MaterialSource(
                id: "capture:\(url.deletingPathExtension().lastPathComponent)",
                url: url, semanticLabel: label, category: category,
                origin: .cameraInbox, reviewStatus: "capture estimate",
                originalEnvelopeURL: FileManager.default.fileExists(atPath: envelope.path) ? envelope : nil
            )
        }.sorted { $0.semanticLabel.localizedStandardCompare($1.semanticLabel) == .orderedAscending }
    }
}
