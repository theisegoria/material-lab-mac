import Accelerate
import CoreML
import CoreVideo
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Errors from locating, importing or running the learned normal estimator.
enum LearnedNormalError: LocalizedError {
    case notInstalled
    case unsupportedFile(String)
    case contractMismatch(String)
    case unexpectedOutput(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "Learned geometry needs the MoGe-2 normal model. Import it in the recipe, or set Learned geometry to 0."
        case .unsupportedFile(let name):
            "“\(name)” is not a Core ML model (.mlpackage, .mlmodel or .mlmodelc)."
        case .contractMismatch(let found):
            "This model does not declare the Material Lab normal contract (found “\(found)”, expected “\(LearnedNormalEstimator.contract)”)."
        case .unexpectedOutput(let detail):
            "The learned model returned an unexpected result: \(detail)"
        }
    }
}

/// A contract-validated model that ships in the app or was imported through Files.
struct LearnedModelInfo: Sendable, Equatable {
    enum Origin: String, Sendable { case bundled, imported }
    let compiledURL: URL
    /// Basename of the model as supplied (e.g. MoGe2Normals.mlpackage); recorded in provenance.
    let modelFile: String
    let weightsSHA256: String
    let mogeCommit: String
    let origin: Origin

    var identity: String { "\(origin.rawValue)|\(modelFile)|\(weightsSHA256)" }
}

/// `guideNormals` provenance recorded in the .pbrcapture `capture` object (fields match the manifest's
/// `guide_normals`, see docs/LEARNED_NORMALS.md).
struct GuideNormalsProvenance: Codable, Equatable, Sendable {
    let estimator: String
    let contract: String
    let weightsSHA256: String
    let mogeCommit: String
    let modelFile: String
    let computeUnits: String
    let workResolution: Int
    let tiles: Int
    /// Tiling contract name (docs/LEARNED_NORMALS.md); absent in captures made before 1.3.0.
    var tiling: String? = nil
    let normalsSHA256: String

    private enum CodingKeys: String, CodingKey {
        case estimator, contract, tiles, tiling
        case weightsSHA256 = "weights_sha256"
        case mogeCommit = "moge_commit"
        case modelFile = "model_file"
        case computeUnits = "compute_units"
        case workResolution = "work_resolution"
        case normalsSHA256 = "normals_sha256"
    }
}

/// Guide normals encoded for `PBRLabInput.guide_normal_rgba8` at one size.
struct GuideNormals: Sendable {
    let rgba8: [UInt8]
    let size: Int
    let provenance: GuideNormalsProvenance
}

/// Learned-inference progress for the UI: passes done, total, and an estimate of the time left.
struct LearnedProgress: Sendable, Equatable {
    var pass: Int
    var passes: Int
    var remaining: TimeInterval?
    /// A quick single-tile estimate, shown while the full-quality field is computed.
    var coarse: Bool
    var fraction: Double { passes == 0 ? 0 : Double(pass) / Double(passes) }
}

/// A finished learned normal field (the core's `PBRLabGuideTiler` after every pass), kept so the 512² live preview,
/// the export and every recipe edit reuse one inference. The tiling contract itself lives in the core, so the CLI,
/// the Mac app and this app feed identical guide normals for identical model output.
final class LearnedNormalField: @unchecked Sendable {
    let work: Int
    let tiles: Int
    let wrap: Bool
    let tiling: String
    let model: LearnedModelInfo
    let computeUnits: String
    private let tiler: OpaquePointer
    private let lock = NSLock()

    fileprivate init(tiler: OpaquePointer, wrap: Bool, model: LearnedModelInfo, computeUnits: String) {
        self.tiler = tiler
        self.work = Int(PBRLabGuideTilerWorkResolution(tiler))
        self.tiles = Int(PBRLabGuideTilerTileCount(tiler))
        self.tiling = String(cString: PBRLabGuideTilerContract(tiler))
        self.wrap = wrap
        self.model = model
        self.computeUnits = computeUnits
    }

    deinit { PBRLabGuideTilerFree(tiler) }

    /// Guide normals at `size`² (bilinear, wrapping when tiled), encoded linear RGBA8 for `PBRLabInput`.
    func guide(size: Int) -> GuideNormals {
        var output = [UInt8](repeating: 255, count: size * size * 4)
        let ok = lock.withLock {
            output.withUnsafeMutableBufferPointer { PBRLabGuideTilerFinish(tiler, UInt32(size), $0.baseAddress, size * 4) }
        }
        if ok == 0 { for i in Swift.stride(from: 0, to: output.count, by: 4) { output[i] = 128; output[i + 1] = 128 } }
        let hash = SHA256.hash(data: output).map { String(format: "%02x", $0) }.joined()
        let provenance = GuideNormalsProvenance(
            estimator: LearnedNormalEstimator.estimatorName, contract: LearnedNormalEstimator.contract,
            weightsSHA256: model.weightsSHA256, mogeCommit: model.mogeCommit, modelFile: model.modelFile,
            computeUnits: computeUnits, workResolution: work, tiles: tiles, tiling: tiling, normalsSHA256: hash)
        return GuideNormals(rgba8: output, size: size, provenance: provenance)
    }
}

/// Runs the Material Lab learned-normal contract (docs/LEARNED_NORMALS.md) through Core ML; the core's
/// `PBRLabGuideTiler` prepares every model input and folds the predictions back. Thread-safe and synchronous: call from a detached task. The model is loaded once, and fields are
/// cached by the SHA-256 of the working image so recipe edits never re-run inference.
final class LearnedNormalEstimator: @unchecked Sendable {
    static let shared = LearnedNormalEstimator()

    static let contract = "tangent_normals_plus_y_v1"
    static let estimatorName = "moge-2-vits-normal"
    static let bundledName = "MoGe2Normals"
    static let tile = Int(PBRLAB_GUIDE_TILE)
    static let maximumWork = 4 * tile
    #if targetEnvironment(simulator)
    /// The simulator's GPU (MPSGraph) Core ML backend returns a constant field for this model; use the CPU there.
    static let computeUnits = "cpu_only"
    static let mlComputeUnits = MLComputeUnits.cpuOnly
    #else
    static let computeUnits = "all"
    static let mlComputeUnits = MLComputeUnits.all
    #endif

    static var importedDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "LearnedModels", directoryHint: .isDirectory)
    }
    private static var importRecordURL: URL { importedDirectory.appending(path: "imported-model.json") }

    private let lock = NSLock()
    /// Serializes inference: a superseded request's successor waits, then hits the cache.
    private let inferenceLock = NSLock()
    private var located: LearnedModelInfo?
    private var didLocate = false
    private var loaded: (identity: String, model: MLModel)?
    private var cache: [(key: String, field: LearnedNormalField)] = []

    // MARK: Model discovery and import

    /// The imported model if one is present, otherwise the bundled one. Validates metadata once.
    func locateModel(refresh: Bool = false) -> LearnedModelInfo? {
        lock.lock()
        if didLocate && !refresh { defer { lock.unlock() }; return located }
        lock.unlock()
        let found = Self.findImported() ?? Self.findBundled()
        lock.lock()
        if located != found { loaded = nil; cache.removeAll() }
        located = found
        didLocate = true
        lock.unlock()
        return found
    }

    private static func findBundled() -> LearnedModelInfo? {
        guard let url = Bundle.main.url(forResource: bundledName, withExtension: "mlmodelc") else { return nil }
        return try? validate(compiledURL: url, modelFile: "\(bundledName).mlpackage", origin: .bundled)
    }

    private static func findImported() -> LearnedModelInfo? {
        guard let data = try? Data(contentsOf: importRecordURL),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let compiled = record["compiled"], let modelFile = record["model_file"] else { return nil }
        let url = importedDirectory.appending(path: compiled, directoryHint: .isDirectory)
        return try? validate(compiledURL: url, modelFile: modelFile, origin: .imported)
    }

    /// Copies (compiling if needed) a model chosen in Files into Application Support and makes it current.
    func importModel(from source: URL) async throws -> LearnedModelInfo {
        let fm = FileManager.default
        let ext = source.pathExtension.lowercased()
        guard ["mlpackage", "mlmodel", "mlmodelc"].contains(ext) else {
            throw LearnedNormalError.unsupportedFile(source.lastPathComponent)
        }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try fm.createDirectory(at: Self.importedDirectory, withIntermediateDirectories: true)
        let staging = Self.importedDirectory.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let stem = source.deletingPathExtension().lastPathComponent
        let staged = staging.appending(path: "\(stem).mlmodelc", directoryHint: .isDirectory)
        if ext == "mlmodelc" {
            try fm.copyItem(at: source, to: staged)
        } else {
            let compiled = try await MLModel.compileModel(at: source)
            defer { try? fm.removeItem(at: compiled) }
            try fm.copyItem(at: compiled, to: staged)
        }
        // Validate before replacing anything already imported.
        _ = try Self.validate(compiledURL: staged, modelFile: source.lastPathComponent, origin: .imported)
        removeImportedFiles()
        let final = Self.importedDirectory.appending(path: "\(stem).mlmodelc", directoryHint: .isDirectory)
        try fm.moveItem(at: staged, to: final)
        let record = ["compiled": final.lastPathComponent, "model_file": source.lastPathComponent]
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            .write(to: Self.importRecordURL, options: .atomic)
        guard let info = locateModel(refresh: true) else { throw LearnedNormalError.notInstalled }
        return info
    }

    /// Removes an imported model; the bundled one (if any) becomes current again.
    func removeImportedModel() -> LearnedModelInfo? {
        removeImportedFiles()
        return locateModel(refresh: true)
    }

    private func removeImportedFiles() {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: Self.importedDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.pathExtension == "mlmodelc" { try? fm.removeItem(at: url) }
        try? fm.removeItem(at: Self.importRecordURL)
    }

    static func validate(compiledURL: URL, modelFile: String, origin: LearnedModelInfo.Origin) throws -> LearnedModelInfo {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: compiledURL, configuration: configuration)
        let description = model.modelDescription
        let metadata = description.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        let contract = metadata["materiallab.contract"] ?? "none"
        guard contract == Self.contract else { throw LearnedNormalError.contractMismatch(contract) }
        guard let constraint = description.inputDescriptionsByName["image"]?.imageConstraint,
              constraint.pixelsWide == tile, constraint.pixelsHigh == tile,
              description.outputDescriptionsByName["normals"] != nil else {
            throw LearnedNormalError.unexpectedOutput("expected a 518 × 518 “image” input and a “normals” output")
        }
        return LearnedModelInfo(compiledURL: compiledURL, modelFile: modelFile,
                                weightsSHA256: metadata["materiallab.weights_sha256"] ?? "unknown",
                                mogeCommit: metadata["materiallab.moge_commit"] ?? "unknown", origin: origin)
    }

    /// Loads the model with `.all` compute units (Neural Engine on device) once per model identity.
    private func loadModel(_ info: LearnedModelInfo) throws -> MLModel {
        lock.lock()
        if let loaded, loaded.identity == info.identity { lock.unlock(); return loaded.model }
        lock.unlock()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = Self.mlComputeUnits
        let model = try MLModel(contentsOf: info.compiledURL, configuration: configuration)
        lock.lock()
        loaded = (info.identity, model)
        lock.unlock()
        return model
    }

    // MARK: Inference

    static func workResolution(for size: Int) -> Int { min(maximumWork, max(tile, size)) }

    /// The core tiler's plan for a `size`² source: working size, tile positions and contract name.
    static func tilingPlan(size: Int, wrap: Bool) -> (work: Int, tiles: Int, passes: Int, contract: String)? {
        let pixels = [UInt8](repeating: 128, count: size * size * 4)
        guard let tiler = pixels.withUnsafeBufferPointer({
            PBRLabGuideTilerCreate($0.baseAddress, size * 4, UInt32(size), wrap ? 1 : 0)
        }) else { return nil }
        defer { PBRLabGuideTilerFree(tiler) }
        return (Int(PBRLabGuideTilerWorkResolution(tiler)), Int(PBRLabGuideTilerTileCount(tiler)),
                Int(PBRLabGuideTilerPassCount(tiler)), String(cString: PBRLabGuideTilerContract(tiler)))
    }

    /// Learned normals for a square, straight sRGB RGBA8 image of `size`²; `wrap` (the recipe's tile option) makes
    /// the field periodic. `shouldContinue` is polled between passes; `progress` receives passes and time left on a
    /// cache miss. `coarse` only labels progress: a quick estimate is simply a field of a `tile`² image.
    func field(rgba: [UInt8], size: Int, wrap: Bool = true, coarse: Bool = false, shouldContinue: () -> Bool = { true },
               progress: (LearnedProgress) -> Void = { _ in }) throws -> LearnedNormalField {
        guard let info = locateModel() else { throw LearnedNormalError.notInstalled }
        let key = SHA256.hash(data: rgba).map { String(format: "%02x", $0) }.joined() +
            "|\(size)|\(wrap)|" + info.identity
        if let hit = cached(key) { return hit }
        inferenceLock.lock()
        defer { inferenceLock.unlock() }
        if let hit = cached(key) { return hit }
        guard shouldContinue() else { throw CaptureError.cancelled }
        progress(LearnedProgress(pass: 0, passes: 0, remaining: nil, coarse: coarse))
        let model = try loadModel(info)
        // Timed after loading: the estimate covers tiling + inference.
        let started = Date()
        guard let tiler = rgba.withUnsafeBufferPointer({
            PBRLabGuideTilerCreate($0.baseAddress, size * 4, UInt32(size), wrap ? 1 : 0)
        }) else { throw LearnedNormalError.unexpectedOutput("could not prepare the estimator input") }
        // Owned by the field from here on, so every exit frees it.
        let result = LearnedNormalField(tiler: tiler, wrap: wrap, model: info, computeUnits: Self.computeUnits)
        let passes = PBRLabGuideTilerPassCount(tiler)
        let buffer = try Self.makePixelBuffer()
        var planar = [Float](repeating: 0, count: 3 * Self.tile * Self.tile)
        var spread: Float = 0
        var first: (Float, Float)?
        for pass in 0..<passes {
            guard shouldContinue() else { throw CaptureError.cancelled }
            try autoreleasepool {
                CVPixelBufferLockBaseAddress(buffer, [])
                let filled = PBRLabGuideTilerFillInput(tiler, pass,
                    CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetBytesPerRow(buffer))
                CVPixelBufferUnlockBaseAddress(buffer, [])
                guard filled != 0 else { throw LearnedNormalError.unexpectedOutput("could not fill the estimator input") }
                let inputs = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)])
                let output = try model.prediction(from: inputs)
                guard let normals = output.featureValue(for: "normals")?.multiArrayValue else {
                    throw LearnedNormalError.unexpectedOutput("missing “normals” output")
                }
                try Self.copyPlanar(normals, into: &planar)
                // A backend that silently fails (seen with the simulator GPU path) yields one constant vector.
                if first == nil { first = (planar[0], planar[Self.tile * Self.tile]) }
                if let first {
                    for i in Swift.stride(from: 0, to: Self.tile * Self.tile, by: 97) {
                        spread = max(spread, abs(planar[i] - first.0), abs(planar[Self.tile * Self.tile + i] - first.1))
                    }
                }
                let added = planar.withUnsafeBufferPointer {
                    PBRLabGuideTilerAddPrediction(tiler, pass, $0.baseAddress, Self.tile * Self.tile, Self.tile, 1)
                }
                guard added != 0 else { throw LearnedNormalError.unexpectedOutput("could not add a prediction") }
            }
            let done = Int(pass) + 1, total = Int(passes)
            let perPass = Date().timeIntervalSince(started) / Double(done)
            progress(LearnedProgress(pass: done, passes: total, remaining: perPass * Double(total - done), coarse: coarse))
        }
        guard spread > 1e-4 else { throw LearnedNormalError.unexpectedOutput("a constant normal field") }
        lock.lock()
        cache.removeAll { $0.key == key }
        cache.insert((key, result), at: 0)
        if cache.count > 3 { cache.removeLast(cache.count - 3) }
        lock.unlock()
        return result
    }

    private func cached(_ key: String) -> LearnedNormalField? {
        lock.lock(); defer { lock.unlock() }
        return cache.first { $0.key == key }?.field
    }

    func clearCache() { lock.lock(); cache.removeAll(); lock.unlock() }

    private static func makePixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(nil, tile, tile, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
                == kCVReturnSuccess, let buffer else {
            throw LearnedNormalError.unexpectedOutput("could not allocate the input pixel buffer")
        }
        return buffer
    }

    /// Copies a (1, 3, 518, 518) prediction of any float type into dense planar Float.
    static func copyPlanar(_ array: MLMultiArray, into planar: inout [Float]) throws {
        let shape = array.shape.map(\.intValue)
        guard shape.count == 4, shape[0] == 1, shape[1] == 3, shape[2] == tile, shape[3] == tile else {
            throw LearnedNormalError.unexpectedOutput("shape \(shape)")
        }
        let strides = array.strides.map(\.intValue)
        let cs = strides[1], ys = strides[2], xs = strides[3]
        func copy<T>(_ pointer: UnsafeBufferPointer<T>, _ value: (T) -> Float) {
            planar.withUnsafeMutableBufferPointer { out in
                for c in 0..<3 { for y in 0..<tile { for x in 0..<tile {
                    out[(c * tile + y) * tile + x] = value(pointer[c * cs + y * ys + x * xs])
                } } }
            }
        }
        switch array.dataType {
        case .float16: array.withUnsafeBufferPointer(ofType: Float16.self) { copy($0) { Float($0) } }
        case .float32: array.withUnsafeBufferPointer(ofType: Float.self) { copy($0) { $0 } }
        case .double: array.withUnsafeBufferPointer(ofType: Double.self) { copy($0) { Float($0) } }
        default: throw LearnedNormalError.unexpectedOutput("data type \(array.dataType.rawValue)")
        }
    }
}

extension UTType {
    /// Core ML model formats accepted by the Files importer.
    static var coreMLModels: [UTType] {
        ["mlpackage", "mlmodel", "mlmodelc"].compactMap { UTType(filenameExtension: $0) } + [.package, .folder]
    }
}
