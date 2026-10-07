import CoreGraphics
import CryptoKit
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
    init(_ value: PBRLabPreset) {
        self = Self.allCases.first { $0.cValue == value } ?? .flat
    }
}

/// How Make tileable joins opposite edges (core 1.2.0 `seamless_mode`); emitted as "cut" or "blend".
enum SeamlessMode: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Aligned minimum-error seam cut: best for brick, tiles, planks and most photos.
    case cut
    /// Histogram-preserving blend: fine stochastic textures such as noise, sand and grain.
    case blend
    var id: String { rawValue }
    var title: String { self == .cut ? "Structured" : "Soft blend" }
    var cValue: UInt32 { self == .cut ? 1 : 0 }
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
    /// Weight of learned (MoGe-2) form and detail orientation over the analytic relief (core 1.3.0): 0 = analytic only,
    /// 1 = learned form with photo detail oriented by it.
    var guideNormalWeight: Float = 0
    /// Core 1.2.0 seam method for Make tileable; the core default is the seam cut.
    var seamlessMode: SeamlessMode = .cut
    /// Core 1.4.0: rebuild the albedo itself so it tiles; the repaired albedo feeds every derived map.
    var albedoRepair: AlbedoRepair = .off
    /// The material-library preset (LibraryPreset) this recipe started from; later edits keep the name, as the CLI
    /// does. Recorded as recipe.material_preset in bundles.
    var materialPreset: String?

    /// Whether the core changes the albedo pixels (delighting, edge treatment or repair).
    var conditionsAlbedo: Bool { albedoEqualize > 0 || seamlessBlend > 0 || albedoRepair != .off }

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
        seamlessMode = defaults.seamless_mode == 1 ? .cut : .blend
    }

    /// A library preset's recipe (its prior plus tuned values), keeping the caller's export, tiling, lighting-cleanup
    /// and learned-geometry choices.
    func applyingLibraryPreset(_ library: LibraryPreset) -> Self {
        let r = library.recipe
        var next = applyingPreset(MaterialPreset(r.preset))
        next.heightStrength = r.height_strength
        next.heightPolarity = r.height_polarity
        next.roughnessBase = r.roughness_base
        next.roughnessVariation = r.roughness_variation
        next.aoRadiusPixels = r.ao_radius_pixels
        next.aoStrength = r.ao_strength
        next.normalStrength = r.normal_strength
        next.albedoEqualize = max(albedoEqualize, r.albedo_equalize)
        next.assignedMetalness = r.assigned_metalness_enabled != 0 ? r.assigned_metalness : nil
        next.materialPreset = library.id
        return next
    }

    /// Switch the material prior while keeping export, tiling and lighting-cleanup choices.
    func applyingPreset(_ preset: MaterialPreset) -> Self {
        var next = Self(preset: preset)
        next.normalYDown = normalYDown
        next.tileWrap = tileWrap
        next.bentNormal = bentNormal
        next.seamlessBlend = seamlessBlend
        next.albedoEqualize = albedoEqualize
        next.guideNormalWeight = guideNormalWeight
        next.seamlessMode = seamlessMode
        next.albedoRepair = albedoRepair
        return next
    }

    private enum CodingKeys: String, CodingKey {
        case preset, heightStrength, heightPolarity, roughnessBase, roughnessVariation, aoRadiusPixels
        case tileWrap, assignedMetalness, bentNormal, normalStrength, normalYDown, aoStrength
        case albedoEqualize, seamlessBlend, guideNormalWeight, seamlessMode, albedoRepair, materialPreset
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
        // Recipes saved before the seam cut existed used the histogram blend.
        seamlessMode = try c.decodeIfPresent(SeamlessMode.self, forKey: .seamlessMode) ?? .blend
        albedoRepair = try c.decodeIfPresent(AlbedoRepair.self, forKey: .albedoRepair) ?? .off
        materialPreset = LibraryPreset.named(try c.decodeIfPresent(String.self, forKey: .materialPreset))?.id
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
        try c.encode(seamlessMode, forKey: .seamlessMode)
        try c.encode(albedoRepair, forKey: .albedoRepair)
        try c.encodeIfPresent(materialPreset, forKey: .materialPreset)
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
        value.seamless_mode = seamlessMode.cValue
        value.albedo_repair = albedoRepair.cValue
        if albedoRepair != .off { value.tile_wrap = 1 }
        // MaterialProcessor zeroes this when no guide normals accompany the derivation.
        value.guide_normal_weight = guideNormalWeight.clamped(to: 0...1)
        return value
    }
}

/// PBRLabRecipe.albedo_repair (core 1.4.0). Off keeps the legacy Make-tileable behaviour.
enum AlbedoRepair: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, auto, quilt, blend
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Off"
        case .auto: "Auto"
        case .quilt: "Quilt"
        case .blend: "Blend"
        }
    }
    var explanation: String {
        switch self {
        case .off: "The albedo stays as photographed, plus any Make tileable edge treatment."
        case .auto: "Rebuilds the albedo so it tiles: cuts along the cheapest seam, or blends when no clean cut exists."
        case .quilt: "Cuts a copy in along the lowest-difference seam. Keeps features crisp."
        case .blend: "Histogram-preserving cross-fade. Best for fine noise and grain."
        }
    }
    var cValue: UInt32 {
        switch self {
        case .off: 0
        case .blend: 1
        case .quilt: 2
        case .auto: 3
        }
    }
}

/// What albedo repair did (PBRLabAlbedoRepairInfo), recorded in the capture.
struct AlbedoRepairResult: Codable, Sendable, Equatable {
    struct Seam: Codable, Sendable, Equatable {
        var pixelX: Float, pixelY: Float, toneX: Float, toneY: Float, detail: Float
        var worst: Float { max(pixelX, pixelY, toneX, toneY) }
    }
    var mode: AlbedoRepair
    var method: AlbedoRepair
    var bandFraction: Float
    var cutCostRatio: Float
    var offsetPx: [Int]
    var seamBefore: Seam
    var seamAfter: Seam
    var seamMeasure = "linear_light_luminance_v1"
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
    /// Height provenance names learned normals when they contributed (docs/LEARNED_NORMALS.md).
    func provenance(recipe: MaterialRecipe, guided: Bool) -> String {
        guard self == .height, guided else { return provenance }
        return recipe.preset == .flat ? "learned_normals" : "estimated_from_albedo_and_learned_normals"
    }
    func provenance(recipe: MaterialRecipe, guided: Bool, repaired: Bool) -> String {
        if self == .albedo, repaired { return "repaired_tileable_albedo_derived_from_source" }
        guard self == .height, guided else { return provenance }
        return recipe.preset == .flat ? "learned_normals" : "estimated_from_albedo_and_learned_normals"
    }
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

/// How the core built the geometry (PBRLabDerivationInfo; the manifest's `relief`, algorithm 1.3.0).
struct ReliefDiagnostics: Sendable, Equatable {
    let heightSpanTileWidths: Float
    let rmsSlope: Float
    let learnedFormShare: Float
    let learnedDetailCorrelation: Float
    let detailPolarity: Int
    let heightWrapSeamRatio: Float
}

/// SHA-256 of the straight RGBA8 albedo before and after repair (manifest `albedo_repair`).
struct RepairDigests: Sendable, Equatable {
    let sourceRGBA8: String
    let repairedRGBA8: String
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
    /// Provenance of the learned guide normals that fed the core; nil when the analytic path ran alone.
    var guideNormals: GuideNormalsProvenance? = nil
    /// The learned field behind `guideNormals`, reusable for previews at other sizes.
    var learnedField: LearnedNormalField? = nil
    /// Present when the albedo was repaired before derivation (core 1.4.0).
    var repair: AlbedoRepairResult? = nil
    /// Geometry diagnostics for .pbrmaterial manifests (full derivations only).
    var relief: ReliefDiagnostics? = nil
    /// Hashes of the albedo before and after repair, when repair ran.
    var repairDigests: RepairDigests? = nil
    /// Artist-made inputs used by this derivation.
    var authored = AuthoredMaps()
}

/// Where a derivation gets learned guide normals when `recipe.guideNormalWeight > 0`.
enum GuideSource: @unchecked Sendable {
    /// A field already inferred for this source and crop; resampled to the derivation size.
    case field(LearnedNormalField)
    /// Run (or reuse from the estimator's cache) inference on the corrected crop.
    case estimate(LearnedNormalEstimator)
}

/// Thread-safe progress sink and cancellation flag passed to the C callback through its context pointer.
final class DerivationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var lastReported = -1.0
    private var base = 0.0
    private let onProgress: (@Sendable (Double) -> Void)?

    init(onProgress: (@Sendable (Double) -> Void)? = nil) { self.onProgress = onProgress }

    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }

    /// Maps later `report` values into [offset, 1], after an earlier phase (learned inference) used [0, offset].
    func setPhaseOffset(_ offset: Double) { lock.withLock { base = offset } }

    /// Returns false to cancel. Forwards at most ~100 updates per derivation.
    @discardableResult
    func report(_ value: Double, absolute: Bool = false) -> Bool {
        let (forward, stop, value) = lock.withLock { () -> (Bool, Bool, Double) in
            let value = absolute ? value : base + (1 - base) * value
            let forward = value >= 1 || value - lastReported >= 0.01
            if forward { lastReported = value }
            return (forward, cancelled, value)
        }
        if forward { onProgress?(min(1, max(0, value))) }
        return !stop
    }
}

enum MaterialProcessor {
    static let previewResolution = 512

    static func derive(image: UIImage, quad: PerspectiveQuad, resolution: Int, recipe: MaterialRecipe,
                       control: DerivationControl? = nil, preview: Bool = false,
                       guide: GuideSource? = nil, authored: AuthoredMaps = AuthoredMaps()) throws -> DerivedMaterial {
        guard let cgImage = image.cgImage else { throw CaptureError.invalidImage }
        return try derive(image: cgImage, quad: quad, resolution: resolution, recipe: recipe,
                          control: control, preview: preview, guide: guide, authored: authored)
    }

    /// Call off the main actor. A `preview` derivation skips PNG encoding and is never exported.
    /// With `recipe.guideNormalWeight > 0` and a `guide`, learned normals are resampled to `resolution` and blended
    /// by the core; without a guide the weight is treated as 0 (previews only — the store always supplies one
    /// for exportable derivations).
    static func derive(image: CGImage, quad: PerspectiveQuad, resolution: Int, recipe: MaterialRecipe,
                       control: DerivationControl? = nil, preview: Bool = false,
                       guide: GuideSource? = nil, authored: AuthoredMaps = AuthoredMaps()) throws -> DerivedMaterial {
        // An authored metalness map fills the ORM blue channel, which exists only with assigned metalness.
        var recipe = recipe
        if authored.maps[.metalness] != nil, recipe.assignedMetalness == nil { recipe.assignedMetalness = 0 }
        let correctedRGBA = try PerspectiveCropper.correctedRGBA8(image, quad: quad, pixels: resolution)
        let corrected = try makeImage(Data(correctedRGBA), width: resolution, height: resolution,
                                      format: PBRLabPixelFormatRGBA8SRGB, rowBytes: resolution * 4)
        if control?.isCancelled == true { throw CaptureError.cancelled }
        let quality = assessQuality(correctedRGBA, width: resolution)
        // Explicit albedo repair runs first, as in the CLI and Mac app: the repaired albedo is the exported albedo
        // and the image both learned inference and every derived map see; derivation then runs unconditioned.
        var rgba = correctedRGBA
        var repair: AlbedoRepairResult?
        if recipe.albedoRepair != .off {
            (rgba, repair) = try conditionAlbedo(correctedRGBA, size: resolution, recipe: recipe)
        }
        if control?.isCancelled == true { throw CaptureError.cancelled }
        var learnedField: LearnedNormalField?
        var guideNormals: GuideNormals?
        if recipe.guideNormalWeight > 0, !authored.hasGeometry, let guide {
            switch guide {
            case .field(let field): learnedField = field
            case .estimate(let estimator):
                // Inference owns the first 35% of the progress bar; the estimator cache makes repeats free.
                learnedField = try estimator.field(rgba: rgba, size: resolution, wrap: recipe.tileWrap || repair != nil,
                                                   shouldContinue: { control?.isCancelled != true },
                                                   progress: { control?.report($0.fraction * 0.35, absolute: true) })
                control?.setPhaseOffset(0.35)
            }
            guideNormals = learnedField?.guide(size: resolution)
        }
        if control?.isCancelled == true { throw CaptureError.cancelled }
        let authoredPixels = try authored.decoded(size: resolution)
        var cRecipe = recipe.cValue
        if guideNormals == nil { cRecipe.guide_normal_weight = 0 }
        if repair != nil {
            cRecipe.albedo_equalize = 0
            cRecipe.seamless_blend = 0
            cRecipe.albedo_repair = 0
            cRecipe.tile_wrap = 1
        }
        var maps: [MaterialMapKind: DerivedMap] = [:]
        var seam = SeamDiagnostics(heightValueDelta: 0, heightGradientDelta: 0, albedoValueDelta: 0)
        var relief: ReliefDiagnostics?
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
                input.relief_mask_r8 = UnsafePointer(authoredPixels.reliefMask?.baseAddress)
                input.relief_mask_row_bytes = authoredPixels.reliefMask == nil ? 0 : resolution
                input.height_override_r16 = nil
                input.height_override_row_bytes = 0
                input.width = UInt32(resolution)
                input.height = UInt32(resolution)
                input.guide_normal_rgba8 = nil
                input.guide_normal_row_bytes = 0
                input.height_override_r16 = UnsafePointer(authoredPixels.height?.baseAddress)
                input.height_override_row_bytes = authoredPixels.height == nil ? 0 : resolution * 2
                input.authored_normal_rgba8 = UnsafePointer(authoredPixels.normal?.baseAddress)
                input.authored_normal_row_bytes = authoredPixels.normal == nil ? 0 : resolution * 4
                input.authored_roughness_r8 = UnsafePointer(authoredPixels.roughness?.baseAddress)
                input.authored_roughness_row_bytes = authoredPixels.roughness == nil ? 0 : resolution
                input.authored_ao_r8 = UnsafePointer(authoredPixels.ao?.baseAddress)
                input.authored_ao_row_bytes = authoredPixels.ao == nil ? 0 : resolution
                input.authored_metalness_r8 = UnsafePointer(authoredPixels.metalness?.baseAddress)
                input.authored_metalness_row_bytes = authoredPixels.metalness == nil ? 0 : resolution
                let result: OpaquePointer? = { () -> OpaquePointer? in
                    guard let guideNormals else {
                        return PBRLabDerive(&input, &cRecipe, callback, context, &error, error.count)
                    }
                    return guideNormals.rgba8.withUnsafeBufferPointer { guideBuffer in
                        input.guide_normal_rgba8 = guideBuffer.baseAddress
                        input.guide_normal_row_bytes = resolution * 4
                        return PBRLabDerive(&input, &cRecipe, callback, context, &error, error.count)
                    }
                }()
                guard let result else {
                    if control?.isCancelled == true { throw CaptureError.cancelled }
                    throw CaptureError.derivationFailed(String(cString: error))
                }
                defer { PBRLabFreeResult(result) }
                let cSeam = PBRLabGetSeamMetrics(result)
                seam = SeamDiagnostics(heightValueDelta: cSeam.height_value_delta,
                                       heightGradientDelta: cSeam.height_gradient_delta,
                                       albedoValueDelta: cSeam.albedo_value_delta)
                let info = PBRLabGetDerivationInfo(result)
                relief = ReliefDiagnostics(heightSpanTileWidths: info.height_span_tile_widths, rmsSlope: info.rms_slope,
                                           learnedFormShare: info.learned_form_share,
                                           learnedDetailCorrelation: info.learned_detail_correlation,
                                           detailPolarity: Int(info.detail_polarity),
                                           heightWrapSeamRatio: info.height_wrap_seam_ratio)
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
        // The capture's canonical source is the unconditioned corrected crop: a receiver re-derives with the same
        // recipe, so shipping a delit, blended or repaired albedo as the source would condition it twice.
        let sourcePNG = preview || !recipe.conditionsAlbedo ? albedo.png : try pngData(corrected)
        control?.report(1)
        return DerivedMaterial(maps: maps, sourcePNG: sourcePNG, correctedSource: corrected, seam: seam,
                               quality: quality, algorithmVersion: String(cString: PBRLabVersion()),
                               resolution: resolution, recipe: recipe, isPreview: preview,
                               guideNormals: guideNormals?.provenance, learnedField: learnedField, repair: repair,
                               relief: relief,
                               repairDigests: repair == nil || preview ? nil
                                   : RepairDigests(sourceRGBA8: Self.sha256(correctedRGBA), repairedRGBA8: Self.sha256(rgba)),
                               authored: authored)
    }

    static func sha256(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// PBRLabConditionAlbedo: delighting plus the requested albedo repair.
    private static func conditionAlbedo(_ rgba: [UInt8], size: Int, recipe: MaterialRecipe) throws
        -> ([UInt8], AlbedoRepairResult) {
        var cRecipe = recipe.cValue
        cRecipe.tile_wrap = 1
        var output = [UInt8](repeating: 0, count: rgba.count)
        var info = PBRLabAlbedoRepairInfo()
        var error = [CChar](repeating: 0, count: 512)
        let ok = rgba.withUnsafeBufferPointer { buffer in
            output.withUnsafeMutableBufferPointer { out in
                var input = PBRLabInput()
                input.rgba8 = buffer.baseAddress
                input.rgba_row_bytes = size * 4
                input.width = UInt32(size)
                input.height = UInt32(size)
                return PBRLabConditionAlbedo(&input, &cRecipe, out.baseAddress, size * 4, &info, &error, error.count)
            }
        }
        guard ok != 0 else { throw CaptureError.derivationFailed("Albedo repair failed: " + String(cString: error)) }
        func seam(_ s: PBRLabWrapSeam) -> AlbedoRepairResult.Seam {
            .init(pixelX: s.pixel_x, pixelY: s.pixel_y, toneX: s.tone_x, toneY: s.tone_y, detail: s.detail)
        }
        let result = AlbedoRepairResult(mode: recipe.albedoRepair, method: info.method == 2 ? .quilt : .blend,
                                        bandFraction: info.band_fraction, cutCostRatio: info.cut_cost_ratio,
                                        offsetPx: [Int(info.offset_x), Int(info.offset_y)],
                                        seamBefore: seam(info.before), seamAfter: seam(info.after))
        return (output, result)
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

    /// The albedo lit from (azimuth, elevation) through the normal and occlusion maps: the Mac's relit view.
    static func relitImage(_ material: DerivedMaterial, azimuth: Float, elevation: Float) -> CGImage? {
        guard let albedo = material.maps[.albedo], let normal = material.maps[.normal],
              albedo.width == normal.width, albedo.height == normal.height,
              let albedoData = albedo.previewImage.dataProvider?.data as Data?,
              let normalData = normal.previewImage.dataProvider?.data as Data? else { return nil }
        let aoMap = material.maps[.ao].flatMap { $0.width == albedo.width ? $0 : nil }
        let aoData = aoMap?.previewImage.dataProvider?.data as Data?
        let width = albedo.width, height = albedo.height
        let albedoRow = albedo.previewImage.bytesPerRow, normalRow = normal.previewImage.bytesPerRow
        let aoRow = aoMap?.previewImage.bytesPerRow ?? 0
        let lx = cosf(elevation) * cosf(azimuth), ly = cosf(elevation) * sinf(azimuth), lz = sinf(elevation)
        // +Y maps store "up" in green, so image-space y (down) is the negation.
        let greenSign: Float = material.recipe.normalYDown ? 1 : -1
        var toLinear = [Float](repeating: 0, count: 256)
        for i in 0..<256 {
            let c = Float(i) / 255
            toLinear[i] = c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
        }
        var toSRGB = [UInt8](repeating: 0, count: 4096)
        for i in 0..<4096 {
            let l = Float(i) / 4095
            let c = l <= 0.0031308 ? l * 12.92 : 1.055 * powf(l, 1 / 2.4) - 0.055
            toSRGB[i] = UInt8(max(0, min(255, (c * 255).rounded())))
        }
        var output = [UInt8](repeating: 255, count: width * height * 4)
        albedoData.withUnsafeBytes { a in
            normalData.withUnsafeBytes { n in
                (aoData ?? Data()).withUnsafeBytes { o in
                    let a = a.bindMemory(to: UInt8.self), n = n.bindMemory(to: UInt8.self), o = o.bindMemory(to: UInt8.self)
                    for y in 0..<height {
                        for x in 0..<width {
                            let ai = y * albedoRow + x * 4, ni = y * normalRow + x * 4
                            var nx = Float(n[ni]) / 127.5 - 1
                            var ny = greenSign * (Float(n[ni + 1]) / 127.5 - 1)
                            var nz = Float(n[ni + 2]) / 127.5 - 1
                            let length = max(1e-4, (nx * nx + ny * ny + nz * nz).squareRoot())
                            nx /= length; ny /= length; nz /= length
                            let diffuse = max(0, nx * lx + ny * ly + nz * lz)
                            let occlusion = o.isEmpty ? 1 : Float(o[y * aoRow + x * 4]) / 255
                            let light = 0.14 * occlusion + 0.95 * diffuse
                            let out = (y * width + x) * 4
                            for c in 0..<3 {
                                output[out + c] = toSRGB[Int(min(1, toLinear[Int(a[ai + c])] * light) * 4095)]
                            }
                        }
                    }
                }
            }
        }
        return try? makeImage(Data(output), width: width, height: height, format: PBRLabPixelFormatRGBA8SRGB,
                              rowBytes: width * 4)
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
