import Metal
import RealityKit
import SwiftUI

/// Preview geometry, as on the Mac: a sphere, a cube or a flat tile.
enum PreviewShape: String, CaseIterable, Identifiable {
    case sphere, cube, plane
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .sphere: "circle"
        case .cube: "cube"
        case .plane: "square"
        }
    }
    var mesh: MeshResource {
        switch self {
        case .sphere: .generateSphere(radius: 0.1)
        case .cube: .generateBox(size: 0.14, cornerRadius: 0.004)
        case .plane: .generatePlane(width: 0.2, depth: 0.2)
        }
    }
    /// UV repeats that keep texels roughly square on each mesh.
    var textureScale: SIMD2<Float> {
        switch self {
        case .sphere: [4, 2]
        case .cube: [1, 1]
        case .plane: [2, 2]
        }
    }
}

/// A physically based sphere, cube or tile lit by the default environment plus a key light. Drag to orbit.
struct MaterialSphereView: View {
    let material: DerivedMaterial
    @State private var pbr: PhysicallyBasedMaterial?
    @State private var failed = false
    @State private var shape: PreviewShape = .sphere

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.30), Color(white: 0.10)], startPoint: .top, endPoint: .bottom)
            RealityView { content in
                content.camera = .virtual
                let sphere = ModelEntity(mesh: .generateSphere(radius: 0.1),
                                         materials: [SimpleMaterial(color: .gray, roughness: 0.6, isMetallic: false)])
                sphere.name = "material-sphere"
                content.add(sphere)
                let key = DirectionalLight()
                key.light.intensity = 2800
                key.look(at: .zero, from: [0.35, 0.45, 0.4], relativeTo: nil)
                content.add(key)
                content.cameraTarget = sphere
            } update: { content in
                guard var pbr,
                      let sphere = content.entities.first(where: { $0.name == "material-sphere" }) as? ModelEntity
                else { return }
                pbr.textureCoordinateTransform.scale = shape.textureScale
                sphere.model = ModelComponent(mesh: shape.mesh, materials: [pbr])
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
            .overlay(alignment: .bottomTrailing) {
                Menu {
                    Picker("Shape", selection: $shape) {
                        ForEach(PreviewShape.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                } label: {
                    Image(systemName: shape.symbol)
                        .font(.body.weight(.semibold))
                        .frame(width: 40, height: 40)
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
