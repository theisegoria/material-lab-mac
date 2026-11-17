import CoreGraphics
import Metal
import RealityKit
import SwiftUI

enum PreviewShape: String, CaseIterable, Identifiable {
    case sphere, cube, plane
    var id: String { rawValue }

    var title: String { L(englishTitle) }
    var englishTitle: String {
        switch self {
        case .sphere: "Sphere"
        case .cube: "Rounded cube"
        case .plane: "Plane"
        }
    }

    var symbol: String {
        switch self {
        case .sphere: "circle.fill"
        case .cube: "cube.fill"
        case .plane: "square.fill"
        }
    }

    /// UV repeats so tiling is visible on the preview geometry.
    var uvRepeat: Float {
        switch self {
        case .sphere: 2
        case .cube: 1
        case .plane: 2
        }
    }
}

/// Real-time RealityKit preview of the derived material (albedo, normal, roughness, AO and
/// assigned metalness) under image-based plus directional light, with orbit camera controls.
struct MaterialPreview3D: View {
    let material: DerivedMaterial
    let shape: PreviewShape
    var lighting: PreviewLighting = .builtIn(.studio)
    /// UV repeats across the preview geometry, so tiling shows.
    var tiling: Float = 2
    /// Preview-only displacement, wetness and wear (never exported).
    var surface = PreviewSurface()
    @State private var scene = PreviewScene()

    private var materialKey: MaterialKey {
        MaterialKey(
            albedo: material.previews[.albedo].map { ObjectIdentifier($0) },
            normalYDown: material.recipe.normalYDown,
            metalness: material.recipe.assignedMetalnessEnabled ? material.recipe.assignedMetalness : -1,
            shape: shape, tiling: tiling, surface: surface
        )
    }

    var body: some View {
        RealityView { content in
            content.camera = .virtual
            scene.install(into: &content)
        } update: { _ in
            scene.setShape(shape)
        }
        .realityViewCameraControls(.orbit)
        .task(id: lighting) {
            await scene.setLighting(lighting)
        }
        .task(id: materialKey) {
            if !surface.isNeutral {
                // Coalesce slider drags: weathering and displacement are rebuilt once the value settles.
                try? await Task.sleep(for: .milliseconds(90))
                guard !Task.isCancelled else { return }
            }
            await scene.apply(material, shape: shape, tiling: tiling, surface: surface)
        }
        .accessibilityLabel("Interactive 3D preview of the material on a \(shape.title.lowercased())")
    }

    private struct MaterialKey: Hashable {
        let albedo: ObjectIdentifier?
        let normalYDown: Bool
        let metalness: Float
        let shape: PreviewShape
        let tiling: Float
        let surface: PreviewSurface
    }
}

@MainActor
final class PreviewScene {
    let root = Entity()
    let model = ModelEntity()
    private(set) var environment: EnvironmentResource?
    private var currentShape: PreviewShape?
    private var currentLighting: PreviewLighting = .builtIn(.studio)
    /// True while the model shows a tessellated, height-displaced mesh instead of the generated shape.
    private var displaced = false
    private var installed = false

    func install(into content: inout RealityViewCameraContent) {
        build()
        content.add(root)
        content.cameraTarget = model
    }

    func build() {
        if !installed {
            installed = true
            model.name = "material-preview"
            root.addChild(model)

            let key = DirectionalLight()
            key.light.intensity = 3200
            key.light.color = NSColor(calibratedRed: 1, green: 0.97, blue: 0.92, alpha: 1)
            key.shadow = DirectionalLightComponent.Shadow(maximumDistance: 4, depthBias: 1.5)
            key.look(at: .zero, from: SIMD3(-1.6, 2.2, 2.4), relativeTo: nil)
            root.addChild(key)

            environment = PreviewEnvironment.studio.makeResource()
            if let environment {
                root.components.set(ImageBasedLightComponent(source: .single(environment), intensityExponent: 0.4))
                model.components.set(ImageBasedLightReceiverComponent(imageBasedLight: root))
            }
            setShape(.sphere)
        }
    }

    func setShape(_ shape: PreviewShape) {
        guard shape != currentShape else { return }
        currentShape = shape
        switch shape {
        case .sphere:
            model.model?.mesh = .generateSphere(radius: 0.5)
            model.orientation = simd_quatf(angle: 0, axis: [0, 1, 0])
        case .cube:
            model.model?.mesh = .generateBox(size: 0.78, cornerRadius: 0.09)
            model.orientation = simd_quatf(angle: .pi / 7, axis: normalize(SIMD3<Float>(1, 1, 0)))
        case .plane:
            model.model?.mesh = .generatePlane(width: 1.15, depth: 1.15)
            model.orientation = simd_quatf(angle: .pi / 2.6, axis: [1, 0, 0])
        }
        if model.model == nil {
            model.model = ModelComponent(mesh: .generateSphere(radius: 0.5), materials: [SimpleMaterial()])
            currentShape = nil
            setShape(shape)
        }
    }

    /// Switches the image-based light to a built-in sky or an imported HDRI (decoded off the main thread).
    func setLighting(_ choice: PreviewLighting) async {
        guard choice != currentLighting else { return }
        let resource: EnvironmentResource?
        switch choice {
        case .builtIn(let environment):
            resource = environment.makeResource()
        case .custom(let url):
            let image = await Task.detached(priority: .userInitiated) { CustomEnvironmentLibrary.loadImage(url) }.value
            guard !Task.isCancelled, let image else { return }
            resource = try? await EnvironmentResource(equirectangular: image, options: .init(samplingQuality: .normal))
        }
        guard !Task.isCancelled, let resource else { return }
        currentLighting = choice
        environment = resource
        root.components.set(ImageBasedLightComponent(source: .single(resource), intensityExponent: 0.4))
    }

    func apply(_ material: DerivedMaterial, shape: PreviewShape, tiling: Float? = nil,
               surface: PreviewSurface = PreviewSurface()) async {
        setShape(shape)
        let repeats = tiling ?? shape.uvRepeat
        var albedoImage = material.previews[.albedo]
        var roughnessImage = material.previews[.roughness]
        if surface.changesTextures {
            let weathered = await Task.detached(priority: .userInitiated) {
                PreviewWeathering.apply(material, wetness: surface.wetness, wear: surface.wear)
            }.value
            guard !Task.isCancelled else { return }
            albedoImage = weathered.albedo ?? albedoImage
            roughnessImage = weathered.roughness ?? roughnessImage
        }
        var displacedMesh: MeshResource?
        if surface.displacement > 0, shape != .cube, let height = material.maps[.height] {
            let data = await Task.detached(priority: .userInitiated) {
                PreviewGeometry.displaced(shape, height: height, scale: surface.displacement, tiling: repeats)
            }.value
            guard !Task.isCancelled else { return }
            displacedMesh = try? data?.makeMesh()
        }
        do {
            var pbr = PhysicallyBasedMaterial()
            if let albedo = try await texture(albedoImage, semantic: .color) {
                pbr.baseColor = .init(tint: .white, texture: albedo)
            }
            if let normal = try await texture(MaterialEngine.openGLNormalImage(material), semantic: .normal) {
                pbr.normal = .init(texture: normal)
            }
            if let roughness = try await texture(roughnessImage, semantic: .raw) {
                pbr.roughness = .init(scale: 1, texture: roughness)
            } else {
                pbr.roughness = .init(floatLiteral: material.recipe.roughnessBase)
            }
            if let ao = try await texture(material.previews[.ao], semantic: .raw) {
                pbr.ambientOcclusion = .init(texture: ao)
            }
            pbr.metallic = .init(floatLiteral: material.recipe.assignedMetalnessEnabled
                                 ? material.recipe.assignedMetalness : 0)
            pbr.textureCoordinateTransform = .init(scale: SIMD2(repeating: repeats))
            if displacedMesh != nil { pbr.faceCulling = .none }
            guard !Task.isCancelled else { return }
            model.model?.materials = [pbr]
            if let displacedMesh {
                model.model?.mesh = displacedMesh
                currentShape = shape
                displaced = true
            } else if displaced {
                displaced = false
                currentShape = nil
                setShape(shape)
            }
        } catch {
            // Keep the previous material; the 2D views remain authoritative.
        }
    }

    private func texture(
        _ image: CGImage?, semantic: TextureResource.Semantic
    ) async throws -> PhysicallyBasedMaterial.Texture? {
        guard let image else { return nil }
        let resource = try await TextureResource(image: image, options: .init(semantic: semantic))
        var texture = PhysicallyBasedMaterial.Texture(resource)
        let descriptor = MTLSamplerDescriptor()
        descriptor.sAddressMode = .repeat
        descriptor.tAddressMode = .repeat
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .linear
        descriptor.maxAnisotropy = 8
        texture.sampler = .init(descriptor)
        return texture
    }
}

extension PreviewScene {
    /// Offscreen render of the same scene (used by the snapshot harness; RealityView's Metal
    /// layer cannot be captured by drawing the view hierarchy).
    static func renderSnapshot(
        _ material: DerivedMaterial, shape: PreviewShape, side: Int, background: CGColor
    ) async -> CGImage? {
        let scene = PreviewScene()
        scene.build()
        await scene.apply(material, shape: shape)
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = try? RealityRenderer() else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb, width: side, height: side, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor),
              let output = try? RealityRenderer.CameraOutput(.singleProjection(colorTexture: texture))
        else { return nil }
        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 38
        camera.look(at: .zero, from: SIMD3(0.35, 0.45, 1.9), relativeTo: nil)
        renderer.entities.append(scene.root)
        renderer.entities.append(camera)
        renderer.activeCamera = camera
        renderer.lighting.resource = scene.environment
        renderer.lighting.intensityExponent = 0.4
        renderer.cameraSettings.colorBackground = .color(background)
        for _ in 0..<4 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                do {
                    try renderer.updateAndRender(deltaTime: 1.0 / 60, cameraOutput: output, onComplete: { _ in
                        continuation.resume()
                    })
                } catch {
                    continuation.resume()
                }
            }
        }
        let rowBytes = side * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * side)
        texture.getBytes(&bytes, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
