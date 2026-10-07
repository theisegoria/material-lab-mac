import AppIntents
import Foundation

/// Shortcuts and Spotlight: derive a material from a photo and export it, without opening a window.
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

    static var parameterSummary: some ParameterSummary {
        Summary("Derive a material from \(\.$photo)") {
            \.$material
            \.$formats
            \.$name
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let label = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? photo.filename.split(separator: ".").first.map(String.init) ?? "Material"
        let work = FileManager.default.temporaryDirectory.appending(path: "derive-\(UUID().uuidString)", directoryHint: .isDirectory)
        let output = work.appending(path: "\(IntentOutput.slug(label)) material", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let input = work.appending(path: photo.filename.isEmpty ? "photo.png" : photo.filename)
        try photo.data.write(to: input)
        let source = MaterialSource(id: "intent:\(UUID().uuidString)", url: input, semanticLabel: label,
                                    category: "uncategorized", origin: .imported, reviewStatus: "reviewed",
                                    originalEnvelopeURL: nil)
        let recipe = material.flatMap { LibraryPreset.named($0.id) }.map(MaterialRecipe.library)
            ?? MaterialEngine.defaultRecipe(for: .stone)
        let targets = ExportTarget.named(formats.map(\.id))
        try await Task.detached(priority: .userInitiated) {
            let derived = try MaterialEngine.derive(source: source, recipe: recipe, control: DerivationControl(onProgress: { _ in }))
            let bundle = try MaterialBundle.export(derived, into: output)
            for target in targets { try target.export(bundle: bundle) }
        }.value
        return .result(value: try IntentOutput.files(in: output))
    }
}

struct MaterialLabShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: DeriveMaterialIntent(),
                    phrases: ["Derive a material with \(.applicationName)", "Make a PBR material in \(.applicationName)"],
                    shortTitle: "Derive Material", systemImageName: "square.stack.3d.up")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
