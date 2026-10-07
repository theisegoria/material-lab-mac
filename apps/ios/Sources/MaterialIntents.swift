import AppIntents
import CoreGraphics
import Foundation
import ImageIO

/// Shortcuts and Spotlight: derive a material from a photo and export it, without opening the app.
struct DeriveMaterialIntent: AppIntent {
    static let title: LocalizedStringResource = "Derive PBR Material"
    static let description = IntentDescription(
        "Turns a photo into a PBR material: a .pbrmaterial bundle with every map, plus any export formats you choose.")
    static let openAppWhenRun = false

    @Parameter(title: "Photo", supportedContentTypes: [.image])
    var photo: IntentFile

    @Parameter(title: "Material", description: "A starting recipe such as Red brick or Brushed steel.")
    var material: MaterialPresetEntity?

    @Parameter(title: "Export Formats", default: [])
    var formats: [ExportFormatEntity]

    @Parameter(title: "Name")
    var name: String?

    @Parameter(title: "Resolution", default: 2048, inclusiveRange: (512, 4096))
    var resolution: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Derive a material from \(\.$photo)") {
            \.$material
            \.$formats
            \.$name
            \.$resolution
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let label = (name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? photo.filename.split(separator: ".").first.map(String.init) ?? "Material"
        guard let source = CGImageSourceCreateWithData(photo.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CaptureError.invalidImage }
        var recipe = MaterialRecipe(preset: .stone)
        if let preset = material.flatMap({ LibraryPreset.named($0.id) }) { recipe = recipe.applyingLibraryPreset(preset) }
        let size = [512, 1024, 2048, 4096].last { $0 <= resolution } ?? 2048
        let targets = ExportTarget.named(formats.map(\.id))
        let quad = PerspectiveQuad.centeredSquare(for: CGSize(width: image.width, height: image.height))
        let folder = try await Task.detached(priority: .userInitiated) { () throws -> URL in
            let derived = try MaterialProcessor.derive(image: image, quad: quad, resolution: size, recipe: recipe)
            let output = FileManager.default.temporaryDirectory
                .appending(path: "derive-\(UUID().uuidString)/\(IntentOutput.slug(label)) material", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let identity = MaterialBundleWriter.Identity(label: label, category: "uncategorized", origin: .files,
                                                         captureMode: "estimated-albedo-files")
            let bundle = try MaterialBundleWriter.write(derived, identity: identity, into: output, name: IntentOutput.slug(label))
            for target in targets { try target.export(bundle: bundle) }
            return output
        }.value
        return .result(value: try IntentOutput.files(in: folder))
    }
}

struct MaterialCaptureShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: DeriveMaterialIntent(),
                    phrases: ["Derive a material with \(.applicationName)", "Make a PBR material in \(.applicationName)"],
                    shortTitle: "Derive Material", systemImageName: "square.stack.3d.up")
    }
}
