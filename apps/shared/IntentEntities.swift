import AppIntents
import Foundation

/// A material-library preset for Shortcuts parameters.
struct MaterialPresetEntity: AppEntity {
    let id: String
    let title: String
    let category: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Material"
    static let defaultQuery = MaterialPresetQuery()
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(category)")
    }

    init(_ preset: LibraryPreset) {
        id = preset.id
        title = preset.title
        category = preset.category
    }
}

struct MaterialPresetQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [MaterialPresetEntity] {
        LibraryPreset.all.filter { identifiers.contains($0.id) }.map(MaterialPresetEntity.init)
    }
    func suggestedEntities() async throws -> [MaterialPresetEntity] { LibraryPreset.all.map(MaterialPresetEntity.init) }
    func entities(matching string: String) async throws -> [MaterialPresetEntity] {
        LibraryPreset.all.filter { $0.title.localizedCaseInsensitiveContains(string) || $0.category.localizedCaseInsensitiveContains(string) }
            .map(MaterialPresetEntity.init)
    }
}

/// An export target for Shortcuts parameters.
struct ExportFormatEntity: AppEntity {
    let id: String
    let title: String
    let detail: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Export Format"
    static let defaultQuery = ExportFormatQuery()
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)", subtitle: "\(detail)") }

    init(_ target: ExportTarget) {
        id = target.id
        title = target.title
        detail = target.detail
    }
}

struct ExportFormatQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ExportFormatEntity] {
        ExportTarget.all.filter { identifiers.contains($0.id) }.map(ExportFormatEntity.init)
    }
    func suggestedEntities() async throws -> [ExportFormatEntity] { ExportTarget.all.map(ExportFormatEntity.init) }
}

/// Collects a finished export folder's top-level items as Shortcuts files.
enum IntentOutput {
    static func files(in folder: URL) throws -> [IntentFile] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { IntentFile(fileURL: $0, filename: $0.lastPathComponent) }
    }

    static func slug(_ label: String) -> String {
        let cleaned = label.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? "material" : String(cleaned.prefix(64))
    }
}
