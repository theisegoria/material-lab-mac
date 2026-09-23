import AVFoundation
import CoreVideo
import Foundation
import ImageIO
import UIKit

struct ConfidenceMap: Sendable {
    let width: Int
    let height: Int
    let pixels: Data

    func oriented(as orientation: CGImagePropertyOrientation) -> Self {
        oriented(as: UIImage.Orientation(orientation))
    }

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
                let point = quad.interpolate(u: (Double(column) + 0.5) / 32, v: (Double(row) + 0.5) / 32)
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

extension UIImage.Orientation {
    init(_ orientation: CGImagePropertyOrientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

struct ConfidenceSummary: Codable, Sendable {
    let mean: Double
    let lowFraction: Double
    let sampleCount: Int

    static let unavailable = Self(mean: 0, lowFraction: 1, sampleCount: 0)
    var adequate: Bool { sampleCount > 0 && mean >= 0.7 && lowFraction <= 0.15 }
}

struct CameraCapture: Sendable {
    let primaryData: Data
    let fallbackData: Data?
    let confidence: ConfidenceMap?
    let constantColorRequested: Bool
    let centerConfidence: Float
    let capturedAt: Date
}

/// Live exposure reading from sparse luma samples of the preview stream.
struct ExposureReading: Equatable, Sendable {
    var clippedFraction: Double
    var meanLuma: Double
}

/// All mutable capture state is confined to `queue`; callbacks are delivered on the main queue.
final class CameraController: NSObject, AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate,
                              @unchecked Sendable {
    let session = AVCaptureSession()
    var onCapture: ((Result<CameraCapture, Error>) -> Void)?
    var onReady: ((Result<Bool, Error>) -> Void)?
    var onExposure: ((ExposureReading) -> Void)?

    private let queue = DispatchQueue(label: "io.materiallab.capture.camera", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "io.materiallab.capture.video", qos: .utility)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var frameCounter = 0

    /// Per-request accumulation keyed by `AVCaptureResolvedPhotoSettings.uniqueID`.
    private struct InFlight {
        var constantColorRequested: Bool
        var primaryData: Data?
        var fallbackData: Data?
        var confidence: ConfidenceMap?
        var centerConfidence: Float = 0
        var error: Error?
    }
    private var inFlight: [Int64: InFlight] = [:]
    private var requested: [Int64: Bool] = [:]

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
                    if !self.session.isRunning { self.session.startRunning() }
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
            let constantColor = preferConstantColor && self.photoOutput.isConstantColorSupported
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            settings.photoQualityPrioritization = self.photoOutput.maxPhotoQualityPrioritization
            let supportedFlash = self.photoOutput.supportedFlashModes
            let desiredFlash = constantColor ? (flash == .off ? .auto : flash) : flash
            settings.flashMode = supportedFlash.contains(desiredFlash) ? desiredFlash : .off
            if constantColor {
                settings.isConstantColorEnabled = true
                settings.isConstantColorFallbackPhotoDeliveryEnabled = true
            }
            self.requested[settings.uniqueID] = constantColor
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
        session.sessionPreset = .photo
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CaptureError.cameraUnavailable
        }
        session.addInput(input)
        guard session.canAddOutput(photoOutput) else {
            session.removeInput(input)
            session.commitConfiguration()
            throw CaptureError.cameraUnavailable
        }
        session.addOutput(photoOutput)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        }
        session.commitConfiguration()

        // The preset has now selected the active format. Raise the output limits before any request
        // asks for .quality or full resolution; exceeding them raises NSInvalidArgumentException.
        session.beginConfiguration()
        photoOutput.maxPhotoQualityPrioritization = .quality
        if let largest = camera.activeFormat.supportedMaxPhotoDimensions
            .max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            photoOutput.maxPhotoDimensions = largest
        }
        if photoOutput.isConstantColorSupported {
            photoOutput.isConstantColorEnabled = true
        }
        session.commitConfiguration()
    }

    // MARK: Photo delegate — hop to `queue` so state is never touched concurrently.

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let id = photo.resolvedSettings.uniqueID
        let data = error == nil ? photo.fileDataRepresentation() : nil
        let isFallback = photo.isConstantColorFallbackPhoto
        let center = photo.constantColorCenterWeightedMeanConfidenceLevel
        let confidence = isFallback ? nil : photo.constantColorConfidenceMap.flatMap(Self.copyConfidence)
        queue.async {
            var state = self.inFlight[id] ?? InFlight(constantColorRequested: self.requested[id] ?? false)
            if let error {
                state.error = state.error ?? error
            } else if let data {
                if isFallback {
                    state.fallbackData = data
                } else {
                    state.primaryData = data
                    state.centerConfidence = center
                    state.confidence = confidence
                }
            }
            self.inFlight[id] = state
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        let id = resolvedSettings.uniqueID
        queue.async {
            let state = self.inFlight.removeValue(forKey: id)
            let constantColor = self.requested.removeValue(forKey: id) ?? false
            let result: Result<CameraCapture, Error>
            if let primary = state?.primaryData {
                // A usable primary photo wins over a failed fallback delivery.
                result = .success(CameraCapture(primaryData: primary, fallbackData: state?.fallbackData,
                                                confidence: state?.confidence, constantColorRequested: constantColor,
                                                centerConfidence: state?.centerConfidence ?? 0, capturedAt: Date()))
            } else if let failure = error ?? state?.error {
                result = .failure(failure)
            } else {
                result = .failure(CaptureError.photoUnavailable)
            }
            DispatchQueue.main.async { self.onCapture?(result) }
        }
    }

    // MARK: Exposure guidance

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameCounter += 1
        guard frameCounter % 8 == 0, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(buffer) > 0,
              let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)
        // Sample the centered square the user is framing.
        let side = min(width, height)
        let x0 = (width - side) / 2, y0 = (height - side) / 2
        var clipped = 0, total = 0, sum = 0
        for row in 0..<40 {
            let y = y0 + (row * side) / 40 + side / 80
            for column in 0..<40 {
                let x = x0 + (column * side) / 40 + side / 80
                let value = Int(luma[y * stride + x])
                if value >= 250 { clipped += 1 }
                sum += value
                total += 1
            }
        }
        let reading = ExposureReading(clippedFraction: Double(clipped) / Double(total),
                                      meanLuma: Double(sum) / Double(total) / 255)
        DispatchQueue.main.async { self.onExposure?(reading) }
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
    case importTooLarge
    case invalidCrop
    case missingLabel
    case derivationFailed(String)
    case cancelled
    case metadataScrubFailed
    case bundleTooLarge

    var errorDescription: String? {
        switch self {
        case .cameraPermissionDenied: "Camera access is disabled. Allow access in Settings or import a photo."
        case .cameraUnavailable: "No usable camera is available. Import a photo instead."
        case .cameraNotReady: "Camera is starting. Try again shortly."
        case .photoUnavailable: "No processed photo was delivered. Try another capture."
        case .invalidImage: "The selected image could not be decoded."
        case .importTooLarge: "This image is larger than the 120 MB import limit."
        case .invalidCrop: "The crop corners do not form a usable square."
        case .missingLabel: "Add a material name before exporting."
        case .derivationFailed(let reason): "Derivation failed: \(reason)"
        case .cancelled: "Derivation was cancelled."
        case .metadataScrubFailed: "The original photo could not be re-encoded without private metadata."
        case .bundleTooLarge: "This material bundle exceeds the 64 MiB transfer limit."
        }
    }
}
