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
    let normalsSHA256: String

    private enum CodingKeys: String, CodingKey {
        case estimator, contract, tiles
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

/// The blended, per-pixel normalized W×W learned normal field (+X right, +Y up, +Z out), before resampling.
/// Kept so the 512² live preview and every recipe edit reuse one inference.
final class LearnedNormalField: @unchecked Sendable {
    let work: Int
    let tiles: Int
    /// Interleaved unit xyz, `work * work * 3` floats.
    let normals: [Float]
    let model: LearnedModelInfo
    let computeUnits: String

    init(work: Int, tiles: Int, normals: [Float], model: LearnedModelInfo, computeUnits: String) {
        self.work = work
        self.tiles = tiles
        self.normals = normals
        self.model = model
        self.computeUnits = computeUnits
    }

    /// Bilinearly resamples to `size`², renormalizes and encodes linear RGBA8 (`round((n·0.5+0.5)·255)`, alpha 255).
    func guide(size: Int) -> GuideNormals {
        var output = [UInt8](repeating: 255, count: size * size * 4)
        let work = work
        let scale = Float(work) / Float(size)
        @inline(__always) func byte(_ c: Float) -> UInt8 { UInt8(max(0, min(255, ((c * 0.5 + 0.5) * 255).rounded()))) }
        normals.withUnsafeBufferPointer { unit in
            output.withUnsafeMutableBufferPointer { dst in
                for y in 0..<size {
                    let fy = max(0, min(Float(work - 1), (Float(y) + 0.5) * scale - 0.5))
                    let iy = Int(fy), ty = fy - Float(iy), iy1 = min(work - 1, iy + 1)
                    for x in 0..<size {
                        var n: SIMD3<Float>
                        if work == size {
                            let i = (y * work + x) * 3
                            n = SIMD3(unit[i], unit[i + 1], unit[i + 2])
                        } else {
                            let fx = max(0, min(Float(work - 1), (Float(x) + 0.5) * scale - 0.5))
                            let ix = Int(fx), tx = fx - Float(ix), ix1 = min(work - 1, ix + 1)
                            @inline(__always) func at(_ px: Int, _ py: Int) -> SIMD3<Float> {
                                let i = (py * work + px) * 3
                                return SIMD3(unit[i], unit[i + 1], unit[i + 2])
                            }
                            let top = at(ix, iy) * (1 - tx) + at(ix1, iy) * tx
                            let bottom = at(ix, iy1) * (1 - tx) + at(ix1, iy1) * tx
                            n = top * (1 - ty) + bottom * ty
                            let length = (n * n).sum().squareRoot()
                            n = length > 1e-6 ? n / length : SIMD3(0, 0, 1)
                        }
                        let o = (y * size + x) * 4
                        dst[o] = byte(n.x); dst[o + 1] = byte(n.y); dst[o + 2] = byte(n.z)
                    }
                }
            }
        }
        let hash = SHA256.hash(data: output).map { String(format: "%02x", $0) }.joined()
        let provenance = GuideNormalsProvenance(
            estimator: LearnedNormalEstimator.estimatorName, contract: LearnedNormalEstimator.contract,
            weightsSHA256: model.weightsSHA256, mogeCommit: model.mogeCommit, modelFile: model.modelFile,
            computeUnits: computeUnits, workResolution: work, tiles: tiles, normalsSHA256: hash)
        return GuideNormals(rgba8: output, size: size, provenance: provenance)
    }
}

/// Runs the Material Lab learned-normal contract (docs/LEARNED_NORMALS.md) through Core ML: a W = clamp(N, 518, 1036)
/// working image, 518² tiles at stride 259 plus a final aligned tile, sine-window blending and per-pixel
/// normalization. Thread-safe and synchronous: call from a detached task. The model is loaded once, and fields are
/// cached by the SHA-256 of the working image so recipe edits never re-run inference.
final class LearnedNormalEstimator: @unchecked Sendable {
    static let shared = LearnedNormalEstimator()

    static let contract = "tangent_normals_plus_y_v1"
    static let estimatorName = "moge-2-vits-normal"
    static let bundledName = "MoGe2Normals"
    static let tile = 518
    static let stride = 259
    static let maximumWork = 1036
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

    /// Origins start at 0 and step by 259; a final origin at W − 518 closes any gap.
    static func tileOrigins(_ work: Int) -> [Int] {
        let last = work - tile
        var origins = Array(Swift.stride(from: 0, through: last, by: stride))
        if let final = origins.last, final < last { origins.append(last) }
        return origins
    }

    /// Learned normals for a square, straight sRGB RGBA8 image of `size`². `shouldContinue` is polled between tiles;
    /// `progress` receives tile progress in [0, 1] on a cache miss.
    func field(rgba: [UInt8], size: Int, shouldContinue: () -> Bool = { true },
               progress: (Double) -> Void = { _ in }) throws -> LearnedNormalField {
        guard let info = locateModel() else { throw LearnedNormalError.notInstalled }
        let work = Self.workResolution(for: size)
        let workImage = work == size ? rgba : try Self.resample(rgba, from: size, to: work)
        let key = SHA256.hash(data: workImage).map { String(format: "%02x", $0) }.joined() + "|" + info.identity
        if let hit = cached(key) { return hit }
        inferenceLock.lock()
        defer { inferenceLock.unlock() }
        if let hit = cached(key) { return hit }
        guard shouldContinue() else { throw CaptureError.cancelled }
        progress(0)
        let model = try loadModel(info)
        let origins = Self.tileOrigins(work)
        let tileCount = origins.count * origins.count
        let window = (0..<Self.tile).map { t in max(sinf(Float.pi * (Float(t) + 0.5) / Float(Self.tile)), 1e-3) }
        // The only float allocation at working size: weighted xyz, then normalized in place.
        var field = [Float](repeating: 0, count: work * work * 3)
        let buffer = try Self.makePixelBuffer()
        var done = 0
        for oy in origins {
            for ox in origins {
                guard shouldContinue() else { throw CaptureError.cancelled }
                try autoreleasepool {
                    try Self.fill(buffer, from: workImage, work: work, x0: ox, y0: oy)
                    let inputs = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)])
                    let output = try model.prediction(from: inputs)
                    guard let normals = output.featureValue(for: "normals")?.multiArrayValue else {
                        throw LearnedNormalError.unexpectedOutput("missing “normals” output")
                    }
                    try Self.accumulate(normals, into: &field, work: work, x0: ox, y0: oy, window: window)
                }
                done += 1
                progress(Double(done) / Double(tileCount))
            }
        }
        // A backend that silently fails (seen with the simulator GPU path) yields one constant vector.
        var spread: Float = 0
        field.withUnsafeBufferPointer { f in
            for i in Swift.stride(from: 0, to: f.count, by: 3 * 97) {
                spread = max(spread, abs(f[i] - f[0]), abs(f[i + 1] - f[1]))
            }
        }
        guard spread > 1e-4 else { throw LearnedNormalError.unexpectedOutput("a constant normal field") }
        // Normalizing the weighted sum divides out the window weights.
        field.withUnsafeMutableBufferPointer { f in
            for i in 0..<(work * work) {
                let x = f[i * 3], y = f[i * 3 + 1], z = f[i * 3 + 2]
                let length = (x * x + y * y + z * z).squareRoot()
                if length > 1e-12 { f[i * 3] = x / length; f[i * 3 + 1] = y / length; f[i * 3 + 2] = z / length }
                else { f[i * 3] = 0; f[i * 3 + 1] = 0; f[i * 3 + 2] = 1 }
            }
        }
        let result = LearnedNormalField(work: work, tiles: tileCount, normals: field, model: info,
                                        computeUnits: Self.computeUnits)
        lock.lock()
        cache.removeAll { $0.key == key }
        cache.insert((key, result), at: 0)
        if cache.count > 2 { cache.removeLast(cache.count - 2) }
        lock.unlock()
        return result
    }

    private func cached(_ key: String) -> LearnedNormalField? {
        lock.lock(); defer { lock.unlock() }
        return cache.first { $0.key == key }?.field
    }

    func clearCache() { lock.lock(); cache.removeAll(); lock.unlock() }

    /// High-quality (Lanczos) sRGB resample to the working size.
    static func resample(_ rgba: [UInt8], from size: Int, to work: Int) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: work * work * 4)
        let error = rgba.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress), height: vImagePixelCount(size),
                                         width: vImagePixelCount(size), rowBytes: size * 4)
                var to = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(work),
                                       width: vImagePixelCount(work), rowBytes: work * 4)
                return vImageScale_ARGB8888(&from, &to, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        guard error == kvImageNoError else { throw LearnedNormalError.unexpectedOutput("could not resample the source") }
        return output
    }

    private static func makePixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(nil, tile, tile, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
                == kCVReturnSuccess, let buffer else {
            throw LearnedNormalError.unexpectedOutput("could not allocate the input pixel buffer")
        }
        return buffer
    }

    /// Copies one tile of raw sRGB values (no colour conversion) into the BGRA input buffer.
    private static func fill(_ buffer: CVPixelBuffer, from rgba: [UInt8], work: Int, x0: Int, y0: Int) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
            throw LearnedNormalError.unexpectedOutput("input pixel buffer is not addressable")
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        rgba.withUnsafeBufferPointer { src in
            guard let src = src.baseAddress else { return }
            for y in 0..<tile {
                let s = src + ((y0 + y) * work + x0) * 4
                let d = base + y * rowBytes
                for x in 0..<tile {
                    let i = x * 4
                    d[i] = s[i + 2]; d[i + 1] = s[i + 1]; d[i + 2] = s[i]; d[i + 3] = 255
                }
            }
        }
    }

    private static func accumulate(_ array: MLMultiArray, into field: inout [Float], work: Int,
                                   x0: Int, y0: Int, window: [Float]) throws {
        let shape = array.shape.map(\.intValue)
        guard shape.count == 4, shape[0] == 1, shape[1] == 3, shape[2] == tile, shape[3] == tile else {
            throw LearnedNormalError.unexpectedOutput("shape \(shape)")
        }
        let strides = array.strides.map(\.intValue)
        let cs = strides[1], ys = strides[2], xs = strides[3]
        func add<T>(_ pointer: UnsafeBufferPointer<T>, _ value: (T) -> Float) {
            field.withUnsafeMutableBufferPointer { out in
                for y in 0..<tile {
                    let wy = window[y]
                    let row = (y0 + y) * work + x0
                    for x in 0..<tile {
                        let w = wy * window[x]
                        let o = (row + x) * 3
                        let p = y * ys + x * xs
                        out[o] += w * value(pointer[p])
                        out[o + 1] += w * value(pointer[p + cs])
                        out[o + 2] += w * value(pointer[p + 2 * cs])
                    }
                }
            }
        }
        switch array.dataType {
        case .float16: array.withUnsafeBufferPointer(ofType: Float16.self) { add($0) { Float($0) } }
        case .float32: array.withUnsafeBufferPointer(ofType: Float.self) { add($0) { $0 } }
        case .double: array.withUnsafeBufferPointer(ofType: Double.self) { add($0) { Float($0) } }
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
