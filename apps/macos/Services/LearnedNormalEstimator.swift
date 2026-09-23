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
    let sha256: String
    let computeUnits: LearnedComputeUnits
    let model: LearnedModelInfo
    let inferenceDuration: TimeInterval
    let wasCached: Bool
}

/// Runs the Material Lab learned-normal contract (docs/LEARNED_NORMALS.md) through Core ML:
/// overlapping 518² tiles, sine-window blending, bilinear resample and RGBA8 encoding.
/// Thread-safe; loaded models and results are reused across derivations.
final class LearnedNormalEstimator: @unchecked Sendable {
    static let shared = LearnedNormalEstimator()

    static let contract = "tangent_normals_plus_y_v1"
    static let estimatorName = "moge-2-vits-normal"
    static let tile = 518
    static let maximumWork = 1036
    static let stride = 259

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

    func cachedGuide(sourceSHA256: String) -> GuideNormals? {
        lock.lock(); defer { lock.unlock() }
        guard let info = installed else { return nil }
        let key = Self.cacheKey(source: sourceSHA256, model: info, units: units)
        return cache.first { $0.key == key }?.value
    }

    /// Guide normals for a square sRGB RGBA8 working image. Cached per (source hash, model, compute units),
    /// so recipe edits never re-run inference. `willInfer` is called with tile progress in [0, 1] on a miss.
    func guideNormals(
        rgba: Data, size: Int, sourceSHA256: String,
        shouldContinue: () -> Bool,
        progress: (Float) -> Void
    ) throws -> GuideNormals {
        if let hit = cachedGuide(sourceSHA256: sourceSHA256) { return hit }
        inferenceLock.lock()
        defer { inferenceLock.unlock() }
        if let hit = cachedGuide(sourceSHA256: sourceSHA256) { return hit }
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
        let work = min(Self.maximumWork, max(Self.tile, size))
        let workImage = work == size ? rgba : try Self.resampleRGBA(rgba, from: size, to: work)
        let origins = Self.tileOrigins(work)
        let tileCount = origins.count * origins.count
        let window = (0..<Self.tile).map { t in
            max(sinf(Float.pi * (Float(t) + 0.5) / Float(Self.tile)), 1e-3)
        }
        var field = [Float](repeating: 0, count: work * work * 3)
        let pixelBuffer = try Self.makePixelBuffer()
        var done = 0
        for oy in origins {
            for ox in origins {
                guard shouldContinue() else { throw LearnedNormalError.cancelled }
                try Self.fill(pixelBuffer, from: workImage, work: work, x0: ox, y0: oy)
                let inputs = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: pixelBuffer)])
                let output = try model.prediction(from: inputs)
                guard let normals = output.featureValue(for: "normals")?.multiArrayValue else {
                    throw LearnedNormalError.unexpectedOutput("missing “normals” multi-array")
                }
                try Self.accumulate(normals, into: &field, work: work, x0: ox, y0: oy, window: window)
                done += 1
                progress(Float(done) / Float(tileCount))
            }
        }
        let encoded = Self.encode(field, work: work, size: size)
        let guide = GuideNormals(
            rgba8: encoded, size: size, workResolution: work, tiles: tileCount,
            sha256: SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined(),
            computeUnits: unitSetting, model: info,
            inferenceDuration: Date().timeIntervalSince(started), wasCached: false
        )
        lock.lock()
        if installed == info {
            let key = Self.cacheKey(source: sourceSHA256, model: info, units: unitSetting)
            let cachedCopy = GuideNormals(
                rgba8: guide.rgba8, size: guide.size, workResolution: guide.workResolution, tiles: guide.tiles,
                sha256: guide.sha256, computeUnits: guide.computeUnits, model: guide.model,
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

    private static func cacheKey(source: String, model: LearnedModelInfo, units: LearnedComputeUnits) -> String {
        "\(source)|\(model.identity)|\(units.rawValue)"
    }

    /// Origins start at 0 and step by 259; a final origin at W − 518 closes any gap.
    static func tileOrigins(_ work: Int) -> [Int] {
        let last = work - tile
        var origins = Array(Swift.stride(from: 0, through: last, by: stride))
        if let final = origins.last, final < last { origins.append(last) }
        return origins
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

    /// Copies one tile of raw sRGB values (no colour conversion) into the BGRA input buffer.
    private static func fill(_ buffer: CVPixelBuffer, from rgba: Data, work: Int, x0: Int, y0: Int) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
            throw LearnedNormalError.unexpectedOutput("input pixel buffer is not addressable")
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        rgba.withUnsafeBytes { raw in
            guard let src = raw.bindMemory(to: UInt8.self).baseAddress else { return }
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

    private static func accumulate(
        _ array: MLMultiArray, into field: inout [Float], work: Int, x0: Int, y0: Int, window: [Float]
    ) throws {
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

    /// Normalizes the blended W×W field, bilinearly resamples it to N×N, renormalizes and encodes linear RGBA8.
    private static func encode(_ field: [Float], work: Int, size: Int) -> Data {
        func normalized(_ v: SIMD3<Float>) -> SIMD3<Float> {
            let length = (v * v).sum().squareRoot()
            return length > 1e-12 ? v / length : SIMD3(0, 0, 1)
        }
        var unit = [SIMD3<Float>](repeating: .zero, count: work * work)
        for i in 0..<(work * work) {
            unit[i] = normalized(SIMD3(field[i * 3], field[i * 3 + 1], field[i * 3 + 2]))
        }
        var output = Data(count: size * size * 4)
        output.withUnsafeMutableBytes { raw in
            guard let dst = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let scale = Float(work) / Float(size)
            func byte(_ c: Float) -> UInt8 { UInt8(max(0, min(255, ((c * 0.5 + 0.5) * 255).rounded()))) }
            for y in 0..<size {
                let fy = max(0, min(Float(work - 1), (Float(y) + 0.5) * scale - 0.5))
                let iy = Int(fy), ty = fy - Float(iy), iy1 = min(work - 1, iy + 1)
                for x in 0..<size {
                    let n: SIMD3<Float>
                    if work == size {
                        n = unit[y * work + x]
                    } else {
                        let fx = max(0, min(Float(work - 1), (Float(x) + 0.5) * scale - 0.5))
                        let ix = Int(fx), tx = fx - Float(ix), ix1 = min(work - 1, ix + 1)
                        let top = unit[iy * work + ix] * (1 - tx) + unit[iy * work + ix1] * tx
                        let bottom = unit[iy1 * work + ix] * (1 - tx) + unit[iy1 * work + ix1] * tx
                        n = normalized(top * (1 - ty) + bottom * ty)
                    }
                    let o = (y * size + x) * 4
                    dst[o] = byte(n.x); dst[o + 1] = byte(n.y); dst[o + 2] = byte(n.z); dst[o + 3] = 255
                }
            }
        }
        return output
    }

    /// High-quality Core Graphics resample of a square sRGB RGBA8 image (only when N is outside [518, 1036]).
    private static func resampleRGBA(_ rgba: Data, from size: Int, to work: Int) throws -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = MaterialEngine.rgbaImage(rgba, width: size, height: size, rowBytes: size * 4, colorSpace: space),
              let context = CGContext(
                data: nil, width: work, height: work, bitsPerComponent: 8, bytesPerRow: work * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { throw LearnedNormalError.unexpectedOutput("could not resample the source") }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: work, height: work))
        guard let pointer = context.data else { throw LearnedNormalError.unexpectedOutput("resample buffer") }
        return Data(bytes: pointer, count: work * work * 4)
    }

    /// Linear RGBA8 display image of guide normals.
    static func previewMap(_ guide: GuideNormals) -> MaterialMapData {
        MaterialMapData(width: guide.size, height: guide.size, rowBytes: guide.size * 4,
                        format: .rgba8Linear, bytes: guide.rgba8)
    }
}
