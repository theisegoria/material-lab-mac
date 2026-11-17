import CoreGraphics
import Foundation
import simd

/// A height map resampled for preview displacement: luminance in 0…1, row 0 = the image's top row.
struct PreviewHeightField: Sendable, Equatable {
    let width: Int
    let height: Int
    let values: [Float]
    /// Mean height; displacement is measured from it so the surface neither swells nor shrinks.
    let mean: Float

    init(width: Int, height: Int, values: [Float]) {
        precondition(values.count == width * height && width > 0 && height > 0)
        self.width = width
        self.height = height
        self.values = values
        mean = values.reduce(0, +) / Float(values.count)
    }

    /// Draws `image` into an 8-bit grey buffer no larger than `maxSide` on a side.
    init?(image: CGImage, maxSide: Int = 256) {
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let w = max(2, Int((Double(image.width) * scale).rounded()))
        let h = max(2, Int((Double(image.height) * scale).rounded()))
        var bytes = [UInt8](repeating: 0, count: w * h)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        // A bitmap context's memory starts at the image's top row.
        self.init(width: w, height: h, values: bytes.map { Float($0) / 255 })
    }

    /// Bilinear, wrapping sample at texture coordinates (s, t) the way RealityKit's physically based material samples
    /// a texture: t runs bottom to top (the shader flips it), and the map repeats.
    func sample(s: Float, t: Float) -> Float {
        let x = (s - s.rounded(.down)) * Float(width) - 0.5
        let yUnit = 1 - (t - t.rounded(.down))
        let y = yUnit * Float(height) - 0.5
        let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
        let fx = x - Float(x0), fy = y - Float(y0)
        func at(_ xi: Int, _ yi: Int) -> Float {
            let xx = ((xi % width) + width) % width
            let yy = ((yi % height) + height) % height
            return values[yy * width + xx]
        }
        let top = at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx
        let bottom = at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx
        return top * (1 - fy) + bottom * fy
    }
}

/// CPU-displaced preview geometry: the lit preview's sphere, cube or tile, tessellated and pushed along its normals
/// by the height map, at the height span the core reported (`relief.heightSpanTileWidths`) times a user scale.
/// Preview only: nothing here touches derivation or export.
enum DisplacedPreviewMesh {
    struct Geometry: Sendable {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
    }

    /// The core's height span when the material has none recorded (live previews): a modest relief.
    static let fallbackHeightSpanTileWidths: Float = 0.04

    /// Builds the displaced geometry for `shape`, with the same sizes and UV repeats as the undisplaced meshes.
    /// `heightSpan` is the height map's full 0…1 range in tile widths; `scale` multiplies it.
    static func make(shape: PreviewShape, field: PreviewHeightField, tiling: Float, heightSpan: Float,
                     scale: Float) -> Geometry {
        let repeats = shape.textureScale(tiling: tiling)
        var geometry = Geometry()
        switch shape {
        case .sphere:
            let radius: Float = 0.21
            // Sphere UVs span 2:1, so a tile is half the circumference over the tiling.
            let amplitude = heightSpan * scale * (.pi * radius / tiling)
            appendGrid(&geometry, columns: 192, rows: 96, field: field, repeats: repeats, amplitude: amplitude) { a, b in
                let theta = a * 2 * .pi
                let phi = b * .pi
                let normal = SIMD3<Float>(sin(phi) * sin(theta), cos(phi), sin(phi) * cos(theta))
                // Fade to nothing at the poles, where every column meets.
                let fade = min(1, sin(phi) / 0.18)
                return (normal * radius, normal, SIMD2(a, 1 - b), fade)
            }
        case .cube:
            let side: Float = 0.29
            let amplitude = heightSpan * scale * (side / tiling)
            let faces: [(n: SIMD3<Float>, u: SIMD3<Float>, v: SIMD3<Float>)] = [
                ([0, 0, 1], [1, 0, 0], [0, 1, 0]), ([0, 0, -1], [-1, 0, 0], [0, 1, 0]),
                ([1, 0, 0], [0, 0, -1], [0, 1, 0]), ([-1, 0, 0], [0, 0, 1], [0, 1, 0]),
                ([0, 1, 0], [1, 0, 0], [0, 0, -1]), ([0, -1, 0], [1, 0, 0], [0, 0, 1]),
            ]
            for face in faces {
                appendGrid(&geometry, columns: 72, rows: 72, field: field, repeats: repeats, amplitude: amplitude) { a, b in
                    // b runs top to bottom of the face; v is up.
                    let position = face.n * (side / 2) + face.u * ((a - 0.5) * side) + face.v * ((0.5 - b) * side)
                    // Fade at the edges so neighbouring faces still meet.
                    let edge = min(min(a, 1 - a), min(b, 1 - b))
                    return (position, face.n, SIMD2(a, 1 - b), min(1, edge / 0.06))
                }
            }
        case .plane:
            let size: Float = 0.42
            let amplitude = heightSpan * scale * (size / tiling)
            appendGrid(&geometry, columns: 192, rows: 192, field: field, repeats: repeats, amplitude: amplitude) { a, b in
                (SIMD3((a - 0.5) * size, 0, (b - 0.5) * size), SIMD3(0, 1, 0), SIMD2(a, 1 - b), 1)
            }
        }
        return geometry
    }

    /// Appends a (columns+1)×(rows+1) vertex grid. `surface(a, b)` gives the undisplaced position, outward normal,
    /// UV and a 0…1 displacement fade; triangles face outward and normals are recomputed from the displaced surface,
    /// shared across coincident vertices (sphere seam and poles) that face the same way.
    private static func appendGrid(_ geometry: inout Geometry, columns: Int, rows: Int, field: PreviewHeightField,
                                   repeats: SIMD2<Float>, amplitude: Float,
                                   surface: (Float, Float) -> (SIMD3<Float>, SIMD3<Float>, SIMD2<Float>, Float)) {
        let base = geometry.positions.count
        var baseNormals: [SIMD3<Float>] = []
        baseNormals.reserveCapacity((columns + 1) * (rows + 1))
        for j in 0...rows {
            for i in 0...columns {
                let (position, normal, uv, fade) = surface(Float(i) / Float(columns), Float(j) / Float(rows))
                let h = field.sample(s: uv.x * repeats.x, t: uv.y * repeats.y) - field.mean
                geometry.positions.append(position + normal * (h * amplitude * fade))
                geometry.uvs.append(uv)
                baseNormals.append(normal)
            }
        }
        // Pick the winding whose face normal points outward (checked on a quad away from any pole or edge).
        let stride = columns + 1
        let probe = base + (rows / 2) * stride + columns / 2
        let p = geometry.positions
        let faceNormal = cross(p[probe + stride] - p[probe], p[probe + 1] - p[probe])
        let flip = dot(faceNormal, baseNormals[probe - base]) < 0
        var accumulated = [SIMD3<Float>](repeating: .zero, count: baseNormals.count)
        for j in 0..<rows {
            for i in 0..<columns {
                let a = UInt32(base + j * stride + i), b = a + 1
                let c = a + UInt32(stride), d = c + 1
                let triangles: [(UInt32, UInt32, UInt32)] = flip ? [(a, b, c), (b, d, c)] : [(a, c, b), (b, c, d)]
                for (x, y, z) in triangles {
                    geometry.indices += [x, y, z]
                    let n = cross(p[Int(y)] - p[Int(x)], p[Int(z)] - p[Int(x)])
                    for index in [x, y, z] { accumulated[Int(index) - base] += n }
                }
            }
        }
        // Weld normals across coincident vertices facing the same way (sphere seam and poles).
        struct Key: Hashable { let p: SIMD3<Int32>; let n: SIMD3<Int32> }
        var groups: [Key: SIMD3<Float>] = [:]
        func key(_ index: Int) -> Key {
            Key(p: SIMD3<Int32>((p[base + index] * 100_000).rounded(.toNearestOrEven)), n: SIMD3<Int32>((baseNormals[index] * 50).rounded(.toNearestOrEven)))
        }
        for index in accumulated.indices { groups[key(index), default: .zero] += accumulated[index] }
        for index in accumulated.indices {
            let n = groups[key(index)] ?? accumulated[index]
            let length = simd_length(n)
            geometry.normals.append(length > 1e-12 ? n / length : baseNormals[index])
        }
    }
}
