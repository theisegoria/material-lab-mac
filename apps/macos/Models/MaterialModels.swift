import CoreGraphics
import Foundation

enum MaterialSourceOrigin: String, Codable, Sendable {
    case catalog = "Generated catalog"
    case imported = "Imported file"
    case cameraInbox = "Camera inbox"

    var symbol: String {
        switch self {
        case .catalog: "square.stack"
        case .imported: "square.and.arrow.down"
        case .cameraInbox: "camera"
        }
    }
}

struct MaterialSource: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let semanticLabel: String
    let category: String
    let origin: MaterialSourceOrigin
    let reviewStatus: String
    let originalEnvelopeURL: URL?

    var displayName: String { semanticLabel.replacingOccurrences(of: "_", with: " ") }
}

enum MaterialPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case flat, stone, fabric, organic, coatedMetal, bareMetal
    var id: String { rawValue }

    var title: String {
        switch self {
        case .flat: "Flat / painted"
        case .stone: "Stone / masonry"
        case .fabric: "Fabric / soft"
        case .organic: "Organic"
        case .coatedMetal: "Coated metal"
        case .bareMetal: "Bare metal"
        }
    }

    var symbol: String {
        switch self {
        case .flat: "square"
        case .stone: "square.stack.3d.down.right"
        case .fabric: "tshirt"
        case .organic: "leaf"
        case .coatedMetal: "paintbrush"
        case .bareMetal: "gearshape"
        }
    }

    /// Accepts the manifest (snake/kebab) and capture (camelCase) spellings.
    init?(externalName: String) {
        let key = externalName.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        guard let match = MaterialPreset.allCases.first(where: { $0.rawValue.lowercased() == key })
        else { return nil }
        self = match
    }
}

struct MaterialRecipe: Equatable, Sendable {
    var preset: MaterialPreset = .flat
    var heightStrength: Float = 0
    var heightPolarity: Int32 = 1
    var roughnessBase: Float = 0.6
    var roughnessVariation: Float = 0
    var aoRadiusPixels: Float = 10
    var tileWrap = true
    var assignedMetalnessEnabled = false
    var assignedMetalness: Float = 0
    var bentNormalEnabled = false
    // Algorithm 1.1.0 fields.
    var normalStrength: Float = 1
    var normalYDown = false
    var aoStrength: Float = 1
    var albedoEqualize: Float = 0
    var seamlessBlend: Float = 0
    // Algorithm 1.2.0: blend of learned guide-normal height over inferred height.
    var guideNormalWeight: Float = 0
    /// Method used by Make tileable when seamlessBlend > 0.
    var seamlessMode: SeamlessMode = .cut
    /// Algorithm 1.4.0: rebuild the albedo itself so it tiles; the repaired albedo feeds every derived map.
    var albedoRepair: AlbedoRepair = .off
    var reliefMaskURL: URL?
    var heightOverrideURL: URL?

    /// Parameter ranges accepted by the 1.1.0 core.
    enum Range {
        static let heightStrength: ClosedRange<Float> = 0...0.5
        static let roughness: ClosedRange<Float> = 0...1
        static let aoRadius: ClosedRange<Float> = 0...64
        static let metalness: ClosedRange<Float> = 0...1
        static let normalStrength: ClosedRange<Float> = 0...16
        static let aoStrength: ClosedRange<Float> = 0...4
        static let albedoEqualize: ClosedRange<Float> = 0...1
        static let seamlessBlend: ClosedRange<Float> = 0...0.45
        static let guideNormalWeight: ClosedRange<Float> = 0...1
    }

    var normalConvention: String { normalYDown ? "-Y" : "+Y" }
}

/// A named recipe the user saved to reuse on other sources (relief mask and height override are per source and
/// never saved here).
struct SavedRecipe: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var recipe: MaterialRecipe
    var saved = Date()
}

/// Persisted per source (MaterialLibrary.recipes). Every field decodes optionally on top of the preset's
/// defaults, so recipes saved by older builds keep loading as fields are added.
extension MaterialRecipe: Codable {
    private enum CodingKeys: String, CodingKey {
        case preset, heightStrength, heightPolarity, roughnessBase, roughnessVariation, aoRadiusPixels, tileWrap
        case assignedMetalnessEnabled, assignedMetalness, bentNormalEnabled, normalStrength, normalYDown
        case aoStrength, albedoEqualize, seamlessBlend, guideNormalWeight, seamlessMode, albedoRepair
        case reliefMaskPath, heightOverridePath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self = MaterialEngine.defaultRecipe(for: try c.decodeIfPresent(MaterialPreset.self, forKey: .preset) ?? .flat)
        func value<T: Decodable>(_ key: CodingKeys, _ current: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? current
        }
        heightStrength = value(.heightStrength, heightStrength)
        heightPolarity = value(.heightPolarity, heightPolarity)
        roughnessBase = value(.roughnessBase, roughnessBase)
        roughnessVariation = value(.roughnessVariation, roughnessVariation)
        aoRadiusPixels = value(.aoRadiusPixels, aoRadiusPixels)
        tileWrap = value(.tileWrap, tileWrap)
        assignedMetalnessEnabled = value(.assignedMetalnessEnabled, assignedMetalnessEnabled)
        assignedMetalness = value(.assignedMetalness, assignedMetalness)
        bentNormalEnabled = value(.bentNormalEnabled, bentNormalEnabled)
        normalStrength = value(.normalStrength, normalStrength)
        normalYDown = value(.normalYDown, normalYDown)
        aoStrength = value(.aoStrength, aoStrength)
        albedoEqualize = value(.albedoEqualize, albedoEqualize)
        seamlessBlend = value(.seamlessBlend, seamlessBlend)
        guideNormalWeight = value(.guideNormalWeight, guideNormalWeight)
        seamlessMode = value(.seamlessMode, seamlessMode)
        albedoRepair = value(.albedoRepair, albedoRepair)
        // Side inputs are kept only while their files still exist, so a moved file cannot break derivation.
        func existing(_ key: CodingKeys) -> URL? {
            guard let path = value(key, String?.none), FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }
        reliefMaskURL = existing(.reliefMaskPath)
        heightOverrideURL = existing(.heightOverridePath)
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
        try c.encode(assignedMetalnessEnabled, forKey: .assignedMetalnessEnabled)
        try c.encode(assignedMetalness, forKey: .assignedMetalness)
        try c.encode(bentNormalEnabled, forKey: .bentNormalEnabled)
        try c.encode(normalStrength, forKey: .normalStrength)
        try c.encode(normalYDown, forKey: .normalYDown)
        try c.encode(aoStrength, forKey: .aoStrength)
        try c.encode(albedoEqualize, forKey: .albedoEqualize)
        try c.encode(seamlessBlend, forKey: .seamlessBlend)
        try c.encode(guideNormalWeight, forKey: .guideNormalWeight)
        try c.encode(seamlessMode, forKey: .seamlessMode)
        try c.encode(albedoRepair, forKey: .albedoRepair)
        try c.encodeIfPresent(reliefMaskURL?.path, forKey: .reliefMaskPath)
        try c.encodeIfPresent(heightOverrideURL?.path, forKey: .heightOverridePath)
    }
}

/// PBRLabRecipe.seamless_mode: 1 = aligned minimum-error seam cut, 0 = histogram-preserving blend.
enum SeamlessMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case cut, blend
    var id: String { rawValue }
    var title: String { self == .cut ? "Structured" : "Soft blend" }
    var explanation: String {
        self == .cut
            ? "Cuts along the lowest-difference seam. Best for brick, tiles, planks and most photos."
            : "Histogram-preserving cross-fade. Best for fine noise, sand and grain."
    }
    var cValue: UInt32 { self == .cut ? 1 : 0 }
    init(cValue: UInt32) { self = cValue == 0 ? .blend : .cut }
}

/// PBRLabRecipe.albedo_repair (1.4.0). Off keeps the legacy Make-tileable behaviour.
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
        case .off: "The albedo is exported as photographed (plus any Make tileable edge treatment)."
        case .auto: "Rebuilds the albedo so it tiles on both axes: quilts along the cheapest seam, or blends when no clean cut exists."
        case .quilt: "Rebuilds the albedo by cutting a copy in along the lowest-difference seam. Keeps features crisp."
        case .blend: "Rebuilds the albedo with a histogram-preserving cross-fade. Best for fine noise and grain."
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

/// What albedo repair actually did, from PBRLabAlbedoRepairInfo.
struct AlbedoRepairResult: Sendable, Equatable {
    struct Seam: Sendable, Equatable {
        var pixelX: Float, pixelY: Float, toneX: Float, toneY: Float, detail: Float
        /// The worse of the two axes at pixel and tone scale (about 1 or below means no visible step).
        var worst: Float { max(pixelX, pixelY, toneX, toneY) }
    }
    var mode: AlbedoRepair
    var method: AlbedoRepair            // .quilt or .blend: the method actually applied
    var bandFraction: Float
    var cutCostRatio: Float
    var offsetX: Int, offsetY: Int
    var before: Seam, after: Seam
    var sourceRGBA8SHA256: String
    var repairedRGBA8SHA256: String
}

enum NormalConvention: String, CaseIterable, Identifiable {
    case openGL, directX
    var id: String { rawValue }
    var title: String { self == .openGL ? "OpenGL (+Y)" : "DirectX (−Y)" }
}

enum MaterialMapKind: String, CaseIterable, Identifiable, Sendable {
    case albedo, height, normal, roughness, ao, cavity, convexity, slope, edge, bentNormal, orm
    /// Guide normals from the learned estimator: inspection only, never exported as a map.
    case learnedNormal
    var id: String { rawValue }

    var title: String {
        switch self {
        case .ao: "Ambient occlusion"
        case .bentNormal: "Bent normal"
        case .orm: "ORM"
        case .learnedNormal: "Learned normals"
        default: rawValue.capitalized
        }
    }

    /// Maps written to .pbrmaterial bundles; learned guide normals are display-only.
    var isExported: Bool { self != .learnedNormal }

    var symbol: String {
        switch self {
        case .albedo: "paintpalette"
        case .height: "mountain.2"
        case .normal, .bentNormal: "cube.transparent"
        case .roughness: "circle.lefthalf.filled"
        case .ao, .cavity: "circle.dotted.circle"
        case .convexity, .slope, .edge: "waveform.path"
        case .orm: "square.stack.3d.up"
        case .learnedNormal: "sparkles"
        }
    }

    var shortTitle: String {
        switch self {
        case .ao: "AO"
        case .bentNormal: "Bent normal"
        case .orm: "ORM"
        case .learnedNormal: "Learned"
        default: rawValue.capitalized
        }
    }

    var exportedName: String {
        switch self {
        case .bentNormal: "bent_normal"
        case .learnedNormal: "learned_normal"
        default: rawValue
        }
    }

    /// One-line explanation used for help tags and accessibility hints.
    var explanation: String {
        switch self {
        case .albedo: "Base color with lighting optionally flattened."
        case .height: "Estimated relief, 16-bit."
        case .normal: "Tangent-space surface direction."
        case .roughness: "Microsurface scattering, 0 glossy to 1 matte."
        case .ao: "Ambient occlusion from the height field."
        case .cavity: "Small crevices."
        case .convexity: "Raised ridges."
        case .slope: "Local steepness."
        case .edge: "Edge wear mask."
        case .bentNormal: "Average unoccluded direction."
        case .orm: "Packed occlusion, roughness and metalness."
        case .learnedNormal: "Guide normals from the learned estimator (+Y). For inspection; not exported."
        }
    }
}

enum MaterialPixelFormat: String, Sendable {
    case rgba8SRGB = "rgba8-srgb"
    case rgba8Linear = "rgba8-linear"
    case r16Linear = "r16-unorm-linear"
}

struct MaterialMapData: Sendable {
    let width: Int
    let height: Int
    let rowBytes: Int
    let format: MaterialPixelFormat
    let bytes: Data
}

struct MaterialSeamMetrics: Sendable {
    let heightValue: Float
    let heightGradient: Float
    let albedoValue: Float
}

/// How the core built the geometry (PBRLabDerivationInfo, manifest `relief`, algorithm 1.3.0).
struct MaterialRelief: Sendable {
    let heightSpanTileWidths: Float
    let rmsSlope: Float
    let learnedFormShare: Float
    let learnedDetailCorrelation: Float
    let detailPolarity: Int
    let heightWrapSeamRatio: Float
}

struct WorkingImageInfo: Sendable {
    let sourceWidth: Int
    let sourceHeight: Int
    let size: Int
    var wasCropped: Bool { sourceWidth != sourceHeight }
}

struct DerivedMaterial: @unchecked Sendable {
    let source: MaterialSource
    let recipe: MaterialRecipe
    let sourceSHA256: String
    let reliefMaskSHA256: String?
    let heightOverrideSHA256: String?
    /// Learned guide normals fed to the core (present only when guideNormalWeight > 0).
    let guide: GuideNormals?
    let algorithmVersion: String
    let working: WorkingImageInfo
    let maps: [MaterialMapKind: MaterialMapData]
    let seams: MaterialSeamMetrics
    let relief: MaterialRelief
    let warnings: [String]
    /// Display images created off the main thread; they wrap the map bytes without copying.
    let previews: [MaterialMapKind: CGImage]
    /// The square working image the maps were derived from (for before/after comparison).
    let workingPreview: CGImage?
    let duration: TimeInterval
    /// Present when the albedo was repaired before derivation (algorithm 1.4.0).
    var repair: AlbedoRepairResult? = nil
}
