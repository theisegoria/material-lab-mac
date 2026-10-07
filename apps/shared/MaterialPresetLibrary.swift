import Foundation

/// A named starting recipe from the core's material library (PBRLabMaterialPreset): brick, wood planks, rusted
/// steel... Shared by both apps and the CLI, so the same name gives the same recipe everywhere.
struct LibraryPreset: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let category: String
    private let index: UInt32

    /// The preset's recipe values (its relief prior plus tuned relief, roughness, AO and metalness).
    var recipe: PBRLabRecipe { PBRLabMaterialPresetAt(index)!.pointee.recipe }

    var symbol: String {
        switch String(cString: PBRLabMaterialPresetAt(index)!.pointee.category) {
        case "Masonry": "square.stack.3d.up"
        case "Concrete & plaster": "building.2"
        case "Tile": "square.grid.3x3"
        case "Wood": "tree"
        case "Ground": "leaf"
        case "Fabric": "tshirt"
        case "Metal": "gearshape.2"
        default: "shippingbox"
        }
    }

    static let all: [LibraryPreset] = (0..<PBRLabMaterialPresetCount()).compactMap { index in
        guard let preset = PBRLabMaterialPresetAt(index)?.pointee else { return nil }
        return LibraryPreset(id: String(cString: preset.identifier), title: L(String(cString: preset.title)),
                             category: L(String(cString: preset.category)), index: index)
    }

    /// Categories in library order, each with its presets.
    static let byCategory: [(category: String, presets: [LibraryPreset])] = {
        var order: [String] = []
        var groups: [String: [LibraryPreset]] = [:]
        for preset in all {
            if groups[preset.category] == nil { order.append(preset.category) }
            groups[preset.category, default: []].append(preset)
        }
        return order.map { ($0, groups[$0]!) }
    }()

    static func named(_ id: String?) -> LibraryPreset? { id.flatMap { id in all.first { $0.id == id } } }
}
