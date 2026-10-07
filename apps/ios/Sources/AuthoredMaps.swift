import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// Artist-made inputs for a capture: the source marked as a hand-made albedo, and maps that replace the derived
/// ones. Stored as the original image data (saved beside the capture), decoded as data at each derivation size.
struct AuthoredMaps: Sendable, Equatable {
    enum Role: String, CaseIterable, Identifiable, Codable, Sendable {
        case height, normal, roughness, ao, metalness, reliefMask
        var id: String { rawValue }
        /// The relief mask steers the estimate instead of replacing a map; it is recorded in the recipe.
        var replacesMap: Bool { self != .reliefMask }
        var title: String { L(englishTitle) }
        var englishTitle: String {
            switch self {
            case .height: "Height map"
            case .normal: "Normal map"
            case .roughness: "Roughness map"
            case .ao: "Occlusion map"
            case .metalness: "Metalness map"
            case .reliefMask: "Relief mask"
            }
        }
        var symbol: String {
            switch self {
            case .height: "mountain.2"
            case .normal: "cube.transparent"
            case .roughness: "circle.dotted"
            case .ao: "circle.lefthalf.filled"
            case .metalness: "gearshape"
            case .reliefMask: "circle.lefthalf.striped.horizontal"
            }
        }
        var explanation: String { L(englishExplanation) }
        var englishExplanation: String {
            switch self {
            case .height: "Grayscale height (white is high). 16-bit keeps full precision."
            case .normal: "Tangent-space normal map; also drives height, AO and the masks."
            case .roughness: "Grayscale roughness: white is rough."
            case .ao: "Grayscale ambient occlusion: white is open."
            case .metalness: "Grayscale metalness: white is metal."
            case .reliefMask: "Grayscale mask: black flattens the estimated relief, white keeps it."
            }
        }
    }

    struct Map: Sendable, Equatable {
        let data: Data
        let name: String
        var sha256: String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    }

    /// The source is painted or drawn, not photographed: it is used without perspective correction.
    var handMadeAlbedo = false
    var normalDirectX = false
    var maps: [Role: Map] = [:]

    var isEmpty: Bool { !handMadeAlbedo && maps.isEmpty }
    /// Authored height or normals supply the geometry, so learned inference is skipped.
    var hasGeometry: Bool { maps[.height] != nil || maps[.normal] != nil }

    /// Checks that `data` decodes as an image before it is accepted.
    static func isDecodable(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }

    /// Decoded maps at one size, owned until `free()`; pointers are valid for PBRLabInput.
    final class Decoded {
        var normal: UnsafeMutableBufferPointer<UInt8>?
        var roughness: UnsafeMutableBufferPointer<UInt8>?
        var ao: UnsafeMutableBufferPointer<UInt8>?
        var metalness: UnsafeMutableBufferPointer<UInt8>?
        var height: UnsafeMutableBufferPointer<UInt8>?   // R16 little-endian
        var reliefMask: UnsafeMutableBufferPointer<UInt8>?
        deinit { [normal, roughness, ao, metalness, height, reliefMask].forEach { $0?.deallocate() } }
    }

    /// Decodes every map without colour management, center-cropped to a square and resampled to `size`².
    func decoded(size: Int) throws -> Decoded {
        let result = Decoded()
        for (role, map) in maps {
            switch role {
            case .normal:
                let buffer = try Self.decode(map.data, size: size, channels: 4, sixteen: false)
                if normalDirectX { for i in stride(from: 1, to: buffer.count, by: 4) { buffer[i] = 255 &- buffer[i] } }
                result.normal = buffer
            case .roughness: result.roughness = try Self.decode(map.data, size: size, channels: 1, sixteen: false)
            case .ao: result.ao = try Self.decode(map.data, size: size, channels: 1, sixteen: false)
            case .metalness: result.metalness = try Self.decode(map.data, size: size, channels: 1, sixteen: false)
            case .height: result.height = try Self.decode(map.data, size: size, channels: 1, sixteen: true)
            case .reliefMask: result.reliefMask = try Self.decode(map.data, size: size, channels: 1, sixteen: false)
            }
        }
        return result
    }

    private static func decode(_ data: Data, size: Int, channels: Int, sixteen: Bool) throws -> UnsafeMutableBufferPointer<UInt8> {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CaptureError.invalidImage }
        let bytesPerSample = sixteen ? 2 : 1
        let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: size * size * channels * bytesPerSample)
        buffer.initialize(repeating: 0)
        let space = channels == 4 ? CGColorSpaceCreateDeviceRGB() : CGColorSpaceCreateDeviceGray()
        let info = channels == 4 ? CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            : CGImageAlphaInfo.none.rawValue | (sixteen ? CGBitmapInfo.byteOrder16Little.rawValue : 0)
        guard let context = CGContext(data: buffer.baseAddress, width: size, height: size,
                                      bitsPerComponent: sixteen ? 16 : 8, bytesPerRow: size * channels * bytesPerSample,
                                      space: space, bitmapInfo: info) else {
            buffer.deallocate()
            throw CaptureError.invalidImage
        }
        context.interpolationQuality = .high
        context.setBlendMode(.copy)
        let side = CGFloat(min(image.width, image.height)), scale = CGFloat(size) / side
        context.draw(image, in: CGRect(x: -(CGFloat(image.width) - side) * scale / 2,
                                       y: -(CGFloat(image.height) - side) * scale / 2,
                                       width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale))
        if channels == 4 { for i in stride(from: 3, to: buffer.count, by: 4) { buffer[i] = 255 } }
        return buffer
    }
}
