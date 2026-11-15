import AVFoundation
import Foundation
import simd

/// Recent LiDAR depth frames streamed while the user frames the shot (sensor orientation). A single depth frame is
/// centimetre-noisy; averaging the frames of the second before the shutter, after dropping frames taken while the
/// phone moved, lowers the noise and yields a per-pixel confidence.
struct DepthStack: Sendable {
    /// About a second of LiDAR depth at 30 Hz.
    static let capacity = 30
    private(set) var frames: [DepthCapture] = []

    mutating func add(_ frame: DepthCapture) {
        if let last = frames.last, last.width != frame.width || last.height != frame.height { frames.removeAll() }
        frames.append(frame)
        if frames.count > Self.capacity { frames.removeFirst(frames.count - Self.capacity) }
    }

    mutating func removeAll() { frames.removeAll() }

    /// Mean depth change (metres) between two frames over pixels valid in both, or nil if they barely overlap.
    static func meanDifference(_ a: DepthCapture, _ b: DepthCapture) -> Float? {
        guard a.width == b.width, a.height == b.height else { return nil }
        var sum: Float = 0, count = 0
        for i in Swift.stride(from: 0, to: a.depth.count, by: 3) {
            let x = a.depth[i], y = b.depth[i]
            guard x.isFinite, y.isFinite, x > 0, y > 0 else { continue }
            sum += abs(x - y); count += 1
        }
        return count * 3 >= a.depth.count / 4 ? sum / Float(count) : nil
    }

    /// The frames consistent with the newest one: frames from before the phone moved are dropped.
    static func steadyFrames(_ frames: [DepthCapture], motionLimit: Float = 0.012) -> [DepthCapture] {
        guard let reference = frames.last else { return [] }
        return frames.filter { frame in (meanDifference(frame, reference) ?? .infinity) <= motionLimit }
    }

    /// Per-pixel robust average of the steady frames, oriented as the photo (`orientation`, EXIF). Pixels seen in too
    /// few frames, or whose readings scatter more than LiDAR noise explains, become holes; `confidence` records the
    /// rest (255 = every frame agreed). Nil without at least one frame.
    static func average(_ frames: [DepthCapture], orientation: UInt32, minimumConfidence: Float = 0.3) -> DepthCapture? {
        let steady = steadyFrames(frames)
        guard let reference = steady.last else { return nil }
        let count = steady.count
        let pixels = reference.width * reference.height
        var depth = [Float](repeating: .nan, count: pixels)
        var confidence = [UInt8](repeating: 0, count: pixels)
        var samples = [Float](repeating: 0, count: count)
        for p in 0..<pixels {
            var n = 0
            for frame in steady {
                let z = frame.depth[p]
                if z.isFinite, z > 0 { samples[n] = z; n += 1 }
            }
            // Seen in at least half the frames (all of them when there are only one or two).
            guard n > 0, n * 2 >= count || n == count else { continue }
            var values = Array(samples[0..<n])
            values.sort()
            let median = values[n / 2]
            var deviations = values.map { abs($0 - median) }
            deviations.sort()
            let mad = deviations[n / 2] * 1.4826
            let keep = max(3 * mad, 0.002)
            var sum: Float = 0, squares: Float = 0, kept = 0
            for z in values where abs(z - median) <= keep { sum += z; squares += z * z; kept += 1 }
            let mean = sum / Float(kept)
            let spread = sqrt(max(0, squares / Float(kept) - mean * mean))
            // iPhone LiDAR: a few millimetres plus about half a percent of the range per frame.
            let noise = 0.004 + 0.005 * mean
            let agreement = max(0, 1 - spread / (3 * noise))
            let c = Float(kept) / Float(count) * agreement
            guard c >= minimumConfidence else { continue }
            depth[p] = mean
            confidence[p] = UInt8(max(1, min(255, (c * 255).rounded())))
        }
        return DepthCapture(width: reference.width, height: reference.height, depth: depth,
                            fx: reference.fx, fy: reference.fy, cx: reference.cx, cy: reference.cy,
                            orientation: orientation, isAbsolute: reference.isAbsolute,
                            confidence: confidence, frames: count)
    }
}

// MARK: - Sidecar file

extension DepthCapture {
    private static let magic: [UInt8] = Array("MLD1".utf8)

    /// A compact little-endian file for averaged depth, kept beside a capture: the photo's embedded depth can only
    /// hold one frame, and re-embedding edited depth drops the camera calibration (AVDepthData.replacingDepthDataMap).
    func encoded() -> Data {
        var data = Data(Self.magic)
        func put<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        put(UInt32(width).littleEndian); put(UInt32(height).littleEndian)
        for v in [fx, fy, cx, cy] { put(v.bitPattern.littleEndian) }
        put(orientation.littleEndian)
        put(UInt8(isAbsolute ? 1 : 0)); put(UInt16(clamping: frames).littleEndian)
        put(UInt8(confidence == nil ? 0 : 1))
        for z in depth { put(z.bitPattern.littleEndian) }
        if let confidence { data.append(contentsOf: confidence) }
        return data
    }

    init?(encoded data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 36, Array(bytes[0..<4]) == Self.magic else { return nil }
        var offset = 4
        func u32() -> UInt32 {
            defer { offset += 4 }
            return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        let width = Int(u32()), height = Int(u32())
        let fx = Float(bitPattern: u32()), fy = Float(bitPattern: u32())
        let cx = Float(bitPattern: u32()), cy = Float(bitPattern: u32())
        let orientation = u32()
        let absolute = bytes[offset] != 0
        let frames = Int(UInt16(bytes[offset + 1]) | UInt16(bytes[offset + 2]) << 8)
        let hasConfidence = bytes[offset + 3] != 0
        offset += 4
        let pixels = width * height
        guard width >= 16, height >= 16, width <= 4096, height <= 4096,
              bytes.count == offset + pixels * 4 + (hasConfidence ? pixels : 0) else { return nil }
        var depth = [Float](repeating: 0, count: pixels)
        for i in 0..<pixels { depth[i] = Float(bitPattern: u32()) }
        let confidence = hasConfidence ? Array(bytes[offset..<(offset + pixels)]) : nil
        self.init(width: width, height: height, depth: depth, fx: fx, fy: fy, cx: cx, cy: cy,
                  orientation: orientation, isAbsolute: absolute, confidence: confidence, frames: max(1, frames))
    }

    /// Mean confidence over the pixels that have depth (1 for a single photo frame, which carries none).
    var meanConfidence: Float {
        guard let confidence else { return 1 }
        var sum = 0, n = 0
        for (z, c) in zip(depth, confidence) where z.isFinite && z > 0 { sum += Int(c); n += 1 }
        return n == 0 ? 0 : Float(sum) / Float(n) / 255
    }
}

// MARK: - Measurement and band split

/// What the depth says about the photographed surface: its real size, and how the guide was built.
struct DepthMeasurement: Sendable, Equatable {
    /// Width and height of the corrected crop on the surface, in metres.
    let widthMetres: Float
    let heightMetres: Float
    let validFraction: Double
    /// Spread of the surface about its fitted plane, metres.
    let planeResidual: Float
    /// Depth frames averaged (1 = the photo's own depth map).
    let frames: Int
    let meanConfidence: Float
}

extension DepthGuide {
    /// The crop's real width and height (absolute depth only), from unsmoothed back-projected points (smoothing
    /// would pull the edges inward): a straight line fitted along every row and column gives the 3D step per grid
    /// cell, which averages out depth noise and is exact on a plane.
    static func measure(_ capture: DepthCapture, quad: PerspectiveQuad, grid: Int = 48) -> DepthMeasurement? {
        guard capture.isAbsolute, let surface = surfacePoints(capture, quad: quad, grid: grid, smoothing: 0) else { return nil }
        let points = surface.points
        /// Least-squares slope (metres per cell) of points[k] against k.
        func step(_ line: [SIMD3<Float>]) -> Float {
            let n = Float(line.count), mean = Float(line.count - 1) / 2
            let centroid = line.reduce(SIMD3<Float>.zero, +) / n
            var num = SIMD3<Float>.zero, den: Float = 0
            for (k, p) in line.enumerated() { let t = Float(k) - mean; num += t * (p - centroid); den += t * t }
            return simd_length(num / den)
        }
        var width: Float = 0, height: Float = 0
        for j in 0..<grid { width += step(Array(points[(j * grid)..<(j * grid + grid)])) }
        for i in 0..<grid { height += step((0..<grid).map { points[$0 * grid + i] }) }
        // Grid cells tile the crop, so the crop is `grid` steps across.
        width = width / Float(grid) * Float(grid)
        height = height / Float(grid) * Float(grid)
        guard width.isFinite, height.isFinite, width > 0.005, height > 0.005 else { return nil }
        let plane = fitPlane(points)
        return DepthMeasurement(widthMetres: width, heightMetres: height, validFraction: surface.validFraction,
                                planeResidual: plane.residual, frames: capture.frames,
                                meanConfidence: capture.meanConfidence)
    }

    /// Measured form below a cutoff from `low` (depth normals), learned detail above it from `high` (both linear RGBA8
    /// +Y at `size`²). The split is done on surface slopes, which both fields express in real units.
    static func splitBands(low: [UInt8], high: [UInt8], size: Int, cutoff: Int? = nil) -> [UInt8] {
        let radius = cutoff ?? max(2, size / 64)
        func slopes(_ rgba: [UInt8]) -> (gx: [Float], gy: [Float]) {
            var gx = [Float](repeating: 0, count: size * size), gy = gx
            for i in 0..<(size * size) {
                let nx = Float(rgba[i * 4]) / 127.5 - 1, ny = Float(rgba[i * 4 + 1]) / 127.5 - 1
                let nz = max(Float(rgba[i * 4 + 2]) / 127.5 - 1, 0.15)
                gx[i] = -nx / nz; gy[i] = ny / nz
            }
            return (gx, gy)
        }
        let measured = slopes(low), learned = slopes(high)
        let learnedLowX = blur(learned.gx, size: size, radius: radius), learnedLowY = blur(learned.gy, size: size, radius: radius)
        var out = [UInt8](repeating: 255, count: size * size * 4)
        for i in 0..<(size * size) {
            let gx = measured.gx[i] + learned.gx[i] - learnedLowX[i]
            let gy = measured.gy[i] + learned.gy[i] - learnedLowY[i]
            let n = simd_normalize(SIMD3<Float>(-gx, gy, 1))
            out[i * 4] = encodeUnit(n.x); out[i * 4 + 1] = encodeUnit(n.y); out[i * 4 + 2] = encodeUnit(n.z)
        }
        return out
    }

    static func encodeUnit(_ v: Float) -> UInt8 { UInt8(max(0, min(255, ((v + 1) * 127.5).rounded()))) }

    /// Three passes of a separable box blur (close to a Gaussian), clamped at the edges.
    static func blur(_ values: [Float], size: Int, radius: Int) -> [Float] {
        var current = values
        var temp = values
        for _ in 0..<3 {
            for y in 0..<size {
                var sum: Float = 0
                for k in -radius...radius { sum += current[y * size + min(size - 1, max(0, k))] }
                for x in 0..<size {
                    temp[y * size + x] = sum / Float(2 * radius + 1)
                    sum += current[y * size + min(size - 1, x + radius + 1)] - current[y * size + max(0, x - radius)]
                }
            }
            for x in 0..<size {
                var sum: Float = 0
                for k in -radius...radius { sum += temp[min(size - 1, max(0, k)) * size + x] }
                for y in 0..<size {
                    current[y * size + x] = sum / Float(2 * radius + 1)
                    sum += temp[min(size - 1, y + radius + 1) * size + x] - temp[max(0, y - radius) * size + x]
                }
            }
        }
        return current
    }
}

// MARK: - Streaming frames

extension DepthCapture {
    /// A streamed depth frame (sensor orientation) for the stack; disparity is converted to depth.
    static func frame(_ depthData: AVDepthData) -> DepthCapture? {
        let converted = depthData.depthDataType == kCVPixelFormatType_DepthFloat32
            ? depthData : depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        return make(converted, orientation: 1)
    }

    /// This capture re-labelled with the photo's orientation.
    func oriented(_ orientation: UInt32) -> DepthCapture {
        DepthCapture(width: width, height: height, depth: depth, fx: fx, fy: fy, cx: cx, cy: cy,
                     orientation: orientation, isAbsolute: isAbsolute, confidence: confidence, frames: frames)
    }
}
