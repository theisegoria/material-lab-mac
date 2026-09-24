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

enum MaterialPreset: String, CaseIterable, Identifiable, Sendable {
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

/// PBRLabRecipe.seamless_mode: 1 = aligned minimum-error seam cut, 0 = histogram-preserving blend.
enum SeamlessMode: String, CaseIterable, Identifiable, Sendable {
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
}
