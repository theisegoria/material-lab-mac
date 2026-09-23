import Foundation

enum MaterialSourceOrigin: String, Codable {
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

struct MaterialSource: Identifiable, Hashable {
    let id: String
    let url: URL
    let semanticLabel: String
    let category: String
    let origin: MaterialSourceOrigin
    let reviewStatus: String
    let originalEnvelopeURL: URL?

    var displayName: String { semanticLabel.replacingOccurrences(of: "_", with: " ") }
}

enum MaterialPreset: String, CaseIterable, Identifiable {
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
}

struct MaterialRecipe: Equatable {
    var preset: MaterialPreset = .flat
    var heightStrength: Float = 0
    var heightPolarity: Int32 = 1
    var roughnessBase: Float = 0.6
    var roughnessVariation: Float = 0
    var aoRadiusPixels: Float = 24
    var tileWrap = true
    var assignedMetalnessEnabled = false
    var assignedMetalness: Float = 0
    var bentNormalEnabled = false
    var reliefMaskURL: URL?
    var heightOverrideURL: URL?
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

    var symbol: String {
        switch self {
        case .albedo: "paintpalette"
        case .height: "mountain.2"
        case .normal, .bentNormal: "cube.transparent"
        case .roughness: "circle.lefthalf.filled"
        case .ao, .cavity: "circle.dotted.circle"
        case .convexity, .slope, .edge: "waveform.path"
        case .orm: "square.stack.3d.up"
        }
    }

    var exportedName: String {
        self == .bentNormal ? "bent_normal" : rawValue
    }
}

enum MaterialPixelFormat: String {
    case rgba8SRGB = "rgba8-srgb"
    case rgba8Linear = "rgba8-linear"
    case r16Linear = "r16-unorm-linear"
}

struct MaterialMapData {
    let width: Int
    let height: Int
    let rowBytes: Int
    let format: MaterialPixelFormat
    let bytes: Data
}

struct MaterialSeamMetrics {
    let heightValue: Float
    let heightGradient: Float
    let albedoValue: Float
}

struct DerivedMaterial {
    let source: MaterialSource
    let recipe: MaterialRecipe
    let sourceSHA256: String
    let algorithmVersion: String
    let maps: [MaterialMapKind: MaterialMapData]
    let seams: MaterialSeamMetrics
    let warnings: [String]
}
