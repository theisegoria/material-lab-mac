import AVFoundation
import CoreVideo
import Foundation
import UIKit

struct ConfidenceMap {
    let width: Int
    let height: Int
    let pixels: Data

    func oriented(as orientation: UIImage.Orientation) -> Self {
        let rotated: Bool
        switch orientation {
        case .left, .right, .leftMirrored, .rightMirrored: rotated = true
        default: rotated = false
        }
        let newWidth = rotated ? height : width
        let newHeight = rotated ? width : height
        var output = [UInt8](repeating: 0, count: newWidth * newHeight)
        let input = [UInt8](pixels)
        for y in 0..<height {
            for x in 0..<width {
                let destination: (x: Int, y: Int)
                switch orientation {
                case .up: destination = (x, y)
                case .upMirrored: destination = (width - 1 - x, y)
                case .down: destination = (width - 1 - x, height - 1 - y)
                case .downMirrored: destination = (x, height - 1 - y)
                case .left: destination = (y, width - 1 - x)
                case .right: destination = (height - 1 - y, x)
                case .leftMirrored: destination = (y, x)
                case .rightMirrored: destination = (height - 1 - y, width - 1 - x)
                @unknown default: destination = (x, y)
                }
                output[destination.y * newWidth + destination.x] = input[y * width + x]
            }
        }
        return Self(width: newWidth, height: newHeight, pixels: Data(output))
    }

    func score(in quad: PerspectiveQuad) -> ConfidenceSummary {
        guard width > 0, height > 0, pixels.count == width * height else {
            return .unavailable
        }
        let bytes = [UInt8](pixels)
        var samples: [Double] = []
        samples.reserveCapacity(32 * 32)
        for row in 0..<32 {
            for column in 0..<32 {
                let u = (Double(column) + 0.5) / 32
                let v = (Double(row) + 0.5) / 32
                let top = quad.topLeft.interpolated(to: quad.topRight, fraction: u)
                let bottom = quad.bottomLeft.interpolated(to: quad.bottomRight, fraction: u)
                let point = top.interpolated(to: bottom, fraction: v)
                let x = min(width - 1, max(0, Int(point.x * Double(width - 1))))
                let y = min(height - 1, max(0, Int(point.y * Double(height - 1))))
                samples.append(Double(bytes[y * width + x]) / 255)
            }
        }
        let mean = samples.reduce(0, +) / Double(samples.count)
        let lowFraction = Double(samples.filter { $0 < 0.5 }.count) / Double(samples.count)
        return ConfidenceSummary(mean: mean, lowFraction: lowFraction, sampleCount: samples.count)
    }
}

struct ConfidenceSummary: Codable {
    let mean: Double
    let lowFraction: Double
    let sampleCount: Int

    static let unavailable = Self(mean: 0, lowFraction: 1, sampleCount: 0)
    var adequate: Bool { sampleCount > 0 && mean >= 0.7 && lowFraction <= 0.15 }
}

struct CameraCapture {
    let primaryData: Data
    let fallbackData: Data?
    let confidence: ConfidenceMap?
    let constantColorRequested: Bool
    let centerConfidence: Float
    let capturedAt: Date
}

final class CameraController: NSObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    var onCapture: ((Result<CameraCapture, Error>) -> Void)?
    var onReady: ((Result<Bool, Error>) -> Void)?

    private let queue = DispatchQueue(label: "io.materiallab.capture.camera", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private var primaryData: Data?
    private var fallbackData: Data?
    private var confidence: ConfidenceMap?
    private var centerConfidence: Float = 0
    private var constantColorRequested = false

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            guard let self else { return }
            guard allowed else {
                DispatchQueue.main.async { self.onReady?(.failure(CaptureError.cameraPermissionDenied)) }
                return
            }
            self.queue.async {
                do {
                    try self.configureIfNeeded()
                    self.session.startRunning()
                    let supportsConstantColor = self.photoOutput.isConstantColorSupported
                    DispatchQueue.main.async { self.onReady?(.success(supportsConstantColor)) }
                } catch {
                    DispatchQueue.main.async { self.onReady?(.failure(error)) }
                }
            }
        }
    }

    func stop() {
        queue.async { [weak self] in self?.session.stopRunning() }
    }

    func capture(preferConstantColor: Bool, flash: AVCaptureDevice.FlashMode) {
        queue.async {
            guard self.session.isRunning else {
                DispatchQueue.main.async { self.onCapture?(.failure(CaptureError.cameraNotReady)) }
                return
            }
            self.primaryData = nil
            self.fallbackData = nil
            self.confidence = nil
            self.centerConfidence = 0
            self.constantColorRequested = preferConstantColor && self.photoOutput.isConstantColorSupported
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.photoQualityPrioritization = .quality
            settings.flashMode = self.constantColorRequested ? (flash == .off ? .auto : flash) : flash
            if self.constantColorRequested {
                settings.isConstantColorEnabled = true
                settings.isConstantColorFallbackPhotoDeliveryEnabled = true
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func configureIfNeeded() throws {
        guard session.inputs.isEmpty else { return }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CaptureError.cameraUnavailable
        }
        let input = try AVCaptureDeviceInput(device: camera)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(photoOutput) else {
            throw CaptureError.cameraUnavailable
        }
        session.addInput(input)
        session.addOutput(photoOutput)
        if photoOutput.isConstantColorSupported {
            photoOutput.isConstantColorEnabled = true
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            DispatchQueue.main.async { self.onCapture?(.failure(error)) }
            return
        }
        guard let data = photo.fileDataRepresentation() else { return }
        if photo.isConstantColorFallbackPhoto {
            fallbackData = data
        } else {
            primaryData = data
            centerConfidence = photo.constantColorCenterWeightedMeanConfidenceLevel
            if let buffer = photo.constantColorConfidenceMap {
                confidence = Self.copyConfidence(buffer)
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error {
            DispatchQueue.main.async { self.onCapture?(.failure(error)) }
            return
        }
        guard let primaryData else {
            DispatchQueue.main.async { self.onCapture?(.failure(CaptureError.photoUnavailable)) }
            return
        }
        let capture = CameraCapture(primaryData: primaryData, fallbackData: fallbackData,
                                    confidence: confidence, constantColorRequested: constantColorRequested,
                                    centerConfidence: centerConfidence, capturedAt: Date())
        DispatchQueue.main.async { self.onCapture?(.success(capture)) }
    }

    private static func copyConfidence(_ buffer: CVPixelBuffer) -> ConfidenceMap? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let source = base.assumingMemoryBound(to: UInt8.self)
        var pixels = Data(count: width * height)
        pixels.withUnsafeMutableBytes { target in
            guard let destination = target.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for y in 0..<height {
                destination.advanced(by: y * width).update(from: source.advanced(by: y * stride), count: width)
            }
        }
        return ConfidenceMap(width: width, height: height, pixels: pixels)
    }
}

enum CaptureError: LocalizedError {
    case cameraPermissionDenied
    case cameraUnavailable
    case cameraNotReady
    case photoUnavailable
    case invalidImage
    case invalidCrop
    case missingLabel
    case derivationFailed(String)
    case bundleTooLarge

    var errorDescription: String? {
        switch self {
        case .cameraPermissionDenied: "Camera access is disabled. Allow access in Settings or import a photo."
        case .cameraUnavailable: "No usable camera is available. Import a photo instead."
        case .cameraNotReady: "Camera is starting. Try again shortly."
        case .photoUnavailable: "No processed photo was delivered. Try another capture."
        case .invalidImage: "The selected image could not be decoded."
        case .invalidCrop: "The crop corners do not form a usable square."
        case .missingLabel: "Add a semantic material label before deriving."
        case .derivationFailed(let reason): "Derivation failed: \(reason)"
        case .bundleTooLarge: "This material bundle exceeds the 64 MiB transfer limit."
        }
    }
}
