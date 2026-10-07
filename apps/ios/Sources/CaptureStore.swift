import Foundation
import Observation
import UIKit

/// The current capture: source photo, crop, identity, recipe, and derived maps.
///
/// Only pixel-affecting inputs (source, crop, recipe, resolution) invalidate derived maps; label and
/// category are metadata. Edits trigger a debounced live preview derivation; the explicit Derive action
/// produces the exportable full-resolution maps with progress and cancellation.
@MainActor
@Observable
final class CaptureStore {
    static let resolutions = [512, 1024, 2048, 4096]

    private(set) var source: SourceImage?
    var crop = PerspectiveQuad.full {
        didSet { if crop != oldValue { pixelInputsChanged() } }
    }
    var semanticLabel = "" { didSet { if semanticLabel != oldValue { scheduleStateSave() } } }
    var category = "uncategorized" { didSet { if category != oldValue { scheduleStateSave() } } }
    var resolution = 2048 {
        didSet { if resolution != oldValue { pixelInputsChanged(refreshPreview: false) } }
    }
    var recipe = MaterialRecipe(preset: .flat) {
        didSet {
            guard recipe != oldValue else { return }
            recordUndo(from: oldValue)
            pixelInputsChanged()
        }
    }

    // MARK: Undo

    /// Recipe history for this capture. Edits within ~0.7 s (a slider drag) coalesce into one step.
    private var undoStack: [MaterialRecipe] = []
    private var redoStack: [MaterialRecipe] = []
    private var lastEdit = Date.distantPast
    private var applyingHistory = false
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private func recordUndo(from previous: MaterialRecipe) {
        guard !applyingHistory else { return }
        let now = Date()
        if now.timeIntervalSince(lastEdit) > 0.7 || undoStack.isEmpty {
            undoStack.append(previous)
            if undoStack.count > 100 { undoStack.removeFirst() }
        }
        lastEdit = now
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(recipe)
        applyingHistory = true
        recipe = previous
        applyingHistory = false
        lastEdit = .distantPast
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(recipe)
        applyingHistory = true
        recipe = next
        applyingHistory = false
        lastEdit = .distantPast
    }

    /// A new or reopened capture starts with an empty history.
    private func resetHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        lastEdit = .distantPast
    }

    /// Full-resolution, exportable maps for the current inputs; nil once any pixel input changes.
    private(set) var derived: DerivedMaterial?
    /// Display-only preview at `MaterialProcessor.previewResolution`, refreshed while editing.
    private(set) var livePreview: DerivedMaterial?
    private(set) var isDeriving = false
    private(set) var deriveProgress = 0.0
    private(set) var isUpdatingPreview = false
    private(set) var isImporting = false
    private(set) var cropWasAutoDetected = false
    /// Incremented on each completed capture/import and full derivation; drives haptics.
    private(set) var importCount = 0
    private(set) var deriveCount = 0
    var errorMessage: String?

    /// The contract-validated learned normal model (imported via Files, else bundled); nil when none is available.
    private(set) var learnedModel: LearnedModelInfo?
    private(set) var learnedModelChecked = false
    private(set) var isImportingModel = false
    /// Pass progress while learned normals are inferred for the current source and crop; nil when idle.
    private(set) var learnedProgress: LearnedProgress?
    /// Set while `learnedField` is the quick single-tile estimate and the full field is still being computed.
    private var learnedIsQuickEstimate = false
    /// True when the preview's learned geometry is the quick estimate.
    var showsQuickLearnedEstimate: Bool { learnedIsQuickEstimate && currentLearnedField() != nil }
    /// Learned normals for `learnedGeometry`, reused by every preview and recipe edit (possibly the quick estimate,
    /// which full derivations never use: its working size only matches the export's at 512²).
    private var learnedField: LearnedNormalField?
    private var learnedGeometry: String?
    private var learnedTask: Task<Void, Never>?
    private var learnedTaskGeometry: String?
    private var learnedControl: DerivationControl?
    private let estimator = LearnedNormalEstimator.shared

    private var inputRevision = 0
    private var derivedRevision: Int?
    private var derivationControl: DerivationControl?
    private var previewTask: Task<Void, Never>?
    private var previewControl: DerivationControl?
    private var saveTask: Task<Void, Never>?
    /// Every saved capture; the current one persists in its own directory.
    let library: CaptureLibrary?
    /// Saved captures, most recently edited first (refreshed on save, open and delete).
    private(set) var libraryEntries: [CaptureLibrary.Entry] = []
    /// Named recipes the user saved, newest first.
    private(set) var savedRecipes: [SavedRecipe] = []
    private var persistence: CapturePersistence? { source.flatMap { source in library?.persistence(for: source.id) } }

    /// `libraryDirectory` is the capture library root; nil keeps captures in memory only.
    init(libraryDirectory: URL? = nil) {
        library = libraryDirectory.map(CaptureLibrary.init(root:))
        Task { await refreshLearnedModel() }
        Task { await refreshLibrary() }
    }

    /// What the review screen shows: full-resolution maps when current, otherwise the live preview.
    var displayed: DerivedMaterial? { derived ?? livePreview }
    var hasExportableMaps: Bool { derived != nil && derivedRevision == inputRevision }
    var trimmedLabel: String { semanticLabel.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Learned normals depend only on the source pixels under the crop and the recipe's tile option (a tiled field
    /// is periodic).
    private var geometryKey: String? {
        guard let source else { return nil }
        let q = crop
        return "\(source.id)|\(recipe.tileWrap)|\(q.topLeft.x),\(q.topLeft.y),\(q.topRight.x),\(q.topRight.y)," +
            "\(q.bottomRight.x),\(q.bottomRight.y),\(q.bottomLeft.x),\(q.bottomLeft.y)"
    }

    private func pixelInputsChanged(refreshPreview: Bool = true) {
        inputRevision += 1
        if let task = learnedTaskGeometry, task != geometryKey {
            learnedControl?.cancel()
            learnedTask?.cancel()
            learnedTaskGeometry = nil
            learnedProgress = nil
        }
        derived = nil
        derivedRevision = nil
        derivationControl?.cancel()
        if refreshPreview { scheduleLivePreview() }
        scheduleStateSave()
    }

    // MARK: Import

    @discardableResult
    func receiveCamera(_ result: CameraCapture) async -> Bool {
        await receive(origin: .camera, data: result.primaryData, fallback: result.fallbackData,
                      confidence: result.confidence, constantColorRequested: result.constantColorRequested,
                      centerConfidence: result.centerConfidence, capturedAt: result.capturedAt)
    }

    /// Decodes and analyzes the photo off the main actor, then makes it the current capture.
    @discardableResult
    func receive(origin: SourceImage.Origin, data: Data, fallback: Data? = nil,
                 confidence: ConfidenceMap? = nil, constantColorRequested: Bool = false,
                 centerConfidence: Float? = nil, capturedAt: Date = Date()) async -> Bool {
        isImporting = true
        defer { isImporting = false }
        do {
            let (image, detected) = try await Task.detached(priority: .userInitiated) {
                let image = try SourceImage(origin: origin, data: data, fallback: fallback,
                                            confidence: confidence,
                                            constantColorRequested: constantColorRequested,
                                            centerConfidence: centerConfidence, capturedAt: capturedAt)
                return (image, RectangleDetector.detect(in: image.displayImage))
            }.value
            install(image, crop: detected ?? .centeredSquare(for: image.size),
                    label: "", category: "uncategorized")
            cropWasAutoDetected = detected != nil
            errorMessage = nil
            importCount += 1
            if let library {
                let snapshot = image
                library.setCurrent(image.id)
                await Task.detached(priority: .utility) { library.persistence(for: snapshot.id).saveSource(snapshot) }.value
            }
            scheduleStateSave(immediately: true)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func install(_ image: SourceImage, crop: PerspectiveQuad, label: String, category: String) {
        source = image
        authored = AuthoredMaps()
        defer { resetHistory() }
        livePreview = nil
        semanticLabel = label
        self.category = category
        if self.crop == crop { pixelInputsChanged() } else { self.crop = crop }
    }

    func resetCrop() {
        guard let source else { return }
        crop = .centeredSquare(for: source.size)
        cropWasAutoDetected = false
    }

    /// Re-runs rectangle detection; returns false when no surface was found.
    @discardableResult
    func autoDetectCrop() async -> Bool {
        guard let source else { return false }
        let display = source.displayImage
        let detected = await Task.detached(priority: .userInitiated) { RectangleDetector.detect(in: display) }.value
        guard let detected else { return false }
        crop = detected
        cropWasAutoDetected = true
        return true
    }

    func setPreset(_ preset: MaterialPreset) {
        recipe = recipe.applyingPreset(preset)
    }

    /// Closes the current capture; it stays in the library.
    func clear() {
        derivationControl?.cancel()
        previewControl?.cancel()
        previewTask?.cancel()
        learnedControl?.cancel()
        learnedTask?.cancel()
        learnedTaskGeometry = nil
        learnedProgress = nil
        learnedField = nil
        learnedGeometry = nil
        learnedIsQuickEstimate = false
        source = nil
        authored = AuthoredMaps()
        derived = nil
        livePreview = nil
        semanticLabel = ""
        category = "uncategorized"
        inputRevision += 1
        library?.setCurrent(nil)
    }

    // MARK: Library

    func refreshLibrary() async {
        guard let library else { return }
        let (entries, recipes) = await Task.detached(priority: .utility) {
            (library.entries(), library.loadSavedRecipes())
        }.value
        libraryEntries = entries
        savedRecipes = recipes
    }

    // MARK: Saved recipes

    /// Saves the current recipe under `name`; a recipe with the same name is replaced.
    func saveCurrentRecipe(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        savedRecipes.removeAll { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
        savedRecipes.insert(SavedRecipe(name: trimmed, recipe: recipe), at: 0)
        library?.saveSavedRecipes(savedRecipes)
    }

    func applySavedRecipe(_ saved: SavedRecipe) { recipe = saved.recipe }

    /// The values the recipe sheet compares against: the chosen material's recipe, or the prior's defaults.
    var baselineRecipe: MaterialRecipe {
        if let library = LibraryPreset.named(recipe.materialPreset) { return recipe.applyingLibraryPreset(library) }
        return recipe.applyingPreset(recipe.preset)
    }

    /// Starts from a material-library preset, keeping export, tiling and learned-geometry choices.
    func applyLibraryPreset(_ preset: LibraryPreset) { recipe = recipe.applyingLibraryPreset(preset) }

    func deleteSavedRecipe(_ saved: SavedRecipe) {
        savedRecipes.removeAll { $0.id == saved.id }
        library?.saveSavedRecipes(savedRecipes)
    }

    /// Opens a saved capture (closing the current one, which stays saved).
    func open(_ id: UUID) async {
        guard let library, source?.id != id else { return }
        guard let restored = await Task.detached(priority: .userInitiated, operation: {
            library.persistence(for: id).load()
        }).value else {
            errorMessage = "That capture could not be opened."
            await refreshLibrary()
            return
        }
        clear()
        apply(restored)
        library.setCurrent(id)
    }

    /// Deletes a saved capture permanently from this iPhone.
    func delete(_ id: UUID) async {
        guard let library else { return }
        if source?.id == id { clear() }
        await Task.detached(priority: .utility) { library.delete(id) }.value
        await refreshLibrary()
    }

    private func saveThumbnail(from material: DerivedMaterial) {
        guard let library, let id = source?.id, let albedo = material.maps[.albedo]?.previewImage else { return }
        Task.detached(priority: .utility) { library.saveThumbnail(albedo, for: id) }
    }

    // MARK: Derivation

    func scheduleLivePreview(after delay: Duration = .milliseconds(220)) {
        previewTask?.cancel()
        previewControl?.cancel()
        guard let source, crop.isValid, !isDeriving else {
            isUpdatingPreview = false
            return
        }
        isUpdatingPreview = true
        let control = DerivationControl()
        previewControl = control
        let image = source.selectedImage(for: crop)
        let quad = crop
        let recipe = recipe
        let revision = inputRevision
        // Until learned normals exist for this crop the preview stays analytic; inference runs alongside.
        let authored = authored
        let wantsLearned = recipe.guideNormalWeight > 0 && !authored.hasGeometry
        let guide: GuideSource? = wantsLearned ? currentLearnedField().map(GuideSource.field) : nil
        if wantsLearned && guide == nil { startLearnedInference() }
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            let result = await Task.detached(priority: .userInitiated) {
                try? MaterialProcessor.derive(image: image, quad: quad, resolution: MaterialProcessor.previewResolution,
                                              recipe: recipe, control: control, preview: true, guide: guide,
                                              authored: authored)
            }.value
            guard !Task.isCancelled else { return }
            if let result, revision == self.inputRevision {
                self.livePreview = result
                self.saveThumbnail(from: result)
            }
            self.isUpdatingPreview = false
        }
    }

    func derive() async {
        guard let source, !isDeriving else { return }
        guard crop.isValid else { errorMessage = CaptureError.invalidCrop.localizedDescription; return }
        if recipe.guideNormalWeight > 0 && learnedModel == nil {
            errorMessage = LearnedNormalError.notInstalled.localizedDescription
            return
        }
        previewTask?.cancel()
        previewControl?.cancel()
        isUpdatingPreview = false
        // 2K and 4K derivations (learned 4K takes ~20 s) keep running if the user leaves the app.
        let background = Box<ContinuedDerivation>()
        let control = DerivationControl { [weak self] value in
            background.value?.update(value)
            Task { @MainActor in
                guard let self, self.isDeriving else { return }
                self.deriveProgress = max(self.deriveProgress, value)
            }
        }
        derivationControl = control
        if resolution >= 2048 {
            let name = trimmedLabel.isEmpty ? "material" : "“\(trimmedLabel)”"
            background.value = ContinuedDerivation.begin(
                title: "Deriving \(name)", subtitle: "\(resolution) × \(resolution) PBR maps",
                onExpire: { control.cancel() })
        }
        isDeriving = true
        deriveProgress = 0
        errorMessage = nil
        let image = source.selectedImage(for: crop)
        let quad = crop
        let recipe = recipe
        let resolution = resolution
        let revision = inputRevision
        let geometry = geometryKey
        let authored = authored
        var guide: GuideSource?
        if recipe.guideNormalWeight > 0 {
            // Reuse the preview's inference only when it ran at this resolution's working size (the tiling contract).
            if let field = currentLearnedField(),
               field.work == LearnedNormalEstimator.workResolution(for: resolution), field.wrap == recipe.tileWrap {
                guide = .field(field)
            } else {
                guide = .estimate(estimator)
            }
        }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try MaterialProcessor.derive(image: image, quad: quad, resolution: resolution,
                                             recipe: recipe, control: control, guide: guide, authored: authored)
            }.value
            if let field = result.learnedField, geometry == geometryKey {
                learnedField = field
                learnedGeometry = geometry
                learnedIsQuickEstimate = false
            }
            if revision == inputRevision {
                derived = result
                derivedRevision = revision
                deriveCount += 1
                saveThumbnail(from: result)
            }
        } catch CaptureError.cancelled {
            // User cancelled or inputs changed mid-derivation.
        } catch {
            errorMessage = error.localizedDescription
        }
        background.value?.finish(success: derived != nil && derivedRevision == revision)
        isDeriving = false
        derivationControl = nil
        if derived == nil { scheduleLivePreview(after: .zero) }
    }

    func cancelDerivation() { derivationControl?.cancel() }

    // MARK: Learned normals

    private func currentLearnedField() -> LearnedNormalField? {
        guard let field = learnedField, learnedGeometry == geometryKey,
              field.model.identity == learnedModel?.identity else { return nil }
        return field
    }

    /// Infers learned normals for the current crop at the export resolution's working size, off the main actor.
    /// Above 512² a quick single-tile estimate (a 518² crop: one or two passes) reaches the preview first, then the
    /// full field replaces it. The estimator caches by working-image hash, so a later full derivation reuses it.
    private func startLearnedInference() {
        guard let source, crop.isValid, learnedModel != nil, let geometry = geometryKey,
              learnedTaskGeometry != geometry else { return }
        learnedControl?.cancel()
        learnedTask?.cancel()
        let control = DerivationControl()
        learnedControl = control
        learnedTaskGeometry = geometry
        learnedProgress = LearnedProgress(pass: 0, passes: 0, remaining: nil, coarse: false)
        let image = source.selectedImage(for: crop)
        let quad = crop
        let resolution = resolution
        let quick = resolution > LearnedNormalEstimator.tile
        let wrap = recipe.tileWrap
        let estimator = estimator
        let report: @Sendable (LearnedProgress) -> Void = { [weak self] value in
            Task { @MainActor in
                guard let self, self.learnedTaskGeometry == geometry else { return }
                self.learnedProgress = value
            }
        }
        func infer(size: Int, coarse: Bool) async -> Result<LearnedNormalField, Error> {
            await Task.detached(priority: .userInitiated) {
                Result {
                    let rgba = try PerspectiveCropper.correctedRGBA8(image, quad: quad, pixels: size)
                    return try estimator.field(rgba: rgba, size: size, wrap: wrap, coarse: coarse,
                                               shouldContinue: { !control.isCancelled }, progress: report)
                }
            }.value
        }
        learnedTask = Task { [weak self] in
            if quick, case .success(let field) = await infer(size: LearnedNormalEstimator.tile, coarse: true) {
                guard let self, self.learnedTaskGeometry == geometry else { return }
                // Show the quick estimate unless a full field for this crop already arrived (e.g. from derive()).
                if self.currentLearnedField() == nil {
                    self.learnedField = field
                    self.learnedGeometry = geometry
                    self.learnedIsQuickEstimate = true
                    self.scheduleLivePreview(after: .zero)
                }
            }
            let result = await infer(size: resolution, coarse: false)
            guard let self, self.learnedTaskGeometry == geometry else { return }
            self.learnedTaskGeometry = nil
            self.learnedProgress = nil
            switch result {
            case .success(let field):
                self.learnedField = field
                self.learnedGeometry = geometry
                self.learnedIsQuickEstimate = false
                self.scheduleLivePreview(after: .zero)
            case .failure(CaptureError.cancelled):
                break
            case .failure(let error):
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Finds the imported or bundled model off the main actor (validating its metadata once).
    func refreshLearnedModel() async {
        let estimator = estimator
        let model = await Task.detached(priority: .utility) { estimator.locateModel(refresh: true) }.value
        setLearnedModel(model)
        learnedModelChecked = true
    }

    func importLearnedModel(from url: URL) async {
        isImportingModel = true
        defer { isImportingModel = false }
        do {
            setLearnedModel(try await estimator.importModel(from: url))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeImportedLearnedModel() async {
        let estimator = estimator
        let model = await Task.detached(priority: .utility) { estimator.removeImportedModel() }.value
        setLearnedModel(model)
    }

    private func setLearnedModel(_ model: LearnedModelInfo?) {
        guard model != learnedModel else { return }
        learnedModel = model
        learnedField = nil
        learnedGeometry = nil
        learnedIsQuickEstimate = false
        learnedControl?.cancel()
        learnedTask?.cancel()
        learnedTaskGeometry = nil
        learnedProgress = nil
        if recipe.guideNormalWeight > 0 { pixelInputsChanged() }
    }

    // MARK: Export

    /// Builds the .pbrcapture off the main actor. Each call uses a fresh capture ID.
    func makeBundle(linkToken: String? = nil, captureId: UUID = UUID()) async throws -> Data {
        let label = trimmedLabel
        guard !label.isEmpty else { throw CaptureError.missingLabel }
        guard let source, let derived, hasExportableMaps else {
            throw CaptureError.derivationFailed("Inputs changed; derive again before export")
        }
        let quad = crop
        let category = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let recipe = recipe
        return try await Task.detached(priority: .userInitiated) {
            try MaterialBundle.make(source: source, quad: quad, label: label,
                                    category: category.isEmpty ? "uncategorized" : category,
                                    recipe: recipe, material: derived, linkToken: linkToken,
                                    captureId: captureId)
        }.value
    }

    /// Artist-made inputs for this capture: a hand-made albedo and maps that replace the derived ones.
    private(set) var authored = AuthoredMaps()

    /// Marks the source as a hand-made albedo: it is used whole (a centered square, no perspective correction).
    func setHandMadeAlbedo(_ on: Bool) {
        guard authored.handMadeAlbedo != on else { return }
        authored.handMadeAlbedo = on
        if on, let source { crop = .centeredSquare(for: source.size); cropWasAutoDetected = false }
        pixelInputsChanged()
    }

    func setNormalMapDirectX(_ on: Bool) {
        guard authored.normalDirectX != on else { return }
        authored.normalDirectX = on
        if authored.maps[.normal] != nil { pixelInputsChanged() }
    }

    /// Adds (or replaces) an authored map from image data; returns false when the data is not an image.
    @discardableResult
    func setAuthoredMap(_ role: AuthoredMaps.Role, data: Data, name: String) -> Bool {
        guard AuthoredMaps.isDecodable(data) else {
            errorMessage = "That file is not an image this iPhone can read."
            return false
        }
        authored.maps[role] = AuthoredMaps.Map(data: data, name: name)
        if role == .metalness, recipe.assignedMetalness == nil { recipe.assignedMetalness = 0 }
        pixelInputsChanged()
        return true
    }

    func removeAuthoredMap(_ role: AuthoredMaps.Role) {
        guard authored.maps.removeValue(forKey: role) != nil else { return }
        pixelInputsChanged()
    }

    /// Engine and interchange formats written beside the .pbrmaterial bundle (remembered across launches).
    var exportTargets: Set<String> = ExportTargetPreference.load() {
        didSet { ExportTargetPreference.save(exportTargets) }
    }

    /// Writes "<label> material/" in a temporary folder: the .pbrmaterial bundle (validator-compatible, as from the
    /// Mac app and CLI) plus every chosen export target. Returns the folder for the Files exporter.
    func makeMaterialExport() async throws -> URL {
        let label = trimmedLabel
        guard !label.isEmpty else { throw CaptureError.missingLabel }
        guard let source, let derived, hasExportableMaps else {
            throw CaptureError.derivationFailed("Inputs changed; derive again before export")
        }
        let category = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = MaterialBundleWriter.Identity(label: label, category: category.isEmpty ? "uncategorized" : category,
                                                     origin: source.origin, captureMode: source.captureMode(for: crop))
        let targets = ExportTarget.named(exportTargets)
        let slug = Self.exportSlug(label)
        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let staging = fm.temporaryDirectory.appending(path: "material-export-\(UUID().uuidString)", directoryHint: .isDirectory)
            let folder = staging.appending(path: "\(slug) material", directoryHint: .isDirectory)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let bundle = try MaterialBundleWriter.write(derived, identity: identity, into: folder, name: slug)
            for target in targets { try target.export(bundle: bundle) }
            return folder
        }.value
    }

    /// A USDZ of the full-resolution maps for AR Quick Look (written to a temporary folder).
    func makeARPreview() async throws -> URL {
        guard let source, let derived, hasExportableMaps else {
            throw CaptureError.derivationFailed("Derive at full resolution first")
        }
        let label = trimmedLabel.isEmpty ? "Material" : trimmedLabel
        let identity = MaterialBundleWriter.Identity(label: label, category: "preview", origin: source.origin,
                                                     captureMode: source.captureMode(for: crop))
        let slug = Self.exportSlug(label)
        return try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let folder = fm.temporaryDirectory.appending(path: "ar-\(UUID().uuidString)", directoryHint: .isDirectory)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let bundle = try MaterialBundleWriter.write(derived, identity: identity, into: folder, name: slug)
            return try ExportTarget.all.first { $0.id == "usdz" }!.export(bundle: bundle)
        }.value
    }

    /// Filesystem-safe name from the label ("Red brick #2" → "red-brick-2").
    static func exportSlug(_ label: String) -> String {
        let cleaned = label.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? "material" : String(cleaned.prefix(64))
    }

    // MARK: Persistence

    /// Restores the capture that was open when the app was last terminated.
    func restore() async {
        guard let library, source == nil else { return }
        guard let restored = await Task.detached(priority: .userInitiated, operation: { () -> (source: SourceImage, state: CapturePersistence.State)? in
            guard let id = library.currentID else { return nil }
            return library.persistence(for: id).load()
        }).value else { return }
        apply(restored)
    }

    private func apply(_ restored: (source: SourceImage, state: CapturePersistence.State)) {
        source = restored.source
        semanticLabel = restored.state.semanticLabel
        category = restored.state.category
        resolution = Self.resolutions.contains(restored.state.resolution) ? restored.state.resolution : 2048
        recipe = restored.state.recipe
        authored = restored.state.authored
        resetHistory()
        let restoredCrop = restored.state.crop.isValid ? restored.state.crop : .centeredSquare(for: restored.source.size)
        if crop == restoredCrop { pixelInputsChanged() } else { crop = restoredCrop }
    }

    private func scheduleStateSave(immediately: Bool = false) {
        guard let persistence, let source else { return }
        let library = library
        saveTask?.cancel()
        let state = CapturePersistence.State(source: source, crop: crop, semanticLabel: semanticLabel,
                                             category: category, resolution: resolution, recipe: recipe,
                                             authored: authored)
        saveTask = Task {
            if !immediately { try? await Task.sleep(for: .milliseconds(600)) }
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) { persistence.saveState(state) }.value
            if let library {
                let entries = await Task.detached(priority: .utility) { library.entries() }.value
                self.libraryEntries = entries
            }
        }
    }
}

/// Stores the current capture in Application Support so an app kill does not lose work.
/// Derived maps are not stored; they are re-derived from the saved source and recipe.
final class CapturePersistence: Sendable {
    struct State: Codable, Sendable {
        var id: UUID
        var origin: SourceImage.Origin
        var capturedAt: Date
        var constantColorRequested: Bool
        var centerConfidence: Double?
        var confidenceWidth: Int?
        var confidenceHeight: Int?
        var crop: PerspectiveQuad
        var semanticLabel: String
        var category: String
        var resolution: Int
        var recipe: MaterialRecipe
        /// Authored-map metadata (absent in captures saved before authored maps existed).
        var authoredHandMade: Bool?
        var authoredNormalDirectX: Bool?
        var authoredNames: [String: String]?
        /// The authored maps themselves, saved as separate files beside the state and loaded with it.
        var authored = AuthoredMaps()

        private enum CodingKeys: String, CodingKey {
            case id, origin, capturedAt, constantColorRequested, centerConfidence, confidenceWidth, confidenceHeight
            case crop, semanticLabel, category, resolution, recipe
            case authoredHandMade, authoredNormalDirectX, authoredNames
        }

        init(source: SourceImage, crop: PerspectiveQuad, semanticLabel: String, category: String,
             resolution: Int, recipe: MaterialRecipe, authored: AuthoredMaps = AuthoredMaps()) {
            id = source.id
            origin = source.origin
            capturedAt = source.capturedAt
            constantColorRequested = source.constantColorRequested
            centerConfidence = source.constantColorCenterConfidence
            confidenceWidth = source.rawConfidence?.width
            confidenceHeight = source.rawConfidence?.height
            self.crop = crop
            self.semanticLabel = semanticLabel
            self.category = category
            self.resolution = resolution
            self.recipe = recipe
            self.authored = authored
            authoredHandMade = authored.handMadeAlbedo
            authoredNormalDirectX = authored.normalDirectX
            authoredNames = Dictionary(uniqueKeysWithValues: authored.maps.map { ($0.key.rawValue, $0.value.name) })
        }
    }

    let directory: URL
    init(directory: URL) { self.directory = directory }

    private var primaryURL: URL { directory.appending(path: "primary.image") }
    private var fallbackURL: URL { directory.appending(path: "fallback.image") }
    private var confidenceURL: URL { directory.appending(path: "confidence.r8") }
    private var stateURL: URL { directory.appending(path: "state.json") }
    private func authoredURL(_ role: AuthoredMaps.Role) -> URL { directory.appending(path: "authored-\(role.rawValue).image") }

    func saveSource(_ source: SourceImage) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Photos never leave the app sandbox; protect them while the device is locked.
            try source.primaryData.write(to: primaryURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            if let fallback = source.fallbackData {
                try fallback.write(to: fallbackURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            } else {
                try? FileManager.default.removeItem(at: fallbackURL)
            }
            if let confidence = source.rawConfidence {
                try confidence.pixels.write(to: confidenceURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            } else {
                try? FileManager.default.removeItem(at: confidenceURL)
            }
        } catch {
            clear()
        }
    }

    func saveState(_ state: State) {
        guard FileManager.default.fileExists(atPath: primaryURL.path) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: stateURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        for role in AuthoredMaps.Role.allCases {
            if let map = state.authored.maps[role] {
                try? map.data.write(to: authoredURL(role), options: [.atomic, .completeFileProtectionUnlessOpen])
            } else {
                try? FileManager.default.removeItem(at: authoredURL(role))
            }
        }
    }

    func load() -> (source: SourceImage, state: State)? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stateData = try? Data(contentsOf: stateURL),
              var state = try? decoder.decode(State.self, from: stateData),
              let primary = try? Data(contentsOf: primaryURL) else { return nil }
        let fallback = try? Data(contentsOf: fallbackURL)
        var confidence: ConfidenceMap?
        if let width = state.confidenceWidth, let height = state.confidenceHeight,
           let pixels = try? Data(contentsOf: confidenceURL), pixels.count == width * height {
            confidence = ConfidenceMap(width: width, height: height, pixels: pixels)
        }
        guard let source = try? SourceImage(origin: state.origin, data: primary, fallback: fallback,
                                            confidence: confidence,
                                            constantColorRequested: state.constantColorRequested,
                                            centerConfidence: state.centerConfidence.map(Float.init),
                                            capturedAt: state.capturedAt, id: state.id) else {
            clear()
            return nil
        }
        state.authored.handMadeAlbedo = state.authoredHandMade ?? false
        state.authored.normalDirectX = state.authoredNormalDirectX ?? false
        for (key, name) in state.authoredNames ?? [:] {
            guard let role = AuthoredMaps.Role(rawValue: key), let data = try? Data(contentsOf: authoredURL(role)) else { continue }
            state.authored.maps[role] = AuthoredMaps.Map(data: data, name: name)
        }
        return (source, state)
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// A late-bound reference shared with a `@Sendable` progress closure.
private final class Box<Value: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    var value: Value? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
