import ImageIO
import UniformTypeIdentifiers
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
        XCTAssertEqual(derived.algorithmVersion, String(cString: PBRLabVersion()))
    }

    func testBundleHashesCanonicalAlbedoAndDeclaresOriginalMime() throws {
        let image = checkerboard(size: 256)
        let original = try XCTUnwrap(image.pngData())
        let source = try SourceImage(origin: .files, data: original)
        let quad = PerspectiveQuad.centeredSquare(for: source.size)
        let recipe = MaterialRecipe(preset: .stone)
        let derived = try MaterialProcessor.derive(image: source.image, quad: quad,
                                                   resolution: 256, recipe: recipe)
        let encoded = try MaterialBundle.make(source: source, quad: quad, label: "painted tile",
                                              category: "architectural", recipe: recipe,
                                              material: derived)
        let bundle = try JSONDecoder().decode(MaterialBundle.self, from: encoded)
        XCTAssertEqual(bundle.schemaVersion, 1)
        XCTAssertEqual(bundle.algorithmVersion, String(cString: PBRLabVersion()))
        XCTAssertEqual(bundle.sourceSHA256, MaterialBundle.sha256(derived.sourcePNG))
        XCTAssertEqual(bundle.capture.originalMime, "image/png")
        let embedded = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(bundle.capture.originalBase64)))
        XCTAssertEqual(bundle.capture.originalSHA256, MaterialBundle.sha256(embedded))
        XCTAssertEqual(bundle.capture.originalWidth, 256)
        XCTAssertEqual(bundle.capture.originalHeight, 256)
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

    func testRecipeEmitsAlgorithm110FieldsInCamelCase() throws {
        var recipe = MaterialRecipe(preset: .stone)
        recipe.normalStrength = 2.5
        recipe.normalYDown = true
        recipe.aoStrength = 1.5
        recipe.albedoEqualize = 0.4
        recipe.seamlessBlend = 0.2
        let image = checkerboard(size: 256)
        let source = try SourceImage(origin: .files, data: try XCTUnwrap(image.pngData()))
        let quad = PerspectiveQuad.centeredSquare(for: source.size)
        let derived = try MaterialProcessor.derive(image: source.image, quad: quad, resolution: 256, recipe: recipe)
        let encoded = try MaterialBundle.make(source: source, quad: quad, label: "tile", category: "stone",
                                              recipe: recipe, material: derived)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let json = try XCTUnwrap(document["recipe"] as? [String: Any])
        XCTAssertEqual(json["normalStrength"] as? Double, 2.5)
        XCTAssertEqual(json["normalYDown"] as? Bool, true)
        XCTAssertEqual(json["aoStrength"] as? Double, 1.5)
        XCTAssertEqual((json["albedoEqualize"] as? Double) ?? 0, 0.4, accuracy: 1e-6)
        XCTAssertEqual((json["seamlessBlend"] as? Double) ?? 0, 0.2, accuracy: 1e-6)
        XCTAssertEqual(document["algorithmVersion"] as? String, String(cString: PBRLabVersion()))
        // Recipes persisted by 1.0.0 builds decode with neutral 1.1.0 defaults.
        let legacy = Data(#"{"preset":"stone","heightStrength":0.2,"heightPolarity":1,"roughnessBase":0.7,"roughnessVariation":0.1,"aoRadiusPixels":10,"tileWrap":true,"bentNormal":false}"#.utf8)
        let decoded = try JSONDecoder().decode(MaterialRecipe.self, from: legacy)
        XCTAssertEqual(decoded.normalStrength, 1)
        XCTAssertFalse(decoded.normalYDown)
        XCTAssertEqual(decoded.seamlessBlend, 0)
    }

    func testEachBundleGetsAFreshCaptureID() throws {
        let image = checkerboard(size: 256)
        let source = try SourceImage(origin: .files, data: try XCTUnwrap(image.pngData()))
        let quad = PerspectiveQuad.centeredSquare(for: source.size)
        let recipe = MaterialRecipe(preset: .flat)
        let derived = try MaterialProcessor.derive(image: source.image, quad: quad, resolution: 256, recipe: recipe)
        let first = try JSONDecoder().decode(MaterialBundle.self, from: try MaterialBundle.make(
            source: source, quad: quad, label: "a", category: "b", recipe: recipe, material: derived))
        let second = try JSONDecoder().decode(MaterialBundle.self, from: try MaterialBundle.make(
            source: source, quad: quad, label: "a", category: "b", recipe: recipe, material: derived))
        XCTAssertNotEqual(first.captureId, second.captureId)
        let fixed = UUID()
        let pinned = try JSONDecoder().decode(MaterialBundle.self, from: try MaterialBundle.make(
            source: source, quad: quad, label: "a", category: "b", recipe: recipe, material: derived,
            captureId: fixed))
        XCTAssertEqual(pinned.captureId, fixed)
    }

    func testPreviewDerivationCannotBeExported() throws {
        let image = checkerboard(size: 256)
        let source = try SourceImage(origin: .files, data: try XCTUnwrap(image.pngData()))
        let quad = PerspectiveQuad.centeredSquare(for: source.size)
        let preview = try MaterialProcessor.derive(image: source.image, quad: quad, resolution: 256,
                                                   recipe: MaterialRecipe(preset: .flat), preview: true)
        XCTAssertTrue(preview.maps.values.allSatisfy { $0.png.isEmpty })
        XCTAssertThrowsError(try MaterialBundle.make(source: source, quad: quad, label: "a", category: "b",
                                                     recipe: MaterialRecipe(preset: .flat), material: preview))
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
        let quad = PerspectiveQuad.centeredSquare(for: source.size)
        let recipe = MaterialRecipe(preset: .stone)
        let derived = try MaterialProcessor.derive(image: source.selectedImage(for: quad), quad: quad,
                                                   resolution: 256, recipe: recipe)
        let encoded = try MaterialBundle.make(source: source, quad: quad, label: "test stone",
                                              category: "stone", recipe: recipe, material: derived)
        let bundle = try JSONDecoder().decode(MaterialBundle.self, from: encoded)
        XCTAssertTrue(bundle.capture.fallbackUsed)
        XCTAssertEqual(bundle.capture.constantColorCenterConfidence ?? 0, 0.42, accuracy: 0.0001)
        XCTAssertEqual(bundle.capture.fallbackOriginalMime, "image/png")
        let embedded = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(bundle.capture.fallbackOriginalBase64)))
        XCTAssertEqual(bundle.capture.fallbackOriginalSHA256, MaterialBundle.sha256(embedded))
        XCTAssertNotNil(UIImage(data: embedded))
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
        let quad = PerspectiveQuad.centeredSquare(for: source.size)
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

    func testMismatchedConfidenceAspectIsTreatedAsUnavailable() throws {
        let image = checkerboard(size: 256)
        let confidence = ConfidenceMap(width: 8, height: 4, pixels: Data(repeating: 255, count: 32))
        let source = try SourceImage(origin: .camera, data: try XCTUnwrap(image.pngData()),
                                     confidence: confidence, constantColorRequested: true, centerConfidence: 0.9)
        XCTAssertNil(source.confidence)
        XCTAssertEqual(source.captureMode(for: .centeredSquare(for: source.size)), "estimated-albedo-ordinary-photo")
    }

    @MainActor
    func testChangingInputsInvalidatesDerivedMapsAndNewPhotoClearsLabel() async throws {
        let image = checkerboard(size: 256)
        let bytes = try XCTUnwrap(image.pngData())
        let store = CaptureStore()
        let received = await store.receive(origin: .files, data: bytes)
        XCTAssertTrue(received, store.errorMessage ?? "Import failed")
        store.semanticLabel = "painted tile"
        store.resolution = 512
        await store.derive()
        XCTAssertNotNil(store.derived, store.errorMessage ?? "Derivation failed")
        XCTAssertTrue(store.hasExportableMaps)
        // Metadata is not a pixel input: maps stay exportable.
        store.semanticLabel = "renamed painted tile"
        store.category = "architectural"
        XCTAssertTrue(store.hasExportableMaps)
        let bundle = try await store.makeBundle()
        XCTAssertFalse(bundle.isEmpty)
        store.recipe.roughnessBase = 0.2
        XCTAssertNil(store.derived)
        do {
            _ = try await store.makeBundle()
            XCTFail("Export must require maps derived from the current inputs")
        } catch {}
        await store.receive(origin: .files, data: bytes)
        XCTAssertEqual(store.semanticLabel, "")
    }

    @MainActor
    func testDerivationReportsProgressAndCanBeCancelled() async throws {
        let image = checkerboard(size: 512)
        let quad = PerspectiveQuad.centeredSquare(for: image.size)
        let values = ProgressLog()
        let control = DerivationControl { values.append($0) }
        _ = try MaterialProcessor.derive(image: image, quad: quad, resolution: 512,
                                         recipe: MaterialRecipe(preset: .stone), control: control)
        XCTAssertEqual(values.last, 1)
        XCTAssertGreaterThan(values.count, 2)
        let cancelled = DerivationControl()
        cancelled.cancel()
        XCTAssertThrowsError(try MaterialProcessor.derive(image: image, quad: quad, resolution: 512,
                                                          recipe: MaterialRecipe(preset: .stone),
                                                          control: cancelled)) { error in
            guard case CaptureError.cancelled = error else { return XCTFail("Expected cancellation, got \(error)") }
        }
    }

    @MainActor
    func testCurrentCaptureSurvivesRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "persist-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = try XCTUnwrap(checkerboard(size: 256).pngData())
        let first = CaptureStore(persistenceDirectory: directory)
        await first.receive(origin: .files, data: bytes)
        first.semanticLabel = "persisted slate"
        first.recipe.normalYDown = true
        first.resolution = 1024
        let sourceID = try XCTUnwrap(first.source?.id)
        let stateFile = directory.appending(path: "state.json")
        for _ in 0..<40 {
            if let data = try? Data(contentsOf: stateFile), String(decoding: data, as: UTF8.self).contains("persisted slate") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let second = CaptureStore(persistenceDirectory: directory)
        await second.restore()
        XCTAssertEqual(second.source?.id, sourceID)
        XCTAssertEqual(second.semanticLabel, "persisted slate")
        XCTAssertTrue(second.recipe.normalYDown)
        XCTAssertEqual(second.resolution, 1024)
        XCTAssertEqual(second.crop, first.crop)
    }

    func testPrivacyScrubRemovesLocationSerialsAndOwnerMetadata() throws {
        let image = try XCTUnwrap(checkerboard(size: 64).cgImage)
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 122.0, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifBodySerialNumber: "SERIAL-123",
                                             kCGImagePropertyExifCameraOwnerName: "Jane Owner",
                                             kCGImagePropertyExifLensSerialNumber: "LENS-9"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Jane Artist",
                                             kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCity: "Cupertino",
                                             kCGImagePropertyIPTCByline: "Jane Byline"]
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let dirty = output as Data
        XCTAssertTrue(dirty.range(of: Data("SERIAL-123".utf8)) != nil, "Fixture must contain the serial")

        let clean = try PrivacyScrubber.scrub(dirty)
        XCTAssertEqual(clean.mime, "image/jpeg")
        for needle in ["SERIAL-123", "Jane", "LENS-9", "Cupertino"] {
            XCTAssertNil(clean.bytes.range(of: Data(needle.utf8)), "\(needle) survived scrubbing")
        }
        let source = try XCTUnwrap(CGImageSourceCreateWithData(clean.bytes as CFData, nil))
        let cleanProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertNil(cleanProperties[kCGImagePropertyGPSDictionary])
        XCTAssertNil(cleanProperties[kCGImagePropertyIPTCDictionary])
        XCTAssertEqual((cleanProperties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 6,
                       "Orientation is on the allow-list")
        XCTAssertEqual(clean.width, 64)
        XCTAssertThrowsError(try PrivacyScrubber.scrub(Data("not an image".utf8)))
    }

    func testCorrectedCropIsUprightAndKeepsAlpha() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 128))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 128, width: 256, height: 128))
            UIColor.clear.setFill()
            context.cgContext.clear(CGRect(x: 192, y: 192, width: 64, height: 64))
        }
        let pixels = try PerspectiveCropper.correctedRGBA8(try XCTUnwrap(image.cgImage), quad: .full, pixels: 256)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(pixels[(y * 256 + x) * 4..<(y * 256 + x) * 4 + 4]) }
        XCTAssertGreaterThan(pixel(10, 10)[0], 200, "Top row must come first (red)")
        XCTAssertLessThan(pixel(10, 10)[2], 40)
        XCTAssertGreaterThan(pixel(10, 200)[2], 200, "Bottom half must be blue")
        XCTAssertEqual(pixel(10, 10)[3], 255)
        XCTAssertGreaterThan(pixel(0, 0)[0], 200, "Edge pixels must not blend with outside black")
        XCTAssertEqual(pixel(0, 0)[3], 255)
        XCTAssertGreaterThan(pixel(0, 255)[2], 200)
        XCTAssertEqual(pixel(0, 255)[3], 255)
        XCTAssertLessThan(pixel(230, 230)[3], 10, "Transparent input must stay transparent")
    }

    func testRectangleDetectionFindsATiltedSwatch() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600), format: format).image { context in
            UIColor(white: 0.1, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
            UIColor(white: 0.9, alpha: 1).setFill()
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 220, y: 110))
            path.addLine(to: CGPoint(x: 600, y: 130))
            path.addLine(to: CGPoint(x: 580, y: 500))
            path.addLine(to: CGPoint(x: 200, y: 480))
            path.close()
            path.fill()
        }
        guard let quad = RectangleDetector.detect(in: try XCTUnwrap(image.cgImage)) else {
            throw XCTSkip("Vision rectangle detection returned no result on this runtime")
        }
        XCTAssertEqual(quad.topLeft.x, 220.0 / 800, accuracy: 0.03)
        XCTAssertEqual(quad.topLeft.y, 110.0 / 600, accuracy: 0.03)
        XCTAssertEqual(quad.bottomRight.x, 580.0 / 800, accuracy: 0.03)
        XCTAssertEqual(quad.bottomRight.y, 500.0 / 600, accuracy: 0.03)
        // The crop is pulled inside the detected edges.
        XCTAssertGreaterThan(quad.topLeft.x, 220.0 / 800 - 0.002)
        XCTAssertLessThan(quad.bottomRight.y, 500.0 / 600 + 0.002)
    }

    func testDuplicateAcknowledgementCountsAsDelivered() {
        XCTAssertTrue(MaterialLinkClient.isDuplicate("A capture with this ID is already in the inbox."))
        XCTAssertTrue(MaterialLinkClient.isDuplicate("Duplicate capture"))
        XCTAssertFalse(MaterialLinkClient.isDuplicate("Pairing code is invalid, expired, or busy"))
        XCTAssertGreaterThanOrEqual(MaterialLinkClient.approvalTimeout, 150,
                                    "The phone must outwait the Mac's 120 s approval window")
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
        format.preferredRange = .standard
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

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func append(_ value: Double) { lock.withLock { values.append(value) } }
    var last: Double? { lock.withLock { values.last } }
    var count: Int { lock.withLock { values.count } }
}

extension MaterialCaptureTests {
    func testConfidenceMapRotatesWithPhotoOrientation() {
        let original = ConfidenceMap(width: 2, height: 3,
                                     pixels: Data([1, 2, 3, 4, 5, 6]))
        let right = original.oriented(as: UIImage.Orientation.right)
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
        let quad = PerspectiveQuad.centeredSquare(for: source.size)
        let recipe = MaterialRecipe(preset: .stone)
        let derived = try MaterialProcessor.derive(image: source.image, quad: quad,
                                                   resolution: 256, recipe: recipe)
        let captureID = UUID()
        let envelope = try MaterialBundle.make(source: source, quad: quad,
                                               label: "integration painted tile", category: "test",
                                               recipe: recipe, material: derived,
                                               linkToken: code.token, captureId: captureID)
        let acknowledged = try await MaterialLinkClient().send(envelope: envelope, pairing: code, captureId: captureID)
        XCTAssertEqual(acknowledged, captureID)
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
        } catch {
            XCTFail("Expected a TLS failure, got \(error)")
        }
    }
}
