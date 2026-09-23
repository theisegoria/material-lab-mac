import Accelerate
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct NormalizedPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double

    func interpolated(to other: Self, fraction: Double) -> Self {
        Self(x: x + (other.x - x) * fraction, y: y + (other.y - y) * fraction)
    }
}

struct PerspectiveQuad: Codable, Equatable, Sendable {
    var topLeft: NormalizedPoint
    var topRight: NormalizedPoint
    var bottomRight: NormalizedPoint
    var bottomLeft: NormalizedPoint

    static let full = Self(topLeft: .init(x: 0, y: 0), topRight: .init(x: 1, y: 0),
                           bottomRight: .init(x: 1, y: 1), bottomLeft: .init(x: 0, y: 1))

    static func centeredSquare(for size: CGSize) -> Self {
        let fraction = min(1, min(Double(size.width), Double(size.height)) /
                           max(Double(size.width), Double(size.height)))
        let xInset = size.width > size.height ? (1 - fraction) / 2 : 0
        let yInset = size.height > size.width ? (1 - fraction) / 2 : 0
        return Self(topLeft: .init(x: xInset, y: yInset),
                    topRight: .init(x: 1 - xInset, y: yInset),
                    bottomRight: .init(x: 1 - xInset, y: 1 - yInset),
                    bottomLeft: .init(x: xInset, y: 1 - yInset))
    }

    var isValid: Bool {
        let points = [topLeft, topRight, bottomRight, bottomLeft]
        guard points.allSatisfy({ (0...1).contains($0.x) && (0...1).contains($0.y) }) else { return false }
        var signedArea = 0.0
        for index in 0..<4 {
            let current = points[index]
            let next = points[(index + 1) % 4]
            signedArea += current.x * next.y - next.x * current.y
        }
        return signedArea > 0.02 && topLeft.x < topRight.x && bottomLeft.x < bottomRight.x &&
               topLeft.y < bottomLeft.y && topRight.y < bottomRight.y
    }

    func point(at corner: CropCorner) -> NormalizedPoint {
        switch corner {
        case .topLeft: topLeft
        case .topRight: topRight
        case .bottomRight: bottomRight
        case .bottomLeft: bottomLeft
        }
    }

    mutating func set(_ point: NormalizedPoint, at corner: CropCorner) {
        switch corner {
        case .topLeft: topLeft = point
        case .topRight: topRight = point
        case .bottomRight: bottomRight = point
        case .bottomLeft: bottomLeft = point
        }
    }

    /// Moves each corner toward the opposite corner by `fraction` of the diagonal.
    func inset(by fraction: Double) -> Self {
        Self(topLeft: topLeft.interpolated(to: bottomRight, fraction: fraction),
             topRight: topRight.interpolated(to: bottomLeft, fraction: fraction),
             bottomRight: bottomRight.interpolated(to: topLeft, fraction: fraction),
             bottomLeft: bottomLeft.interpolated(to: topRight, fraction: fraction))
    }

    /// Bilinear point inside the quad at (u, v) in [0,1]².
    func interpolate(u: Double, v: Double) -> NormalizedPoint {
        let top = topLeft.interpolated(to: topRight, fraction: u)
        let bottom = bottomLeft.interpolated(to: bottomRight, fraction: u)
        return top.interpolated(to: bottom, fraction: v)
    }
}

enum CropCorner: String, CaseIterable, Identifiable {
    case topLeft, topRight, bottomRight, bottomLeft
    var id: String { rawValue }
    var label: String {
        switch self {
        case .topLeft: "Top left"
        case .topRight: "Top right"
        case .bottomRight: "Bottom right"
        case .bottomLeft: "Bottom left"
        }
    }
}

/// Interactive four-corner perspective editor over a display-sized copy of the source.
struct PerspectiveCropView: View {
    let image: CGImage
    @Binding var quad: PerspectiveQuad
    var showsGrid = true
    var interactive = true
    @State private var activeCorner: CropCorner?

    var body: some View {
        GeometryReader { geometry in
            let imageSize = CGSize(width: image.width, height: image.height)
            let scale = min(geometry.size.width / imageSize.width, geometry.size.height / imageSize.height)
            let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let origin = CGPoint(x: (geometry.size.width - fitted.width) / 2,
                                 y: (geometry.size.height - fitted.height) / 2)
            let map: (NormalizedPoint) -> CGPoint = { p in
                CGPoint(x: origin.x + fitted.width * p.x, y: origin.y + fitted.height * p.y)
            }
            ZStack {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fitted.width, height: fitted.height)
                    .position(x: origin.x + fitted.width / 2, y: origin.y + fitted.height / 2)

                // Dim everything outside the selected material.
                Path { path in
                    path.addRect(CGRect(origin: origin, size: fitted))
                    path.addLines(CropCorner.allCases.map { map(quad.point(at: $0)) })
                    path.closeSubpath()
                }
                .fill(.black.opacity(0.5), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                if showsGrid {
                    Path { path in
                        for step in 1..<3 {
                            let t = Double(step) / 3
                            path.move(to: map(quad.interpolate(u: t, v: 0)))
                            path.addLine(to: map(quad.interpolate(u: t, v: 1)))
                            path.move(to: map(quad.interpolate(u: 0, v: t)))
                            path.addLine(to: map(quad.interpolate(u: 1, v: t)))
                        }
                    }
                    .stroke(.white.opacity(0.45), lineWidth: 0.75)
                    .allowsHitTesting(false)
                }

                Path { path in
                    path.addLines(CropCorner.allCases.map { map(quad.point(at: $0)) })
                    path.closeSubpath()
                }
                .stroke(quad.isValid ? Color.white : Color.orange,
                        style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                .shadow(color: .black.opacity(0.4), radius: 2)
                .allowsHitTesting(false)

                if interactive {
                    ForEach(CropCorner.allCases) { corner in
                        let point = map(quad.point(at: corner))
                        ZStack {
                            Circle().fill(.clear).frame(width: 48, height: 48).contentShape(Circle())
                            Circle()
                                .fill(.white)
                                .frame(width: activeCorner == corner ? 26 : 20,
                                       height: activeCorner == corner ? 26 : 20)
                                .overlay(Circle().stroke(Color.accentColor, lineWidth: 3))
                                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        }
                        .position(point)
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("materialCrop"))
                                .onChanged { value in
                                    activeCorner = corner
                                    let x = min(1, max(0, (value.location.x - origin.x) / fitted.width))
                                    let y = min(1, max(0, (value.location.y - origin.y) / fitted.height))
                                    quad.set(.init(x: x, y: y), at: corner)
                                }
                                .onEnded { _ in activeCorner = nil }
                        )
                        .sensoryFeedback(.selection, trigger: activeCorner == corner)
                        .accessibilityElement()
                        .accessibilityLabel("Crop \(corner.label)")
                        .accessibilityValue(String(format: "%.0f%% across, %.0f%% down",
                                                   quad.point(at: corner).x * 100, quad.point(at: corner).y * 100))
                        .accessibilityHint("Drag to the material corner")
                        .accessibilityAdjustableAction { direction in
                            var p = quad.point(at: corner)
                            p.x = min(1, max(0, p.x + (direction == .increment ? 0.01 : -0.01)))
                            quad.set(p, at: corner)
                        }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .coordinateSpace(name: "materialCrop")
        }
    }
}

enum PerspectiveCropper {
    /// Linear-light resampling; results are encoded to sRGB on output.
    static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        .cacheIntermediates: false
    ])

    /// Perspective-corrects and resamples to a `pixels`² straight-alpha sRGB RGBA8 buffer (top row first).
    static func correctedRGBA8(_ cgImage: CGImage, quad: PerspectiveQuad, pixels: Int) throws -> [UInt8] {
        guard quad.isValid, (256...4096).contains(pixels),
              cgImage.width > 0, cgImage.height > 0 else { throw CaptureError.invalidCrop }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = CIImage(cgImage: cgImage)
        func point(_ p: NormalizedPoint) -> CGPoint { CGPoint(x: p.x * width, y: (1 - p.y) * height) }
        filter.topLeft = point(quad.topLeft)
        filter.topRight = point(quad.topRight)
        filter.bottomRight = point(quad.bottomRight)
        filter.bottomLeft = point(quad.bottomLeft)
        guard let corrected = filter.outputImage, !corrected.extent.isInfinite,
              corrected.extent.width >= 1, corrected.extent.height >= 1 else { throw CaptureError.invalidCrop }
        let extent = corrected.extent
        let scaleX = CGFloat(pixels) / extent.width
        let scaleY = CGFloat(pixels) / extent.height
        let lanczos = CIFilter.lanczosScaleTransform()
        // Clamp so edge pixels are not blended with transparent black while resampling.
        lanczos.inputImage = corrected.clampedToExtent()
        lanczos.scale = Float(scaleY)
        lanczos.aspectRatio = Float(scaleX / scaleY)
        guard let scaled = lanczos.outputImage else { throw CaptureError.invalidCrop }
        let bounds = CGRect(x: (extent.minX * scaleX).rounded(), y: (extent.minY * scaleY).rounded(),
                            width: CGFloat(pixels), height: CGFloat(pixels))
        let output = scaled.cropped(to: bounds)
        var bytes = [UInt8](repeating: 0, count: pixels * pixels * 4)
        bytes.withUnsafeMutableBytes { buffer in
            context.render(output, toBitmap: buffer.baseAddress!, rowBytes: pixels * 4, bounds: bounds,
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            var vbuffer = vImage_Buffer(data: buffer.baseAddress, height: vImagePixelCount(pixels),
                                        width: vImagePixelCount(pixels), rowBytes: pixels * 4)
            // Core Image renders premultiplied alpha; the core expects straight alpha.
            vImageUnpremultiplyData_RGBA8888(&vbuffer, &vbuffer, vImage_Flags(kvImageNoFlags))
        }
        return bytes
    }
}
