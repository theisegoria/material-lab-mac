import CoreGraphics
import CoreML
import CoreVideo
import CryptoKit
import Foundation

/// Errors from installing, loading or running the learned normal estimator.
enum LearnedNormalError: LocalizedError {
    case notInstalled
    case unsupportedFile(String)
    case contractMismatch(String)
    case unexpectedOutput(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "Learned geometry needs the MoGe-2 normal model. Install it in Settings (⌘,) or set Learned geometry to 0."
        case .unsupportedFile(let name):
            "\(name) is not a Core ML model package (.mlpackage) or compiled model (.mlmodelc)."
        case .contractMismatch(let found):
            "This model does not declare the Material Lab normal contract (found “\(found)”, expected “\(LearnedNormalEstimator.contract)”)."
        case .unexpectedOutput(let detail):
            "The learned model returned an unexpected output: \(detail)"
        case .cancelled:
            "Learned normal estimation cancelled."
        }
    }
}

enum LearnedComputeUnits: String, Sendable {
    case all
    case cpuOnly = "cpu_only"

    var mlValue: MLComputeUnits { self == .all ? .all : .cpuOnly }
    var title: String { self == .all ? "All (Neural Engine, GPU, CPU)" : "CPU only" }
}

/// Where the active model came from, in resolution order.
enum LearnedModelOrigin: String, Sendable {
    /// Installed by the user into Application Support (takes precedence).
    case installed
    /// Shipped inside the app at Contents/Resources/Models.
    case builtIn = "built_in"
    /// Development override from MATERIAL_LAB_MOGE_MODEL.
    case environment
}

/// Identity of an installed, contract-validated model.
struct LearnedModelInfo: Sendable, Equatable {
    let origin: LearnedModelOrigin
    let compiledURL: URL
    /// Basename of the file the user installed (e.g. MoGe2Normals.mlpackage).
    let modelFile: String
    let weightsSHA256: String
    let mogeCommit: String
    let version: String
    let installedAt: Date

    /// Stable identity used in the guide-normal cache key.
    var identity: String {
        "\(origin.rawValue)|\(weightsSHA256)|\(modelFile)|\(installedAt.timeIntervalSinceReferenceDate)"
    }
}

/// Guide normals for one working image, ready for PBRLabInput.guide_normal_rgba8.
struct GuideNormals: @unchecked Sendable {
    let rgba8: Data
    let size: Int
    let workResolution: Int
    let tiles: Int
    /// Tiling contract name (docs/LEARNED_NORMALS.md), from the core's PBRLabGuideTiler.
    let tiling: String
    let sha256: String
    let computeUnits: LearnedComputeUnits
    let model: LearnedModelInfo
    let inferenceDuration: TimeInterval
    let wasCached: Bool
}

/// Runs the Material Lab learned-normal contract (docs/LEARNED_NORMALS.md) through Core ML; the core's
/// PBRLabGuideTiler prepares every model input and folds the predictions back, so the CLI and both apps agree.
/// Thread-safe; loaded models and results are reused across derivations.
final class LearnedNormalEstimator: @unchecked Sendable {
    static let shared = LearnedNormalEstimator()

    static let contract = "tangent_normals_plus_y_v1"
    static let estimatorName = "moge-2-vits-normal"
    static let tile = Int(PBRLAB_GUIDE_TILE)

    static var modelsDirectory: URL {
        MaterialLibrary.appSupport.appendingPathComponent("Models", isDirectory: true)
    }

    private static var installRecordURL: URL {
        modelsDirectory.appendingPathComponent("installed-model.json")
    }

    private let lock = NSLock()
    /// Serializes inference so a superseded derivation's successor waits and then hits the cache.
    private let inferenceLock = NSLock()
    /// Serializes model loading so a warm-up and a first inference never compile the model twice.
    private let loadLock = NSLock()
    private var installed: LearnedModelInfo?
    private var units: LearnedComputeUnits = .all
    private var loadedModels: [String: MLModel] = [:]
    private var cache: [(key: String, value: GuideNormals)] = []

    var model: LearnedModelInfo? {
        lock.lock(); defer { lock.unlock() }
        return installed
    }

    var computeUnits: LearnedComputeUnits {
        get { lock.lock(); defer { lock.unlock() }; return units }
        set { lock.lock(); units = newValue; lock.unlock() }
    }

    // MARK: - Installation

    static let environmentKey = "MATERIAL_LAB_MOGE_MODEL"

    /// The compiled model shipped in the app bundle (Contents/Resources/Models/*.mlmodelc), if any.
    static var bundledModelURL: URL? {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Models", isDirectory: true),
              let contents = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return nil }
        return contents.filter { $0.pathExtension == "mlmodelc" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.first
    }

    /// Resolves the active model in order: user-installed (Application Support), the built-in bundle
    /// resource, then MATERIAL_LAB_MOGE_MODEL. Returns nil (not an error) when none exists; throws only
    /// when every candidate that exists failed validation.
    func resolveModel() async throws -> LearnedModelInfo? {
        var firstError: Error?
        do {
            if let info = try loadInstalledRecord() { setInstalled(info); return info }
        } catch { firstError = error }
        if let bundled = Self.bundledModelURL {
            do {
                let stamp = (try? bundled.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                let info = try Self.validate(compiledURL: bundled, modelFile: bundled.lastPathComponent,
                                             installedAt: stamp ?? .distantPast, origin: .builtIn)
                setInstalled(info)
                return info
            } catch { firstError = firstError ?? error }
        }
        if let path = ProcessInfo.processInfo.environment[Self.environmentKey], !path.isEmpty,
           FileManager.default.fileExists(atPath: path) {
            do {
                let info = try await Self.environmentModel(URL(fileURLWithPath: path))
                setInstalled(info)
                return info
            } catch { firstError = firstError ?? error }
        }
        setInstalled(nil)
        if let firstError { throw firstError }
        return nil
    }

    /// Uses a development model in place; a .mlpackage is compiled into the caches folder once per change.
    private static func environmentModel(_ source: URL) async throws -> LearnedModelInfo {
        let fm = FileManager.default
        let ext = source.pathExtension.lowercased()
        guard ext == "mlpackage" || ext == "mlmodelc" else {
            throw LearnedNormalError.unsupportedFile(source.lastPathComponent)
        }
        let stamp = (try? source.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        guard ext == "mlpackage" else {
            return try validate(compiledURL: source, modelFile: source.lastPathComponent, installedAt: stamp, origin: .environment)
        }
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Material Lab/EnvironmentModel", isDirectory: true)
        let compiled = caches.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".mlmodelc", isDirectory: true)
        let cachedStamp = (try? compiled.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if cachedStamp == nil || cachedStamp! < stamp {
            try fm.createDirectory(at: caches, withIntermediateDirectories: true)
            let fresh = try await MLModel.compileModel(at: source)
            try? fm.removeItem(at: compiled)
            try fm.moveItem(at: fresh, to: compiled)
        }
        return try validate(compiledURL: compiled, modelFile: source.lastPathComponent, installedAt: stamp, origin: .environment)
    }

    /// Reads the user-installed model record. Returns nil when none is installed.
    private func loadInstalledRecord() throws -> LearnedModelInfo? {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: Self.installRecordURL),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let compiledName = record["compiled"] as? String,
              let modelFile = record["model_file"] as? String
        else { return nil }
        let compiled = Self.modelsDirectory.appendingPathComponent(compiledName, isDirectory: true)
        guard fm.fileExists(atPath: compiled.path) else { return nil }
        let installedAt = (record["installed_at"] as? Double).map(Date.init(timeIntervalSinceReferenceDate:)) ?? .distantPast
        return try Self.validate(compiledURL: compiled, modelFile: modelFile, installedAt: installedAt, origin: .installed)
    }

    /// Copies (compiling if needed) a model into Application Support, validates it and makes it current.
    func install(from source: URL) async throws -> LearnedModelInfo {
        let fm = FileManager.default
        let ext = source.pathExtension.lowercased()
        guard ext == "mlpackage" || ext == "mlmodelc" else {
            throw LearnedNormalError.unsupportedFile(source.lastPathComponent)
        }
        try fm.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)
        let staging = Self.modelsDirectory.appendingPathComponent(".staging-\(UUID().uuidString.lowercased())", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let stem = source.deletingPathExtension().lastPathComponent
        let stagedCompiled = staging.appendingPathComponent("\(stem).mlmodelc", isDirectory: true)
        if ext == "mlpackage" {
            let compiled = try await MLModel.compileModel(at: source)
            defer { try? fm.removeItem(at: compiled) }
            try fm.copyItem(at: compiled, to: stagedCompiled)
        } else {
            try fm.copyItem(at: source, to: stagedCompiled)
        }
        let installedAt = Date()
        // Validate before replacing anything already installed.
        _ = try Self.validate(compiledURL: stagedCompiled, modelFile: source.lastPathComponent, installedAt: installedAt, origin: .installed)
        let finalName = "\(stem).mlmodelc"
        let final = Self.modelsDirectory.appendingPathComponent(finalName, isDirectory: true)
        removeInstalledFiles()
        try fm.moveItem(at: stagedCompiled, to: final)
        let record: [String: Any] = [
            "compiled": finalName, "model_file": source.lastPathComponent,
            "installed_at": installedAt.timeIntervalSinceReferenceDate
        ]
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            .write(to: Self.installRecordURL, options: .atomic)
        let info = try Self.validate(compiledURL: final, modelFile: source.lastPathComponent, installedAt: installedAt, origin: .installed)
        setInstalled(info)
        return info
    }

    /// Removes the user-installed model; call resolveModel() afterwards to fall back to a built-in one.
    func uninstall() {
        removeInstalledFiles()
        setInstalled(nil)
    }

    /// Makes no model active without touching any files (used by the snapshot harness).
    func deactivate() { setInstalled(nil) }

    private func removeInstalledFiles() {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: Self.modelsDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.pathExtension == "mlmodelc" { try? fm.removeItem(at: url) }
        try? fm.removeItem(at: Self.installRecordURL)
    }

    private func setInstalled(_ info: LearnedModelInfo?) {
        lock.lock()
        if installed != info {
            installed = info
            loadedModels.removeAll()
            cache.removeAll()
        }
        lock.unlock()
    }

    private static func validate(
        compiledURL: URL, modelFile: String, installedAt: Date, origin: LearnedModelOrigin
    ) throws -> LearnedModelInfo {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: compiledURL, configuration: configuration)
        let description = model.modelDescription
        let metadata = description.metadata[.creatorDefinedKey] as? [String: String] ?? [:]
        let contract = metadata["materiallab.contract"] ?? "none"
        guard contract == Self.contract else { throw LearnedNormalError.contractMismatch(contract) }
        guard let input = description.inputDescriptionsByName["image"],
              let constraint = input.imageConstraint,
              constraint.pixelsWide == tile, constraint.pixelsHigh == tile,
              description.outputDescriptionsByName["normals"] != nil
        else { throw LearnedNormalError.unexpectedOutput("expected a 518 × 518 “image” input and a “normals” output") }
        return LearnedModelInfo(
            origin: origin, compiledURL: compiledURL, modelFile: modelFile,
            weightsSHA256: metadata["materiallab.weights_sha256"] ?? "unknown",
            mogeCommit: metadata["materiallab.moge_commit"] ?? "unknown",
            version: description.metadata[.versionString] as? String ?? "",
            installedAt: installedAt
        )
    }

    // MARK: - Model loading

    /// Loads (once per compute-unit setting) the Core ML model; the first Neural Engine load can take seconds.
    @discardableResult
    func prepare() throws -> MLModel {
        loadLock.lock()
        defer { loadLock.unlock() }
        lock.lock()
        let info = installed, unitSetting = units
        let key = "\(info?.identity ?? "")|\(unitSetting.rawValue)"
        if let loaded = loadedModels[key] { lock.unlock(); return loaded }
        lock.unlock()
        guard let info else { throw LearnedNormalError.notInstalled }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = unitSetting.mlValue
        let model = try MLModel(contentsOf: info.compiledURL, configuration: configuration)
        lock.lock()
        if installed == info { loadedModels[key] = model }
        lock.unlock()
        return model
    }

    // MARK: - Inference

    func cachedGuide(sourceSHA256: String, wrap: Bool) -> GuideNormals? {
        lock.lock(); defer { lock.unlock() }
        guard let info = installed else { return nil }
        let key = Self.cacheKey(source: sourceSHA256, model: info, units: units, wrap: wrap)
        return cache.first { $0.key == key }?.value
    }

    /// Guide normals for a square sRGB RGBA8 working image. Cached per (source hash, model, compute units),
    /// so recipe edits never re-run inference. `willInfer` is called with tile progress in [0, 1] on a miss.
    func guideNormals(
        rgba: Data, size: Int, sourceSHA256: String, wrap: Bool,
        shouldContinue: () -> Bool,
        progress: (Float) -> Void
    ) throws -> GuideNormals {
        if let hit = cachedGuide(sourceSHA256: sourceSHA256, wrap: wrap) { return hit }
        inferenceLock.lock()
        defer { inferenceLock.unlock() }
        if let hit = cachedGuide(sourceSHA256: sourceSHA256, wrap: wrap) { return hit }
        guard shouldContinue() else { throw LearnedNormalError.cancelled }
        lock.lock()
        let info = installed, unitSetting = units
        lock.unlock()
        guard let info else { throw LearnedNormalError.notInstalled }
        progress(0)
        let model = try prepare()
        guard shouldContinue() else { throw LearnedNormalError.cancelled }
        // Timed after loading: the figure reported is tiling + inference + encoding.
        let started = Date()
        guard let tiler = rgba.withUnsafeBytes({ raw in
            PBRLabGuideTilerCreate(raw.bindMemory(to: UInt8.self).baseAddress, size * 4, UInt32(size), wrap ? 1 : 0)
        }) else { throw LearnedNormalError.unexpectedOutput("could not prepare the estimator input") }
        defer { PBRLabGuideTilerFree(tiler) }
        let passes = PBRLabGuideTilerPassCount(tiler)
        let pixelBuffer = try Self.makePixelBuffer()
        var planar = [Float](repeating: 0, count: 3 * Self.tile * Self.tile)
        for pass in 0..<passes {
            guard shouldContinue() else { throw LearnedNormalError.cancelled }
            try autoreleasepool {
                CVPixelBufferLockBaseAddress(pixelBuffer, [])
                let filled = PBRLabGuideTilerFillInput(tiler, pass,
                    CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self),
                    CVPixelBufferGetBytesPerRow(pixelBuffer))
                CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                guard filled != 0 else { throw LearnedNormalError.unexpectedOutput("could not fill the model input") }
                let inputs = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: pixelBuffer)])
                let output = try model.prediction(from: inputs)
                guard let normals = output.featureValue(for: "normals")?.multiArrayValue else {
                    throw LearnedNormalError.unexpectedOutput("missing “normals” multi-array")
                }
                try Self.copyPlanar(normals, into: &planar)
                let added = planar.withUnsafeBufferPointer {
                    PBRLabGuideTilerAddPrediction(tiler, pass, $0.baseAddress, Self.tile * Self.tile, Self.tile, 1)
                }
                guard added != 0 else { throw LearnedNormalError.unexpectedOutput("could not add a prediction") }
            }
            progress(Float(pass + 1) / Float(passes))
        }
        var encoded = Data(count: size * size * 4)
        let finished = encoded.withUnsafeMutableBytes { raw in
            PBRLabGuideTilerFinish(tiler, UInt32(size), raw.bindMemory(to: UInt8.self).baseAddress, size * 4)
        }
        guard finished != 0 else { throw LearnedNormalError.unexpectedOutput("could not finish the guide normals") }
        let guide = GuideNormals(
            rgba8: encoded, size: size, workResolution: Int(PBRLabGuideTilerWorkResolution(tiler)),
            tiles: Int(PBRLabGuideTilerTileCount(tiler)), tiling: String(cString: PBRLabGuideTilerContract(tiler)),
            sha256: SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined(),
            computeUnits: unitSetting, model: info,
            inferenceDuration: Date().timeIntervalSince(started), wasCached: false
        )
        lock.lock()
        if installed == info {
            let key = Self.cacheKey(source: sourceSHA256, model: info, units: unitSetting, wrap: wrap)
            let cachedCopy = GuideNormals(
                rgba8: guide.rgba8, size: guide.size, workResolution: guide.workResolution, tiles: guide.tiles,
                tiling: guide.tiling, sha256: guide.sha256, computeUnits: guide.computeUnits, model: guide.model,
                inferenceDuration: guide.inferenceDuration, wasCached: true
            )
            cache.removeAll { $0.key == key }
            cache.insert((key, cachedCopy), at: 0)
            if cache.count > 6 { cache.removeLast(cache.count - 6) }
        }
        lock.unlock()
        return guide
    }

    /// Drops cached guide normals (the loaded model stays warm).
    func clearCache() {
        lock.lock(); cache.removeAll(); lock.unlock()
    }

    private static func cacheKey(source: String, model: LearnedModelInfo, units: LearnedComputeUnits, wrap: Bool) -> String {
        "\(source)|\(model.identity)|\(units.rawValue)|\(wrap)"
    }

    private static func makePixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        let status = CVPixelBufferCreate(nil, tile, tile, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw LearnedNormalError.unexpectedOutput("could not allocate the input pixel buffer")
        }
        return buffer
    }

    /// Copies a (1, 3, 518, 518) prediction of any float type into dense planar Float.
    private static func copyPlanar(_ array: MLMultiArray, into planar: inout [Float]) throws {
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

    /// Linear RGBA8 display image of guide normals.
    static func previewMap(_ guide: GuideNormals) -> MaterialMapData {
        MaterialMapData(width: guide.size, height: guide.size, rowBytes: guide.size * 4,
                        format: .rgba8Linear, bytes: guide.rgba8)
    }
}
