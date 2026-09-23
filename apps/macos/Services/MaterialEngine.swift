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

    var errorDescription: String? {
        switch self {
        case .unreadableImage(let url): "Cannot decode image: \(url.lastPathComponent)"
        case .nonSquareImage: "The source could not be converted to a square image."
        case .invalidBuffer: "The material core returned an invalid image buffer."
        case .derivation(let text): text
        }
    }
}

final class DerivationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    let onProgress: (Float) -> Void

    init(onProgress: @escaping (Float) -> Void) {
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
}

private let materialProgressCallback: PBRLabProgressCallback = { value, opaque in
    guard let opaque else { return 1 }
    let control = Unmanaged<DerivationControl>.fromOpaque(opaque).takeUnretainedValue()
    control.onProgress(value)
    return control.shouldContinue ? 1 : 0
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
            reliefMaskURL: nil,
            heightOverrideURL: nil
        )
    }

    static func derive(
        source: MaterialSource,
        recipe: MaterialRecipe,
        control: DerivationControl
    ) throws -> DerivedMaterial {
        let sourceBytes = try Data(contentsOf: source.url)
        let loaded = try loadRGBA(from: source.url)
        let relief: [UInt8]? = try recipe.reliefMaskURL.map { url in
            let loadedRelief = try loadRGBA(from: url)
            var result = [UInt8](repeating: 0, count: targetSize * targetSize)
            for i in result.indices {
                let p = i * 4
                result[i] = UInt8(
                    (UInt16(loadedRelief.bytes[p]) * 54 +
                     UInt16(loadedRelief.bytes[p + 1]) * 183 +
                     UInt16(loadedRelief.bytes[p + 2]) * 19) / 256
                )
            }
            return result
        }

        let heightOverride: [UInt8]? = try recipe.heightOverrideURL.map {
            Array(try loadHeightOverrideR16(from: $0))
        }

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
        var error = [CChar](repeating: 0, count: 1024)

        let maskBytes = relief ?? []
        let heightBytes = heightOverride ?? []
        let nativeResult = loaded.bytes.withUnsafeBytes { sourceRaw in
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
            throw MaterialEngineError.derivation(String(cString: error))
        }
        defer { PBRLabFreeResult(nativeResult) }

        var maps: [MaterialMapKind: MaterialMapData] = [:]
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
            maps[kind] = MaterialMapData(
                width: Int(output.width), height: Int(output.height),
                rowBytes: output.row_bytes, format: format,
                bytes: Data(bytes: pixels, count: output.byte_count)
            )
        }
        let seams = PBRLabGetSeamMetrics(nativeResult)
        var warnings = [
            "Height, normals, AO, and roughness are editable estimates from one color image.",
            "Metalness is an artist assignment; physical surface properties were not measured."
        ]
        if loaded.wasCropped {
            warnings.append("The input was center-cropped to a square 1024-pixel working image.")
        }
        if source.reviewStatus.lowercased().contains("candidate") {
            warnings.append("This source is still a review candidate.")
        }
        if seams.height_value_delta > 0.02 || seams.albedo_value_delta > 0.03 {
            warnings.append("Opposite image edges differ; inspect the 3×3 tile preview before repeating.")
        }
        return DerivedMaterial(
            source: source, recipe: recipe,
            sourceSHA256: SHA256.hash(data: sourceBytes).map { String(format: "%02x", $0) }.joined(),
            algorithmVersion: String(cString: PBRLabVersion()),
            maps: maps,
            seams: MaterialSeamMetrics(
                heightValue: seams.height_value_delta,
                heightGradient: seams.height_gradient_delta,
                albedoValue: seams.albedo_value_delta
            ),
            warnings: warnings
        )
    }

    static func previewImage(_ map: MaterialMapData) -> NSImage? {
        let pixels: Data
        let rowBytes: Int
        if map.format == .r16Linear {
            var grayscale = Data(count: map.width * map.height * 4)
            grayscale.withUnsafeMutableBytes { output in
                map.bytes.withUnsafeBytes { input in
                    guard let dst = output.bindMemory(to: UInt8.self).baseAddress,
                          let src = input.bindMemory(to: UInt8.self).baseAddress else { return }
                    for i in 0..<(map.width * map.height) {
                        let value = src[i * 2 + 1]
                        let j = i * 4
                        dst[j] = value
                        dst[j + 1] = value
                        dst[j + 2] = value
                        dst[j + 3] = 255
                    }
                }
            }
            pixels = grayscale
            rowBytes = map.width * 4
        } else {
            pixels = map.bytes
            rowBytes = map.rowBytes
        }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: map.width, height: map.height,
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: rowBytes, space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
                    .union(.byteOrder32Big),
                provider: provider, decode: nil,
                shouldInterpolate: false, intent: .defaultIntent
              )
        else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: map.width, height: map.height))
    }

    static func relitPreview(_ material: DerivedMaterial, azimuth: Float = 0.6) -> NSImage? {
        guard let albedo = material.maps[.albedo],
              let normal = material.maps[.normal],
              albedo.width == normal.width, albedo.height == normal.height
        else { return nil }
        let lx = cos(azimuth) * 0.65
        let ly = sin(azimuth) * 0.65
        let lz: Float = 0.76
        var output = Data(count: albedo.width * albedo.height * 4)
        output.withUnsafeMutableBytes { destination in
            albedo.bytes.withUnsafeBytes { color in
                normal.bytes.withUnsafeBytes { normals in
                    guard let dst = destination.bindMemory(to: UInt8.self).baseAddress,
                          let src = color.bindMemory(to: UInt8.self).baseAddress,
                          let nor = normals.bindMemory(to: UInt8.self).baseAddress else { return }
                    for i in 0..<(albedo.width * albedo.height) {
                        let j = i * 4
                        let nx = Float(nor[j]) / 127.5 - 1
                        let ny = Float(nor[j + 1]) / 127.5 - 1
                        let nz = Float(nor[j + 2]) / 127.5 - 1
                        let shade = min(1, max(0, 0.18 + 0.82 * max(0, nx * lx + ny * ly + nz * lz)))
                        dst[j] = UInt8(Float(src[j]) * shade)
                        dst[j + 1] = UInt8(Float(src[j + 1]) * shade)
                        dst[j + 2] = UInt8(Float(src[j + 2]) * shade)
                        dst[j + 3] = src[j + 3]
                    }
                }
            }
        }
        return previewImage(MaterialMapData(
            width: albedo.width, height: albedo.height,
            rowBytes: albedo.rowBytes, format: .rgba8SRGB, bytes: output
        ))
    }

    private static func loadHeightOverrideR16(from url: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 8192
                ] as CFDictionary
              ),
              image.bitsPerComponent == 16,
              let context = CGContext(
                data: nil, width: targetSize, height: targetSize,
                bitsPerComponent: 16, bytesPerRow: targetSize * 2,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo.byteOrder16Little.rawValue
              )
        else { throw MaterialEngineError.derivation("Height override must be a readable 16-bit grayscale image.") }
        let side = min(image.width, image.height)
        guard side > 0 else { throw MaterialEngineError.nonSquareImage }
        let scale = CGFloat(targetSize) / CGFloat(side)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(
            x: -CGFloat(image.width - side) * scale / 2,
            y: -CGFloat(image.height - side) * scale / 2,
            width: CGFloat(image.width) * scale,
            height: CGFloat(image.height) * scale
        ))
        guard let pointer = context.data else { throw MaterialEngineError.invalidBuffer }
        return Data(bytes: pointer, count: targetSize * targetSize * 2)
    }

    private static func loadRGBA(from url: URL) throws -> (bytes: Data, wasCropped: Bool) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 8192
                ] as CFDictionary
              ),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { throw MaterialEngineError.unreadableImage(url) }
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
        let rectangle = CGRect(
            x: -CGFloat(cgImage.width - size) * scale / 2,
            y: -CGFloat(cgImage.height - size) * scale / 2,
            width: CGFloat(cgImage.width) * scale,
            height: CGFloat(cgImage.height) * scale
        )
        context.draw(cgImage, in: rectangle)
        guard let pointer = context.data else { throw MaterialEngineError.invalidBuffer }
        var bytes = Data(bytes: pointer, count: targetSize * targetSize * 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for i in 0..<(targetSize * targetSize) {
                let offset = i * 4
                let alpha = Int(p[offset + 3])
                if alpha > 0 && alpha < 255 {
                    for channel in 0..<3 {
                        p[offset + channel] = UInt8(min(255, Int(p[offset + channel]) * 255 / alpha))
                    }
                }
            }
        }
        return (bytes, cgImage.width != cgImage.height)
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
