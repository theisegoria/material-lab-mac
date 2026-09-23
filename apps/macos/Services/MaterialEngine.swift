import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

enum MaterialEngineError: LocalizedError {
    case unreadableImage(URL)
    case nonSquareImage
    case invalidBuffer
    case derivation(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unreadableImage(let url): "Cannot decode image: \(url.lastPathComponent)"
        case .nonSquareImage: "The source could not be converted to a square image."
        case .invalidBuffer: "The material core returned an invalid image buffer."
        case .derivation(let text): text
        case .cancelled: "Derivation cancelled."
        }
    }
}

/// Cancellation flag plus throttled progress reporting shared with the C core.
final class DerivationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var lastReported: Float = -1
    private let onProgress: @Sendable (Float) -> Void

    init(onProgress: @escaping @Sendable (Float) -> Void) {
        self.onProgress = onProgress
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var shouldContinue: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cancelled
    }

    /// Forwards at most ~50 updates per derivation so the main actor is not flooded.
    func report(_ value: Float) {
        lock.lock()
        let forward = value >= 1 || value - lastReported >= 0.02 || value < lastReported
        if forward { lastReported = value }
        lock.unlock()
        if forward { onProgress(value) }
    }
}

private let materialProgressCallback: PBRLabProgressCallback = { value, opaque in
    guard let opaque else { return 1 }
    let control = Unmanaged<DerivationControl>.fromOpaque(opaque).takeUnretainedValue()
    control.report(value)
    return control.shouldContinue ? 1 : 0
}

/// Decoded working images keyed by file identity so live re-derivation skips decode and hashing.
private final class WorkingImageCache: @unchecked Sendable {
    struct Entry {
        let key: String
        let sha256: String
        let payload: Data
        let info: WorkingImageInfo
    }

    static let shared = WorkingImageCache()
    private let lock = NSLock()
    private var entries: [Entry] = []

    static func key(for url: URL, role: String) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        else { return nil }
        let stamp = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        return "\(role)|\(url.standardizedFileURL.path)|\(values.fileSize ?? -1)|\(stamp)"
    }

    func lookup(_ key: String?) -> Entry? {
        guard let key else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return entries.first { $0.key == key }
    }

    func store(_ entry: Entry) {
        lock.lock()
        entries.removeAll { $0.key == entry.key }
        entries.insert(entry, at: 0)
        if entries.count > 6 { entries.removeLast(entries.count - 6) }
        lock.unlock()
    }
}

enum MaterialEngine {
    static let targetSize = 1024

    static func defaultRecipe(for preset: MaterialPreset) -> MaterialRecipe {
        let native = PBRLabDefaultRecipe(preset.cValue)
        return MaterialRecipe(
            preset: preset,
            heightStrength: native.height_strength,
            heightPolarity: native.height_polarity,
            roughnessBase: native.roughness_base,
            roughnessVariation: native.roughness_variation,
            aoRadiusPixels: native.ao_radius_pixels,
            tileWrap: native.tile_wrap != 0,
            assignedMetalnessEnabled: native.assigned_metalness_enabled != 0,
            assignedMetalness: native.assigned_metalness,
            bentNormalEnabled: native.bent_normal_enabled != 0,
            normalStrength: native.normal_strength,
            normalYDown: native.normal_y_down != 0,
            aoStrength: native.ao_strength,
            albedoEqualize: native.albedo_equalize,
            seamlessBlend: native.seamless_blend,
            reliefMaskURL: nil,
            heightOverrideURL: nil
        )
    }

    static func derive(
        source: MaterialSource,
        recipe: MaterialRecipe,
        control: DerivationControl
    ) throws -> DerivedMaterial {
        let started = Date()
        let working = try workingImage(for: source.url)
        guard control.shouldContinue else { throw MaterialEngineError.cancelled }

        var reliefSHA: String?
        let relief: Data? = try recipe.reliefMaskURL.map { url in
            let entry = try reliefMask(for: url)
            reliefSHA = entry.sha256
            return entry.payload
        }
        var heightSHA: String?
        let heightOverride: Data? = try recipe.heightOverrideURL.map { url in
            let entry = try heightOverrideEntry(for: url)
            heightSHA = entry.sha256
            return entry.payload
        }
        guard control.shouldContinue else { throw MaterialEngineError.cancelled }

        var nativeRecipe = PBRLabDefaultRecipe(recipe.preset.cValue)
        nativeRecipe.height_strength = recipe.heightStrength
        nativeRecipe.height_polarity = recipe.heightPolarity
        nativeRecipe.roughness_base = recipe.roughnessBase
        nativeRecipe.roughness_variation = recipe.roughnessVariation
        nativeRecipe.ao_radius_pixels = recipe.aoRadiusPixels
        nativeRecipe.tile_wrap = recipe.tileWrap ? 1 : 0
        nativeRecipe.assigned_metalness_enabled = recipe.assignedMetalnessEnabled ? 1 : 0
        nativeRecipe.assigned_metalness = recipe.assignedMetalness
        nativeRecipe.bent_normal_enabled = recipe.bentNormalEnabled ? 1 : 0
        nativeRecipe.normal_strength = recipe.normalStrength
        nativeRecipe.normal_y_down = recipe.normalYDown ? 1 : 0
        nativeRecipe.ao_strength = recipe.aoStrength
        nativeRecipe.albedo_equalize = recipe.albedoEqualize
        nativeRecipe.seamless_blend = recipe.seamlessBlend
        var error = [CChar](repeating: 0, count: 1024)

        let maskBytes = relief ?? Data()
        let heightBytes = heightOverride ?? Data()
        let nativeResult = working.payload.withUnsafeBytes { sourceRaw in
            maskBytes.withUnsafeBytes { maskRaw in
                heightBytes.withUnsafeBytes { heightRaw in
                    var input = PBRLabInput()
                    input.rgba8 = sourceRaw.bindMemory(to: UInt8.self).baseAddress
                    input.rgba_row_bytes = targetSize * 4
                    input.relief_mask_r8 = maskBytes.isEmpty ? nil :
                        maskRaw.bindMemory(to: UInt8.self).baseAddress
                    input.relief_mask_row_bytes = maskBytes.isEmpty ? 0 : targetSize
                    input.height_override_r16 = heightBytes.isEmpty ? nil :
                        heightRaw.bindMemory(to: UInt8.self).baseAddress
                    input.height_override_row_bytes = heightBytes.isEmpty ? 0 : targetSize * 2
                    input.width = UInt32(targetSize)
                    input.height = UInt32(targetSize)
                    return error.withUnsafeMutableBufferPointer { errorBuffer in
                        PBRLabDerive(
                            &input, &nativeRecipe, materialProgressCallback,
                            Unmanaged.passUnretained(control).toOpaque(),
                            errorBuffer.baseAddress, errorBuffer.count
                        )
                    }
                }
            }
        }
        guard let nativeResult else {
            if !control.shouldContinue { throw MaterialEngineError.cancelled }
            throw MaterialEngineError.derivation(String(cString: error))
        }
        defer { PBRLabFreeResult(nativeResult) }

        var maps: [MaterialMapKind: MaterialMapData] = [:]
        var previews: [MaterialMapKind: CGImage] = [:]
        for kind in MaterialMapKind.allCases {
            var output = PBRLabMap()
            guard PBRLabGetMap(nativeResult, kind.cValue, &output) != 0 else { continue }
            guard let pixels = output.pixels,
                  output.width > 0, output.height > 0,
                  output.byte_count > 0,
                  output.byte_count == output.row_bytes * Int(output.height)
            else { throw MaterialEngineError.invalidBuffer }
            let format: MaterialPixelFormat
            switch output.format {
            case PBRLabPixelFormatRGBA8SRGB: format = .rgba8SRGB
            case PBRLabPixelFormatRGBA8Linear: format = .rgba8Linear
            case PBRLabPixelFormatR16UNormLE: format = .r16Linear
            default: throw MaterialEngineError.invalidBuffer
            }
            let map = MaterialMapData(
                width: Int(output.width), height: Int(output.height),
                rowBytes: output.row_bytes, format: format,
                bytes: Data(bytes: pixels, count: output.byte_count)
            )
            maps[kind] = map
            previews[kind] = kind == .height ? heightDisplayImage(map) ?? previewImage(map) : previewImage(map)
        }
        let seams = PBRLabGetSeamMetrics(nativeResult)
        var warnings = [
            "Height, normals, AO and roughness are editable estimates from one color image.",
            "Metalness is an artist assignment; physical surface properties were not measured."
        ]
        if working.info.wasCropped {
            warnings.append("The input was center-cropped to a square \(targetSize)-pixel working image.")
        }
        if source.reviewStatus.lowercased().contains("candidate") {
            warnings.append("This source is still a review candidate.")
        }
        if seams.height_value_delta > 0.02 || seams.albedo_value_delta > 0.03 {
            warnings.append("Opposite image edges differ; inspect the tiled view before repeating.")
        }
        if recipe.normalYDown {
            warnings.append("Normals are encoded DirectX-style (−Y, green down).")
        }
        let workingPreview = rgbaImage(
            working.payload, width: targetSize, height: targetSize,
            rowBytes: targetSize * 4, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        return DerivedMaterial(
            source: source, recipe: recipe,
            sourceSHA256: working.sha256,
            reliefMaskSHA256: reliefSHA,
            heightOverrideSHA256: heightSHA,
            algorithmVersion: String(cString: PBRLabVersion()),
            working: working.info,
            maps: maps,
            seams: MaterialSeamMetrics(
                heightValue: seams.height_value_delta,
                heightGradient: seams.height_gradient_delta,
                albedoValue: seams.albedo_value_delta
            ),
            warnings: warnings,
            previews: previews,
            workingPreview: workingPreview,
            duration: Date().timeIntervalSince(started)
        )
    }

    // MARK: - Display images

    /// Wraps map bytes in a CGImage without copying or converting pixels.
    static func previewImage(_ map: MaterialMapData) -> CGImage? {
        if map.format == .r16Linear {
            guard let provider = CGDataProvider(data: map.bytes as CFData) else { return nil }
            return CGImage(
                width: map.width, height: map.height,
                bitsPerComponent: 16, bitsPerPixel: 16,
                bytesPerRow: map.rowBytes,
                space: CGColorSpace(name: CGColorSpace.linearGray) ?? CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
                    .union(.byteOrder16Little),
                provider: provider, decode: nil,
                shouldInterpolate: true, intent: .defaultIntent
            )
        }
        // Data maps (normals, masks) are shown as their raw encoded values.
        return rgbaImage(
            map.bytes, width: map.width, height: map.height,
            rowBytes: map.rowBytes, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
    }

    /// Estimated relief is often a few percent of the 16-bit range; stretch it to the full
    /// display range so the preview is readable. Exported data is untouched.
    static func heightDisplayImage(_ map: MaterialMapData) -> CGImage? {
        guard map.format == .r16Linear else { return nil }
        let count = map.width * map.height
        var gray = Data(count: count)
        map.bytes.withUnsafeBytes { input in
            gray.withUnsafeMutableBytes { output in
                guard let src = input.bindMemory(to: UInt8.self).baseAddress,
                      let dst = output.bindMemory(to: UInt8.self).baseAddress else { return }
                func value(_ x: Int, _ y: Int) -> Int {
                    let p = src + y * map.rowBytes + x * 2
                    return Int(p[0]) | Int(p[1]) << 8
                }
                var low = Int.max, high = Int.min
                for y in 0..<map.height { for x in 0..<map.width { let v = value(x, y); low = min(low, v); high = max(high, v) } }
                let span = max(1, high - low)
                for y in 0..<map.height {
                    for x in 0..<map.width { dst[y * map.width + x] = UInt8((value(x, y) - low) * 255 / span) }
                }
            }
        }
        guard let provider = CGDataProvider(data: gray as CFData) else { return nil }
        return CGImage(
            width: map.width, height: map.height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: map.width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    static func rgbaImage(
        _ bytes: Data, width: Int, height: Int, rowBytes: Int, colorSpace: CGColorSpace?
    ) -> CGImage? {
        guard let provider = CGDataProvider(data: bytes as CFData), let colorSpace else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: rowBytes, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
                .union(.byteOrder32Big),
            provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent
        )
    }

    /// Normal map for renderers that expect +Y (OpenGL/RealityKit). Flips green for DirectX-encoded maps.
    static func openGLNormalImage(_ material: DerivedMaterial) -> CGImage? {
        guard let normal = material.maps[.normal] else { return nil }
        guard material.recipe.normalYDown else { return material.previews[.normal] }
        var bytes = normal.bytes
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0..<normal.height {
                let row = base + y * normal.rowBytes
                for x in 0..<normal.width { row[x * 4 + 1] = 255 &- row[x * 4 + 1] }
            }
        }
        return rgbaImage(bytes, width: normal.width, height: normal.height,
                         rowBytes: normal.rowBytes, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    // MARK: - Relighting

    private static let srgbToLinear: [Float] = (0..<256).map { value in
        let c = Float(value) / 255
        return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    private static let linearToSRGB: [UInt8] = (0..<4096).map { index in
        let c = Float(index) / 4095
        let s = c <= 0.0031308 ? c * 12.92 : 1.055 * powf(c, 1 / 2.4) - 0.055
        return UInt8(max(0, min(255, (s * 255).rounded())))
    }

    /// Lambert + ambient relight in linear light. Azimuth is measured in the image plane
    /// (x right, y down); elevation is the angle above the surface.
    static func relitImage(_ material: DerivedMaterial, azimuth: Float, elevation: Float) -> CGImage? {
        guard let albedo = material.maps[.albedo],
              let normal = material.maps[.normal],
              albedo.width == normal.width, albedo.height == normal.height
        else { return nil }
        let ao = material.maps[.ao].flatMap {
            $0.width == albedo.width && $0.height == albedo.height ? $0 : nil
        }
        let aoRowBytes = ao?.rowBytes ?? 0
        let width = albedo.width, height = albedo.height
        let cosEl = cosf(elevation)
        let lx = cosEl * cosf(azimuth)
        let ly = cosEl * sinf(azimuth)
        let lz = sinf(elevation)
        // +Y (OpenGL) maps store "up" in green, so image-space y (down) is the negation.
        let greenSign: Float = material.recipe.normalYDown ? 1 : -1
        let outputRowBytes = width * 4
        var output = Data(count: outputRowBytes * height)
        let toLinear = srgbToLinear
        let toSRGB = linearToSRGB
        let aoData = ao?.bytes ?? Data()
        output.withUnsafeMutableBytes { destination in
            albedo.bytes.withUnsafeBytes { color in
                normal.bytes.withUnsafeBytes { normals in
                    aoData.withUnsafeBytes { occlusion in
                        guard let dst = destination.bindMemory(to: UInt8.self).baseAddress,
                              let src = color.bindMemory(to: UInt8.self).baseAddress,
                              let nor = normals.bindMemory(to: UInt8.self).baseAddress else { return }
                        let occ = occlusion.bindMemory(to: UInt8.self).baseAddress
                        toLinear.withUnsafeBufferPointer { lin in
                            toSRGB.withUnsafeBufferPointer { enc in
                                for y in 0..<height {
                                    let srcRow = src + y * albedo.rowBytes
                                    let norRow = nor + y * normal.rowBytes
                                    let occRow = occ.map { $0 + y * aoRowBytes }
                                    let dstRow = dst + y * outputRowBytes
                                    for x in 0..<width {
                                        let j = x * 4
                                        var nx = Float(norRow[j]) / 127.5 - 1
                                        var ny = greenSign * (Float(norRow[j + 1]) / 127.5 - 1)
                                        var nz = Float(norRow[j + 2]) / 127.5 - 1
                                        let length = max(1e-4, (nx * nx + ny * ny + nz * nz).squareRoot())
                                        nx /= length; ny /= length; nz /= length
                                        let diffuse = max(0, nx * lx + ny * ly + nz * lz)
                                        let occlusion = occRow.map { Float($0[j]) / 255 } ?? 1
                                        let light = 0.14 * occlusion + 0.95 * diffuse
                                        for c in 0..<3 {
                                            let value = min(1, lin[Int(srcRow[j + c])] * light)
                                            dstRow[j + c] = enc[Int(value * 4095)]
                                        }
                                        dstRow[j + 3] = 255
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        return rgbaImage(output, width: width, height: height, rowBytes: outputRowBytes,
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    // MARK: - Input loading

    private static func workingImage(for url: URL) throws -> WorkingImageCache.Entry {
        let key = WorkingImageCache.key(for: url, role: "source")
        if let cached = WorkingImageCache.shared.lookup(key) { return cached }
        // Read once: the same bytes are hashed for provenance and decoded for pixels.
        let bytes = try Data(contentsOf: url)
        let loaded = try decodeRGBA(bytes, url: url)
        let entry = WorkingImageCache.Entry(
            key: key ?? UUID().uuidString, sha256: sha256Hex(bytes),
            payload: loaded.pixels, info: loaded.info
        )
        if key != nil { WorkingImageCache.shared.store(entry) }
        return entry
    }

    private static func reliefMask(for url: URL) throws -> WorkingImageCache.Entry {
        let key = WorkingImageCache.key(for: url, role: "relief")
        if let cached = WorkingImageCache.shared.lookup(key) { return cached }
        let bytes = try Data(contentsOf: url)
        let loaded = try decodeRGBA(bytes, url: url)
        var result = Data(count: targetSize * targetSize)
        result.withUnsafeMutableBytes { output in
            loaded.pixels.withUnsafeBytes { input in
                guard let dst = output.bindMemory(to: UInt8.self).baseAddress,
                      let src = input.bindMemory(to: UInt8.self).baseAddress else { return }
                for i in 0..<(targetSize * targetSize) {
                    let p = i * 4
                    dst[i] = UInt8((UInt32(src[p]) * 54 + UInt32(src[p + 1]) * 183 +
                                    UInt32(src[p + 2]) * 19 + 128) / 256)
                }
            }
        }
        let entry = WorkingImageCache.Entry(
            key: key ?? UUID().uuidString, sha256: sha256Hex(bytes),
            payload: result, info: loaded.info
        )
        if key != nil { WorkingImageCache.shared.store(entry) }
        return entry
    }

    private static func heightOverrideEntry(for url: URL) throws -> WorkingImageCache.Entry {
        let key = WorkingImageCache.key(for: url, role: "height")
        if let cached = WorkingImageCache.shared.lookup(key) { return cached }
        let bytes = try Data(contentsOf: url)
        let loaded = try decodeHeightOverrideR16(bytes)
        let entry = WorkingImageCache.Entry(
            key: key ?? UUID().uuidString, sha256: sha256Hex(bytes),
            payload: loaded.pixels, info: loaded.info
        )
        if key != nil { WorkingImageCache.shared.store(entry) }
        return entry
    }

    /// Decodes a 16-bit grayscale image without colour management, center-crops it to a
    /// square and bilinearly resamples the raw 16-bit samples to the working size.
    static func decodeHeightOverrideR16(_ bytes: Data) throws -> (pixels: Data, info: WorkingImageInfo) {
        let failure = MaterialEngineError.derivation("Height override must be a readable 16-bit grayscale image.")
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ),
              image.bitsPerComponent == 16,
              image.colorSpace?.model == .monochrome,
              !image.bitmapInfo.contains(.floatComponents),
              image.bitsPerPixel == 16 || image.bitsPerPixel == 32,
              let raw = image.dataProvider?.data as Data?
        else { throw failure }
        let stride = image.bitsPerPixel / 16
        let alphaFirst: Bool = {
            switch image.alphaInfo {
            case .first, .premultipliedFirst, .noneSkipFirst: return true
            default: return false
            }
        }()
        let channel = stride == 2 && alphaFirst ? 1 : 0
        let little = image.bitmapInfo.contains(.byteOrder16Little)
        let width = image.width, height = image.height
        let rowBytes = image.bytesPerRow
        let side = min(width, height)
        guard side > 0, raw.count >= rowBytes * height else { throw failure }
        let x0 = (width - side) / 2, y0 = (height - side) / 2
        let target = targetSize
        var output = Data(count: target * target * 2)
        raw.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { out in
                guard let src = input.bindMemory(to: UInt8.self).baseAddress,
                      let dst = out.bindMemory(to: UInt8.self).baseAddress else { return }
                func sample(_ x: Int, _ y: Int) -> Float {
                    let p = src + (y0 + y) * rowBytes + ((x0 + x) * stride + channel) * 2
                    let value = little ? UInt16(p[0]) | UInt16(p[1]) << 8 : UInt16(p[0]) << 8 | UInt16(p[1])
                    return Float(value)
                }
                let scale = Float(side) / Float(target)
                for y in 0..<target {
                    let fy = max(0, min(Float(side - 1), (Float(y) + 0.5) * scale - 0.5))
                    let iy = Int(fy), ty = fy - Float(iy), iy1 = min(side - 1, iy + 1)
                    for x in 0..<target {
                        let fx = max(0, min(Float(side - 1), (Float(x) + 0.5) * scale - 0.5))
                        let ix = Int(fx), tx = fx - Float(ix), ix1 = min(side - 1, ix + 1)
                        let top = sample(ix, iy) * (1 - tx) + sample(ix1, iy) * tx
                        let bottom = sample(ix, iy1) * (1 - tx) + sample(ix1, iy1) * tx
                        let value = UInt16(max(0, min(65535, (top * (1 - ty) + bottom * ty).rounded())))
                        let o = (y * target + x) * 2
                        dst[o] = UInt8(value & 0xff)
                        dst[o + 1] = UInt8(value >> 8)
                    }
                }
            }
        }
        return (output, WorkingImageInfo(sourceWidth: width, sourceHeight: height, size: target))
    }

    /// Decodes to straight-alpha sRGB RGBA8 at the working size, center-cropping non-square input.
    private static func decodeRGBA(_ bytes: Data, url: URL) throws -> (pixels: Data, info: WorkingImageInfo) {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { throw MaterialEngineError.unreadableImage(url) }
        // Let ImageIO decode at reduced scale when the short side still covers the target.
        var maxPixel = 8192
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = properties[kCGImagePropertyPixelWidth] as? Int,
           let h = properties[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 {
            let aspect = Double(max(w, h)) / Double(min(w, h))
            maxPixel = min(8192, max(targetSize, Int((Double(targetSize) * aspect).rounded(.up)) + 2))
            maxPixel = min(maxPixel, max(w, h))
        }
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary
        ) else { throw MaterialEngineError.unreadableImage(url) }
        let size = min(cgImage.width, cgImage.height)
        guard size > 0 else { throw MaterialEngineError.nonSquareImage }
        guard let context = CGContext(
            data: nil, width: targetSize, height: targetSize,
            bitsPerComponent: 8, bytesPerRow: targetSize * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                .union(.byteOrder32Big).rawValue
        ) else { throw MaterialEngineError.invalidBuffer }
        context.interpolationQuality = .high
        let scale = CGFloat(targetSize) / CGFloat(size)
        context.draw(cgImage, in: CGRect(
            x: -CGFloat(cgImage.width - size) * scale / 2,
            y: -CGFloat(cgImage.height - size) * scale / 2,
            width: CGFloat(cgImage.width) * scale,
            height: CGFloat(cgImage.height) * scale
        ))
        guard let pointer = context.data else { throw MaterialEngineError.invalidBuffer }
        var pixels = Data(bytes: pointer, count: targetSize * targetSize * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for i in 0..<(targetSize * targetSize) {
                let offset = i * 4
                let alpha = Int(p[offset + 3])
                if alpha > 0 && alpha < 255 {
                    for channel in 0..<3 {
                        // Round to nearest when undoing premultiplication.
                        p[offset + channel] = UInt8(min(255, (Int(p[offset + channel]) * 255 + alpha / 2) / alpha))
                    }
                }
            }
        }
        let info = WorkingImageInfo(sourceWidth: cgImage.width, sourceHeight: cgImage.height, size: targetSize)
        return (pixels, info)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension MaterialPreset {
    var cValue: PBRLabPreset {
        switch self {
        case .flat: PBRLabPresetFlat
        case .stone: PBRLabPresetStone
        case .fabric: PBRLabPresetFabric
        case .organic: PBRLabPresetOrganic
        case .coatedMetal: PBRLabPresetCoatedMetal
        case .bareMetal: PBRLabPresetBareMetal
        }
    }
}

private extension MaterialMapKind {
    var cValue: PBRLabMapKind {
        switch self {
        case .albedo: PBRLabMapAlbedo
        case .height: PBRLabMapHeight
        case .normal: PBRLabMapNormal
        case .roughness: PBRLabMapRoughness
        case .ao: PBRLabMapAO
        case .cavity: PBRLabMapCavity
        case .convexity: PBRLabMapConvexity
        case .slope: PBRLabMapSlope
        case .edge: PBRLabMapEdge
        case .bentNormal: PBRLabMapBentNormal
        case .orm: PBRLabMapORM
        }
    }
}

/// Small, thread-safe thumbnail cache for sidebar, inbox and source previews.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, CGImage>()

    init() { cache.countLimit = 400 }

    func image(for url: URL, maxPixel: Int) -> CGImage? {
        let key = "\(url.path)#\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary)
        else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
