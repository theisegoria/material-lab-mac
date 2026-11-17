import CoreGraphics
import Foundation
import ImageIO
import RealityKit
import UniformTypeIdentifiers

/// Preview-only adjustments of the 3D view. None of them change the derived maps or anything exported.
struct PreviewSurface: Hashable, Sendable {
    /// Displacement amplitude from the height map, in preview units (the sphere's radius is 0.5).
    var displacement: Float = 0
    /// 0 dry to 1 soaked: darker albedo and a smoother (lower roughness) water film, pooling in cavities first.
    var wetness: Float = 0
    /// 0 new to 1 worn: brightened, slightly polished edges from the convexity map and dirt in the cavities.
    var wear: Float = 0

    static let displacementRange: ClosedRange<Float> = 0...0.15

    var isNeutral: Bool { displacement == 0 && wetness == 0 && wear == 0 }
    var changesTextures: Bool { wetness > 0 || wear > 0 }
}

/// A built-in procedural sky or an HDRI the user imported (.hdr or .exr).
enum PreviewLighting: Hashable, Sendable {
    case builtIn(PreviewEnvironment)
    case custom(URL)

    var title: String {
        switch self {
        case .builtIn(let environment): environment.title
        case .custom(let url): url.deletingPathExtension().lastPathComponent
        }
    }

    var symbol: String {
        switch self {
        case .builtIn(let environment): environment.symbol
        case .custom: "photo.on.rectangle.angled"
        }
    }
}

/// Imported HDRIs, copied into Application Support/Material Lab/Environments so they survive the original moving.
enum CustomEnvironmentLibrary {
    static var folder: URL { MaterialLibrary.appSupport.appendingPathComponent("Environments", isDirectory: true) }
    static let extensions: Set<String> = ["hdr", "exr"]

    static var contentTypes: [UTType] {
        [UTType(filenameExtension: "hdr"), UTType(filenameExtension: "exr"), UTType("com.ilm.openexr-image")]
            .compactMap { $0 }
    }

    static func list() -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return items.filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Copies an HDRI in (after checking it decodes) and returns the library copy.
    static func importFile(_ url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard extensions.contains(url.pathExtension.lowercased()) else { throw CustomEnvironmentError.unsupported }
        guard loadImage(url) != nil else { throw CustomEnvironmentError.unreadable }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var destination = folder.appendingPathComponent(url.lastPathComponent)
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent(
                "\(url.deletingPathExtension().lastPathComponent) \(suffix).\(url.pathExtension)")
            suffix += 1
        }
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    /// Removes Material Lab's copy (the file the user imported from is untouched).
    static func remove(_ url: URL) {
        guard url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL else { return }
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Decodes the HDRI keeping floating-point values, capped at 4096 px wide for preview lighting.
    static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldAllowFloat: true] as CFDictionary)
        else { return nil }
        let options = [kCGImageSourceShouldAllowFloat: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options) else { return nil }
        guard image.width > 4096 else { return image }
        let width = 4096, height = max(1, image.height * 4096 / image.width)
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 16,
                                      bytesPerRow: width * 8, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                                  CGBitmapInfo.floatComponents.rawValue |
                                                  CGBitmapInfo.byteOrder16Little.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}

enum CustomEnvironmentError: LocalizedError {
    case unsupported, unreadable
    var errorDescription: String? {
        switch self {
        case .unsupported: String(localized: "Choose a Radiance HDR (.hdr) or OpenEXR (.exr) panorama.")
        case .unreadable: String(localized: "This file could not be decoded as an HDR image.")
        }
    }
}

/// Vertex data for a tessellated, height-displaced preview shape (built off the main thread).
struct PreviewMeshData: Sendable {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var uvs: [SIMD2<Float>] = []
    var tangents: [SIMD3<Float>] = []
    var bitangents: [SIMD3<Float>] = []
    var indices: [UInt32] = []

    @MainActor
    func makeMesh() throws -> MeshResource {
        var descriptor = MeshDescriptor(name: "displaced-preview")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor[MeshBuffers.tangents] = MeshBuffers.Tangents(tangents)
        descriptor[MeshBuffers.bitangents] = MeshBuffers.Tangents(bitangents)
        descriptor.primitives = .triangles(indices)
        return try MeshResource.generate(from: [descriptor])
    }
}

enum PreviewGeometry {
    /// A plane (1.15 × 1.15, +Y up) or sphere (radius 0.5) tessellated finely enough to show the height map, displaced
    /// along the surface normal by `(height − 0.5) × scale`. The height repeats `tiling` times, as the textures do.
    static func displaced(_ shape: PreviewShape, height: MaterialMapData, scale: Float, tiling: Float) -> PreviewMeshData? {
        guard height.format == .r16Linear, height.width > 1, height.height > 1, shape != .cube else { return nil }
        let columns = shape == .sphere ? 256 : 220
        let rows = shape == .sphere ? 128 : 220
        var mesh = PreviewMeshData()
        let count = (rows + 1) * (columns + 1)
        mesh.positions.reserveCapacity(count)
        mesh.normals.reserveCapacity(count)
        mesh.uvs.reserveCapacity(count)
        var base: [SIMD3<Float>] = []
        var outward: [SIMD3<Float>] = []
        base.reserveCapacity(count)
        outward.reserveCapacity(count)
        height.bytes.withUnsafeBytes { raw in
            guard let pixels = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            func sample(_ u: Float, _ v: Float) -> Float {
                // Texture coordinates start at the image's bottom-left; rows are stored top-down.
                let fu = (u * tiling).truncatingRemainder(dividingBy: 1)
                let fv = (v * tiling).truncatingRemainder(dividingBy: 1)
                let x = (fu < 0 ? fu + 1 : fu) * Float(height.width) - 0.5
                let y = (1 - (fv < 0 ? fv + 1 : fv)) * Float(height.height) - 0.5
                let x0 = Int(floor(x)), y0 = Int(floor(y))
                let tx = x - Float(x0), ty = y - Float(y0)
                func value(_ px: Int, _ py: Int) -> Float {
                    let wx = (px % height.width + height.width) % height.width
                    let wy = (py % height.height + height.height) % height.height
                    let p = pixels + wy * height.rowBytes + wx * 2
                    return Float(UInt16(p[0]) | UInt16(p[1]) << 8) / 65535
                }
                let top = value(x0, y0) * (1 - tx) + value(x0 + 1, y0) * tx
                let bottom = value(x0, y0 + 1) * (1 - tx) + value(x0 + 1, y0 + 1) * tx
                return top * (1 - ty) + bottom * ty
            }
            for row in 0...rows {
                let v = 1 - Float(row) / Float(rows)
                for column in 0...columns {
                    let u = Float(column) / Float(columns)
                    let point: SIMD3<Float>, normal: SIMD3<Float>
                    if shape == .sphere {
                        let theta = Float(row) / Float(rows) * .pi
                        let phi = u * 2 * .pi
                        // Increasing u runs left to right seen from outside (no mirroring).
                        normal = SIMD3(sin(theta) * cos(phi), cos(theta), -sin(theta) * sin(phi))
                        point = normal * 0.5
                    } else {
                        normal = SIMD3(0, 1, 0)
                        point = SIMD3((u - 0.5) * 1.15, 0, (0.5 - v) * 1.15)
                    }
                    base.append(point)
                    outward.append(normal)
                    mesh.uvs.append(SIMD2(u, v))
                    mesh.positions.append(point + normal * ((sample(u, v) - 0.5) * scale))
                }
            }
        }
        guard mesh.positions.count == count else { return nil }
        let stride = columns + 1
        mesh.indices.reserveCapacity(rows * columns * 6)
        for row in 0..<rows {
            for column in 0..<columns {
                let a = UInt32(row * stride + column), b = a + 1
                let c = UInt32((row + 1) * stride + column), d = c + 1
                mesh.indices += [a, c, b, b, c, d]
            }
        }
        // Smooth normals from the displaced faces.
        var accumulated = [SIMD3<Float>](repeating: .zero, count: count)
        var index = 0
        while index < mesh.indices.count {
            let i0 = Int(mesh.indices[index]), i1 = Int(mesh.indices[index + 1]), i2 = Int(mesh.indices[index + 2])
            let face = cross(mesh.positions[i1] - mesh.positions[i0], mesh.positions[i2] - mesh.positions[i0])
            accumulated[i0] += face; accumulated[i1] += face; accumulated[i2] += face
            index += 3
        }
        if shape == .sphere {
            // Weld the seam column and the poles so shading has no line where the grid closes.
            for row in 0...rows {
                let sum = accumulated[row * stride] + accumulated[row * stride + columns]
                accumulated[row * stride] = sum
                accumulated[row * stride + columns] = sum
            }
            for poleRow in [0, rows] {
                let pole = outward[poleRow * stride]
                for column in 0...columns { accumulated[poleRow * stride + column] = pole }
            }
        }
        mesh.normals = zip(accumulated, outward).map { length($0) > 1e-12 ? normalize($0) : $1 }
        // Tangent frame along +u and +v of the grid, orthonormalised against the normal.
        mesh.tangents.reserveCapacity(count)
        mesh.bitangents.reserveCapacity(count)
        for row in 0...rows {
            for column in 0...columns {
                let i = row * stride + column
                let n = mesh.normals[i]
                let left = base[row * stride + max(0, column - 1)], right = base[row * stride + min(columns, column + 1)]
                var t = right - left
                if length(t) < 1e-8 {
                    // At the sphere's poles the u direction collapses; use the longitude's direction instead.
                    let phi = Float(column) / Float(columns) * 2 * .pi
                    t = SIMD3(-sin(phi), 0, -cos(phi))
                }
                t = t - n * dot(n, t)
                t = length(t) > 1e-8 ? normalize(t) : SIMD3(1, 0, 0)
                let up = base[max(0, row - 1) * stride + column], down = base[min(rows, row + 1) * stride + column]
                var b = cross(n, t)
                if dot(b, up - down) < 0 { b = -b }
                mesh.tangents.append(t)
                mesh.bitangents.append(b)
            }
        }
        return mesh
    }
}

/// Preview-only weathering of the albedo and roughness (wetness and edge wear). Data maps are never modified.
enum PreviewWeathering {
    private static let srgbToLinear: [Float] = (0..<256).map { value in
        let c = Float(value) / 255
        return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    private static let linearToSRGB: [UInt8] = (0..<4096).map { index in
        let c = Float(index) / 4095
        let s = c <= 0.0031308 ? c * 12.92 : 1.055 * powf(c, 1 / 2.4) - 0.055
        return UInt8(max(0, min(255, (s * 255).rounded())))
    }

    static func apply(_ material: DerivedMaterial, wetness: Float, wear: Float) -> (albedo: CGImage?, roughness: CGImage?) {
        guard let albedo = material.maps[.albedo], albedo.format != .r16Linear else { return (nil, nil) }
        let width = albedo.width, height = albedo.height
        func matching(_ kind: MaterialMapKind) -> MaterialMapData? {
            guard let map = material.maps[kind], map.width == width, map.height == height, map.format != .r16Linear
            else { return nil }
            return map
        }
        let roughness = matching(.roughness), cavity = matching(.cavity), convexity = matching(.convexity)
        let baseRoughness = UInt8(max(0, min(255, (material.recipe.roughnessBase * 255).rounded())))
        let rowBytes = width * 4
        var outAlbedo = Data(count: rowBytes * height)
        var outRoughness = Data(count: rowBytes * height)
        func read(_ map: MaterialMapData?, _ x: Int, _ y: Int, _ raw: UnsafePointer<UInt8>?) -> Float? {
            guard let map, let raw else { return nil }
            return Float(raw[y * map.rowBytes + x * 4]) / 255
        }
        func withBytes<T>(_ map: MaterialMapData?, _ body: (UnsafePointer<UInt8>?) -> T) -> T {
            guard let map else { return body(nil) }
            return map.bytes.withUnsafeBytes { body($0.bindMemory(to: UInt8.self).baseAddress) }
        }
        withBytes(albedo) { a in
        withBytes(roughness) { r in
        withBytes(cavity) { cav in
        withBytes(convexity) { conv in
            guard let a else { return }
            outAlbedo.withUnsafeMutableBytes { albedoOut in
                outRoughness.withUnsafeMutableBytes { roughOut in
                    guard let oa = albedoOut.bindMemory(to: UInt8.self).baseAddress,
                          let orough = roughOut.bindMemory(to: UInt8.self).baseAddress else { return }
                    for y in 0..<height {
                        for x in 0..<width {
                            let crevice = read(cavity, x, y, cav) ?? 0
                            let ridge = read(convexity, x, y, conv) ?? 0
                            var rough = read(roughness, x, y, r) ?? Float(baseRoughness) / 255
                            // Water pools in crevices first and covers everything when soaked.
                            let wet = max(0, min(1, wetness * (0.55 + 0.9 * crevice) + max(0, wetness - 0.6) * 1.2))
                            // Wear exposes and polishes the raised edges and leaves grime in the crevices.
                            let wornEdge = max(0, min(1, (ridge - (1 - wear) * 0.55) * 2.2 * wear))
                            let grime = wear * crevice * 0.3
                            let p = a + y * albedo.rowBytes + x * 4
                            let o = oa + y * rowBytes + x * 4
                            for channel in 0..<3 {
                                var c = srgbToLinear[Int(p[channel])]
                                c += (min(1, c * 1.55 + 0.06) - c) * wornEdge
                                c *= 1 - grime
                                c *= 1 - 0.5 * wet
                                o[channel] = linearToSRGB[Int(max(0, min(1, c)) * 4095)]
                            }
                            o[3] = p[3]
                            rough += (rough * 0.7 - rough) * wornEdge
                            rough += (0.06 - rough) * wet * 0.92
                            let value = UInt8(max(0, min(255, (rough * 255).rounded())))
                            let q = orough + y * rowBytes + x * 4
                            q[0] = value; q[1] = value; q[2] = value; q[3] = 255
                        }
                    }
                }
            }
        }
        }
        }
        }
        let albedoImage = MaterialEngine.rgbaImage(outAlbedo, width: width, height: height, rowBytes: rowBytes,
                                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let roughnessImage = MaterialEngine.rgbaImage(outRoughness, width: width, height: height, rowBytes: rowBytes,
                                                      colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (albedoImage, roughnessImage)
    }
}
