import Foundation

/// Turns a finished export folder ("<label> material/" from `CaptureStore.makeMaterialExport`) into items for the
/// share sheet: plain files as they are, folders (the .pbrmaterial bundle, multi-file targets) as .zip archives so
/// Mail, Messages and other apps can take them. AirDrop and Save to Files get the same archives.
enum MaterialSharing {
    /// What to share from an export.
    enum Selection: Hashable, Sendable {
        /// The .pbrmaterial bundle and every chosen format.
        case everything
        /// The .pbrmaterial bundle alone.
        case bundleOnly
        /// One export target's output alone (its id).
        case target(String)

        /// The export targets to write for this selection (nil keeps the remembered choice).
        var exportTargets: Set<String>? {
            switch self {
            case .everything: nil
            case .bundleOnly: []
            case .target(let id): [id]
            }
        }
    }

    /// Share items for `folder`, written to a sibling "share" folder in the same temporary staging directory (so
    /// removing the staging directory removes them too). With `.target`, the bundle is left out.
    static func items(forExportFolder folder: URL, selection: Selection) throws -> [URL] {
        let fm = FileManager.default
        let children = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                  options: [.skipsHiddenFiles])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let wanted = children.filter { url in
            let isBundle = url.pathExtension == "pbrmaterial"
            switch selection {
            case .everything: return true
            case .bundleOnly: return isBundle
            case .target: return !isBundle
            }
        }
        let shareFolder = folder.deletingLastPathComponent().appending(path: "share", directoryHint: .isDirectory)
        try fm.createDirectory(at: shareFolder, withIntermediateDirectories: true)
        // The bundle first: it is the material itself.
        return try wanted.sorted { ($0.pathExtension == "pbrmaterial" ? 0 : 1) < ($1.pathExtension == "pbrmaterial" ? 0 : 1) }.map { url in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDirectory ? try zip(url, into: shareFolder) : url
        }
    }

    /// Archives a folder with the system's own zip (`NSFileCoordinator` reading `.forUploading`).
    static func zip(_ directory: URL, into destinationFolder: URL) throws -> URL {
        let destination = destinationFolder.appending(path: directory.lastPathComponent + ".zip")
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: directory, options: .forUploading, error: &coordinationError) { zipped in
            do {
                try? FileManager.default.removeItem(at: destination)
                // The coordinator deletes its archive when the block returns.
                try FileManager.default.copyItem(at: zipped, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError { throw error }
        return destination
    }
}
