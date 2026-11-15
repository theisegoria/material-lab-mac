import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import simd

/// Depth delivered with a photo (LiDAR on Pro iPhones, or dual-camera disparity), kept in the sensor's own frame with
/// pinhole intrinsics scaled to the depth map, plus the photo's EXIF orientation so upright crops can be mapped into it.
struct DepthCapture: Sendable, Equatable {
    let width: Int
    let height: Int
    /// Metres, row-major in sensor orientation; non-finite or ≤ 0 marks a hole.
    let depth: [Float]
    let fx: Float, fy: Float, cx: Float, cy: Float
    /// EXIF orientation of the photo (1 = upright sensor frame).
    let orientation: UInt32
    /// True for LiDAR / time-of-flight style absolute depth; false for relative (disparity-derived) depth.
    let isAbsolute: Bool
    /// Per-pixel confidence from frame averaging (DepthStack; 255 = every frame agreed), nil for a single frame.
    var confidence: [UInt8]? = nil
    /// Depth frames averaged into `depth` (1 = the photo's own depth map).
    var frames = 1

    /// Reads depth embedded in a photo file (auxiliary depth or disparity data), or nil when there is none.
    static func read(from data: Data) -> DepthCapture? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let info = (CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, kCGImageAuxiliaryDataTypeDepth)
                    ?? CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, kCGImageAuxiliaryDataTypeDisparity))
            as? [AnyHashable: Any]
        guard let info, var depthData = try? AVDepthData(fromDictionaryRepresentation: info) else { return nil }
        if depthData.depthDataType != kCVPixelFormatType_DepthFloat32 {
            depthData = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        return make(depthData, orientation: orientation)
    }

    /// Wraps an AVDepthData (DepthFloat32, sensor orientation) with intrinsics scaled to the map.
    static func make(_ depthData: AVDepthData, orientation: UInt32) -> DepthCapture? {
        let map = depthData.depthDataMap
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        guard width >= 16, height >= 16 else { return nil }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        var depth = [Float](repeating: .nan, count: width * height)
        for y in 0..<height {
            let row = (base + y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<width { depth[y * width + x] = row[x] }
        }
        var fx: Float, fy: Float, cx: Float, cy: Float
        if let calibration = depthData.cameraCalibrationData, calibration.intrinsicMatrixReferenceDimensions.width > 0 {
            let k = calibration.intrinsicMatrix
            let scale = Float(width) / Float(calibration.intrinsicMatrixReferenceDimensions.width)
            fx = k[0][0] * scale; fy = k[1][1] * scale; cx = k[2][0] * scale; cy = k[2][1] * scale
        } else {
            // No calibration: assume the wide camera's ~70° horizontal field of view, centred.
            fx = Float(width) / (2 * tanf(35 * .pi / 180)); fy = fx
            cx = Float(width) / 2; cy = Float(height) / 2
        }
        return DepthCapture(width: width, height: height, depth: depth, fx: fx, fy: fy, cx: cx, cy: cy,
                            orientation: orientation, isAbsolute: depthData.depthDataAccuracy == .absolute)
    }

    /// The depth map position (pixels, sensor frame) of a point given in the upright photo (normalized 0...1).
    func sensorPoint(uprightX u: Double, uprightY v: Double) -> SIMD2<Float> {
        let (s, t): (Double, Double)
        switch orientation {
        case 3: (s, t) = (1 - u, 1 - v)          // 180°
        case 6: (s, t) = (v, 1 - u)              // sensor rotated 90° clockwise for display (portrait)
        case 8: (s, t) = (1 - v, u)              // 90° counter-clockwise
        default: (s, t) = (u, v)
        }
        return SIMD2(Float(s) * Float(width), Float(t) * Float(height))
    }

    /// Bilinear depth at a sensor-frame pixel position, or nil over a hole.
    func sample(_ p: SIMD2<Float>) -> Float? {
        let x = p.x - 0.5, y = p.y - 0.5
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        guard x0 >= 0, y0 >= 0, x0 + 1 < width, y0 + 1 < height else { return nil }
        let fx = x - Float(x0), fy = y - Float(y0)
        let a = depth[y0 * width + x0], b = depth[y0 * width + x0 + 1]
        let c = depth[(y0 + 1) * width + x0], d = depth[(y0 + 1) * width + x0 + 1]
        guard [a, b, c, d].allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
    }

    /// The 3D point (metres, camera frame) seen at a sensor-frame pixel at depth `z`.
    func point(_ p: SIMD2<Float>, depth z: Float) -> SIMD3<Float> {
        SIMD3((p.x - cx) * z / fx, (p.y - cy) * z / fy, z)
    }
}

/// Turns photo depth into tangent-space guide normals for the photographed surface: back-project the crop to 3D, fit
/// the surface plane, and express each (smoothed) surface normal in the plane's tangent frame (+X along the crop's
/// width, +Y up the crop, +Z out of the surface), i.e. the core's guide-normal contract.
enum DepthGuide {
    static let estimatorName = "lidar-depth"

    struct Result {
        let rgba8: [UInt8]
        let size: Int
        let validFraction: Double
        /// Spread of the points about the fitted plane (metres); tiny means a flat surface.
        let planeResidual: Float
        var sha256: String { SHA256.hash(data: rgba8).map { String(format: "%02x", $0) }.joined() }
    }

    /// Guide normals at `size`² for the crop `quad`, or nil when too little of the crop has depth.
    static func normals(_ capture: DepthCapture, quad: PerspectiveQuad, size: Int, grid: Int = 96) -> Result? {
        guard size >= 2, let surface = surfacePoints(capture, quad: quad, grid: grid) else { return nil }
        let filled = surface.points, validFraction = surface.validFraction
        // Plane fit (least squares through the centroid) and its tangent frame.
        let plane = fitPlane(filled)
        let normal = plane.normal, residual = plane.residual
        var along = SIMD3<Float>.zero, down = SIMD3<Float>.zero
        for j in 0..<grid {
            for i in 0..<(grid - 1) { along += filled[j * grid + i + 1] - filled[j * grid + i] }
        }
        for j in 0..<(grid - 1) {
            for i in 0..<grid { down += filled[(j + 1) * grid + i] - filled[j * grid + i] }
        }
        let tangent = simd_normalize(along - simd_dot(along, normal) * normal)
        var up = simd_normalize(simd_cross(normal, tangent))
        if simd_dot(up, down) > 0 { up = -up }   // +Y points up the crop (against increasing v).
        return encodeNormals(filled, grid: grid, size: size, normal: normal, tangent: tangent, up: up,
                             validFraction: validFraction, residual: residual)
    }

    /// The crop back-projected to 3D (metres, camera frame) on a grid, holes filled and smoothed: LiDAR depth is coarse
    /// and noisy, so this carries form, not texture. Nil when less than 60 % of the crop has depth.
    static func surfacePoints(_ capture: DepthCapture, quad: PerspectiveQuad, grid: Int, smoothing: Int = 3)
        -> (points: [SIMD3<Float>], validFraction: Double)? {
        guard grid >= 8 else { return nil }
        let homography = SquareToQuad(quad)
        // 1. 3D points on a grid over the corrected crop.
        var points = [SIMD3<Float>?](repeating: nil, count: grid * grid)
        var valid = 0
        for j in 0..<grid {
            for i in 0..<grid {
                let u = (Double(i) + 0.5) / Double(grid), v = (Double(j) + 0.5) / Double(grid)
                let upright = homography.map(u, v)
                let sensor = capture.sensorPoint(uprightX: upright.x, uprightY: upright.y)
                if let z = capture.sample(sensor) {
                    points[j * grid + i] = capture.point(sensor, depth: z)
                    valid += 1
                }
            }
        }
        let validFraction = Double(valid) / Double(grid * grid)
        guard validFraction >= 0.6 else { return nil }
        var filled = fillHoles(points, grid: grid)
        for _ in 0..<smoothing { filled = boxBlur(filled, grid: grid) }
        return (filled, validFraction)
    }

    /// Least-squares plane through the points: its camera-facing normal, centroid and rms residual (metres).
    static func fitPlane(_ points: [SIMD3<Float>]) -> (normal: SIMD3<Float>, centroid: SIMD3<Float>, residual: Float) {
        let centroid = points.reduce(SIMD3<Float>.zero, +) / Float(points.count)
        var covariance = simd_float3x3()
        for p in points {
            let d = p - centroid
            covariance += simd_float3x3(columns: (d * d.x, d * d.y, d * d.z))
        }
        var normal = smallestEigenvector(covariance)
        if simd_dot(normal, -centroid) < 0 { normal = -normal }   // Face the camera.
        let residual = sqrt(points.map { pow(simd_dot($0 - centroid, normal), 2) }.reduce(0, +) / Float(points.count))
        return (normal, centroid, residual)
    }

    private static func encodeNormals(_ filled: [SIMD3<Float>], grid: Int, size: Int, normal: SIMD3<Float>,
                                      tangent: SIMD3<Float>, up: SIMD3<Float>, validFraction: Double,
                                      residual: Float) -> Result {
        // Per-cell normals from central differences, in the tangent frame.
        var tangentNormals = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: grid * grid)
        for j in 0..<grid {
            for i in 0..<grid {
                let du = filled[j * grid + min(grid - 1, i + 1)] - filled[j * grid + max(0, i - 1)]
                let dv = filled[min(grid - 1, j + 1) * grid + i] - filled[max(0, j - 1) * grid + i]
                var n = simd_normalize(simd_cross(dv, du))
                if simd_dot(n, normal) < 0 { n = -n }
                var t = SIMD3(simd_dot(n, tangent), simd_dot(n, up), max(0.05, simd_dot(n, normal)))
                t = simd_normalize(t)
                tangentNormals[j * grid + i] = t
            }
        }
        // 5. Resample to size² (bilinear on vectors, renormalized) and encode linear RGBA8 (+Y green-up).
        var rgba = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            let gy = min(Float(grid - 1), max(0, (Float(y) + 0.5) / Float(size) * Float(grid) - 0.5))
            let y0 = Int(gy), y1 = min(grid - 1, y0 + 1), fy = gy - Float(y0)
            for x in 0..<size {
                let gx = min(Float(grid - 1), max(0, (Float(x) + 0.5) / Float(size) * Float(grid) - 0.5))
                let x0 = Int(gx), x1 = min(grid - 1, x0 + 1), fx = gx - Float(x0)
                let top = tangentNormals[y0 * grid + x0] * (1 - fx) + tangentNormals[y0 * grid + x1] * fx
                let bottom = tangentNormals[y1 * grid + x0] * (1 - fx) + tangentNormals[y1 * grid + x1] * fx
                let n = simd_normalize(top * (1 - fy) + bottom * fy)
                let o = (y * size + x) * 4
                rgba[o] = encode(n.x); rgba[o + 1] = encode(n.y); rgba[o + 2] = encode(n.z)
            }
        }
        return Result(rgba8: rgba, size: size, validFraction: validFraction, planeResidual: residual)
    }

    /// Averages two guide-normal fields (both linear RGBA8, +Y) with weights, renormalized.
    static func blend(_ a: [UInt8], _ b: [UInt8], weightB: Float) -> [UInt8] {
        var out = a
        for o in stride(from: 0, to: min(a.count, b.count), by: 4) {
            func vector(_ p: [UInt8]) -> SIMD3<Float> {
                SIMD3(Float(p[o]) / 127.5 - 1, Float(p[o + 1]) / 127.5 - 1, Float(p[o + 2]) / 127.5 - 1)
            }
            let n = simd_normalize(vector(a) * (1 - weightB) + vector(b) * weightB)
            out[o] = encode(n.x); out[o + 1] = encode(n.y); out[o + 2] = encode(n.z); out[o + 3] = 255
        }
        return out
    }

    private static func encode(_ v: Float) -> UInt8 { UInt8(max(0, min(255, ((v + 1) * 127.5).rounded()))) }

    private static func fillHoles(_ points: [SIMD3<Float>?], grid: Int) -> [SIMD3<Float>] {
        var current = points
        for _ in 0..<grid where current.contains(where: { $0 == nil }) {
            var next = current
            for j in 0..<grid {
                for i in 0..<grid where current[j * grid + i] == nil {
                    var sum = SIMD3<Float>.zero, count: Float = 0
                    for (di, dj) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                        let ii = i + di, jj = j + dj
                        guard ii >= 0, jj >= 0, ii < grid, jj < grid, let p = current[jj * grid + ii] else { continue }
                        sum += p; count += 1
                    }
                    if count > 0 { next[j * grid + i] = sum / count }
                }
            }
            current = next
        }
        return current.map { $0 ?? .zero }
    }

    private static func boxBlur(_ points: [SIMD3<Float>], grid: Int) -> [SIMD3<Float>] {
        var out = points
        for j in 0..<grid {
            for i in 0..<grid {
                var sum = SIMD3<Float>.zero, count: Float = 0
                for dj in -1...1 {
                    for di in -1...1 {
                        let ii = i + di, jj = j + dj
                        guard ii >= 0, jj >= 0, ii < grid, jj < grid else { continue }
                        sum += points[jj * grid + ii]; count += 1
                    }
                }
                out[j * grid + i] = sum / count
            }
        }
        return out
    }

    /// Eigenvector of the smallest eigenvalue of a symmetric 3×3 matrix (inverse iteration on the shifted matrix).
    private static func smallestEigenvector(_ m: simd_float3x3) -> SIMD3<Float> {
        let trace = m[0][0] + m[1][1] + m[2][2]
        // Power iteration on (trace·I − M) converges to M's smallest eigenvector.
        let shifted = simd_float3x3(diagonal: SIMD3(repeating: trace)) - m
        var v = simd_normalize(SIMD3<Float>(0.1, 0.2, 1))
        for _ in 0..<64 { v = simd_normalize(shifted * v) }
        return v
    }
}

/// The projective map from the unit square (the corrected crop) to a perspective quad in the upright photo.
struct SquareToQuad {
    private let a, b, c, d, e, f, g, h: Double

    init(_ quad: PerspectiveQuad) {
        let x0 = quad.topLeft.x, y0 = quad.topLeft.y, x1 = quad.topRight.x, y1 = quad.topRight.y
        let x2 = quad.bottomRight.x, y2 = quad.bottomRight.y, x3 = quad.bottomLeft.x, y3 = quad.bottomLeft.y
        let dx1 = x1 - x2, dx2 = x3 - x2, dy1 = y1 - y2, dy2 = y3 - y2
        let sx = x0 - x1 + x2 - x3, sy = y0 - y1 + y2 - y3
        let det = dx1 * dy2 - dx2 * dy1
        let gg = abs(det) > 1e-12 ? (sx * dy2 - dx2 * sy) / det : 0
        let hh = abs(det) > 1e-12 ? (dx1 * sy - sx * dy1) / det : 0
        a = x1 - x0 + gg * x1; b = x3 - x0 + hh * x3; c = x0
        d = y1 - y0 + gg * y1; e = y3 - y0 + hh * y3; f = y0
        g = gg; h = hh
    }

    /// (u, v) in the unit square (u right, v down) → normalized upright photo coordinates.
    func map(_ u: Double, _ v: Double) -> (x: Double, y: Double) {
        let w = g * u + h * v + 1
        return ((a * u + b * v + c) / w, (d * u + e * v + f) / w)
    }
}
