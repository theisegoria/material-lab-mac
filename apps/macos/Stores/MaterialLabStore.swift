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
    /// The authored-map slot the shared image importer fills (nil when it is closed).
    var authoredImporter: AuthoredSlot?
    var alert: MaterialAlert?
    var lastExportURL: URL?
    /// Engine and interchange formats written beside every exported bundle (remembered across launches).
    var exportTargets: Set<String> = ExportTargetPreference.load() {
        didSet { ExportTargetPreference.save(exportTargets) }
    }
    var showExportSheet = false
    var includeUnreviewedBatch = false
    /// Named recipes the user saved, newest first.
    private(set) var savedRecipes: [SavedRecipe] = []
    var metadataEditorSource: MaterialSource?
    let link = LocalLinkService()
    let learned = LearnedModelStore()

    @ObservationIgnored private var started = false
    @ObservationIgnored private var recipesBySource: [String: MaterialRecipe] = [:]
    @ObservationIgnored private var recipeSaveTask: Task<Void, Never>?
    /// The window's undo manager (set by ContentView). Recipe edits are undoable per source.
    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var lastUndoRegistration: (source: String, at: Date)?
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
        if currentMaterial?.guide?.isCoarse == true { return "Refining learned geometry. Export when it finishes." }
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
        learned.onModelChanged = { [weak self] in
            guard let self, self.recipe.guideNormalWeight > 0, self.selectedSource != nil else { return }
            self.deriveSelected()
        }
        learned.bootstrap()
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
            recipesBySource = MaterialLibrary.loadRecipes()
            savedRecipes = MaterialLibrary.loadSavedRecipes()
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
        scheduleRecipeSave()
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
        if let id = selectedSourceID {
            recipesBySource[id] = recipe
            registerUndo(restoring: oldValue, for: id)
            scheduleRecipeSave()
        }
        if autoDerive { scheduleDerive() }
    }

    /// One undo step per gesture: changes to the same source within 0.75 s (a slider drag, typing a value)
    /// coalesce into the step that restores the value before the gesture began.
    private func registerUndo(restoring oldValue: MaterialRecipe, for id: String) {
        guard let undoManager else { return }
        let replaying = undoManager.isUndoing || undoManager.isRedoing
        // Coalesce only into a step that still exists on the stack (it may have been cleared or undone).
        if !replaying, undoManager.canUndo, let last = lastUndoRegistration, last.source == id,
           Date().timeIntervalSince(last.at) < 0.75 {
            lastUndoRegistration = (id, Date())
            return
        }
        lastUndoRegistration = replaying ? nil : (id, Date())
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.restoreRecipe(oldValue, for: id) }
        }
        undoManager.setActionName("Recipe Change")
    }

    // MARK: - Saved recipes

    /// Saves the current recipe under `name` (replacing one with the same name). Side inputs stay per source.
    func saveCurrentRecipe(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var stored = recipe
        stored.takeSideInputs(from: MaterialRecipe())
        savedRecipes.removeAll { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        savedRecipes.insert(SavedRecipe(name: trimmed, recipe: stored), at: 0)
        persistSavedRecipes()
        status = "Saved recipe “\(trimmed)”."
    }

    /// Applies a saved recipe to the selected source, keeping that source's relief mask and height override.
    func applySavedRecipe(_ saved: SavedRecipe) {
        var next = saved.recipe
        next.takeSideInputs(from: recipe)
        resetUndoCoalescing()
        recipe = next
        undoManager?.setActionName("Apply “\(saved.name)”")
    }

    func deleteSavedRecipe(_ saved: SavedRecipe) {
        savedRecipes.removeAll { $0.id == saved.id }
        persistSavedRecipes()
    }

    private func persistSavedRecipes() {
        do { try MaterialLibrary.saveSavedRecipes(savedRecipes) }
        catch { alert = MaterialAlert(message: "Could not save recipes: \(error.localizedDescription)") }
    }

    /// Starts the next edit as a new undo step.
    func resetUndoCoalescing() { lastUndoRegistration = nil }

    private func restoreRecipe(_ value: MaterialRecipe, for id: String) {
        if selectedSourceID != id { selectSource(id) }
        recipe = value
        lastUndoRegistration = nil
    }

    private func scheduleRecipeSave() {
        recipeSaveTask?.cancel()
        recipeSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            // Transient verification sources (SnapshotHarness) are never persisted.
            let snapshot = self.recipesBySource.filter { !$0.key.hasPrefix("snapshot:") }
            do { try MaterialLibrary.saveRecipes(snapshot) }
            catch { self.status = "Could not save recipes: \(error.localizedDescription)" }
        }
    }

    func choosePreset(_ preset: MaterialPreset) {
        var next = MaterialEngine.defaultRecipe(for: preset)
        next.takeSideInputs(from: recipe)
        next.normalYDown = recipe.normalYDown
        next.guideNormalWeight = recipe.guideNormalWeight
        recipe = next
    }

    /// Applies a material-library preset (its prior plus tuned values), keeping side inputs, the normal
    /// convention, learned geometry, tiling and albedo-repair choices.
    func chooseLibraryPreset(_ library: LibraryPreset) {
        let r = library.recipe
        var next = MaterialEngine.defaultRecipe(for: MaterialPreset(cValue: r.preset))
        next.heightStrength = r.height_strength
        next.heightPolarity = r.height_polarity
        next.roughnessBase = r.roughness_base
        next.roughnessVariation = r.roughness_variation
        next.aoRadiusPixels = r.ao_radius_pixels
        next.aoStrength = r.ao_strength
        next.normalStrength = r.normal_strength
        next.albedoEqualize = max(recipe.albedoEqualize, r.albedo_equalize)
        next.assignedMetalnessEnabled = r.assigned_metalness_enabled != 0
        next.assignedMetalness = r.assigned_metalness
        next.takeSideInputs(from: recipe)
        next.normalYDown = recipe.normalYDown
        next.guideNormalWeight = recipe.guideNormalWeight
        next.tileWrap = recipe.tileWrap
        next.seamlessBlend = recipe.seamlessBlend
        next.seamlessMode = recipe.seamlessMode
        next.albedoRepair = recipe.albedoRepair
        next.bentNormalEnabled = recipe.bentNormalEnabled
        next.materialPreset = library.id
        recipe = next
    }

    func resetRecipe() {
        if let library = LibraryPreset.named(recipe.materialPreset) { chooseLibraryPreset(library) }
        else { choosePreset(recipe.preset) }
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

    /// `coarseLearned`: show a quick learned estimate first, then refine automatically (interactive edits).
    func deriveSelected(coarseLearned: Bool = true) {
        debounceTask?.cancel()
        debounceTask = nil
        guard let source = selectedSource, !isBatching else { return }
        deriveControl?.cancel()
        deriveGeneration += 1
        let generation = deriveGeneration
        let chosenRecipe = recipe
        let control = DerivationControl(onProgress: { [weak self] value in
            Task { @MainActor in
                guard let self, self.deriveGeneration == generation else { return }
                self.progress = value
            }
        }, onLearned: { [weak self] value in
            Task { @MainActor in
                guard let self, self.deriveGeneration == generation else { return }
                self.learned.inferenceProgress = value?.fraction
                self.learned.inferenceDetail = value
            }
        })
        deriveControl = control
        learned.inferenceProgress = nil
        learned.inferenceDetail = nil
        progress = 0
        isDeriving = true
        derivationError = nil
        status = "Deriving maps for \(source.displayName)…"
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result {
                try MaterialEngine.derive(source: source, recipe: chosenRecipe, control: control, learnedCoarse: coarseLearned)
            }
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
        learned.inferenceProgress = nil
        learned.inferenceDetail = nil
        switch result {
        case .success(let value):
            guard selectedSourceID == source.id else { return }
            derived = value
            derivationSerial += 1
            if let guide = value.guide, !guide.wasCached { learned.lastInferenceDuration = guide.inferenceDuration }
            progress = 1
            if !value.maps.keys.contains(selectedMap) { selectedMap = .albedo }
            let ms = Int((value.duration * 1000).rounded())
            status = recipe == chosenRecipe
                ? "Derived \(value.maps.count) maps in \(ms) ms."
                : "Recipe changed while deriving; updating…"
            if recipe != chosenRecipe, autoDerive { scheduleDerive() }
            else if value.guide?.isCoarse == true {
                // The quick learned field is on screen; compute the full-quality one now (then it is cached).
                status = "Showing a quick learned estimate; refining…"
                deriveSelected(coarseLearned: false)
            }
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

    /// Saves the selected map alone as a PNG (data maps untagged-linear, albedo sRGB, height 16-bit).
    func exportSelectedMap() {
        guard let material = currentMaterial, let map = material.maps[selectedMap], selectedMap.isExported else {
            NSSound.beep()
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save \(selectedMap.title) Map"
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(MaterialBundle.exportSlug(material.source.semanticLabel))_\(selectedMap.exportedName).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try? FileManager.default.removeItem(at: url)
            try MaterialBundle.writePNG(map, to: url)
            status = "Saved \(url.lastPathComponent)."
        } catch {
            alert = MaterialAlert(title: "Save Failed", message: error.localizedDescription)
        }
    }

    /// Opens the export sheet (formats to write beside the bundle).
    func requestExport() {
        if let blocker = exportBlocker {
            status = blocker
            NSSound.beep()
            return
        }
        showExportSheet = true
    }

    func exportSelected() {
        if let blocker = exportBlocker {
            status = blocker
            NSSound.beep()
            return
        }
        guard let derived = currentMaterial, let destination = chooseDestination() else { return }
        isExporting = true
        let targets = ExportTarget.named(exportTargets)
        status = targets.isEmpty ? "Exporting validated PNG maps and manifest…"
                                 : "Exporting the bundle and \(targets.count) formats…"
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { () throws -> (URL, Int) in
                let bundle = try MaterialBundle.export(derived, into: destination)
                for target in targets { try target.export(bundle: bundle) }
                return (bundle, targets.count)
            }
            await self?.finishExport(result)
        }
    }

    private func finishExport(_ result: Result<(URL, Int), Error>) {
        isExporting = false
        switch result {
        case .success(let (url, formats)):
            lastExportURL = url
            status = formats == 0 ? "Exported \(url.lastPathComponent)."
                                  : "Exported \(url.lastPathComponent) and \(formats) format\(formats == 1 ? "" : "s")."
        case .failure(let error):
            status = "Export failed."
            alert = MaterialAlert(title: "Export Failed", message: error.localizedDescription)
        }
    }

    func batchDeriveVisible() {
        guard !isBatching, !isExporting, !eligibleBatchSources.isEmpty,
              let destination = chooseDestination() else { return }
        let targets = eligibleBatchSources
        let formats = ExportTarget.named(exportTargets)
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
                    let bundle = try MaterialBundle.export(result, into: destination)
                    for format in formats { try format.export(bundle: bundle) }
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
