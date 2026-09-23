import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

struct MaterialAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    init(title: String = "Material Lab", message: String) {
        self.title = title
        self.message = message
    }
}

enum SidebarDestination: Hashable {
    case source(String)
    case inbox
    case link
}

enum CanvasMode: String, CaseIterable, Identifiable {
    case map, relit, compare, tile, shaded3D
    var id: String { rawValue }

    var title: String {
        switch self {
        case .map: "Map"
        case .relit: "Relit"
        case .compare: "Compare"
        case .tile: "Tile"
        case .shaded3D: "3D"
        }
    }

    var symbol: String {
        switch self {
        case .map: "photo"
        case .relit: "sun.max"
        case .compare: "square.split.2x1"
        case .tile: "square.grid.3x3"
        case .shaded3D: "cube"
        }
    }
}

@MainActor
@Observable
final class MaterialLabStore {
    var sources: [MaterialSource] = []
    var destination: SidebarDestination = .inbox
    private(set) var selectedSourceID: String?
    var searchText = ""
    var recipe = MaterialEngine.defaultRecipe(for: .flat) {
        didSet { recipeDidChange(from: oldValue) }
    }
    var selectedMap: MaterialMapKind = .albedo
    var canvasMode: CanvasMode = .map
    var derived: DerivedMaterial?
    var derivationSerial = 0
    var progress: Float = 0
    var batchProgress: Float = 0
    var status = "Import a source image or material catalog to begin."
    var derivationError: String?
    var isDeriving = false
    var isBatching = false
    var isExporting = false
    var isImporting = false
    var autoDerive = UserDefaults.standard.object(forKey: "materialLab.autoDerive") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoDerive, forKey: "materialLab.autoDerive")
            if autoDerive, !derivedIsCurrent { scheduleDerive() }
        }
    }
    var showInspector = true
    var lightAzimuth: Float = -2.35
    var lightElevation: Float = 0.62
    var showSourceImporter = false
    var showCatalogImporter = false
    var showBundleImporter = false
    var showReliefImporter = false
    var showHeightImporter = false
    var alert: MaterialAlert?
    var lastExportURL: URL?
    var includeUnreviewedBatch = false
    var metadataEditorSource: MaterialSource?
    let link = LocalLinkService()

    @ObservationIgnored private var started = false
    @ObservationIgnored private var recipesBySource: [String: MaterialRecipe] = [:]
    @ObservationIgnored private var suppressRecipeObserver = false
    @ObservationIgnored private var deriveControl: DerivationControl?
    @ObservationIgnored private var batchControl: DerivationControl?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var deriveGeneration = 0
    @ObservationIgnored private var pendingMetadataSources: [MaterialSource] = []

    // MARK: - Derived state

    var selectedSource: MaterialSource? {
        sources.first { $0.id == selectedSourceID }
    }

    /// The most recent derivation for the selected source (may lag behind recipe edits).
    var currentMaterial: DerivedMaterial? {
        guard let derived, derived.source.id == selectedSourceID else { return nil }
        return derived
    }

    var derivedIsCurrent: Bool {
        guard let material = currentMaterial else { return false }
        return material.recipe == recipe && material.source == selectedSource
    }

    var availableMaps: [MaterialMapKind] {
        guard let material = currentMaterial else { return [] }
        return MaterialMapKind.allCases.filter { material.maps[$0] != nil }
    }

    var canDerive: Bool { selectedSource != nil && !isBatching }

    var canExport: Bool { exportBlocker == nil }

    /// Plain-language reason export is unavailable, or nil when it can proceed.
    var exportBlocker: String? {
        if isExporting { return "An export is already in progress." }
        if isBatching { return "Wait for the batch to finish before exporting." }
        guard selectedSource != nil else { return "Select a source to export." }
        guard currentMaterial != nil else { return "Derive maps before exporting." }
        if isDeriving || !derivedIsCurrent { return "Maps are updating to match the recipe. Export when derivation finishes." }
        return nil
    }

    var filteredSources: [MaterialSource] {
        guard !searchText.isEmpty else { return sources }
        return sources.filter {
            $0.semanticLabel.localizedCaseInsensitiveContains(searchText) ||
            $0.category.localizedCaseInsensitiveContains(searchText)
        }
    }

    var inboxCount: Int { sources.filter { $0.origin == .cameraInbox }.count }

    var eligibleBatchSources: [MaterialSource] {
        filteredSources.filter { source in
            if includeUnreviewedBatch { return true }
            let status = source.reviewStatus.lowercased()
            return status.contains("reviewed") && !status.contains("unreviewed") ||
                   status.contains("approved")
        }
    }

    // MARK: - Lifecycle

    func bootstrap() {
        guard !started else { return }
        started = true
        do {
            try MaterialLibrary.prepareDirectories()
            MaterialLibrary.removeStaleStaging()
            link.onImported = { [weak self] source in
                guard let self else { return }
                self.sources.append(source)
                self.deduplicateAndSort()
                self.selectSource(source.id)
                self.status = "Capture imported from iPhone and checksum verified."
            }
            sources = MaterialLibrary.loadSavedSources() + MaterialLibrary.loadInbox()
            if let savedCatalog = UserDefaults.standard.string(forKey: "materialLab.catalogPath") {
                let url = URL(fileURLWithPath: savedCatalog)
                if FileManager.default.fileExists(atPath: url.path) {
                    sources += (try? MaterialLibrary.importCatalog(url)) ?? []
                }
            }
            sources = MaterialLibrary.applyMetadataOverrides(sources)
            deduplicateAndSort()
            status = sources.isEmpty
                ? "Import a source image or material catalog to begin."
                : "\(sources.count) sources ready."
            if let first = sources.first { selectSource(first.id) }
        } catch {
            alert = MaterialAlert(message: error.localizedDescription)
        }
    }

    // MARK: - Navigation

    func navigate(to destination: SidebarDestination) {
        self.destination = destination
        if case .source(let id) = destination { selectSource(id) }
    }

    /// The single entry point for changing the selected source. It restores that source's
    /// own recipe (including its relief mask and height override) so nothing leaks between sources.
    func selectSource(_ id: String?) {
        if let id, destination != .source(id) { destination = .source(id) }
        guard selectedSourceID != id else { return }
        debounceTask?.cancel()
        deriveControl?.cancel()
        selectedSourceID = id
        derived = nil
        derivationError = nil
        guard let id, let source = selectedSource else { return }
        let remembered = recipesBySource[id]
        setRecipeSilently(remembered ?? MaterialEngine.defaultRecipe(for: .flat))
        if remembered == nil, source.origin == .cameraInbox, let envelope = source.originalEnvelopeURL {
            // Seed from the capture's own recipe (read off the main thread; envelopes can be large).
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let seeded = MaterialBundle.recipe(fromCaptureEnvelope: envelope) else { return }
                await self?.applySeededRecipe(seeded, for: id)
            }
        }
        if autoDerive { deriveSelected() }
    }

    private func applySeededRecipe(_ seeded: MaterialRecipe, for id: String) {
        guard selectedSourceID == id, recipesBySource[id] == nil else { return }
        recipesBySource[id] = seeded
        setRecipeSilently(seeded)
        if autoDerive { deriveSelected() }
    }

    func selectMap(_ kind: MaterialMapKind) {
        guard currentMaterial == nil || currentMaterial?.maps[kind] != nil else { return }
        selectedMap = kind
        if canvasMode == .relit || canvasMode == .shaded3D { canvasMode = .map }
    }

    func selectMap(atShortcutIndex index: Int) {
        let maps = availableMaps.isEmpty ? MaterialMapKind.allCases : availableMaps
        guard maps.indices.contains(index) else { return }
        selectMap(maps[index])
    }

    func toggleCompare() {
        canvasMode = canvasMode == .compare ? .map : .compare
    }

    // MARK: - Recipe

    private func setRecipeSilently(_ value: MaterialRecipe) {
        suppressRecipeObserver = true
        recipe = value
        suppressRecipeObserver = false
    }

    private func recipeDidChange(from oldValue: MaterialRecipe) {
        guard !suppressRecipeObserver, recipe != oldValue else { return }
        if let id = selectedSourceID { recipesBySource[id] = recipe }
        if autoDerive { scheduleDerive() }
    }

    func choosePreset(_ preset: MaterialPreset) {
        var next = MaterialEngine.defaultRecipe(for: preset)
        next.reliefMaskURL = recipe.reliefMaskURL
        next.heightOverrideURL = recipe.heightOverrideURL
        next.normalYDown = recipe.normalYDown
        recipe = next
    }

    func resetRecipe() {
        choosePreset(recipe.preset)
    }

    // MARK: - Derivation

    /// Debounced live re-derivation: in-flight work is cancelled immediately, the new
    /// derivation starts once edits pause for ~150 ms.
    func scheduleDerive() {
        guard selectedSource != nil, !isBatching else { return }
        deriveControl?.cancel()
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.deriveSelected()
        }
    }

    func deriveSelected() {
        debounceTask?.cancel()
        debounceTask = nil
        guard let source = selectedSource, !isBatching else { return }
        deriveControl?.cancel()
        deriveGeneration += 1
        let generation = deriveGeneration
        let chosenRecipe = recipe
        let control = DerivationControl { [weak self] value in
            Task { @MainActor in
                guard let self, self.deriveGeneration == generation else { return }
                self.progress = value
            }
        }
        deriveControl = control
        progress = 0
        isDeriving = true
        derivationError = nil
        status = "Deriving maps for \(source.displayName)…"
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try MaterialEngine.derive(source: source, recipe: chosenRecipe, control: control) }
            await self?.finishDerivation(result, generation: generation, source: source, recipe: chosenRecipe)
        }
    }

    private func finishDerivation(
        _ result: Result<DerivedMaterial, Error>,
        generation: Int, source: MaterialSource, recipe chosenRecipe: MaterialRecipe
    ) {
        guard generation == deriveGeneration else { return }
        isDeriving = false
        deriveControl = nil
        switch result {
        case .success(let value):
            guard selectedSourceID == source.id else { return }
            derived = value
            derivationSerial += 1
            progress = 1
            if !value.maps.keys.contains(selectedMap) { selectedMap = .albedo }
            let ms = Int((value.duration * 1000).rounded())
            status = recipe == chosenRecipe
                ? "Derived \(value.maps.count) maps in \(ms) ms."
                : "Recipe changed while deriving; updating…"
            if recipe != chosenRecipe, autoDerive { scheduleDerive() }
        case .failure(let error):
            if case MaterialEngineError.cancelled = error { return }
            derivationError = error.localizedDescription
            status = "Derivation failed: \(error.localizedDescription)"
        }
    }

    func cancel() {
        debounceTask?.cancel()
        deriveControl?.cancel()
        batchControl?.cancel()
        status = "Cancelling after the current processing step…"
    }

    // MARK: - Export

    func exportSelected() {
        if let blocker = exportBlocker {
            status = blocker
            NSSound.beep()
            return
        }
        guard let derived = currentMaterial, let destination = chooseDestination() else { return }
        isExporting = true
        status = "Exporting validated PNG maps and manifest…"
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try MaterialBundle.export(derived, into: destination) }
            await self?.finishExport(result)
        }
    }

    private func finishExport(_ result: Result<URL, Error>) {
        isExporting = false
        switch result {
        case .success(let url):
            lastExportURL = url
            status = "Exported \(url.lastPathComponent)."
        case .failure(let error):
            status = "Export failed."
            alert = MaterialAlert(title: "Export Failed", message: error.localizedDescription)
        }
    }

    func batchDeriveVisible() {
        guard !isBatching, !isExporting, !eligibleBatchSources.isEmpty,
              let destination = chooseDestination() else { return }
        let targets = eligibleBatchSources
        let chosenRecipe = recipe
        debounceTask?.cancel()
        deriveControl?.cancel()
        isBatching = true
        batchProgress = 0
        status = "Starting batch of \(targets.count) source images…"
        let total = Float(max(1, targets.count))
        let counter = BatchCounter()
        let control = DerivationControl { [weak self] value in
            let completed = Float(counter.value)
            Task { @MainActor in self?.batchProgress = (completed + value) / total }
        }
        batchControl = control
        Task.detached(priority: .userInitiated) { [weak self] in
            var failures: [String] = []
            var finished = 0
            for source in targets {
                if !control.shouldContinue { break }
                do {
                    let result = try MaterialEngine.derive(source: source, recipe: chosenRecipe, control: control)
                    _ = try MaterialBundle.export(result, into: destination)
                    finished += 1
                } catch {
                    if !control.shouldContinue { break }
                    failures.append("\(source.displayName): \(error.localizedDescription)")
                }
                counter.increment()
                await self?.reportBatch(done: counter.value, of: targets.count)
            }
            await self?.finishBatch(exported: finished, failures: failures, completed: control.shouldContinue)
        }
    }

    private func reportBatch(done: Int, of total: Int) {
        batchProgress = Float(done) / Float(max(1, total))
        status = "Batch \(done) of \(total)"
    }

    private func finishBatch(exported: Int, failures: [String], completed: Bool) {
        isBatching = false
        batchControl = nil
        status = completed
            ? "Batch complete: \(exported) exported, \(failures.count) failed."
            : "Batch cancelled after \(exported) exports."
        if !failures.isEmpty {
            alert = MaterialAlert(title: "Some Sources Failed",
                                  message: failures.prefix(5).joined(separator: "\n"))
        }
    }

    // MARK: - Import

    func importSources(_ urls: [URL]) {
        var imported: [MaterialSource] = []
        var failures: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                imported.append(try MaterialLibrary.copyImportedSource(url))
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !imported.isEmpty {
            sources.append(contentsOf: imported)
            deduplicateAndSort()
            // Persist successes even when some files failed, so they survive relaunch.
            do {
                try MaterialLibrary.saveImportedSources(sources)
            } catch {
                failures.append("Could not save the source list: \(error.localizedDescription)")
            }
            selectSource(imported.last?.id)
            pendingMetadataSources.append(contentsOf: imported)
            presentNextMetadataEditor()
            status = "\(imported.count) source image(s) imported. Add semantic labels before exporting."
        }
        if !failures.isEmpty {
            alert = MaterialAlert(
                title: imported.isEmpty ? "Import Failed" : "Some Files Were Not Imported",
                message: failures.prefix(6).joined(separator: "\n")
            )
        }
    }

    func importCatalog(_ url: URL) {
        isImporting = true
        status = "Reading catalog…"
        Task.detached(priority: .userInitiated) { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let result = Result { MaterialLibrary.applyMetadataOverrides(try MaterialLibrary.importCatalog(url)) }
            await self?.finishCatalogImport(result, url: url)
        }
    }

    private func finishCatalogImport(_ result: Result<[MaterialSource], Error>, url: URL) {
        isImporting = false
        switch result {
        case .success(let catalog):
            sources.removeAll { $0.origin == .catalog }
            sources.append(contentsOf: catalog)
            deduplicateAndSort()
            UserDefaults.standard.set(url.path, forKey: "materialLab.catalogPath")
            selectSource(catalog.first?.id)
            status = "\(catalog.count) catalog entries available; review status remains visible."
        case .failure(let error):
            status = "Catalog import failed."
            alert = MaterialAlert(title: "Catalog Import Failed", message: error.localizedDescription)
        }
    }

    /// Reads, hashes, decodes and writes a capture off the main thread.
    func importCapture(_ url: URL) {
        isImporting = true
        status = "Verifying capture…"
        Task.detached(priority: .userInitiated) { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let result = Result { () throws -> MaterialSource in
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                if let size = attributes[.size] as? Int, size > MaterialBundle.maximumCaptureBytes {
                    throw MaterialBundleError.tooLarge
                }
                return try MaterialBundle.importCapture(try Data(contentsOf: url))
            }
            await self?.finishCaptureImport(result)
        }
    }

    private func finishCaptureImport(_ result: Result<MaterialSource, Error>) {
        isImporting = false
        switch result {
        case .success(let source):
            sources.append(source)
            deduplicateAndSort()
            selectSource(source.id)
            status = "Capture imported and checksum verified."
        case .failure(let error):
            status = "Capture import failed."
            alert = MaterialAlert(title: "Capture Import Failed", message: error.localizedDescription)
        }
    }

    /// Routes dropped files: images become sources, .pbrcapture files go to the inbox, JSON is a catalog.
    @discardableResult
    func handleDrop(_ urls: [URL]) -> Bool {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return false }
        let captures = files.filter { $0.pathExtension.lowercased() == "pbrcapture" }
        let catalogs = files.filter { $0.pathExtension.lowercased() == "json" }
        let images = files.filter { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return type.conforms(to: .image)
        }
        captures.forEach(importCapture)
        if let catalog = catalogs.first { importCatalog(catalog) }
        if !images.isEmpty { importSources(images) }
        let handled = !captures.isEmpty || !catalogs.isEmpty || !images.isEmpty
        if !handled { status = "Drop images, .pbrcapture files or a catalog JSON." }
        return handled
    }

    func refreshInbox() {
        sources.removeAll { $0.origin == .cameraInbox }
        sources.append(contentsOf: MaterialLibrary.applyMetadataOverrides(MaterialLibrary.loadInbox()))
        deduplicateAndSort()
        if let id = selectedSourceID, !sources.contains(where: { $0.id == id }) { selectSource(nil) }
        status = "\(inboxCount) camera capture(s) in the inbox."
    }

    // MARK: - Metadata

    func presentNextMetadataEditor() {
        guard metadataEditorSource == nil, !pendingMetadataSources.isEmpty else { return }
        metadataEditorSource = pendingMetadataSources.removeFirst()
    }

    func editMetadata(for source: MaterialSource) {
        metadataEditorSource = source
    }

    func updateSourceMetadata(id: String, label: String, category: String) {
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanLabel.isEmpty, cleanLabel.count <= 240,
              !cleanCategory.isEmpty, cleanCategory.count <= 120,
              let index = sources.firstIndex(where: { $0.id == id }) else {
            alert = MaterialAlert(message: "Enter a semantic label and category before saving.")
            return
        }
        let prior = sources[index]
        let updated = MaterialSource(
            id: prior.id, url: prior.url,
            semanticLabel: cleanLabel, category: cleanCategory,
            origin: prior.origin, reviewStatus: prior.reviewStatus,
            originalEnvelopeURL: prior.originalEnvelopeURL
        )
        do {
            try MaterialLibrary.saveMetadataOverride(updated)
            sources[index] = updated
            if updated.origin == .imported {
                try MaterialLibrary.saveImportedSources(sources)
            }
            deduplicateAndSort()
            if selectedSourceID == id {
                // Only the single-source derivation is affected; a running batch keeps going.
                if autoDerive { deriveSelected() } else { derived = nil }
            }
            status = "Semantic label saved for \(cleanLabel)."
        } catch {
            alert = MaterialAlert(message: error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private func deduplicateAndSort() {
        var seen = Set<String>()
        sources = sources.filter { seen.insert($0.id).inserted }
            .sorted {
                if $0.origin != $1.origin { return $0.origin.rawValue < $1.origin.rawValue }
                return $0.semanticLabel.localizedStandardCompare($1.semanticLabel) == .orderedAscending
            }
    }

    private func chooseDestination() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose an Export Folder"
        panel.message = "Material Lab creates a separate .pbrmaterial bundle for each source."
        panel.prompt = "Export Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

private final class BatchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
