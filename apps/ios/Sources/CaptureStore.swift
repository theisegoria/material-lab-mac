import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class CaptureStore {
    private var inputRevision = 0
    private var derivedRevision: Int?
    private func invalidateDerivation() {
        inputRevision += 1
        derived = nil
        derivedRevision = nil
    }

    var source: SourceImage? { didSet { invalidateDerivation() } }
    var crop = PerspectiveQuad(topLeft: .init(x: 0, y: 0), topRight: .init(x: 1, y: 0),
                               bottomRight: .init(x: 1, y: 1), bottomLeft: .init(x: 0, y: 1)) {
        didSet { invalidateDerivation() }
    }
    var semanticLabel = "" { didSet { invalidateDerivation() } }
    var category = "uncategorized" { didSet { invalidateDerivation() } }
    var resolution = 1024 { didSet { invalidateDerivation() } }
    var recipe = MaterialRecipe(preset: .flat) { didSet { invalidateDerivation() } }
    var derived: DerivedMaterial?
    var isDeriving = false
    var errorMessage: String?

    func receiveCamera(_ result: CameraCapture) {
        receive(origin: .camera, data: result.primaryData, fallback: result.fallbackData,
                confidence: result.confidence, constantColorRequested: result.constantColorRequested,
                centerConfidence: result.centerConfidence, capturedAt: result.capturedAt)
    }

    func receive(origin: SourceImage.Origin, data: Data, fallback: Data? = nil,
                 confidence: ConfidenceMap? = nil, constantColorRequested: Bool = false,
                 centerConfidence: Float? = nil, capturedAt: Date = Date()) {
        do {
            let image = try SourceImage(origin: origin, data: data, fallback: fallback,
                                        confidence: confidence,
                                        constantColorRequested: constantColorRequested,
                                        centerConfidence: centerConfidence, capturedAt: capturedAt)
            source = image
            crop = .centeredSquare(for: image.image.size)
            semanticLabel = ""
            category = "uncategorized"
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setPreset(_ preset: MaterialPreset) {
        recipe = MaterialRecipe(preset: preset)
    }

    func derive() async {
        guard let source else { return }
        let label = semanticLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { errorMessage = CaptureError.missingLabel.localizedDescription; return }
        guard crop.isValid else { errorMessage = CaptureError.invalidCrop.localizedDescription; return }
        isDeriving = true
        errorMessage = nil
        let image = source.selectedImage(for: crop)
        let selectedCrop = crop
        let selectedRecipe = recipe
        let selectedResolution = resolution
        let revision = inputRevision
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try MaterialProcessor.derive(image: image, quad: selectedCrop,
                                             resolution: selectedResolution, recipe: selectedRecipe)
            }.value
            if revision == inputRevision {
                derived = result
                derivedRevision = revision
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isDeriving = false
    }

    func bundle(linkToken: String? = nil) throws -> Data {
        guard let source, let derived, derivedRevision == inputRevision else {
            throw CaptureError.derivationFailed("Inputs changed; derive again before export")
        }
        return try MaterialBundle.make(source: source, quad: crop,
                                       label: semanticLabel.trimmingCharacters(in: .whitespacesAndNewlines),
                                       category: category, recipe: recipe,
                                       material: derived, linkToken: linkToken)
    }
}
