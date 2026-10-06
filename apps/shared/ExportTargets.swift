import Foundation

/// An engine or interchange export of a .pbrmaterial bundle, described and written by the core's shared exporter
/// (PBRLabExport.h), so the CLI, the Mac app and the iOS app produce identical files. Shared by both apps.
struct ExportTarget: Identifiable, Hashable, Sendable {
    enum Group: String, CaseIterable, Sendable {
        case interchange = "Interchange"
        case engines = "Game engines"
        case tools = "3D tools"
    }

    let id: String
    let title: String
    let detail: String
    /// "glb" or "usdz" for single-file formats; nil when the export is a folder.
    let fileExtension: String?

    var group: Group {
        switch id {
        case "glb", "usdz", "materialx": .interchange
        case "blender", "substance": .tools
        default: .engines
        }
    }

    var symbol: String {
        switch id {
        case "glb", "materialx": "cube.transparent"
        case "usdz": "arkit"
        case "blender", "substance": "paintbrush.pointed"
        case "minecraft-labpbr": "square.grid.3x3.fill"
        case "roblox": "person.crop.square"
        default: "gamecontroller"
        }
    }

    /// Every target, in the core's display order.
    static let all: [ExportTarget] = (0..<PBRLabExportFormatCount()).compactMap { index in
        guard let format = PBRLabExportFormatAt(index)?.pointee else { return nil }
        return ExportTarget(id: String(cString: format.identifier), title: String(cString: format.title),
                            detail: String(cString: format.detail),
                            fileExtension: format.file_extension.map { String(cString: $0) })
    }

    static func named(_ ids: some Sequence<String>) -> [ExportTarget] {
        let wanted = Set(ids)
        return all.filter { wanted.contains($0.id) }
    }

    /// Where this target is written beside `bundle` (name.pbrmaterial → name.glb, or the folder name-unreal).
    func destination(beside bundle: URL) -> URL {
        let stem = bundle.deletingPathExtension().lastPathComponent
        let folder = bundle.deletingLastPathComponent()
        if let fileExtension { return folder.appending(path: "\(stem).\(fileExtension)") }
        return folder.appending(path: "\(stem)-\(id)", directoryHint: .isDirectory)
    }

    /// Writes this target beside `bundle`. Synchronous: call off the main actor.
    @discardableResult
    func export(bundle: URL) throws -> URL {
        let output = destination(beside: bundle)
        var error = [CChar](repeating: 0, count: 512)
        let ok = bundle.withUnsafeFileSystemRepresentation { bundlePath in
            output.withUnsafeFileSystemRepresentation { outputPath in
                PBRLabExportBundle(bundlePath, id, outputPath, &error, error.count)
            }
        }
        guard ok != 0 else { throw ExportTargetError(target: title, message: String(cString: error)) }
        return output
    }
}

struct ExportTargetError: LocalizedError {
    let target: String
    let message: String
    var errorDescription: String? { "\(target) export failed: \(message)" }
}

/// The targets chosen for export, remembered across launches.
enum ExportTargetPreference {
    private static let key = "materialLab.exportTargets"

    static func load() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? []).intersection(ExportTarget.all.map(\.id))
    }

    static func save(_ ids: Set<String>) {
        UserDefaults.standard.set(ids.sorted(), forKey: key)
    }
}
