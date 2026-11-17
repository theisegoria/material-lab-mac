import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// The .pbrmaterial package declared in Info.plist.
    static let pbrMaterial = UTType(exportedAs: "io.materiallab.pbrmaterial", conformingTo: .package)
}

/// One derived map dragged out as a PNG file, written by the same encoder as Save Map as PNG and the bundle export.
struct MapPNGTransfer: Transferable, Sendable {
    let map: MaterialMapData
    let fileName: String

    init(material: DerivedMaterial, kind: MaterialMapKind, map: MaterialMapData) {
        self.map = map
        fileName = "\(MaterialBundle.exportSlug(material.source.semanticLabel))_\(kind.exportedName).png"
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .png) { item in
            let url = try DragStaging.makeFolder().appendingPathComponent(item.fileName)
            try MaterialBundle.writePNG(item.map, to: url)
            return SentTransferredFile(url)
        }
        .suggestedFileName { $0.fileName }
    }
}

/// The whole material dragged out as a .pbrmaterial bundle (the same export as Export Material, without extra formats).
struct MaterialBundleTransfer: Transferable, Sendable {
    let material: DerivedMaterial

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pbrMaterial) { item in
            SentTransferredFile(try MaterialBundle.export(item.material, into: DragStaging.makeFolder()))
        }
        .suggestedFileName { "\(MaterialBundle.exportSlug($0.material.source.semanticLabel)).pbrmaterial" }
    }
}

/// Temporary folders for files handed to drags; folders from earlier drags are removed after a day.
enum DragStaging {
    static var root: URL { FileManager.default.temporaryDirectory.appendingPathComponent("MaterialLab-Drag", isDirectory: true) }

    static func makeFolder() throws -> URL {
        let fm = FileManager.default
        if let old = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) {
            let cutoff = Date().addingTimeInterval(-24 * 3600)
            for folder in old where ((try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast) < cutoff {
                try? fm.removeItem(at: folder)
            }
        }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
