import Accelerate
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Vision

/// Albedo from a flash / no-flash pair, for iPhones without Constant Color. The flash sits beside the lens, so light
/// that only the flash contributed casts almost no visible shadows: subtracting the ambient photo (scaled by the
/// exposure difference) leaves albedo × flash irradiance, and dividing out the flash's smooth fall-off leaves albedo.
enum FlashPairAlbedo {
    struct Exposure: Sendable {
        let iso: Double
        let seconds: Double
        var product: Double { iso * seconds }

        /// ISO and exposure time from a photo's EXIF.
        static func read(from data: Data) -> Exposure? {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
                  let seconds = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue,
                  let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.doubleValue,
                  seconds > 0, iso > 0 else { return nil }
            return Exposure(iso: iso, seconds: seconds)
        }
    }

    enum Failure: LocalizedError {
        case unreadable, registration, tooLittleFlash
        var errorDescription: String? {
            switch self {
            case .unreadable: String(localized: "The flash pair could not be read.")
            case .registration: String(localized: "The two flash-pair photos could not be aligned; hold the phone steady.")
            case .tooLittleFlash: String(localized: "The flash barely reached the surface; move closer or use the normal photo.")
            }
        }
    }

    /// Builds the albedo photo (PNG data, sRGB) from the ambient and flash photo files.
    static func albedoPNG(ambient: Data, flash: Data) throws -> Data {
        guard let ambientImage = decode(ambient), let flashImage = decode(flash) else { throw Failure.unreadable }
        let ratio = exposureRatio(ambient: Exposure.read(from: ambient), flash: Exposure.read(from: flash))
        let aligned = try align(ambientImage, to: flashImage)
        let albedo = try compute(ambient: aligned, flash: flashImage, flashToAmbientExposure: ratio)
        guard let png = encodePNG(albedo) else { throw Failure.unreadable }
        return png
    }

    /// How much brighter the flash photo's exposure is than the ambient photo's (ISO × time).
    static func exposureRatio(ambient: Exposure?, flash: Exposure?) -> Float {
        guard let ambient, let flash, ambient.product > 0 else { return 1 }
        return Float(flash.product / ambient.product)
    }

    /// The core: both images the same size, upright. `flashToAmbientExposure` scales the ambient light that is also
    /// present in the flash photo. Returns an sRGB RGBA8 image of the estimated albedo.
    static func compute(ambient: CGImage, flash: CGImage, flashToAmbientExposure k: Float) throws -> CGImage {
        let width = flash.width, height = flash.height
        guard let a = linearRGB(ambient, width: width, height: height),
              let f = linearRGB(flash, width: width, height: height) else { throw Failure.unreadable }
        let count = width * height
        // Flash-only light per channel; clamp tiny negatives from noise and slight misregistration.
        var flashOnly = [Float](repeating: 0, count: count * 3)
        var flashLuma = [Float](repeating: 0, count: count)
        var ambientLumaSum: Double = 0, flashOnlyLumaSum: Double = 0
        for i in 0..<count {
            var luma: Float = 0
            for c in 0..<3 {
                let value = max(0, f[i * 3 + c] - k * a[i * 3 + c])
                flashOnly[i * 3 + c] = value
                luma += value * [0.2126, 0.7152, 0.0722][c]
            }
            flashLuma[i] = luma
            flashOnlyLumaSum += Double(luma)
            ambientLumaSum += Double(0.2126 * a[i * 3] + 0.7152 * a[i * 3 + 1] + 0.0722 * a[i * 3 + 2])
        }
        guard flashOnlyLumaSum / Double(count) > 0.002 else { throw Failure.tooLittleFlash }
        // The flash's fall-off (inverse-square distance and beam shape) is smooth and close to quadratic in log space,
        // so fit a 2D quadratic to log flash-only luminance: the surface texture averages out of a global fit instead
        // of leaking into a local blur. Dividing it out leaves albedo up to one scale.
        let falloff = quadraticFalloff(flashLuma, width: width, height: height)
        let ambientMean = Float(ambientLumaSum / Double(count))
        // Rescale so the albedo keeps the ambient photo's overall brightness.
        var scaled = [Float](repeating: 0, count: count * 3)
        var meanAfter: Double = 0
        for i in 0..<count {
            let norm = max(falloff[i], 1e-4)
            for c in 0..<3 { scaled[i * 3 + c] = flashOnly[i * 3 + c] / norm }
            meanAfter += Double(0.2126 * scaled[i * 3] + 0.7152 * scaled[i * 3 + 1] + 0.0722 * scaled[i * 3 + 2])
        }
        let gain = ambientMean / max(Float(meanAfter / Double(count)), 1e-6)
        var rgba = [UInt8](repeating: 255, count: count * 4)
        for i in 0..<count {
            for c in 0..<3 { rgba[i * 4 + c] = encodeSRGB(scaled[i * 3 + c] * gain) }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw Failure.unreadable }
        return image
    }

    // MARK: Helpers

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // Upright and capped at 3024 px, like the working image.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 3024]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Warps the ambient photo onto the flash photo (Vision homographic registration).
    static func align(_ ambient: CGImage, to flash: CGImage) throws -> CGImage {
        let request = VNHomographicImageRegistrationRequest(targetedCGImage: ambient)
        let handler = VNImageRequestHandler(cgImage: flash)
        do { try handler.perform([request]) } catch { throw Failure.registration }
        guard let observation = request.results?.first else { throw Failure.registration }
        let warp = observation.warpTransform
        let ambientImage = CIImage(cgImage: ambient)
        // Vision's warp maps the target (ambient) into the reference (flash) frame.
        let filter = CIFilter(name: "CIPerspectiveTransform")!
        func corner(_ x: Double, _ y: Double) -> CIVector {
            let p = warp * SIMD3<Float>(Float(x), Float(y), 1)
            return CIVector(x: CGFloat(p.x / p.z), y: CGFloat(p.y / p.z))
        }
        let w = Double(ambient.width), h = Double(ambient.height)
        filter.setValue(ambientImage, forKey: kCIInputImageKey)
        filter.setValue(corner(0, h), forKey: "inputTopLeft")
        filter.setValue(corner(w, h), forKey: "inputTopRight")
        filter.setValue(corner(w, 0), forKey: "inputBottomRight")
        filter.setValue(corner(0, 0), forKey: "inputBottomLeft")
        let bounds = CGRect(x: 0, y: 0, width: flash.width, height: flash.height)
        guard let output = filter.outputImage?.cropped(to: bounds),
              let aligned = CIContext().createCGImage(output, from: bounds) else { throw Failure.registration }
        return aligned
    }

    /// Linear-light RGB floats (0...1) at `width`×`height`.
    private static func linearRGB(_ image: CGImage, width: Int, height: Int) -> [Float]? {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var lut = [Float](repeating: 0, count: 256)
        for i in 0..<256 {
            let c = Float(i) / 255
            lut[i] = c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
        }
        var out = [Float](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) { for c in 0..<3 { out[i * 3 + c] = lut[Int(rgba[i * 4 + c])] } }
        return out
    }

    private static func encodeSRGB(_ linear: Float) -> UInt8 {
        let l = max(0, min(1, linear))
        let c = l <= 0.0031308 ? l * 12.92 : 1.055 * powf(l, 1 / 2.4) - 0.055
        return UInt8((c * 255).rounded())
    }

    /// exp of a least-squares quadratic fit to log luminance over the image (coordinates in −1...1).
    static func quadraticFalloff(_ luma: [Float], width: Int, height: Int) -> [Float] {
        // Normal equations for the basis [1, x, y, x², xy, y²], on a sparse grid of lit pixels.
        var ata = [Double](repeating: 0, count: 36), atb = [Double](repeating: 0, count: 6)
        let step = max(1, min(width, height) / 128)
        func basis(_ x: Double, _ y: Double) -> [Double] { [1, x, y, x * x, x * y, y * y] }
        for py in stride(from: 0, to: height, by: step) {
            for px in stride(from: 0, to: width, by: step) {
                let value = luma[py * width + px]
                guard value > 1e-4 else { continue }
                let x = Double(px) / Double(width - 1) * 2 - 1, y = Double(py) / Double(height - 1) * 2 - 1
                let b = basis(x, y), target = log(Double(value))
                for r in 0..<6 {
                    atb[r] += b[r] * target
                    for c in 0..<6 { ata[r * 6 + c] += b[r] * b[c] }
                }
            }
        }
        let coefficients = solve6(ata, atb) ?? [log(max(1e-4, Double(luma.reduce(0, +)) / Double(luma.count))), 0, 0, 0, 0, 0]
        var out = [Float](repeating: 0, count: width * height)
        for py in 0..<height {
            let y = Double(py) / Double(max(1, height - 1)) * 2 - 1
            for px in 0..<width {
                let x = Double(px) / Double(max(1, width - 1)) * 2 - 1
                let b = basis(x, y)
                var sum = 0.0
                for k in 0..<6 { sum += coefficients[k] * b[k] }
                out[py * width + px] = Float(exp(sum))
            }
        }
        return out
    }

    /// Gaussian elimination with partial pivoting for a 6×6 system; nil when singular.
    private static func solve6(_ a: [Double], _ b: [Double]) -> [Double]? {
        var m = a, v = b
        for col in 0..<6 {
            guard let pivot = (col..<6).max(by: { abs(m[$0 * 6 + col]) < abs(m[$1 * 6 + col]) }),
                  abs(m[pivot * 6 + col]) > 1e-12 else { return nil }
            if pivot != col {
                for k in 0..<6 { m.swapAt(col * 6 + k, pivot * 6 + k) }
                v.swapAt(col, pivot)
            }
            for row in (col + 1)..<6 {
                let factor = m[row * 6 + col] / m[col * 6 + col]
                for k in col..<6 { m[row * 6 + k] -= factor * m[col * 6 + k] }
                v[row] -= factor * v[col]
            }
        }
        var x = [Double](repeating: 0, count: 6)
        for row in stride(from: 5, through: 0, by: -1) {
            var sum = v[row]
            for k in (row + 1)..<6 { sum -= m[row * 6 + k] * x[k] }
            x[row] = sum / m[row * 6 + row]
        }
        return x
    }

    private static func encodePNG(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
