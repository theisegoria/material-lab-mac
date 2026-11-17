import Metal
import RealityKit
import SwiftUI
import UIKit

/// Preview geometry, as on the Mac: a sphere, a cube or a flat tile.
enum PreviewShape: String, CaseIterable, Identifiable {
    case sphere, cube, plane
    var id: String { rawValue }
    var title: String { L(englishTitle) }
    var englishTitle: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .sphere: "circle"
        case .cube: "cube"
        case .plane: "square"
        }
    }
    var mesh: MeshResource {
        switch self {
        case .sphere: .generateSphere(radius: 0.21)
        case .cube: .generateBox(size: 0.29, cornerRadius: 0.012)
        case .plane: .generatePlane(width: 0.42, depth: 0.42)
        }
    }
    /// UV repeats for `tiling` repeats across a face; the sphere's UVs span 2:1, so it doubles horizontally.
    func textureScale(tiling: Float) -> SIMD2<Float> {
        self == .sphere ? [tiling * 2, tiling] : [tiling, tiling]
    }
}

/// What the lit preview shows. Shape, lighting and tiling match the Mac app's built-ins; displacement, wetness and
/// wear change the preview only and never the derived maps or exports.
struct LitPreviewSettings: Equatable {
    var shape: PreviewShape = .sphere
    var environment: PreviewEnvironment = .studio
    var tiling: Float = 2
    /// Multiplies the height span the core reported; 0 turns displacement off (the smooth mesh, normal map only).
    var displacementScale: Double = 1
    /// 0…1: darker albedo, glossier surface and a thin clear coat, as when wet.
    var wetness: Double = 0
    /// 0…1: rougher, less specular, as when scuffed and dusty.
    var wear: Double = 0

    static let displacementRange: ClosedRange<Double> = 0...3

    /// Applies the preview-only wetness and wear to a copy of the derived material.
    func adjusted(_ base: PhysicallyBasedMaterial) -> PhysicallyBasedMaterial {
        guard wetness > 0 || wear > 0 else { return base }
        var pbr = base
        let wet = Float(wetness), worn = Float(wear)
        // Wet surfaces darken (water fills the pores) and turn glossy; wear dulls and roughens.
        let darken = CGFloat(1 - 0.45 * wet)
        pbr.baseColor.tint = UIColor(white: darken, alpha: 1)
        pbr.roughness.scale = max(0.05, (1 - 0.7 * wet) * (1 + 0.6 * worn))
        pbr.specular.scale = 1 - 0.5 * worn
        pbr.clearcoat = .init(floatLiteral: 0.85 * wet)
        pbr.clearcoatRoughness = .init(floatLiteral: 0.04 + 0.2 * worn)
        return pbr
    }
}

/// A physically based sphere, cube or tile lit by a built-in environment plus a key light. Drag to orbit.
/// With a height map, the mesh is really displaced (see `DisplacedPreviewMesh`).
struct MaterialSphereView: View {
    let material: DerivedMaterial
    @Binding var settings: LitPreviewSettings
    @State private var pbr: PhysicallyBasedMaterial?
    @State private var failed = false
    @State private var heightField: PreviewHeightField?
    /// The displaced mesh and the settings it was built for (used only while they still match).
    @State private var displaced: (key: DisplacementKey, mesh: MeshResource)?
    /// Opens the material in AR Quick Look; nil until full-resolution maps exist.
    var viewInAR: (() -> Void)? = nil

    private struct DisplacementKey: Equatable {
        let material: ObjectIdentifier
        let shape: PreviewShape
        let tiling: Float
        let scale: Double
    }

    private var displacementKey: DisplacementKey? {
        guard heightField != nil, settings.displacementScale > 0 else { return nil }
        return DisplacementKey(material: ObjectIdentifier(material.correctedSource), shape: settings.shape,
                               tiling: settings.tiling, scale: settings.displacementScale)
    }

    private var currentMesh: MeshResource {
        if let key = displacementKey, let displaced, displaced.key == key { return displaced.mesh }
        return settings.shape.mesh
    }

    var body: some View {
        let shape = settings.shape
        let environment = settings.environment
        let mesh = currentMesh
        let adjusted = pbr.map(settings.adjusted)
        let tiling = settings.tiling
        ZStack {
            LinearGradient(colors: [Color(white: 0.30), Color(white: 0.10)], startPoint: .top, endPoint: .bottom)
            RealityView { content in
                content.camera = .virtual
                let root = Entity()
                root.name = "preview-root"
                let sphere = ModelEntity(mesh: .generateSphere(radius: 0.21),
                                         materials: [SimpleMaterial(color: .gray, roughness: 0.6, isMetallic: false)])
                sphere.name = "material-sphere"
                root.addChild(sphere)
                if let light = PreviewEnvironment.studio.makeResource() {
                    root.components.set(ImageBasedLightComponent(source: .single(light), intensityExponent: 1.1))
                    sphere.components.set(ImageBasedLightReceiverComponent(imageBasedLight: root))
                }
                content.add(root)
                let key = DirectionalLight()
                key.light.intensity = 4200
                key.look(at: .zero, from: [0.35, 0.45, 0.4], relativeTo: nil)
                content.add(key)
                content.cameraTarget = sphere
            } update: { content in
                guard var pbr = adjusted, let root = content.entities.first(where: { $0.name == "preview-root" }),
                      let sphere = root.children.first(where: { $0.name == "material-sphere" }) as? ModelEntity
                else { return }
                // A named marker child records the environment the root carries.
                let marker = root.children.first { $0.name.hasPrefix("environment-") }
                if marker?.name != "environment-\(environment.rawValue)", let light = environment.makeResource() {
                    root.components.set(ImageBasedLightComponent(source: .single(light), intensityExponent: 1.1))
                    marker?.removeFromParent()
                    let next = Entity()
                    next.name = "environment-\(environment.rawValue)"
                    root.addChild(next)
                }
                pbr.textureCoordinateTransform.scale = shape.textureScale(tiling: tiling)
                sphere.model = ModelComponent(mesh: mesh, materials: [pbr])
                // The orbit camera framed the model when the scene was made; enlarging it afterwards fills the view.
                sphere.scale = SIMD3(repeating: 1.75)
                // Tilt the flat tile toward the camera so it reads as a surface, not an edge.
                switch shape {
                case .plane: sphere.orientation = simd_quatf(angle: .pi / 2.6, axis: [1, 0, 0])
                case .cube:
                    // Three faces in view, so the cube reads as a solid.
                    sphere.orientation = simd_quatf(angle: .pi / 7, axis: [1, 0, 0]) * simd_quatf(angle: .pi / 4, axis: [0, 1, 0])
                case .sphere: sphere.orientation = simd_quatf()
                }
            }
            .realityViewCameraControls(.orbit)
            .accessibilityElement()
            .accessibilityLabel("Lit \(shape.title) preview")
            .accessibilityHint("Drag to orbit.")
            .overlay(alignment: .topTrailing) {
                if let viewInAR {
                    Button(action: viewInAR) {
                        Label("AR", systemImage: "arkit")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("View in AR")
                    .accessibilityIdentifier("view-in-ar")
                    .padding(12)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Menu {
                    Picker("Shape", selection: $settings.shape) {
                        ForEach(PreviewShape.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    Picker("Lighting", selection: $settings.environment) {
                        ForEach(PreviewEnvironment.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    Picker("Tiling", selection: $settings.tiling) {
                        ForEach([1, 2, 3, 4, 6, 8] as [Float], id: \.self) { Text("\(Int($0))×").tag($0) }
                    }
                } label: {
                    Image(systemName: shape.symbol)
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .accessibilityLabel("Preview shape")
                .accessibilityIdentifier("preview-shape")
                .accessibilityValue(shape.title)
                .padding(12)
            }
            if failed {
                Label("Lit preview unavailable", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .padding(10)
                    .glassEffect(.regular, in: .capsule)
            }
        }
        .task(id: ObjectIdentifier(material.correctedSource)) {
            do {
                pbr = try await Self.makeMaterial(material)
                failed = false
            } catch {
                failed = true
            }
            let height = material.maps[.height]?.previewImage
            heightField = await Task.detached(priority: .userInitiated) {
                height.flatMap { PreviewHeightField(image: $0) }
            }.value
        }
        .task(id: displacementKey) {
            guard let key = displacementKey, let field = heightField else { return }
            // Debounce slider drags.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let span = material.relief?.heightSpanTileWidths ?? DisplacedPreviewMesh.fallbackHeightSpanTileWidths
            let geometry = await Task.detached(priority: .userInitiated) {
                DisplacedPreviewMesh.make(shape: key.shape, field: field, tiling: key.tiling,
                                          heightSpan: span, scale: Float(key.scale))
            }.value
            guard !Task.isCancelled else { return }
            var descriptor = MeshDescriptor(name: "displaced-\(key.shape.rawValue)")
            descriptor.positions = MeshBuffers.Positions(geometry.positions)
            descriptor.normals = MeshBuffers.Normals(geometry.normals)
            descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(geometry.uvs)
            descriptor.primitives = .triangles(geometry.indices)
            if let mesh = try? MeshResource.generate(from: [descriptor]) {
                displaced = (key, mesh)
            }
        }
    }

    @MainActor
    static func makeMaterial(_ material: DerivedMaterial) async throws -> PhysicallyBasedMaterial {
        let sampler: MaterialParameters.Texture.Sampler = {
            let descriptor = MTLSamplerDescriptor()
            descriptor.sAddressMode = .repeat
            descriptor.tAddressMode = .repeat
            descriptor.minFilter = .linear
            descriptor.magFilter = .linear
            descriptor.mipFilter = .linear
            descriptor.maxAnisotropy = 8
            return MaterialParameters.Texture.Sampler(descriptor)
        }()
        func texture(_ kind: MaterialMapKind, _ semantic: TextureResource.Semantic,
                     image override: CGImage? = nil) async throws -> MaterialParameters.Texture? {
            guard let image = override ?? material.maps[kind]?.previewImage else { return nil }
            let resource = try await TextureResource(image: image, options: .init(semantic: semantic))
            return MaterialParameters.Texture(resource, sampler: sampler)
        }
        var pbr = PhysicallyBasedMaterial()
        if let albedo = try await texture(.albedo, .color) {
            pbr.baseColor = .init(texture: albedo)
        }
        if let map = material.maps[.normal],
           let normal = try await texture(.normal, .normal,
                                          image: MaterialProcessor.openGLNormalImage(map, yDown: material.recipe.normalYDown)) {
            pbr.normal = .init(texture: normal)
        }
        if let roughness = try await texture(.roughness, .scalar) {
            pbr.roughness = .init(texture: roughness)
        } else {
            pbr.roughness = .init(floatLiteral: material.recipe.roughnessBase)
        }
        if let ao = try await texture(.ao, .scalar) {
            pbr.ambientOcclusion = .init(texture: ao)
        }
        pbr.metallic = .init(floatLiteral: material.recipe.assignedMetalness ?? 0)
        // Sphere UVs span 2:1; repeat so texels stay roughly square.
        pbr.textureCoordinateTransform.scale = [4, 2]
        return pbr
    }
}

