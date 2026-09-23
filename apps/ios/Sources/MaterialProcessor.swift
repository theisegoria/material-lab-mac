import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit

enum MaterialPreset: String, CaseIterable, Codable, Identifiable {
    case flat, stone, fabric, organic, coatedMetal, bareMetal
    var id: String { rawValue }
    var title: String {
        switch self {
        case .flat: "Flat / painted"
        case .stone: "Stone / concrete"
        case .fabric: "Fabric"
        case .organic: "Organic"
        case .coatedMetal: "Coated metal"
        case .bareMetal: "Bare metal"
        }
    }
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

struct MaterialRecipe: Codable, Equatable {
    var preset: MaterialPreset
    var heightStrength: Float
    var heightPolarity: Int32
    var roughnessBase: Float
    var roughnessVariation: Float
    var aoRadiusPixels: Float
    var tileWrap: Bool
    var assignedMetalness: Float?
    var bentNormal: Bool

    init(preset: MaterialPreset) {
        let defaults = PBRLabDefaultRecipe(preset.cValue)
        self.preset = preset
        heightStrength = defaults.height_strength
        heightPolarity = defaults.height_polarity
        roughnessBase = defaults.roughness_base
        roughnessVariation = defaults.roughness_variation
        aoRadiusPixels = defaults.ao_radius_pixels
        tileWrap = defaults.tile_wrap != 0
        assignedMetalness = nil
        bentNormal = false
    }

    var cValue: PBRLabRecipe {
        var value = PBRLabDefaultRecipe(preset.cValue)
        value.height_strength = heightStrength
        value.height_polarity = heightPolarity
        value.roughness_base = roughnessBase
        value.roughness_variation = roughnessVariation
        value.ao_radius_pixels = aoRadiusPixels
        value.tile_wrap = tileWrap ? 1 : 0
        value.assigned_metalness_enabled = assignedMetalness == nil ? 0 : 1
        value.assigned_metalness = assignedMetalness ?? 0
        value.bent_normal_enabled = bentNormal ? 1 : 0
        return value
    }
}

enum MaterialMapKind: String, CaseIterable, Identifiable {
    case albedo, height, normal, roughness, ao, cavity, convexity, slope, edge, bentNormal, orm
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ao: "Ambient occlusion"
        case .bentNormal: "Bent normal"
        case .orm: "ORM"
        default: rawValue.capitalized
        }
    }
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
    var exportedName: String { self == .bentNormal ? "bent_normal" : rawValue }
    var provenance: String {
        switch self {
        case .albedo: "captured or imported source, perspective-corrected"
        case .height: "pseudo-height inferred from albedo and material prior"
        case .roughness: "editable perceptual roughness prior with restrained height variation"
        case .orm: "AO estimate, roughness prior, and explicitly assigned metalness"
        default: "analytically derived from estimated pseudo-height"
        }
    }
}

struct DerivedMap {
    let kind: MaterialMapKind
    let width: Int
    let height: Int
    let pixelFormat: String
    let png: Data
    var preview: UIImage? { UIImage(data: png) }
}

struct SeamDiagnostics: Codable {
    let heightValueDelta: Float
    let heightGradientDelta: Float
    let albedoValueDelta: Float
}

struct ImageQualityDiagnostics: Codable {
    let brightNeutralFraction: Double
    let laplacianVariance: Double
    var warnings: [String] {
        var messages: [String] = []
        if brightNeutralFraction > 0.02 { messages.append("Possible glare or clipped highlights; check the source under softer light.") }
        if laplacianVariance < 24 { messages.append("Low fine detail; inspect focus before using inferred relief.") }
        return messages
    }
}

struct DerivedMaterial {
    let maps: [MaterialMapKind: DerivedMap]
    let sourcePNG: Data
    let seam: SeamDiagnostics
    let quality: ImageQualityDiagnostics
    let algorithmVersion: String
    let resolution: Int
}

enum MaterialProcessor {
    static func derive(image: UIImage, quad: PerspectiveQuad,
                       resolution: Int, recipe: MaterialRecipe) throws -> DerivedMaterial {
        let corrected = try PerspectiveCropper.cropped(image, quad: quad, pixels: resolution)
        let rgba = try rgba8(corrected)
        let quality = assessQuality(rgba, width: resolution)
        var cRecipe = recipe.cValue
        var maps: [MaterialMapKind: DerivedMap] = [:]
        var seam = SeamDiagnostics(heightValueDelta: 0, heightGradientDelta: 0, albedoValueDelta: 0)
        var error = [CChar](repeating: 0, count: 1024)
        try rgba.withUnsafeBufferPointer { buffer in
            var input = PBRLabInput()
            input.rgba8 = buffer.baseAddress
            input.rgba_row_bytes = resolution * 4
            input.relief_mask_r8 = nil
            input.relief_mask_row_bytes = 0
            input.height_override_r16 = nil
            input.height_override_row_bytes = 0
            input.width = UInt32(resolution)
            input.height = UInt32(resolution)
            let result = PBRLabDerive(&input, &cRecipe, nil, nil, &error, error.count)
            guard let result else { throw CaptureError.derivationFailed(String(cString: error)) }
            defer { PBRLabFreeResult(result) }
            let cSeam = PBRLabGetSeamMetrics(result)
            seam = SeamDiagnostics(heightValueDelta: cSeam.height_value_delta,
                                   heightGradientDelta: cSeam.height_gradient_delta,
                                   albedoValueDelta: cSeam.albedo_value_delta)
            for kind in MaterialMapKind.allCases {
                var map = PBRLabMap()
                guard PBRLabGetMap(result, kind.cValue, &map) != 0,
                      let pixels = map.pixels else { continue }
                let bytes = Data(bytes: pixels, count: map.byte_count)
                let format: String
                switch map.format {
                case PBRLabPixelFormatRGBA8SRGB: format = "rgba8_srgb_png"
                case PBRLabPixelFormatRGBA8Linear: format = "rgba8_linear_png"
                case PBRLabPixelFormatR16UNormLE: format = "r16_unorm_png"
                default: throw CaptureError.derivationFailed("Unexpected pixel format")
                }
                let png = try encodePNG(bytes, width: Int(map.width), height: Int(map.height),
                                        format: map.format, rowBytes: map.row_bytes)
                maps[kind] = DerivedMap(kind: kind, width: Int(map.width),
                                        height: Int(map.height), pixelFormat: format, png: png)
            }
        }
        guard let sourcePNG = maps[.albedo]?.png else {
            throw CaptureError.derivationFailed("The canonical sRGB albedo map is missing")
        }
        return DerivedMaterial(maps: maps, sourcePNG: sourcePNG, seam: seam, quality: quality,
                               algorithmVersion: String(cString: PBRLabVersion()), resolution: resolution)
    }

    private static func rgba8(_ image: UIImage) throws -> [UInt8] {
        guard let source = image.cgImage else { throw CaptureError.invalidImage }
        let width = source.width
        let height = source.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmap = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: bitmap) else {
                throw CaptureError.invalidImage
            }
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Int(bytes[index + 3])
            if alpha > 0 && alpha < 255 {
                for channel in 0..<3 { bytes[index + channel] = UInt8(min(255, Int(bytes[index + channel]) * 255 / alpha)) }
            }
        }
        return bytes
    }

    private static func assessQuality(_ rgba: [UInt8], width: Int) -> ImageQualityDiagnostics {
        let step = max(1, width / 256)
        var bright = 0
        var count = 0
        var response = 0.0
        var responseSquare = 0.0
        func luma(_ x: Int, _ y: Int) -> Double {
            let i = (y * width + x) * 4
            return Double(rgba[i]) * 0.2126 + Double(rgba[i + 1]) * 0.7152 + Double(rgba[i + 2]) * 0.0722
        }
        for y in stride(from: step, to: width - step, by: step) {
            for x in stride(from: step, to: width - step, by: step) {
                let i = (y * width + x) * 4
                if min(rgba[i], rgba[i + 1], rgba[i + 2]) > 245 { bright += 1 }
                let lap = 4 * luma(x, y) - luma(x - step, y) - luma(x + step, y) -
                          luma(x, y - step) - luma(x, y + step)
                response += lap
                responseSquare += lap * lap
                count += 1
            }
        }
        let n = Double(max(1, count))
        return ImageQualityDiagnostics(brightNeutralFraction: Double(bright) / n,
                                       laplacianVariance: max(0, responseSquare / n - (response / n) * (response / n)))
    }

    private static func encodePNG(_ bytes: Data, width: Int, height: Int,
                                  format: PBRLabPixelFormat, rowBytes: Int) throws -> Data {
        let provider = CGDataProvider(data: bytes as CFData)!
        let image: CGImage?
        if format == PBRLabPixelFormatR16UNormLE {
            image = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 16,
                            bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder16Little.rawValue |
                                                     CGImageAlphaInfo.none.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent)
        } else {
            let space = format == PBRLabPixelFormatRGBA8SRGB
                ? CGColorSpace(name: CGColorSpace.sRGB)! : CGColorSpace(name: CGColorSpace.linearSRGB)!
            image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: rowBytes, space: space,
                            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue |
                                                     CGImageAlphaInfo.last.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent)
        }
        guard let image else { throw CaptureError.derivationFailed("Cannot encode map pixels") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureError.derivationFailed("Cannot open PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.derivationFailed("PNG export failed") }
        return output as Data
    }
}
