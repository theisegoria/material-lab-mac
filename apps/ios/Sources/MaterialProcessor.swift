import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit

enum MaterialPreset: String, CaseIterable, Codable, Identifiable, Sendable {
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
    var symbol: String {
        switch self {
        case .flat: "paintbrush.pointed"
        case .stone: "mountain.2"
        case .fabric: "tshirt"
        case .organic: "leaf"
        case .coatedMetal: "shield.lefthalf.filled"
        case .bareMetal: "gearshape"
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

/// Encoded camelCase into the .pbrcapture `recipe`. Fields added in algorithm 1.1.0 are always emitted.
struct MaterialRecipe: Codable, Equatable, Sendable {
    var preset: MaterialPreset
    var heightStrength: Float
    var heightPolarity: Int32
    var roughnessBase: Float
    var roughnessVariation: Float
    var aoRadiusPixels: Float
    var tileWrap: Bool
    var assignedMetalness: Float?
    var bentNormal: Bool
    var normalStrength: Float
    var normalYDown: Bool
    var aoStrength: Float
    var albedoEqualize: Float
    var seamlessBlend: Float
    /// Core 1.2.0 guide-normal blend. The iPhone supplies no guide normals yet, so this stays 0.
    var guideNormalWeight: Float = 0

    static let heightStrengthRange: ClosedRange<Float> = 0...0.5
    static let roughnessVariationRange: ClosedRange<Float> = 0...1
    static let aoRadiusRange: ClosedRange<Float> = 1...64
    static let normalStrengthRange: ClosedRange<Float> = 0...16
    static let aoStrengthRange: ClosedRange<Float> = 0...4
    static let albedoEqualizeRange: ClosedRange<Float> = 0...1
    static let seamlessBlendRange: ClosedRange<Float> = 0...0.45

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
        normalStrength = defaults.normal_strength
        normalYDown = defaults.normal_y_down != 0
        aoStrength = defaults.ao_strength
        albedoEqualize = defaults.albedo_equalize
        seamlessBlend = defaults.seamless_blend
    }

    /// Switch the material prior while keeping export, tiling and lighting-cleanup choices.
    func applyingPreset(_ preset: MaterialPreset) -> Self {
        var next = Self(preset: preset)
        next.normalYDown = normalYDown
        next.tileWrap = tileWrap
        next.bentNormal = bentNormal
        next.seamlessBlend = seamlessBlend
        next.albedoEqualize = albedoEqualize
        return next
    }

    private enum CodingKeys: String, CodingKey {
        case preset, heightStrength, heightPolarity, roughnessBase, roughnessVariation, aoRadiusPixels
        case tileWrap, assignedMetalness, bentNormal, normalStrength, normalYDown, aoStrength
        case albedoEqualize, seamlessBlend, guideNormalWeight
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(preset: try c.decode(MaterialPreset.self, forKey: .preset))
        heightStrength = try c.decode(Float.self, forKey: .heightStrength)
        heightPolarity = try c.decode(Int32.self, forKey: .heightPolarity)
        roughnessBase = try c.decode(Float.self, forKey: .roughnessBase)
        roughnessVariation = try c.decode(Float.self, forKey: .roughnessVariation)
        aoRadiusPixels = try c.decode(Float.self, forKey: .aoRadiusPixels)
        tileWrap = try c.decode(Bool.self, forKey: .tileWrap)
        assignedMetalness = try c.decodeIfPresent(Float.self, forKey: .assignedMetalness)
        bentNormal = try c.decode(Bool.self, forKey: .bentNormal)
        // Recipes saved before 1.1.0 lack these; the defaults reproduce the 1.0.0 response.
        normalStrength = try c.decodeIfPresent(Float.self, forKey: .normalStrength) ?? normalStrength
        normalYDown = try c.decodeIfPresent(Bool.self, forKey: .normalYDown) ?? normalYDown
        aoStrength = try c.decodeIfPresent(Float.self, forKey: .aoStrength) ?? aoStrength
        albedoEqualize = try c.decodeIfPresent(Float.self, forKey: .albedoEqualize) ?? albedoEqualize
        seamlessBlend = try c.decodeIfPresent(Float.self, forKey: .seamlessBlend) ?? seamlessBlend
        guideNormalWeight = try c.decodeIfPresent(Float.self, forKey: .guideNormalWeight) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(preset, forKey: .preset)
        try c.encode(heightStrength, forKey: .heightStrength)
        try c.encode(heightPolarity, forKey: .heightPolarity)
        try c.encode(roughnessBase, forKey: .roughnessBase)
        try c.encode(roughnessVariation, forKey: .roughnessVariation)
        try c.encode(aoRadiusPixels, forKey: .aoRadiusPixels)
        try c.encode(tileWrap, forKey: .tileWrap)
        try c.encodeIfPresent(assignedMetalness, forKey: .assignedMetalness)
        try c.encode(bentNormal, forKey: .bentNormal)
        try c.encode(normalStrength, forKey: .normalStrength)
        try c.encode(normalYDown, forKey: .normalYDown)
        try c.encode(aoStrength, forKey: .aoStrength)
        try c.encode(albedoEqualize, forKey: .albedoEqualize)
        try c.encode(seamlessBlend, forKey: .seamlessBlend)
        try c.encode(guideNormalWeight, forKey: .guideNormalWeight)
    }

    var cValue: PBRLabRecipe {
        var value = PBRLabDefaultRecipe(preset.cValue)
        value.height_strength = heightStrength.clamped(to: Self.heightStrengthRange)
        value.height_polarity = heightPolarity < 0 ? -1 : 1
        value.roughness_base = roughnessBase.clamped(to: 0...1)
        value.roughness_variation = roughnessVariation.clamped(to: Self.roughnessVariationRange)
        value.ao_radius_pixels = aoRadiusPixels.clamped(to: Self.aoRadiusRange)
        value.tile_wrap = tileWrap ? 1 : 0
        value.assigned_metalness_enabled = assignedMetalness == nil ? 0 : 1
        value.assigned_metalness = (assignedMetalness ?? 0).clamped(to: 0...1)
        value.bent_normal_enabled = bentNormal ? 1 : 0
        value.normal_strength = normalStrength.clamped(to: Self.normalStrengthRange)
        value.normal_y_down = normalYDown ? 1 : 0
        value.ao_strength = aoStrength.clamped(to: Self.aoStrengthRange)
        value.albedo_equalize = albedoEqualize.clamped(to: Self.albedoEqualizeRange)
        value.seamless_blend = seamlessBlend.clamped(to: Self.seamlessBlendRange)
        // No guide normal input is passed from the iPhone, so a nonzero weight would be rejected.
        value.guide_normal_weight = 0
        return value
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(range.upperBound, max(range.lowerBound, self)) }
}

enum MaterialMapKind: String, CaseIterable, Identifiable, Sendable {
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
    var shortTitle: String {
        switch self {
        case .ao: "AO"
        case .bentNormal: "Bent Normal"
        case .orm: "ORM"
        default: rawValue.capitalized
        }
    }
    var symbol: String {
        switch self {
        case .albedo: "paintpalette"
        case .height: "mountain.2"
        case .normal: "cube.transparent"
        case .roughness: "circle.dotted"
        case .ao: "circle.lefthalf.filled"
        case .cavity: "smallcircle.filled.circle"
        case .convexity: "circle.circle"
        case .slope: "angle"
        case .edge: "square.dashed"
        case .bentNormal: "arrow.turn.up.right"
        case .orm: "square.stack.3d.up"
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

/// One derived map. The preview image wraps the raw pixel buffer, so views never decode PNG.
struct DerivedMap: @unchecked Sendable {
    let kind: MaterialMapKind
    let width: Int
    let height: Int
    let pixelFormat: String
    /// Empty for live previews, which are display-only and never exported.
    let png: Data
    let previewImage: CGImage
    var preview: UIImage? { UIImage(cgImage: previewImage) }
}

struct SeamDiagnostics: Codable, Sendable {
    let heightValueDelta: Float
    let heightGradientDelta: Float
    let albedoValueDelta: Float
}

struct ImageQualityDiagnostics: Codable, Sendable {
    let brightNeutralFraction: Double
    let laplacianVariance: Double
    var warnings: [String] {
        var messages: [String] = []
        if brightNeutralFraction > 0.02 { messages.append("Possible glare or clipped highlights; check the source under softer light.") }
        if laplacianVariance < 24 { messages.append("Low fine detail; inspect focus before using inferred relief.") }
        return messages
    }
}

struct DerivedMaterial: @unchecked Sendable {
    let maps: [MaterialMapKind: DerivedMap]
    let sourcePNG: Data
    /// The perspective-corrected crop before equalization or seamless blending, for before/after compare.
    let correctedSource: CGImage
    let seam: SeamDiagnostics
    let quality: ImageQualityDiagnostics
    let algorithmVersion: String
    let resolution: Int
    let recipe: MaterialRecipe
    let isPreview: Bool
}

/// Thread-safe progress sink and cancellation flag passed to the C callback through its context pointer.
final class DerivationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var lastReported = -1.0
    private let onProgress: (@Sendable (Double) -> Void)?

    init(onProgress: (@Sendable (Double) -> Void)? = nil) { self.onProgress = onProgress }

    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }

    /// Returns false to cancel. Forwards at most ~100 updates per derivation.
    @discardableResult
    func report(_ value: Double) -> Bool {
        let (forward, stop) = lock.withLock { () -> (Bool, Bool) in
            let forward = value >= 1 || value - lastReported >= 0.01
            if forward { lastReported = value }
            return (forward, cancelled)
        }
        if forward { onProgress?(min(1, max(0, value))) }
        return !stop
    }
}

enum MaterialProcessor {
    static let previewResolution = 512

    static func derive(image: UIImage, quad: PerspectiveQuad, resolution: Int, recipe: MaterialRecipe,
                       control: DerivationControl? = nil, preview: Bool = false) throws -> DerivedMaterial {
        guard let cgImage = image.cgImage else { throw CaptureError.invalidImage }
        return try derive(image: cgImage, quad: quad, resolution: resolution, recipe: recipe,
                          control: control, preview: preview)
    }

    /// Call off the main actor. A `preview` derivation skips PNG encoding and is never exported.
    static func derive(image: CGImage, quad: PerspectiveQuad, resolution: Int, recipe: MaterialRecipe,
                       control: DerivationControl? = nil, preview: Bool = false) throws -> DerivedMaterial {
        let rgba = try PerspectiveCropper.correctedRGBA8(image, quad: quad, pixels: resolution)
        let corrected = try makeImage(Data(rgba), width: resolution, height: resolution,
                                      format: PBRLabPixelFormatRGBA8SRGB, rowBytes: resolution * 4)
        if control?.isCancelled == true { throw CaptureError.cancelled }
        let quality = assessQuality(rgba, width: resolution)
        var cRecipe = recipe.cValue
        var maps: [MaterialMapKind: DerivedMap] = [:]
        var seam = SeamDiagnostics(heightValueDelta: 0, heightGradientDelta: 0, albedoValueDelta: 0)
        var error = [CChar](repeating: 0, count: 1024)
        let context = control.map { Unmanaged.passUnretained($0).toOpaque() }
        let callback: PBRLabProgressCallback? = control == nil ? nil : { progress, context in
            guard let context else { return 1 }
            // The core covers ~85% of the work; PNG encoding reports the rest.
            return Unmanaged<DerivationControl>.fromOpaque(context).takeUnretainedValue()
                .report(Double(progress) * 0.85) ? 1 : 0
        }
        try withExtendedLifetime(control) {
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
                let result = PBRLabDerive(&input, &cRecipe, callback, context, &error, error.count)
                guard let result else {
                    if control?.isCancelled == true { throw CaptureError.cancelled }
                    throw CaptureError.derivationFailed(String(cString: error))
                }
                defer { PBRLabFreeResult(result) }
                let cSeam = PBRLabGetSeamMetrics(result)
                seam = SeamDiagnostics(heightValueDelta: cSeam.height_value_delta,
                                       heightGradientDelta: cSeam.height_gradient_delta,
                                       albedoValueDelta: cSeam.albedo_value_delta)
                for (index, kind) in MaterialMapKind.allCases.enumerated() {
                    if control?.report(0.85 + 0.15 * Double(index) / Double(MaterialMapKind.allCases.count)) == false {
                        throw CaptureError.cancelled
                    }
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
                    let image = try makeImage(bytes, width: Int(map.width), height: Int(map.height),
                                              format: map.format, rowBytes: map.row_bytes)
                    let png = preview ? Data() : try pngData(image)
                    maps[kind] = DerivedMap(kind: kind, width: Int(map.width), height: Int(map.height),
                                            pixelFormat: format, png: png, previewImage: image)
                }
            }
        }
        guard let albedo = maps[.albedo] else {
            throw CaptureError.derivationFailed("The canonical sRGB albedo map is missing")
        }
        control?.report(1)
        return DerivedMaterial(maps: maps, sourcePNG: albedo.png, correctedSource: corrected, seam: seam,
                               quality: quality, algorithmVersion: String(cString: PBRLabVersion()),
                               resolution: resolution, recipe: recipe, isPreview: preview)
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

    static func makeImage(_ bytes: Data, width: Int, height: Int,
                          format: PBRLabPixelFormat, rowBytes: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: bytes as CFData) else {
            throw CaptureError.derivationFailed("Cannot wrap map pixels")
        }
        let image: CGImage?
        if format == PBRLabPixelFormatR16UNormLE {
            image = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 16,
                            bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder16Little.rawValue |
                                                     CGImageAlphaInfo.none.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: true,
                            intent: .defaultIntent)
        } else {
            let space = format == PBRLabPixelFormatRGBA8SRGB
                ? CGColorSpace(name: CGColorSpace.sRGB)! : CGColorSpace(name: CGColorSpace.linearSRGB)!
            image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: rowBytes, space: space,
                            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue |
                                                     CGImageAlphaInfo.last.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: true,
                            intent: .defaultIntent)
        }
        guard let image else { throw CaptureError.derivationFailed("Cannot encode map pixels") }
        return image
    }

    static func pngData(_ image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureError.derivationFailed("Cannot open PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.derivationFailed("PNG export failed") }
        return output as Data
    }

    /// The normal map as a +Y (OpenGL/glTF, RealityKit) renderer expects it; DirectX output is green-flipped back.
    static func openGLNormalImage(_ map: DerivedMap, yDown: Bool) -> CGImage {
        guard yDown else { return map.previewImage }
        let width = map.width, height = map.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.linearSRGB)!
        let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: info) else { return false }
            context.draw(map.previewImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return map.previewImage }
        for index in stride(from: 1, to: pixels.count, by: 4) { pixels[index] = 255 &- pixels[index] }
        return (try? makeImage(Data(pixels), width: width, height: height,
                               format: PBRLabPixelFormatRGBA8Linear, rowBytes: width * 4)) ?? map.previewImage
    }
}
