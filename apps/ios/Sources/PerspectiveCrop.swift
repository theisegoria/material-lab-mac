import CoreImage
import SwiftUI

struct NormalizedPoint: Codable, Equatable {
    var x: Double
    var y: Double

    func interpolated(to other: Self, fraction: Double) -> Self {
        Self(x: x + (other.x - x) * fraction, y: y + (other.y - y) * fraction)
    }
}

struct PerspectiveQuad: Codable, Equatable {
    var topLeft: NormalizedPoint
    var topRight: NormalizedPoint
    var bottomRight: NormalizedPoint
    var bottomLeft: NormalizedPoint

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

struct PerspectiveCropView: View {
    let image: UIImage
    @Binding var quad: PerspectiveQuad

    var body: some View {
        GeometryReader { geometry in
            let imageSize = image.size
            let scale = min(geometry.size.width / imageSize.width,
                            geometry.size.height / imageSize.height)
            let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let origin = CGPoint(x: (geometry.size.width - fitted.width) / 2,
                                 y: (geometry.size.height - fitted.height) / 2)
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fitted.width, height: fitted.height)
                    .position(x: origin.x + fitted.width / 2, y: origin.y + fitted.height / 2)
                Path { path in
                    let points = CropCorner.allCases.map { corner -> CGPoint in
                        let normalized = quad.point(at: corner)
                        return CGPoint(x: origin.x + fitted.width * normalized.x,
                                       y: origin.y + fitted.height * normalized.y)
                    }
                    path.addLines(points)
                    path.closeSubpath()
                }
                .stroke(.yellow, lineWidth: 2)
                ForEach(CropCorner.allCases) { corner in
                    let point = quad.point(at: corner)
                    Circle()
                        .fill(.yellow)
                        .stroke(.black, lineWidth: 2)
                        .frame(width: 30, height: 30)
                        .position(x: origin.x + fitted.width * point.x,
                                  y: origin.y + fitted.height * point.y)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("materialCrop")).onChanged { value in
                            let x = min(1, max(0, (value.location.x - origin.x) / fitted.width))
                            let y = min(1, max(0, (value.location.y - origin.y) / fitted.height))
                            quad.set(.init(x: x, y: y), at: corner)
                        })
                        .accessibilityLabel("Crop \(corner.label)")
                        .accessibilityHint("Drag to the material corner")
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .coordinateSpace(name: "materialCrop")
        }
    }
}

enum PerspectiveCropper {
    static func normalized(_ image: UIImage) throws -> UIImage {
        guard let cgImage = image.cgImage,
              cgImage.width > 0, cgImage.height > 0 else { throw CaptureError.invalidImage }
        if image.imageOrientation == .up { return image }
        let rotated: Bool
        switch image.imageOrientation {
        case .left, .right, .leftMirrored, .rightMirrored: rotated = true
        default: rotated = false
        }
        let outputSize = rotated
            ? CGSize(width: cgImage.height, height: cgImage.width)
            : CGSize(width: cgImage.width, height: cgImage.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: outputSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: outputSize))
        }
    }

    static func cropped(_ image: UIImage, quad: PerspectiveQuad, pixels: Int) throws -> UIImage {
        guard quad.isValid, pixels >= 256, pixels <= 4096,
              let cgImage = image.cgImage else { throw CaptureError.invalidCrop }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let input = CIImage(cgImage: cgImage)
        let filter = CIFilter(name: "CIPerspectiveCorrection")!
        filter.setValue(input, forKey: kCIInputImageKey)
        func point(_ p: NormalizedPoint) -> CIVector {
            CIVector(x: p.x * width, y: (1 - p.y) * height)
        }
        filter.setValue(point(quad.topLeft), forKey: "inputTopLeft")
        filter.setValue(point(quad.topRight), forKey: "inputTopRight")
        filter.setValue(point(quad.bottomRight), forKey: "inputBottomRight")
        filter.setValue(point(quad.bottomLeft), forKey: "inputBottomLeft")
        guard let output = filter.outputImage,
              !output.extent.isEmpty,
              output.extent.width > 0,
              output.extent.height > 0 else { throw CaptureError.invalidCrop }
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.workingColorSpace: sRGB, .outputColorSpace: sRGB])
        guard let corrected = context.createCGImage(output, from: output.extent,
                                                     format: .RGBA8, colorSpace: sRGB) else {
            throw CaptureError.invalidCrop
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: pixels, height: pixels),
                                       format: format).image { context in
            context.cgContext.interpolationQuality = .high
            UIImage(cgImage: corrected).draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        }
    }
}
