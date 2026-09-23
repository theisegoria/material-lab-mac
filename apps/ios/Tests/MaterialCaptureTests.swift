import ImageIO
import XCTest
@testable import MaterialCapture

final class MaterialCaptureTests: XCTestCase {
    func testFlatPaintedPatternDoesNotInventGeometry() throws {
        let image = checkerboard(size: 256)
        let recipe = MaterialRecipe(preset: .flat)
        let derived = try MaterialProcessor.derive(image: image, quad: .centeredSquare(for: image.size),
                                                   resolution: 256, recipe: recipe)
        XCTAssertEqual(derived.maps.count, 9)
        guard let height = derived.maps[.height], let normal = derived.maps[.normal],
              let roughness = derived.maps[.roughness] else { return XCTFail("Required map missing") }
        XCTAssertEqual(height.width, 256)
        XCTAssertEqual(height.height, 256)
        XCTAssertEqual(height.pixelFormat, "r16_unorm_png")
        XCTAssertEqual(height.png[24], 16, "Height PNG must remain 16-bit")
        XCTAssertEqual(height.png[25], 0, "Height PNG must be grayscale")
        XCTAssertNotNil(normal.preview)
        XCTAssertNotNil(roughness.preview)
        XCTAssertLessThan(derived.seam.heightValueDelta, 0.001)
    }

    func testBundleHashesCanonicalAlbedoAndDeclaresOriginalMime() throws {
        let image = checkerboard(size: 256)
        let original = try XCTUnwrap(image.pngData())
        let source = try SourceImage(origin: .files, data: original)
        let quad = PerspectiveQuad.centeredSquare(for: image.size)
        let recipe = MaterialRecipe(preset: .stone)
        let derived = try MaterialProcessor.derive(image: source.image, quad: quad,
                                                   resolution: 256, recipe: recipe)
        let encoded = try MaterialBundle.make(source: source, quad: quad, label: "painted tile",
                                              category: "architectural", recipe: recipe,
                                              material: derived)
        let bundle = try JSONDecoder().decode(MaterialBundle.self, from: encoded)
        XCTAssertEqual(bundle.schemaVersion, 1)
        XCTAssertEqual(bundle.sourceSHA256, MaterialBundle.sha256(derived.sourcePNG))
        XCTAssertEqual(bundle.capture.originalMime, "image/png")
        XCTAssertEqual(bundle.capture.originalSHA256, MaterialBundle.sha256(original))
        XCTAssertNil(bundle.link)
        XCTAssertFalse(bundle.runtimeAdmitted)
        XCTAssertNotNil(bundle.derived["normal"])
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let metadata = try XCTUnwrap(document["capture"] as? [String: Any])
        XCTAssertFalse(metadata.keys.contains { $0.lowercased().contains("gps") })
        let fixture = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
            .appendingPathComponent("material-capture-smoke.pbrcapture")
        try encoded.write(to: fixture, options: .atomic)
        print("PBR_CAPTURE_FIXTURE_PATH=\(fixture.path)")
    }


    func testConstantColorFallbackIsEmbeddedWithPrivacySafeProvenance() throws {
        let image = checkerboard(size: 256)
        let original = try XCTUnwrap(image.pngData())
        let fallback = try XCTUnwrap(UIImage(systemName: "square.fill")?.pngData())
        let confidence = ConfidenceMap(width: 4, height: 4,
                                       pixels: Data(repeating: 0, count: 16))
        let source = try SourceImage(origin: .camera, data: original, fallback: fallback,
                                     confidence: confidence, constantColorRequested: true,
                                     centerConfidence: 0.42)
        let quad = PerspectiveQuad.centeredSquare(for: source.image.size)
        let recipe = MaterialRecipe(preset: .stone)
        let derived = try MaterialProcessor.derive(image: source.selectedImage(for: quad), quad: quad,
                                                   resolution: 256, recipe: recipe)
        let encoded = try MaterialBundle.make(source: source, quad: quad, label: "test stone",
                                              category: "stone", recipe: recipe, material: derived)
        let bundle = try JSONDecoder().decode(MaterialBundle.self, from: encoded)
        XCTAssertTrue(bundle.capture.fallbackUsed)
        XCTAssertEqual(bundle.capture.constantColorCenterConfidence ?? 0, 0.42, accuracy: 0.0001)
        XCTAssertEqual(bundle.capture.fallbackOriginalMime, "image/png")
        XCTAssertEqual(bundle.capture.fallbackOriginalSHA256, MaterialBundle.sha256(fallback))
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(bundle.capture.fallbackOriginalBase64)), fallback)
        XCTAssertNil(bundle.capture.fallbackOmissionReason)
        XCTAssertFalse(encoded.contains(Data("GPS".utf8)))
        let fixture = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
            .appendingPathComponent("material-capture-fallback-smoke.pbrcapture")
        try encoded.write(to: fixture, options: .atomic)
        print("PBR_CAPTURE_FALLBACK_FIXTURE_PATH=\(fixture.path)")
    }

    func testConstantColorCenterConfidenceSurvivesMissingConfidenceMap() throws {
        let image = checkerboard(size: 256)
        let original = try XCTUnwrap(image.pngData())
        let source = try SourceImage(origin: .camera, data: original,
                                     constantColorRequested: true, centerConfidence: 0.37)
        let quad = PerspectiveQuad.centeredSquare(for: source.image.size)
        let recipe = MaterialRecipe(preset: .flat)
        let derived = try MaterialProcessor.derive(image: source.image, quad: quad,
                                                   resolution: 256, recipe: recipe)
        let encoded = try MaterialBundle.make(source: source, quad: quad,
                                              label: "painted panel", category: "test",
                                              recipe: recipe, material: derived)
        let bundle = try JSONDecoder().decode(MaterialBundle.self, from: encoded)
        XCTAssertNil(bundle.capture.confidenceSummary)
        XCTAssertEqual(bundle.capture.constantColorCenterConfidence ?? 0, 0.37, accuracy: 0.0001)
    }

    @MainActor
    func testChangingInputsInvalidatesDerivedMapsAndNewPhotoClearsLabel() async throws {
        let image = checkerboard(size: 256)
        let bytes = try XCTUnwrap(image.pngData())
        let store = CaptureStore()
        store.receive(origin: .files, data: bytes)
        store.semanticLabel = "painted tile"
        store.resolution = 512
        await store.derive()
        XCTAssertNotNil(store.derived, store.errorMessage ?? "Derivation failed")
        store.recipe.roughnessBase = 0.2
        XCTAssertNil(store.derived)
        XCTAssertThrowsError(try store.bundle())
        store.receive(origin: .files, data: bytes)
        XCTAssertEqual(store.semanticLabel, "")
    }

    func testConfidenceIsScoredInsideSelectedCrop() {
        var pixels = [UInt8](repeating: 255, count: 16 * 16)
        for y in 0..<16 { for x in 0..<8 { pixels[y * 16 + x] = 0 } }
        let map = ConfidenceMap(width: 16, height: 16, pixels: Data(pixels))
        let right = PerspectiveQuad(topLeft: .init(x: 0.6, y: 0), topRight: .init(x: 1, y: 0),
                                    bottomRight: .init(x: 1, y: 1), bottomLeft: .init(x: 0.6, y: 1))
        let left = PerspectiveQuad(topLeft: .init(x: 0, y: 0), topRight: .init(x: 0.4, y: 0),
                                   bottomRight: .init(x: 0.4, y: 1), bottomLeft: .init(x: 0, y: 1))
        XCTAssertTrue(map.score(in: right).adequate)
        XCTAssertFalse(map.score(in: left).adequate)
    }

    private func checkerboard(size: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { context in
            for y in 0..<8 {
                for x in 0..<8 {
                    ((x + y).isMultiple(of: 2) ? UIColor.white : UIColor.black).setFill()
                    context.fill(CGRect(x: x * size / 8, y: y * size / 8,
                                        width: size / 8, height: size / 8))
                }
            }
        }
    }
}

extension MaterialCaptureTests {
    func testConfidenceMapRotatesWithPhotoOrientation() {
        let original = ConfidenceMap(width: 2, height: 3,
                                     pixels: Data([1, 2, 3, 4, 5, 6]))
        let right = original.oriented(as: .right)
        XCTAssertEqual(right.width, 3)
        XCTAssertEqual(right.height, 2)
        XCTAssertEqual([UInt8](right.pixels), [5, 3, 1, 6, 4, 2])
    }
}


extension MaterialCaptureTests {
    func testPinnedLocalLinkWhenIntegrationPairingIsPresent() async throws {
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory,
                                                                 in: .userDomainMask).first)
        let codeURL = documents.appendingPathComponent("material-lab-test-pairing.json")
        guard FileManager.default.fileExists(atPath: codeURL.path) else {
            throw XCTSkip("No short-lived Mac pairing fixture supplied")
        }
        let code = try PairingCode(json: String(contentsOf: codeURL, encoding: .utf8))
        let image = checkerboard(size: 256)
        let original = try XCTUnwrap(image.pngData())
        let source = try SourceImage(origin: .files, data: original)
        let quad = PerspectiveQuad.centeredSquare(for: image.size)
        let recipe = MaterialRecipe(preset: .stone)
        let derived = try MaterialProcessor.derive(image: source.image, quad: quad,
                                                   resolution: 256, recipe: recipe)
        let envelope = try MaterialBundle.make(source: source, quad: quad,
                                               label: "integration painted tile", category: "test",
                                               recipe: recipe, material: derived,
                                               linkToken: code.token)
        let acknowledged = try await MaterialLinkClient().send(envelope: envelope, pairing: code)
        XCTAssertEqual(acknowledged, source.id)
    }
    func testWrongLeafPinRejectsBeforeTransferWhenIntegrationPairingIsPresent() async throws {
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory,
                                                                 in: .userDomainMask).first)
        let codeURL = documents.appendingPathComponent("material-lab-test-pairing.json")
        guard FileManager.default.fileExists(atPath: codeURL.path) else {
            throw XCTSkip("No short-lived Mac pairing fixture supplied")
        }
        let codeBytes = try Data(contentsOf: codeURL)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: codeBytes) as? [String: Any])
        let correctPin = try XCTUnwrap(json["leafSHA256"] as? String)
        json["leafSHA256"] = (correctPin.first == "0" ? "1" : "0") + correctPin.dropFirst()
        let wrongBytes = try JSONSerialization.data(withJSONObject: json)
        let wrong = try PairingCode(json: try XCTUnwrap(String(data: wrongBytes, encoding: .utf8)))
        do {
            _ = try await MaterialLinkClient().send(envelope: Data("{\"probe\":true}".utf8), pairing: wrong)
            XCTFail("TLS must reject a leaf certificate with the wrong SHA-256 pin")
        } catch LinkError.connectionFailed(let reason) {
            print("PIN_REJECTION_DETAIL=\(reason)")
            XCTAssertTrue(reason.contains("identity does not match"), "Reject the QR pin explicitly")
            // Expected: no capture frame is sent and the pairing token remains available.
        } catch {
            XCTFail("Expected a TLS failure, got \(error)")
        }
    }

}
