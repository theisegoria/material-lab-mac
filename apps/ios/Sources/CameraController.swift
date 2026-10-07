import AVFoundation
import CoreImage
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
    /// Whether this camera can capture Apple ProRAW (set once the session is configured; read on the main queue).
    private(set) var supportsProRAW = false
    /// Whether photos can carry depth (LiDAR camera on Pro iPhones); read on the main queue.
    private(set) var supportsDepth = false
    /// Flash/no-flash albedo for cameras without Constant Color (needs a flash); read on the main queue.
    private(set) var supportsFlashPair = false
    /// Why the last flash pair fell back to the ambient photo, if it did.
    var onFlashPairNote: ((String) -> Void)?

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
    /// Requests that asked for ProRAW: their RAW photo becomes the primary image.
    private var rawRequests: Set<Int64> = []

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
                    let supportsProRAW = self.photoOutput.isAppleProRAWEnabled
                    let supportsDepth = self.photoOutput.isDepthDataDeliveryEnabled
                    let supportsFlashPair = !supportsConstantColor && self.photoOutput.supportedFlashModes.contains(.on)
                    DispatchQueue.main.async {
                        self.supportsFlashPair = supportsFlashPair
                        self.supportsProRAW = supportsProRAW
                        self.supportsDepth = supportsDepth
                        self.onReady?(.success(supportsConstantColor))
                    }
                } catch {
                    DispatchQueue.main.async { self.onReady?(.failure(error)) }
                }
            }
        }
    }

    func stop() {
        queue.async { [weak self] in self?.session.stopRunning() }
    }

    /// `preferProRAW` captures Apple ProRAW plus a processed photo (when supported and Constant Color is not in use);
    /// the RAW is developed neutrally into the primary image and the processed photo is kept as the fallback.
    /// `preferDepth` embeds the photo's depth map (LiDAR) in the file for depth-guided geometry; it is captured on its
    /// own, without Constant Color or ProRAW, to keep the request within combinations the camera supports.
    func capture(preferConstantColor: Bool, flash: AVCaptureDevice.FlashMode, preferProRAW: Bool = false,
                 preferDepth: Bool = false) {
        queue.async {
            guard self.session.isRunning else {
                DispatchQueue.main.async { self.onCapture?(.failure(CaptureError.cameraNotReady)) }
                return
            }
            let depth = preferDepth && self.photoOutput.isDepthDataDeliveryEnabled
            let preferProRAW = preferProRAW && !depth
            let constantColor = !depth && preferConstantColor && self.photoOutput.isConstantColorSupported
            let rawFormat = self.photoOutput.availableRawPhotoPixelFormatTypes.first {
                AVCapturePhotoOutput.isAppleProRAWPixelFormat($0)
            }
            let settings: AVCapturePhotoSettings
            if preferProRAW, !constantColor, self.photoOutput.isAppleProRAWEnabled, let rawFormat {
                settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat,
                                                  processedFormat: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                self.rawRequests.insert(settings.uniqueID)
            } else {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            }
            if depth {
                settings.isDepthDataDeliveryEnabled = true
                settings.isDepthDataFiltered = true
                settings.embedsDepthDataInPhoto = true
            }
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

    /// Flash/no-flash albedo: an ambient photo, then a flash photo, combined by FlashPairAlbedo. The ambient photo is
    /// kept as the fallback; if the pair cannot be used, the ambient photo is delivered alone with a note.
    func captureFlashPair() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let ambient = try await self.takePhoto(flash: .off)
                let flash = try await self.takePhoto(flash: .on)
                let capture: CameraCapture
                do {
                    let albedo = try FlashPairAlbedo.albedoPNG(ambient: ambient, flash: flash)
                    capture = CameraCapture(primaryData: albedo, fallbackData: ambient, confidence: nil,
                                            constantColorRequested: false, centerConfidence: 0, capturedAt: Date())
                } catch {
                    let note = error.localizedDescription
                    DispatchQueue.main.async { self.onFlashPairNote?(note) }
                    capture = CameraCapture(primaryData: ambient, fallbackData: nil, confidence: nil,
                                            constantColorRequested: false, centerConfidence: 0, capturedAt: Date())
                }
                DispatchQueue.main.async { self.onCapture?(.success(capture)) }
            } catch {
                DispatchQueue.main.async { self.onCapture?(.failure(error)) }
            }
        }
    }

    /// One JPEG photo with the given flash mode (used by the flash pair).
    private func takePhoto(flash: AVCaptureDevice.FlashMode) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.session.isRunning else { continuation.resume(throwing: CaptureError.cameraNotReady); return }
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
                settings.flashMode = self.photoOutput.supportedFlashModes.contains(flash) ? flash : .off
                let delegate = SinglePhotoDelegate(continuation: continuation)
                self.pairDelegates.insert(delegate)
                delegate.onFinish = { [weak self] in self?.queue.async { self?.pairDelegates.remove(delegate) } }
                self.photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }
    private var pairDelegates: Set<SinglePhotoDelegate> = []

    private func configureIfNeeded() throws {
        guard session.inputs.isEmpty else { return }
        // The LiDAR depth camera (Pro iPhones) is the wide camera paired with LiDAR, so photos can carry depth.
        guard let camera = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
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
        if photoOutput.isAppleProRAWSupported {
            photoOutput.isAppleProRAWEnabled = true
        }
        if photoOutput.isDepthDataDeliverySupported {
            photoOutput.isDepthDataDeliveryEnabled = true
        }
        session.commitConfiguration()
    }

    // MARK: Photo delegate — hop to `queue` so state is never touched concurrently.

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let id = photo.resolvedSettings.uniqueID
        var data = error == nil ? photo.fileDataRepresentation() : nil
        let isRaw = photo.isRawPhoto
        if isRaw, let dng = data { data = Self.developProRAW(dng) }
        // In a ProRAW request the processed photo is kept as the fallback.
        let isFallback = photo.isConstantColorFallbackPhoto || (!isRaw && rawRequestsContains(id))
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
            self.rawRequests.remove(id)
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

    private func rawRequestsContains(_ id: Int64) -> Bool { queue.sync { rawRequests.contains(id) } }

    /// Develops an Apple ProRAW DNG neutrally for albedo: no tone boost, local tone mapping, sharpening or noise
    /// reduction, so surface colour stays as close to linear-scene as an 8-bit sRGB image allows.
    static func developProRAW(_ dng: Data) -> Data? {
        guard let filter = CIRAWFilter(imageData: dng, identifierHint: nil) else { return nil }
        filter.boostAmount = 0
        filter.localToneMapAmount = 0
        filter.sharpnessAmount = 0
        filter.luminanceNoiseReductionAmount = 0
        filter.extendedDynamicRangeAmount = 0
        guard let image = filter.outputImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CIContext().pngRepresentation(of: image, format: .RGBA8, colorSpace: space)
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
        case .cameraPermissionDenied: String(localized: "Camera access is disabled. Allow access in Settings or import a photo.")
        case .cameraUnavailable: String(localized: "No usable camera is available. Import a photo instead.")
        case .cameraNotReady: String(localized: "Camera is starting. Try again shortly.")
        case .photoUnavailable: String(localized: "No processed photo was delivered. Try another capture.")
        case .invalidImage: String(localized: "The selected image could not be decoded.")
        case .importTooLarge: String(localized: "This image is larger than the 120 MB import limit.")
        case .invalidCrop: String(localized: "The crop corners do not form a usable square.")
        case .missingLabel: String(localized: "Add a material name before exporting.")
        case .derivationFailed(let reason): String(localized: "Derivation failed: \(reason)")
        case .cancelled: String(localized: "Derivation was cancelled.")
        case .metadataScrubFailed: String(localized: "The original photo could not be re-encoded without private metadata.")
        case .bundleTooLarge: String(localized: "This material bundle exceeds the 64 MiB transfer limit.")
        }
    }
}

/// Delivers one photo's file data to an async caller.
private final class SinglePhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<Data, Error>?
    var onFinish: (() -> Void)?

    init(continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { continuation?.resume(throwing: error) }
        else if let data = photo.fileDataRepresentation() { continuation?.resume(returning: data) }
        else { continuation?.resume(throwing: CaptureError.photoUnavailable) }
        continuation = nil
        onFinish?()
    }
}
