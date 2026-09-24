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
        didSet { if recipe != oldValue { pixelInputsChanged() } }
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
    /// Tile progress while learned normals are inferred for the current source and crop; nil when idle.
    private(set) var learnedProgress: Double?
    /// Learned normals for `learnedGeometry`, reused by every preview and recipe edit.
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
    private let persistence: CapturePersistence?

    init(persistenceDirectory: URL? = nil) {
        persistence = persistenceDirectory.map(CapturePersistence.init(directory:))
        Task { await refreshLearnedModel() }
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
            persistence.map { persistence in
                let snapshot = image
                Task.detached(priority: .utility) { persistence.saveSource(snapshot) }
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
        source = nil
        derived = nil
        livePreview = nil
        semanticLabel = ""
        category = "uncategorized"
        inputRevision += 1
        persistence?.clear()
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
        let guide: GuideSource? = recipe.guideNormalWeight > 0 ? currentLearnedField().map(GuideSource.field) : nil
        if recipe.guideNormalWeight > 0 && guide == nil { startLearnedInference() }
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            let result = await Task.detached(priority: .userInitiated) {
                try? MaterialProcessor.derive(image: image, quad: quad, resolution: MaterialProcessor.previewResolution,
                                              recipe: recipe, control: control, preview: true, guide: guide)
            }.value
            guard !Task.isCancelled else { return }
            if let result, revision == self.inputRevision { self.livePreview = result }
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
        let control = DerivationControl { [weak self] value in
            Task { @MainActor in
                guard let self, self.isDeriving else { return }
                self.deriveProgress = max(self.deriveProgress, value)
            }
        }
        derivationControl = control
        isDeriving = true
        deriveProgress = 0
        errorMessage = nil
        let image = source.selectedImage(for: crop)
        let quad = crop
        let recipe = recipe
        let resolution = resolution
        let revision = inputRevision
        let geometry = geometryKey
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
                                             recipe: recipe, control: control, guide: guide)
            }.value
            if let field = result.learnedField, geometry == geometryKey {
                learnedField = field
                learnedGeometry = geometry
            }
            if revision == inputRevision {
                derived = result
                derivedRevision = revision
                deriveCount += 1
            }
        } catch CaptureError.cancelled {
            // User cancelled or inputs changed mid-derivation.
        } catch {
            errorMessage = error.localizedDescription
        }
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
    /// The estimator caches by working-image hash, so a later full derivation at this resolution reuses it.
    private func startLearnedInference() {
        guard let source, crop.isValid, learnedModel != nil, let geometry = geometryKey,
              learnedTaskGeometry != geometry else { return }
        learnedControl?.cancel()
        learnedTask?.cancel()
        let control = DerivationControl()
        learnedControl = control
        learnedTaskGeometry = geometry
        learnedProgress = 0
        let image = source.selectedImage(for: crop)
        let quad = crop
        let resolution = resolution
        let wrap = recipe.tileWrap
        let estimator = estimator
        let report: @Sendable (Double) -> Void = { [weak self] value in
            Task { @MainActor in
                guard let self, self.learnedTaskGeometry == geometry else { return }
                self.learnedProgress = value
            }
        }
        learnedTask = Task { [weak self] in
            let result: Result<LearnedNormalField, Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    let rgba = try PerspectiveCropper.correctedRGBA8(image, quad: quad, pixels: resolution)
                    return try estimator.field(rgba: rgba, size: resolution, wrap: wrap,
                                               shouldContinue: { !control.isCancelled },
                                               progress: report)
                }
            }.value
            guard let self, self.learnedTaskGeometry == geometry else { return }
            self.learnedTaskGeometry = nil
            self.learnedProgress = nil
            switch result {
            case .success(let field):
                self.learnedField = field
                self.learnedGeometry = geometry
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

    // MARK: Persistence

    /// Restores the capture that was open when the app was last terminated.
    func restore() async {
        guard let persistence, source == nil else { return }
        guard let restored = await Task.detached(priority: .userInitiated, operation: { persistence.load() }).value else {
            return
        }
        source = restored.source
        semanticLabel = restored.state.semanticLabel
        category = restored.state.category
        resolution = Self.resolutions.contains(restored.state.resolution) ? restored.state.resolution : 2048
        recipe = restored.state.recipe
        let restoredCrop = restored.state.crop.isValid ? restored.state.crop : .centeredSquare(for: restored.source.size)
        if crop == restoredCrop { pixelInputsChanged() } else { crop = restoredCrop }
    }

    private func scheduleStateSave(immediately: Bool = false) {
        guard let persistence, let source else { return }
        saveTask?.cancel()
        let state = CapturePersistence.State(source: source, crop: crop, semanticLabel: semanticLabel,
                                             category: category, resolution: resolution, recipe: recipe)
        saveTask = Task {
            if !immediately { try? await Task.sleep(for: .milliseconds(600)) }
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) { persistence.saveState(state) }.value
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

        init(source: SourceImage, crop: PerspectiveQuad, semanticLabel: String, category: String,
             resolution: Int, recipe: MaterialRecipe) {
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
        }
    }

    let directory: URL
    init(directory: URL) { self.directory = directory }

    static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "CurrentCapture", directoryHint: .isDirectory)
    }

    private var primaryURL: URL { directory.appending(path: "primary.image") }
    private var fallbackURL: URL { directory.appending(path: "fallback.image") }
    private var confidenceURL: URL { directory.appending(path: "confidence.r8") }
    private var stateURL: URL { directory.appending(path: "state.json") }

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
    }

    func load() -> (source: SourceImage, state: State)? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stateData = try? Data(contentsOf: stateURL),
              let state = try? decoder.decode(State.self, from: stateData),
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
        return (source, state)
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}
