import ImageIO
import UniformTypeIdentifiers
import AppIntents
import AVFoundation
import simd
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

    @MainActor
    func testLibraryKeepsEveryCaptureAndOpensDeletesAndMigrates() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "library-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        // A capture saved by a pre-library build is migrated in and becomes current.
        let legacy = FileManager.default.temporaryDirectory.appending(path: "legacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: legacy) }
        let oldPersistence = CapturePersistence(directory: legacy)
        let oldSource = try SourceImage(origin: .files, data: try XCTUnwrap(checkerboard(size: 128).pngData()))
        oldPersistence.saveSource(oldSource)
        oldPersistence.saveState(.init(source: oldSource, crop: .centeredSquare(for: oldSource.size),
                                       semanticLabel: "legacy plaster", category: "wall", resolution: 1024,
                                       recipe: MaterialRecipe(preset: .stone)))
        CaptureLibrary(root: root).migrateLegacy(from: legacy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(CaptureLibrary(root: root).currentID, oldSource.id)

        let store = CaptureStore(libraryDirectory: root)
        await store.restore()
        XCTAssertEqual(store.semanticLabel, "legacy plaster")
        // A new photo is added alongside, not over, the previous capture.
        await store.receive(origin: .files, data: try XCTUnwrap(syntheticBricks(size: 128).pngData()))
        store.semanticLabel = "new brick"
        let newID = try XCTUnwrap(store.source?.id)
        for _ in 0..<40 where store.libraryEntries.count < 2 || store.libraryEntries.first?.label != "new brick" {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(store.libraryEntries.map(\.label), ["new brick", "legacy plaster"])
        // Open the older one, then delete it: the library keeps the other.
        await store.open(oldSource.id)
        XCTAssertEqual(store.source?.id, oldSource.id)
        XCTAssertEqual(store.semanticLabel, "legacy plaster")
        await store.delete(oldSource.id)
        XCTAssertNil(store.source)
        XCTAssertEqual(store.libraryEntries.map(\.id), [newID])
    }

    @MainActor
    func testSavedRecipesPersistApplyAndDelete() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "recipes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = CaptureStore(libraryDirectory: root)
        first.recipe = MaterialRecipe(preset: .stone)
        first.recipe.heightStrength = 0.31
        first.saveCurrentRecipe(named: "Wet slate")
        first.saveCurrentRecipe(named: "wet SLATE")  // Same name, different case: replaces.
        XCTAssertEqual(first.savedRecipes.count, 1)
        let second = CaptureStore(libraryDirectory: root)
        await second.refreshLibrary()
        let saved = try XCTUnwrap(second.savedRecipes.first)
        XCTAssertEqual(saved.recipe.heightStrength, 0.31)
        second.applySavedRecipe(saved)
        XCTAssertEqual(second.recipe, saved.recipe)
        second.deleteSavedRecipe(saved)
        let third = CaptureStore(libraryDirectory: root)
        await third.refreshLibrary()
        XCTAssertTrue(third.savedRecipes.isEmpty)
    }

    func testAlbedoRepairExportsUnconditionedSourceAndRepairProvenance() throws {
        // A non-tiling source: a horizontal ramp whose left and right edges differ strongly.
        let size = 256
        let ramp = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { context in
            for x in 0..<size {
                UIColor(white: 0.15 + 0.7 * CGFloat(x) / CGFloat(size), alpha: 1).setFill()
                context.fill(CGRect(x: x, y: 0, width: 1, height: size))
            }
            UIColor(red: 0.6, green: 0.2, blue: 0.1, alpha: 1).setFill()
            for row in stride(from: 0, to: size, by: 32) { context.fill(CGRect(x: 0, y: row, width: size, height: 4)) }
        }
        let source = try SourceImage(origin: .files, data: try XCTUnwrap(ramp.pngData()))
        let quad = PerspectiveQuad.centeredSquare(for: source.size)
        var recipe = MaterialRecipe(preset: .stone)
        recipe.albedoRepair = .auto
        XCTAssertTrue(recipe.conditionsAlbedo)
        let derived = try MaterialProcessor.derive(image: source.image, quad: quad, resolution: size, recipe: recipe)
        let repair = try XCTUnwrap(derived.repair)
        XCTAssertLessThan(repair.seamAfter.worst, repair.seamBefore.worst, "Repair must reduce the wrap step")
        // The canonical source stays the corrected crop, so a receiver that re-derives does not repair twice.
        XCTAssertNotEqual(derived.sourcePNG, try XCTUnwrap(derived.maps[.albedo]).png)
        let encoded = try MaterialBundle.make(source: source, quad: quad, label: "ramp", category: "test",
                                              recipe: recipe, material: derived)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual((document["recipe"] as? [String: Any])?["albedoRepair"] as? String, "auto")
        let capture = try XCTUnwrap(document["capture"] as? [String: Any])
        let block = try XCTUnwrap(capture["albedoRepair"] as? [String: Any])
        XCTAssertNotNil(block["seamBefore"]); XCTAssertNotNil(block["seamAfter"])
        let albedo = try XCTUnwrap((document["derived"] as? [String: Any])?["albedo"] as? [String: Any])
        XCTAssertEqual(albedo["provenance"] as? String, "repaired_tileable_albedo_derived_from_source")
        // Recipes saved before 1.4.0 decode with repair off.
        let legacy = Data(#"{"preset":"stone","heightStrength":0.2,"heightPolarity":1,"roughnessBase":0.7,"roughnessVariation":0.1,"aoRadiusPixels":10,"tileWrap":true,"bentNormal":false}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(MaterialRecipe.self, from: legacy).albedoRepair, .off)
        // Left for host-side CLI validation (material-lab --validate).
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("repair-test.pbrcapture")
        try encoded.write(to: out)
        print("REPAIR_CAPTURE=\(out.path)")
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
    func testLearnedPreviewShowsQuickEstimateBeforeFullFieldAndExportUsesFullField() async throws {
        try XCTSkipIf(LearnedNormalEstimator.shared.locateModel() == nil, "MoGe2Normals model is not bundled in this build")
        LearnedNormalEstimator.shared.clearCache()
        let store = CaptureStore()
        await store.refreshLearnedModel()
        let received = await store.receive(origin: .files, data: try XCTUnwrap(syntheticBricks(size: 1024).pngData()))
        XCTAssertTrue(received, store.errorMessage ?? "Import failed")
        store.semanticLabel = "quick bricks"
        store.resolution = 1024
        var recipe = MaterialRecipe(preset: .stone)
        recipe.guideNormalWeight = 1
        store.recipe = recipe
        var sawQuickPreview = false, sawCoarseProgress = false, sawFullPasses = false
        let deadline = Date().addingTimeInterval(300)  // simulator inference runs on the CPU
        repeat {
            try await Task.sleep(for: .milliseconds(20))
            if store.showsQuickLearnedEstimate { sawQuickPreview = true }
            if let progress = store.learnedProgress {
                if progress.coarse { sawCoarseProgress = true }
                if !progress.coarse && progress.passes > 2 { sawFullPasses = true }
            }
        } while (store.learnedProgress != nil || store.showsQuickLearnedEstimate || store.isUpdatingPreview)
            && Date() < deadline
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(sawCoarseProgress, "A quick single-tile estimate runs first")
        XCTAssertTrue(sawQuickPreview, "The preview shows the quick estimate while the full field is computed")
        XCTAssertTrue(sawFullPasses, "The full field runs every pass of the 1024² tiling")
        XCTAssertFalse(store.showsQuickLearnedEstimate, "The full field replaces the quick estimate")
        XCTAssertEqual(store.livePreview?.guideNormals?.workResolution, 1024)
        await store.derive()
        XCTAssertEqual(store.derived?.guideNormals?.workResolution, 1024, "Exports never carry the quick estimate")
    }

    @MainActor
    func testMaterialExportWritesValidatorShapedBundleAndEveryTarget() async throws {
        let store = CaptureStore()
        await store.refreshLearnedModel()
        let received = await store.receive(origin: .files, data: try XCTUnwrap(syntheticBricks(size: 512).pngData()))
        XCTAssertTrue(received, store.errorMessage ?? "Import failed")
        store.semanticLabel = "Export bricks"
        store.resolution = 512
        let library = try XCTUnwrap(LibraryPreset.named("red-brick"))
        store.recipe = store.recipe.applyingLibraryPreset(library)
        store.recipe.albedoRepair = .auto
        store.recipe.bentNormal = true
        if store.learnedModel != nil { store.recipe.guideNormalWeight = 1 }
        store.recipe.tileMetres = 2
        store.recipe.midReliefShare = 0.5
        store.recipe.roughnessAlbedoLimit = 0.3
        XCTAssertEqual(store.recipe.materialPreset, "red-brick")
        XCTAssertEqual(store.recipe.preset, .stone)
        XCTAssertEqual(store.recipe.roughnessBase, library.recipe.roughness_base)
        await store.derive()
        XCTAssertTrue(store.hasExportableMaps, store.errorMessage ?? "Derivation failed")
        let savedTargets = ExportTargetPreference.load()
        defer { ExportTargetPreference.save(savedTargets) }
        store.exportTargets = Set(ExportTarget.all.map(\.id))
        let folder = try await store.makeMaterialExport()
        let bundle = folder.appending(path: "export-bricks.pbrmaterial")
        let manifestData = try Data(contentsOf: bundle.appending(path: "manifest.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let recipe = try XCTUnwrap(manifest["recipe"] as? [String: Any])
        XCTAssertEqual(recipe["material_preset"] as? String, "red-brick")
        XCTAssertEqual(recipe["preset"] as? String, "stone")
        XCTAssertEqual(recipe["tile_metres"] as? Double, 2)
        XCTAssertEqual(recipe["mid_relief_share"] as? Double, 0.5)
        XCTAssertEqual(recipe["roughness_albedo_limit"] as? Double, 0.3)
        XCTAssertEqual(recipe["substrate_relief"] as? Double, 0)
        let relief = try XCTUnwrap(manifest["relief"] as? [String: Any])
        for key in ["mid_relief_share_before", "mid_relief_share_after", "roughness_albedo_correlation_before",
                    "roughness_albedo_correlation_after"] {
            XCTAssertNotNil(relief[key] as? Double, key)
        }
        XCTAssertNotNil(manifest["albedo_repair"])
        XCTAssertEqual((manifest["maps"] as? [String: Any])?.count, 10, "Nine required maps plus the bent normal")
        for target in ExportTarget.all {
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.destination(beside: bundle).path), target.id)
        }
        // Hand the folder to the host so the CLI validator can check it (TEST_RUNNER_EXPORT_DIR).
        if let host = ProcessInfo.processInfo.environment["EXPORT_DIR"], !host.isEmpty {
            let destination = URL(fileURLWithPath: host).appending(path: folder.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: folder, to: destination)
        }
    }

    @MainActor
    func testAuthoredMapsReplaceEstimatesPersistAndExport() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "authored-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureStore(libraryDirectory: root)
        let received = await store.receive(origin: .files, data: try XCTUnwrap(syntheticBricks(size: 256).pngData()))
        XCTAssertTrue(received, store.errorMessage ?? "Import failed")
        store.semanticLabel = "Painted tiles"
        store.resolution = 512
        store.setHandMadeAlbedo(true)
        func gray(_ value: (Int, Int) -> UInt8) -> Data {
            let size = 64
            var pixels = [UInt8](repeating: 0, count: size * size)
            for y in 0..<size { for x in 0..<size { pixels[y * size + x] = value(x, y) } }
            let context = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            return UIImage(cgImage: context.makeImage()!).pngData()!
        }
        XCTAssertTrue(store.setAuthoredMap(.roughness, data: gray { _, _ in 51 }, name: "rough.png"))
        XCTAssertTrue(store.setAuthoredMap(.metalness, data: gray { x, _ in x < 32 ? 255 : 0 }, name: "metal.png"))
        XCTAssertFalse(store.setAuthoredMap(.ao, data: Data("not an image".utf8), name: "x.txt"))
        XCTAssertNotNil(store.recipe.assignedMetalness, "A metalness map turns on assigned metalness")
        await store.derive()
        let derived = try XCTUnwrap(store.derived, store.errorMessage ?? "Derivation failed")
        // The authored roughness replaces the estimate exactly (PNG-decoded check of one pixel).
        let rough = try XCTUnwrap(UIImage(data: try XCTUnwrap(derived.maps[.roughness]?.png))?.cgImage)
        let pixel = try XCTUnwrap(rough.dataProvider?.data as Data?)
        XCTAssertEqual(pixel[0], 51)

        let savedTargets = ExportTargetPreference.load()
        defer { ExportTargetPreference.save(savedTargets) }
        store.exportTargets = ["unity"]
        let folder = try await store.makeMaterialExport()
        let manifestData = try Data(contentsOf: folder.appending(path: "painted-tiles.pbrmaterial/manifest.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let maps = try XCTUnwrap(manifest["maps"] as? [String: [String: Any]])
        XCTAssertEqual(maps["albedo"]?["provenance"] as? String, "authored_albedo")
        XCTAssertEqual(maps["roughness"]?["provenance"] as? String, "authored_roughness_map")
        XCTAssertEqual((manifest["source"] as? [String: Any])?["source_kind"] as? String, "authored_albedo")
        XCTAssertEqual(Set((manifest["authored_inputs"] as? [String: Any])?.keys ?? [:].keys), ["roughness", "metalness"])
        if let host = ProcessInfo.processInfo.environment["EXPORT_DIR"], !host.isEmpty {
            let destination = URL(fileURLWithPath: host).appending(path: "authored-" + folder.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: folder, to: destination)
        }

        // The authored maps are saved with the capture and come back on reopen.
        try await Task.sleep(for: .seconds(1.2))
        let reopened = CaptureStore(libraryDirectory: root)
        await reopened.restore()
        XCTAssertTrue(reopened.authored.handMadeAlbedo)
        XCTAssertEqual(Set(reopened.authored.maps.keys), [.roughness, .metalness])
        XCTAssertEqual(reopened.authored.maps[.roughness]?.name, "rough.png")
    }

    @MainActor
    func testRecipeUndoRedoCoalescesDragsAndResetsPerCapture() async throws {
        let store = CaptureStore()
        _ = await store.receive(origin: .files, data: try XCTUnwrap(checkerboard(size: 128).pngData()))
        XCTAssertFalse(store.canUndo)
        let start = store.recipe
        // A drag: many quick edits are one undo step.
        for value in stride(from: Float(0.1), through: 0.4, by: 0.05) { store.recipe.heightStrength = value }
        try await Task.sleep(for: .seconds(0.8))
        store.recipe.roughnessBase = 0.2
        store.undo()
        XCTAssertEqual(store.recipe.roughnessBase, start.roughnessBase)
        XCTAssertEqual(store.recipe.heightStrength, 0.4, accuracy: 1e-6)
        store.undo()
        XCTAssertEqual(store.recipe, start)
        XCTAssertFalse(store.canUndo)
        store.redo()
        store.redo()
        XCTAssertEqual(store.recipe.roughnessBase, 0.2)
        XCTAssertFalse(store.canRedo)
        // A new capture starts fresh.
        _ = await store.receive(origin: .files, data: try XCTUnwrap(checkerboard(size: 128).pngData()))
        XCTAssertFalse(store.canUndo)
    }

    func testRelitImageFollowsTheLight() throws {
        let image = syntheticBricks(size: 256)
        let source = try SourceImage(origin: .files, data: try XCTUnwrap(image.pngData()))
        var recipe = MaterialRecipe(preset: .stone)
        recipe.heightStrength = 0.4
        let material = try MaterialProcessor.derive(image: source.image, quad: .centeredSquare(for: source.size),
                                                    resolution: 256, recipe: recipe, preview: true)
        func mean(_ image: CGImage) -> Double {
            let data = image.dataProvider!.data! as Data
            var sum = 0
            for i in stride(from: 1, to: data.count, by: 4) { sum += Int(data[i]) }
            return Double(sum) / Double(data.count / 4)
        }
        let overhead = try XCTUnwrap(MaterialProcessor.relitImage(material, azimuth: 0, elevation: .pi / 2))
        let grazing = try XCTUnwrap(MaterialProcessor.relitImage(material, azimuth: 0, elevation: 0.1))
        XCTAssertEqual(overhead.width, 256)
        XCTAssertGreaterThan(mean(overhead), mean(grazing) + 20, "Overhead light is brighter than grazing light")
    }

    func testDeriveMaterialIntentWritesBundleAndFormats() async throws {
        var intent = DeriveMaterialIntent()
        intent.photo = IntentFile(data: try XCTUnwrap(syntheticBricks(size: 512).pngData()), filename: "bricks.png")
        intent.material = LibraryPreset.named("red-brick").map(MaterialPresetEntity.init)
        intent.formats = ExportTarget.named(["glb", "unreal"]).map(ExportFormatEntity.init)
        intent.name = "Shortcut bricks"
        intent.resolution = 512
        let files = try await intent.perform().value ?? []
        let names = files.map(\.filename).sorted()
        XCTAssertEqual(names, ["shortcut-bricks-unreal", "shortcut-bricks.glb", "shortcut-bricks.pbrmaterial"])
        let bundle = try XCTUnwrap(files.first { $0.filename.hasSuffix(".pbrmaterial") }?.fileURL)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: bundle.appending(path: "manifest.json"))) as? [String: Any])
        XCTAssertEqual((manifest["recipe"] as? [String: Any])?["material_preset"] as? String, "red-brick")
    }

    /// A synthetic 256×192 depth map seen by a pinhole camera (fx = fy = 200): `depthAt(x, y)` in metres.
    private func syntheticDepth(orientation: UInt32 = 1, holes: Bool = false,
                                _ depthAt: (Float, Float) -> Float) -> DepthCapture {
        let w = 256, h = 192
        var depth = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                depth[y * w + x] = holes && (x + y) % 2 == 0 ? .nan : depthAt(Float(x) + 0.5, Float(y) + 0.5)
            }
        }
        return DepthCapture(width: w, height: h, depth: depth, fx: 200, fy: 200, cx: 128, cy: 96,
                            orientation: orientation, isAbsolute: true)
    }

    private func decodedNormals(_ result: DepthGuide.Result) -> [SIMD3<Float>] {
        stride(from: 0, to: result.rgba8.count, by: 4).map {
            SIMD3(Float(result.rgba8[$0]) / 127.5 - 1, Float(result.rgba8[$0 + 1]) / 127.5 - 1, Float(result.rgba8[$0 + 2]) / 127.5 - 1)
        }
    }

    func testDepthGuideOfATiltedWallIsFlatInTangentSpace() throws {
        // A wall 0.5 m away rotated 35° about the vertical axis: depth varies across x, yet in the wall's own tangent
        // frame it is flat, so the guide must be +Z everywhere.
        let tilt = Float(35) * .pi / 180
        let capture = syntheticDepth { x, _ in
            let rayX = (x - 128) / 200
            return 0.5 / (1 - rayX * tanf(tilt))   // Plane z = 0.5 + x·tan(tilt), intersected with the pixel ray.
        }
        let result = try XCTUnwrap(DepthGuide.normals(capture, quad: .centeredSquare(for: CGSize(width: 256, height: 192)), size: 64))
        let normals = decodedNormals(result)
        let meanXY = normals.map { abs($0.x) + abs($0.y) }.reduce(0, +) / Float(normals.count)
        XCTAssertLessThan(meanXY, 0.04, "A plane seen at an angle is flat in tangent space")
        XCTAssertLessThan(result.planeResidual, 0.001)
    }

    func testDepthGuideReadsARidgeWithTheRightSigns() throws {
        // A fronto-parallel wall at 0.5 m with a vertical ridge raised 1 cm towards the camera at the centre column.
        let ridge: (Float, Float) -> Float = { x, _ in 0.5 - 0.01 * expf(-powf((x - 128) / 18, 2)) }
        let square = PerspectiveQuad.centeredSquare(for: CGSize(width: 256, height: 192))
        let flat = decodedNormals(try XCTUnwrap(DepthGuide.normals(syntheticDepth(ridge), quad: square, size: 64)))
        let row = 32 * 64
        XCTAssertLessThan(flat[row + 26].x, -0.05, "The left flank faces left")
        XCTAssertGreaterThan(flat[row + 38].x, 0.05, "The right flank faces right")
        XCTAssertLessThan(abs(flat[row + 26].y), 0.05)
        // The same scene shot in portrait (EXIF 6): the sensor's columns run down the upright photo, so the ridge
        // crosses the upright crop horizontally and its upper flank faces up (+Y, green-up).
        let portrait = syntheticDepth(orientation: 6, ridge)
        let uprightSquare = PerspectiveQuad.centeredSquare(for: CGSize(width: 192, height: 256))
        let rotated = decodedNormals(try XCTUnwrap(DepthGuide.normals(portrait, quad: uprightSquare, size: 64)))
        XCTAssertGreaterThan(rotated[26 * 64 + 32].y, 0.05, "The upper flank faces up")
        XCTAssertLessThan(rotated[38 * 64 + 32].y, -0.05, "The lower flank faces down")
        // A crop with no usable depth is refused.
        XCTAssertNil(DepthGuide.normals(syntheticDepth { _, _ in .nan }, quad: square, size: 64))
    }

    func testDepthStackAveragesSteadyFramesAndRejectsMotionAndScatter() throws {
        var seed: UInt32 = 7
        func noise() -> Float { seed = seed &* 1664525 &+ 1013904223; return Float(seed >> 8) / Float(1 << 24) - 0.5 }
        // Three frames before the phone settled (wall 10 cm further), then nine steady frames of a wall at 0.5 m with
        // ±6 mm noise. Columns 0-15 are seen in only two steady frames; columns 16-31 scatter by ±5 cm.
        var stack = DepthStack()
        var single: DepthCapture?
        for k in 0..<12 {
            let frame = syntheticDepth { x, _ in
                if k < 3 { return 0.6 + 0.012 * noise() }
                if x < 16 { return k < 5 ? 0.5 : .nan }
                if x < 32 { return 0.5 + 0.1 * noise() }
                return 0.5 + 0.012 * noise()
            }
            stack.add(frame)
            if k == 11 { single = frame }
        }
        XCTAssertEqual(DepthStack.steadyFrames(stack.frames).count, 9, "Frames from before the phone settled are dropped")
        let averaged = try XCTUnwrap(DepthStack.average(stack.frames, orientation: 6))
        XCTAssertEqual(averaged.frames, 9)
        XCTAssertEqual(averaged.orientation, 6)
        let w = averaged.width
        func rms(_ capture: DepthCapture) -> Float {
            var sum: Float = 0, n: Float = 0
            for y in 0..<capture.height { for x in 64..<192 { let z = capture.depth[y * w + x]; sum += (z - 0.5) * (z - 0.5); n += 1 } }
            return sqrt(sum / n)
        }
        let single1 = try XCTUnwrap(single)
        XCTAssertLessThan(rms(averaged), 0.45 * rms(single1), "Averaging nine frames lowers the noise")
        XCTAssertTrue(averaged.depth[100 * w + 5].isNaN, "Seen in too few frames")
        XCTAssertTrue(averaged.depth[100 * w + 20].isNaN, "Readings scatter more than LiDAR noise")
        XCTAssertGreaterThan(try XCTUnwrap(averaged.confidence)[100 * w + 120], 150)
        XCTAssertGreaterThan(averaged.meanConfidence, 0.6)
        // The sidecar file round-trips exactly.
        let decoded = try XCTUnwrap(DepthCapture(encoded: averaged.encoded()))
        XCTAssertEqual(decoded.width, averaged.width)
        XCTAssertEqual(decoded.frames, 9)
        XCTAssertEqual(decoded.confidence, averaged.confidence)
        XCTAssertEqual(decoded.fx, averaged.fx)
        XCTAssertTrue(zip(decoded.depth, averaged.depth).allSatisfy { $0 == $1 || ($0.isNaN && $1.isNaN) })
        XCTAssertNil(DepthCapture(encoded: Data("nope".utf8)))
    }

    func testDepthMeasuresTheCropOnTheSurface() throws {
        // A fronto-parallel wall 0.5 m away: a crop spanning p pixels of a 200 px focal length is 0.5 · p / 200 m wide.
        let size = CGSize(width: 256, height: 192)
        let quad = PerspectiveQuad.centeredSquare(for: size)
        let measured = try XCTUnwrap(DepthGuide.measure(syntheticDepth { _, _ in 0.5 }, quad: quad))
        let expectedWidth = Float((quad.topRight.x - quad.topLeft.x) * size.width) * 0.5 / 200
        let expectedHeight = Float((quad.bottomLeft.y - quad.topLeft.y) * size.height) * 0.5 / 200
        XCTAssertEqual(measured.widthMetres, expectedWidth, accuracy: expectedWidth * 0.03)
        XCTAssertEqual(measured.heightMetres, expectedHeight, accuracy: expectedHeight * 0.03)
        XCTAssertLessThan(measured.planeResidual, 0.001)
        // Twice as far, twice as wide; relative (disparity) depth measures nothing.
        let far = try XCTUnwrap(DepthGuide.measure(syntheticDepth { _, _ in 1.0 }, quad: quad))
        XCTAssertEqual(far.widthMetres / measured.widthMetres, 2, accuracy: 0.05)
        let relative = DepthCapture(width: 256, height: 192, depth: [Float](repeating: 1, count: 256 * 192),
                                    fx: 200, fy: 200, cx: 128, cy: 96, orientation: 1, isAbsolute: false)
        XCTAssertNil(DepthGuide.measure(relative, quad: quad))
    }

    func testSplitBandsTakesFormFromDepthAndDetailFromLearned() throws {
        let n = 64
        func normals(_ gx: (Int) -> Float) -> [UInt8] {
            var out = [UInt8](repeating: 255, count: n * n * 4)
            for y in 0..<n { for x in 0..<n {
                let v = simd_normalize(SIMD3<Float>(-gx(x), 0, 1)), o = (y * n + x) * 4
                out[o] = DepthGuide.encodeUnit(v.x); out[o + 1] = DepthGuide.encodeUnit(v.y); out[o + 2] = DepthGuide.encodeUnit(v.z)
            } }
            return out
        }
        let k = 2 * Float.pi / Float(n)
        let depth = normals { 0.25 * sinf(k * Float($0)) }                                   // measured form
        let learned = normals { -0.3 * cosf(k * Float($0)) + 0.15 * sinf(Float.pi / 2 * Float($0)) } // wrong form + 4 px detail
        let combined = DepthGuide.splitBands(low: depth, high: learned, size: n)
        let gx: [Float] = (0..<(n * n)).map {
            let nx = Float(combined[$0 * 4]) / 127.5 - 1, nz = Float(combined[$0 * 4 + 2]) / 127.5 - 1
            return -nx / nz
        }
        let low = DepthGuide.blur(gx, size: n, radius: max(2, n / 64))
        var formError: Float = 0, detailCorrelation: Float = 0, detailEnergy: Float = 0
        let row = 32 * n
        for x in 8..<(n - 8) {
            formError = max(formError, abs(low[row + x] - 0.25 * sinf(k * Float(x))))
            let detail = gx[row + x] - low[row + x], expected = sinf(Float.pi / 2 * Float(x))
            detailCorrelation += detail * expected; detailEnergy += expected * expected
        }
        XCTAssertLessThan(formError, 0.06, "Large-scale form follows the measured depth, not the learned field")
        XCTAssertGreaterThan(detailCorrelation / detailEnergy, 0.05, "Fine detail comes from the learned field")
    }

    @MainActor
    func testAveragedLiDARDepthGivesMeasuredFormTileSizeAndPersists() async throws {
        // A 512² photo with averaged LiDAR depth (as the camera's stack delivers): a wall 0.4 m away seen by a 128 px
        // focal length over a 128² map, so the whole frame is 0.4 m wide, with a horizontal ridge 8 mm high.
        let w = 128
        var depth = [Float](repeating: 0, count: w * w)
        for y in 0..<w { for x in 0..<w { depth[y * w + x] = 0.4 - 0.008 * expf(-powf((Float(y) - 64) / 10, 2)) + 0 * Float(x) } }
        let lidar = DepthCapture(width: w, height: w, depth: depth, fx: 128, fy: 128, cx: 64, cy: 64, orientation: 1,
                                 isAbsolute: true, confidence: [UInt8](repeating: 230, count: w * w), frames: 9)
        let root = FileManager.default.temporaryDirectory.appending(path: "lidar-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureStore(libraryDirectory: root)
        // Settle the learned model first: its arrival mid-derivation would mark the result stale.
        await store.refreshLearnedModel()
        let received = await store.receive(origin: .camera, data: try XCTUnwrap(syntheticBricks(size: 512).pngData()), depth: lidar)
        XCTAssertTrue(received, store.errorMessage ?? "Import failed")
        XCTAssertTrue(store.sourceHasDepth)
        let measured = try XCTUnwrap(store.depthMeasurement, "Absolute depth measures the crop")
        let quad = store.crop
        let expected = Float(quad.topRight.x - quad.topLeft.x) * 0.4
        XCTAssertEqual(measured.widthMetres, expected, accuracy: expected * 0.04)
        store.semanticLabel = "LiDAR ridge"
        store.resolution = 512
        store.recipe = MaterialRecipe(preset: .stone)
        XCTAssertEqual(store.recipe.tileMetres, 0)
        store.setDepthGeometry(true)
        await store.derive()
        let derived = try XCTUnwrap(store.derived, store.errorMessage ?? "Derivation failed")
        XCTAssertTrue(derived.measuredGuide)
        XCTAssertEqual(try XCTUnwrap(derived.measuredTileMetres), measured.widthMetres, accuracy: 1e-4)
        XCTAssertGreaterThan(try XCTUnwrap(derived.relief).measuredFormRmsSlope, 0)
        let savedTargets = ExportTargetPreference.load()
        defer { ExportTargetPreference.save(savedTargets) }
        store.exportTargets = []
        let folder = try await store.makeMaterialExport()
        let manifestData = try Data(contentsOf: folder.appending(path: "lidar-ridge.pbrmaterial/manifest.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let section = try XCTUnwrap(manifest["depth"] as? [String: Any])
        XCTAssertEqual(section["frames_averaged"] as? Int, 9)
        XCTAssertEqual(section["tile_metres_from_depth"] as? Bool, true)
        XCTAssertEqual(section["measured_form"] as? Bool, true)
        XCTAssertGreaterThan(section["height_span_mm"] as? Double ?? 0, 0)
        let recipe = try XCTUnwrap(manifest["recipe"] as? [String: Any])
        XCTAssertEqual(recipe["tile_metres"] as? Double ?? 0, Double(measured.widthMetres), accuracy: 1e-3)
        if let host = ProcessInfo.processInfo.environment["EXPORT_DIR"], !host.isEmpty {
            let destination = URL(fileURLWithPath: host).appending(path: "lidar-" + folder.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: folder, to: destination)
        }
        // The averaged depth is kept beside the capture and comes back on reopen.
        try await Task.sleep(for: .seconds(1.2))
        let reopened = CaptureStore(libraryDirectory: root)
        await reopened.restore()
        XCTAssertEqual(reopened.source?.depth?.frames, 9)
        XCTAssertNotNil(reopened.depthMeasurement)
    }

    /// A JPEG of `image` with an embedded DepthFloat32 map (as the LiDAR camera writes with embedsDepthDataInPhoto).
    private func jpegWithDepth(_ image: UIImage, depthWidth: Int, depthHeight: Int,
                               _ depthAt: (Int, Int) -> Float) throws -> Data {
        var depth = [Float32](repeating: 0, count: depthWidth * depthHeight)
        for y in 0..<depthHeight { for x in 0..<depthWidth { depth[y * depthWidth + x] = depthAt(x, y) } }
        let description: [CFString: Any] = [
            kCGImagePropertyWidth: depthWidth, kCGImagePropertyHeight: depthHeight,
            kCGImagePropertyBytesPerRow: depthWidth * 4, kCGImagePropertyPixelFormat: kCVPixelFormatType_DepthFloat32]
        let info: [CFString: Any] = [kCGImageAuxiliaryDataInfoData: Data(bytes: depth, count: depth.count * 4),
                                     kCGImageAuxiliaryDataInfoDataDescription: description]
        let depthData = try AVDepthData(fromDictionaryRepresentation: info)
        var type: NSString?
        let auxiliary = try XCTUnwrap(depthData.dictionaryRepresentation(forAuxiliaryDataType: &type))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), nil)
        CGImageDestinationAddAuxiliaryDataInfo(destination, (type ?? kCGImageAuxiliaryDataTypeDepth as NSString) as CFString,
                                               auxiliary as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @MainActor
    func testEmbeddedPhotoDepthGuidesDerivationAndIsRecorded() async throws {
        // A 512² photo with a 128² depth map: a wall 0.4 m away with a horizontal ridge raised 8 mm across the middle.
        let data = try jpegWithDepth(syntheticBricks(size: 512), depthWidth: 128, depthHeight: 128) { _, y in
            0.4 - 0.008 * expf(-powf((Float(y) - 64) / 10, 2))
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "depth-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureStore(libraryDirectory: root)
        let received = await store.receive(origin: .files, data: data)
        XCTAssertTrue(received, store.errorMessage ?? "Import failed")
        XCTAssertTrue(store.sourceHasDepth, "Depth embedded in the photo is found on import")
        store.semanticLabel = "Depth ridge"
        store.resolution = 512
        store.recipe = MaterialRecipe(preset: .stone)
        store.setDepthGeometry(true)
        XCTAssertEqual(store.recipe.guideNormalWeight, 1)
        await store.derive()
        let derived = try XCTUnwrap(store.derived, store.errorMessage ?? "Derivation failed")
        XCTAssertEqual(derived.guideNormals?.estimator.hasSuffix("lidar-depth"), true)
        let savedTargets = ExportTargetPreference.load()
        defer { ExportTargetPreference.save(savedTargets) }
        store.exportTargets = []
        let folder = try await store.makeMaterialExport()
        let manifestData = try Data(contentsOf: folder.appending(path: "depth-ridge.pbrmaterial/manifest.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let guide = try XCTUnwrap(manifest["guide_normals"] as? [String: Any])
        XCTAssertTrue((guide["estimator"] as? String)?.contains("lidar-depth") == true)
        if let host = ProcessInfo.processInfo.environment["EXPORT_DIR"], !host.isEmpty {
            let destination = URL(fileURLWithPath: host).appending(path: "depth-" + folder.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: folder, to: destination)
        }
    }

    /// Linear-light luminance of an sRGB image, at its own size.
    private func linearLuma(_ image: CGImage) -> [Float] {
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let context = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        func lin(_ v: UInt8) -> Float { let c = Float(v) / 255; return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4) }
        return (0..<(w * h)).map { 0.2126 * lin(rgba[$0 * 4]) + 0.7152 * lin(rgba[$0 * 4 + 1]) + 0.0722 * lin(rgba[$0 * 4 + 2]) }
    }

    /// An sRGB image from linear luminance-scaled copies of `albedo` (per-pixel multiplier).
    private func shaded(_ albedo: CGImage, _ multiplier: (Int, Int) -> Float) -> CGImage {
        let w = albedo.width, h = albedo.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let context = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(albedo, in: CGRect(x: 0, y: 0, width: w, height: h))
        func lin(_ v: UInt8) -> Float { let c = Float(v) / 255; return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4) }
        func enc(_ l: Float) -> UInt8 { let v = max(0, min(1, l)); return UInt8(((v <= 0.0031308 ? v * 12.92 : 1.055 * powf(v, 1 / 2.4) - 0.055) * 255).rounded()) }
        for y in 0..<h { for x in 0..<w { let m = multiplier(x, y); for c in 0..<3 { let i = (y * w + x) * 4 + c; rgba[i] = enc(lin(rgba[i]) * m) } } }
        return context.makeImage()!
    }

    func testFlashPairRecoversAlbedoUnderUnevenAmbientLight() throws {
        let albedo = try XCTUnwrap(syntheticBricks(size: 256).cgImage)
        // Ambient: a strong left-to-right gradient plus a cast shadow. Flash: radial fall-off, at an exposure 1.5×
        // the ambient's, with that ambient light also present.
        let ambientLight: (Int, Int) -> Float = { x, y in
            let shadow: Float = (x - 160) * (x - 160) + (y - 90) * (y - 90) < 2500 ? 0.35 : 1
            return (0.1 + 0.5 * Float(x) / 255) * shadow
        }
        // Kept within an unclipped exposure (flash + ambient ≤ 1), as a camera's auto-exposure would.
        let flashLight: (Int, Int) -> Float = { x, y in 0.5 * expf(-Float((x - 128) * (x - 128) + (y - 128) * (y - 128)) / 40000) }
        let ambient = shaded(albedo) { x, y in ambientLight(x, y) }
        let flash = shaded(albedo) { x, y in flashLight(x, y) + 1.5 * ambientLight(x, y) * 0.5 }
        let recovered = try FlashPairAlbedo.compute(ambient: ambient, flash: flash, flashToAmbientExposure: 0.75)
        // Score: the spread of log(image / true albedo). Lighting left in the image shows up as spread.
        let truth = linearLuma(albedo)
        func spread(_ image: CGImage) -> Float {
            let values = zip(linearLuma(image), truth).compactMap { $1 > 0.01 && $0 > 0.001 ? logf($0 / $1) : nil }
            let mean = values.reduce(0, +) / Float(values.count)
            return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(values.count)).squareRoot()
        }
        let before = spread(ambient), after = spread(recovered)
        XCTAssertLessThan(after, before * 0.35, "Flash-only light removes the ambient gradient and shadow (\(before) → \(after))")
    }

    func testFlashPairAlignmentUndoesHandShake() throws {
        let albedo = try XCTUnwrap(syntheticBricks(size: 256).cgImage)
        // The ambient frame is the scene shifted 6 px right and 4 px down (the phone moved between shots).
        let shifted = CIImage(cgImage: albedo).transformed(by: CGAffineTransform(translationX: 6, y: -4))
            .cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256))
        let ambient = try XCTUnwrap(CIContext().createCGImage(shifted.composited(over: CIImage(color: .black)
            .cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256))), from: CGRect(x: 0, y: 0, width: 256, height: 256)))
        let aligned = try FlashPairAlbedo.align(ambient, to: albedo)
        let a = linearLuma(aligned), t = linearLuma(albedo), b = linearLuma(ambient)
        func error(_ x: [Float]) -> Float {
            var sum: Float = 0, n: Float = 0
            for y in 20..<236 { for x2 in 20..<236 { sum += abs(x[y * 256 + x2] - t[y * 256 + x2]); n += 1 } }
            return sum / n
        }
        XCTAssertLessThan(error(a), error(b) * 0.3, "Registration brings the ambient frame back onto the flash frame")
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
        let first = CaptureStore(libraryDirectory: directory)
        await first.receive(origin: .files, data: bytes)
        first.semanticLabel = "persisted slate"
        first.recipe.normalYDown = true
        first.resolution = 1024
        let sourceID = try XCTUnwrap(first.source?.id)
        let stateFile = directory.appending(path: sourceID.uuidString).appending(path: "state.json")
        for _ in 0..<40 {
            if let data = try? Data(contentsOf: stateFile), String(decoding: data, as: UTF8.self).contains("persisted slate") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let second = CaptureStore(libraryDirectory: directory)
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

    // MARK: Learned normals

    func testLearnedTilingFollowsTheContract() throws {
        XCTAssertEqual(LearnedNormalEstimator.workResolution(for: 256), 518)
        XCTAssertEqual(LearnedNormalEstimator.workResolution(for: 800), 800)
        XCTAssertEqual(LearnedNormalEstimator.workResolution(for: 4096), 2072)
        // The core's tiler owns the contract: wrap padding adds half a tile on every side when tiling.
        let tiled = try XCTUnwrap(LearnedNormalEstimator.tilingPlan(size: 256, wrap: true))
        XCTAssertEqual(tiled.work, 518)
        XCTAssertEqual(tiled.tiles, 9)
        XCTAssertEqual(tiled.passes, 18)
        XCTAssertEqual(tiled.contract, "wrap_padded_rot180_detilted_v2")
        XCTAssertEqual(LearnedNormalEstimator.tilingPlan(size: 256, wrap: false)?.tiles, 1)
    }

    func testFineTuningDefaultsRoundTripAndReachTheCore() throws {
        // Defaults come from the prior: the mid-scale floor is off for flat and on elsewhere.
        let flat = MaterialRecipe(preset: .flat), stone = MaterialRecipe(preset: .stone)
        XCTAssertEqual(flat.midReliefShare, 0)
        XCTAssertEqual(stone.midReliefShare, stone.cValue.mid_relief_share)
        XCTAssertGreaterThan(stone.midReliefShare, 0)
        XCTAssertGreaterThan(stone.roughnessAlbedoLimit, 0)
        var recipe = stone
        recipe.tileMetres = 3.5
        recipe.midReliefShare = 0.6
        recipe.roughnessAlbedoLimit = 0.2
        recipe.substrateRelief = 0.4
        let decoded = try JSONDecoder().decode(MaterialRecipe.self, from: try JSONEncoder().encode(recipe))
        XCTAssertEqual(decoded, recipe)
        XCTAssertEqual(recipe.cValue.tile_metres, 3.5)
        XCTAssertEqual(recipe.cValue.mid_relief_share, 0.6, accuracy: 1e-6)
        XCTAssertEqual(recipe.cValue.roughness_albedo_limit, 0.2, accuracy: 1e-6)
        XCTAssertEqual(recipe.cValue.substrate_relief, 0.4, accuracy: 1e-6)
        // Out-of-range values are clamped to what the core accepts.
        recipe.tileMetres = 500
        recipe.midReliefShare = 2
        XCTAssertEqual(recipe.cValue.tile_metres, 64)
        XCTAssertEqual(recipe.cValue.mid_relief_share, 0.8, accuracy: 1e-6)
        // Recipes saved before core 1.5.0 take the prior's defaults.
        let legacy = Data(#"{"preset":"stone","heightStrength":0.2,"heightPolarity":1,"roughnessBase":0.7,"roughnessVariation":0.1,"aoRadiusPixels":10,"tileWrap":true,"bentNormal":false}"#.utf8)
        let old = try JSONDecoder().decode(MaterialRecipe.self, from: legacy)
        XCTAssertEqual(old.midReliefShare, stone.midReliefShare)
        XCTAssertEqual(old.roughnessAlbedoLimit, stone.roughnessAlbedoLimit)
        XCTAssertEqual(old.tileMetres, 0)
    }

    func testRecipeGuideNormalWeightRoundTripsAndSurvivesPresetChange() throws {
        var recipe = MaterialRecipe(preset: .stone)
        recipe.guideNormalWeight = 0.6
        let decoded = try JSONDecoder().decode(MaterialRecipe.self, from: try JSONEncoder().encode(recipe))
        XCTAssertEqual(decoded.guideNormalWeight, 0.6, accuracy: 1e-6)
        XCTAssertEqual(recipe.applyingPreset(.fabric).guideNormalWeight, 0.6, accuracy: 1e-6)
        XCTAssertEqual(recipe.cValue.guide_normal_weight, 0.6, accuracy: 1e-6)
        // Make tileable defaults to the core's seam cut, is always emitted, and survives a prior switch.
        XCTAssertEqual(recipe.seamlessMode, .cut)
        XCTAssertEqual(recipe.cValue.seamless_mode, 1)
        recipe.seamlessMode = .blend
        XCTAssertEqual(recipe.cValue.seamless_mode, 0)
        XCTAssertEqual(recipe.applyingPreset(.organic).seamlessMode, .blend)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(MaterialRecipe(preset: .flat))) as? [String: Any])
        XCTAssertEqual(json["seamlessMode"] as? String, "cut")
        let legacy = Data(#"{"preset":"stone","heightStrength":0.2,"heightPolarity":1,"roughnessBase":0.7,"roughnessVariation":0.1,"aoRadiusPixels":10,"tileWrap":true,"bentNormal":false}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(MaterialRecipe.self, from: legacy).seamlessMode, .blend)
    }

    func testLearnedEstimatorProducesUnitNormalsAndChangesDerivation() throws {
        let estimator = LearnedNormalEstimator.shared
        try XCTSkipIf(estimator.locateModel() == nil, "MoGe2Normals model is not bundled in this build")
        let image = syntheticBricks(size: 256)
        let source = try SourceImage(origin: .files, data: try XCTUnwrap(image.pngData()))
        let quad = PerspectiveQuad.centeredSquare(for: source.size)
        let rgba = try PerspectiveCropper.correctedRGBA8(source.image, quad: quad, pixels: 256)
        var progress: [Double] = []
        let field = try estimator.field(rgba: rgba, size: 256, progress: { progress.append($0.fraction) })
        XCTAssertEqual(field.work, 518)
        XCTAssertEqual(field.tiles, 9)
        XCTAssertEqual(progress.last, 1)
        let guidePixels = field.guide(size: 256).rgba8
        var unit = 0, facingOut = 0
        for i in Swift.stride(from: 0, to: guidePixels.count, by: 4) {
            let x = Float(guidePixels[i]) / 127.5 - 1, y = Float(guidePixels[i + 1]) / 127.5 - 1, z = Float(guidePixels[i + 2]) / 127.5 - 1
            if abs((x * x + y * y + z * z).squareRoot() - 1) < 0.02 { unit += 1 }
            if z > 0.7 { facingOut += 1 }
        }
        XCTAssertEqual(unit, 256 * 256, "Every guide normal must be unit length")
        XCTAssertGreaterThan(Double(facingOut) / Double(256 * 256), 0.8, "A flat wall should face mostly +Z")
        let greens = stride(from: 1, to: guidePixels.count, by: 4).map { Double(guidePixels[$0]) }
        let mean = greens.reduce(0, +) / Double(greens.count)
        let deviation = (greens.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(greens.count)).squareRoot()
        XCTAssertGreaterThan(deviation, 2, "Joints must tilt the learned normals, not return a constant field")
        // Recipe edits reuse the cached field instead of re-running inference.
        XCTAssertTrue(try estimator.field(rgba: rgba, size: 256) === field)

        var analyticRecipe = MaterialRecipe(preset: .stone)
        analyticRecipe.guideNormalWeight = 0
        var learnedRecipe = analyticRecipe
        learnedRecipe.guideNormalWeight = 1
        let analytic = try MaterialProcessor.derive(image: source.image, quad: quad, resolution: 256, recipe: analyticRecipe)
        let learned = try MaterialProcessor.derive(image: source.image, quad: quad, resolution: 256,
                                                   recipe: learnedRecipe, guide: .estimate(estimator))
        XCTAssertNil(analytic.guideNormals)
        let provenance = try XCTUnwrap(learned.guideNormals)
        XCTAssertEqual(provenance.estimator, "moge-2-vits-normal")
        XCTAssertEqual(provenance.tiles, 9)
        XCTAssertEqual(provenance.tiling, "wrap_padded_rot180_detilted_v2")
        XCTAssertEqual(provenance.normalsSHA256.count, 64)
        XCTAssertNotEqual(analytic.maps[.height]?.png, learned.maps[.height]?.png,
                          "Guided derivation must differ from the analytic height")

        let encoded = try MaterialBundle.make(source: source, quad: quad, label: "brick", category: "masonry",
                                              recipe: learnedRecipe, material: learned)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let recipeJSON = try XCTUnwrap(document["recipe"] as? [String: Any])
        XCTAssertEqual(recipeJSON["guideNormalWeight"] as? Double, 1)
        let capture = try XCTUnwrap(document["capture"] as? [String: Any])
        let guide = try XCTUnwrap(capture["guideNormals"] as? [String: Any])
        for key in ["estimator", "contract", "weights_sha256", "moge_commit", "model_file", "compute_units",
                    "work_resolution", "tiles", "tiling", "normals_sha256"] {
            XCTAssertNotNil(guide[key], "guideNormals.\(key) missing")
        }
        let derived = try XCTUnwrap(document["derived"] as? [String: Any])
        let height = try XCTUnwrap(derived["height"] as? [String: Any])
        XCTAssertEqual(height["provenance"] as? String, "estimated_from_albedo_and_learned_normals")
        let fixture = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
            .appendingPathComponent("material-capture-learned.pbrcapture")
        try encoded.write(to: fixture, options: .atomic)
        print("PBR_CAPTURE_LEARNED_FIXTURE_PATH=\(fixture.path)")
    }

    func testAnalyticCaptureOmitsGuideNormals() throws {
        let image = checkerboard(size: 256)
        let source = try SourceImage(origin: .files, data: try XCTUnwrap(image.pngData()))
        let quad = PerspectiveQuad.centeredSquare(for: source.size)
        var recipe = MaterialRecipe(preset: .stone)
        recipe.guideNormalWeight = 0.5
        // Without guide normals (e.g. a preview before inference finishes) the weight has no effect.
        var analytic = recipe
        analytic.guideNormalWeight = 0
        let a = try MaterialProcessor.derive(image: source.image, quad: quad, resolution: 256, recipe: recipe)
        let b = try MaterialProcessor.derive(image: source.image, quad: quad, resolution: 256, recipe: analytic)
        XCTAssertNil(a.guideNormals)
        XCTAssertEqual(a.maps[.height]?.png, b.maps[.height]?.png)
        // An export whose weight is above 0 must carry learned provenance.
        XCTAssertThrowsError(try MaterialBundle.make(source: source, quad: quad, label: "x", category: "y",
                                                     recipe: recipe, material: a))
        let encoded = try MaterialBundle.make(source: source, quad: quad, label: "x", category: "y",
                                              recipe: analytic, material: b)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil((document["capture"] as? [String: Any])?["guideNormals"])
    }

    /// Red running-bond bricks with pale mortar joints: pale recessed features the luminance heuristic reads as raised.
    private func syntheticBricks(size: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { context in
            UIColor(red: 0.78, green: 0.74, blue: 0.66, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            let rowHeight = size / 8, brickWidth = size / 4, joint = max(2, size / 64)
            for row in 0..<8 {
                let offset = row.isMultiple(of: 2) ? 0 : brickWidth / 2
                for column in -1..<5 {
                    let shade = 0.5 + 0.08 * Double((row * 7 + column * 3) % 5) / 4
                    UIColor(red: shade + 0.1, green: shade * 0.45, blue: shade * 0.32, alpha: 1).setFill()
                    context.fill(CGRect(x: column * brickWidth + offset + joint / 2, y: row * rowHeight + joint / 2,
                                        width: brickWidth - joint, height: rowHeight - joint))
                }
            }
        }
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
