import CryptoKit
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import UIKit

extension UTType {
    static let pbrCapture = UTType(exportedAs: "io.materiallab.pbrcapture", conformingTo: .json)
}

struct MaterialBundleDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pbrCapture] }
    static var writableContentTypes: [UTType] { [.pbrCapture] }
    var bytes: Data

    init(bytes: Data) { self.bytes = bytes }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw CaptureError.invalidImage }
        self.bytes = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: bytes)
    }
}

struct MaterialBundle: Codable {
    struct Capture: Codable {
        let capturedAt: String
        let orientation: String
        let colorProfile: String
        let captureMode: String
        let confidenceSummary: ConfidenceSummary?
        let constantColorCenterConfidence: Double?
        let crop: PerspectiveQuad
        let originalMime: String?
        let originalBase64: String?
        let originalSHA256: String?
        let originalWidth: Int?
        let originalHeight: Int?
        let imageQuality: ImageQualityDiagnostics
        let fallbackUsed: Bool
        let originalOmissionReason: String?
        let fallbackOriginalMime: String?
        let fallbackOriginalBase64: String?
        let fallbackOriginalSHA256: String?
        let fallbackOriginalWidth: Int?
        let fallbackOriginalHeight: Int?
        let fallbackOmissionReason: String?
    }
    struct DerivedMapRecord: Codable {
        let mime: String
        let base64: String
        let sha256: String
        let width: Int
        let height: Int
        let pixelFormat: String
        let provenance: String
    }
    struct Link: Codable { let token: String }

    let schemaVersion: Int
    let bundleKind: String
    let captureId: UUID
    let semanticLabel: String
    let category: String
    let sourceMime: String
    let sourceBase64: String
    let sourceSHA256: String
    let algorithmVersion: String
    let recipe: MaterialRecipe
    let capture: Capture
    let derived: [String: DerivedMapRecord]
    let seamMetrics: SeamDiagnostics
    let runtimeAdmitted: Bool
    let link: Link?

    static func make(source: SourceImage, quad: PerspectiveQuad, label: String, category: String,
                     recipe: MaterialRecipe, material: DerivedMaterial, linkToken: String? = nil) throws -> Data {
        let original = source.sanitizedOriginal
        let fallback = source.sanitizedFallback
        let mode = source.captureMode(for: quad)
        let maps = Dictionary(uniqueKeysWithValues: material.maps.map { kind, map in
            (kind.exportedName, DerivedMapRecord(mime: "image/png", base64: map.png.base64EncodedString(),
                                             sha256: sha256(map.png), width: map.width, height: map.height,
                                             pixelFormat: map.pixelFormat, provenance: kind.provenance))
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let maximumSize = 64 * 1024 * 1024
        // Base64 grows by at least a third. A single image larger than this cannot
        // fit the transfer frame even before maps and metadata are counted.
        let maximumEmbeddableImageSize = 48 * 1024 * 1024
        var includeOriginal = original.bytes.count <= maximumEmbeddableImageSize
        var includeFallback = fallback != nil && fallback!.bytes.count <= maximumEmbeddableImageSize
        var originalReason: String? = includeOriginal ? nil : "Original image exceeds the 64 MiB capture limit"
        var fallbackReason: String? = source.fallbackData == nil ? nil :
            (fallback == nil ? "Fallback image could not be decoded" :
             (includeFallback ? nil : "Fallback image exceeds the 64 MiB capture limit"))

        func encode() throws -> Data {
            let originalImage = includeOriginal ? UIImage(data: original.bytes) : nil
            let fallbackImage = includeFallback ? UIImage(data: fallback!.bytes) : nil
            let capture = Capture(capturedAt: ISO8601DateFormatter().string(from: source.capturedAt),
                                  orientation: "up after correction", colorProfile: "sRGB",
                                  captureMode: mode, confidenceSummary: source.confidence?.score(in: quad),
                                  constantColorCenterConfidence: source.constantColorCenterConfidence,
                                  crop: quad,
                                  originalMime: includeOriginal ? original.mime : nil,
                                  originalBase64: includeOriginal ? original.bytes.base64EncodedString() : nil,
                                  originalSHA256: includeOriginal ? sha256(original.bytes) : nil,
                                  originalWidth: originalImage?.cgImage?.width,
                                  originalHeight: originalImage?.cgImage?.height,
                                  imageQuality: material.quality,
                                  fallbackUsed: source.shouldUseFallback(for: quad),
                                  originalOmissionReason: originalReason,
                                  fallbackOriginalMime: includeFallback ? fallback!.mime : nil,
                                  fallbackOriginalBase64: includeFallback ? fallback!.bytes.base64EncodedString() : nil,
                                  fallbackOriginalSHA256: includeFallback ? sha256(fallback!.bytes) : nil,
                                  fallbackOriginalWidth: fallbackImage?.cgImage?.width,
                                  fallbackOriginalHeight: fallbackImage?.cgImage?.height,
                                  fallbackOmissionReason: fallbackReason)
            let bundle = Self(schemaVersion: 1, bundleKind: "pbr-capture", captureId: source.id,
                              semanticLabel: label, category: category, sourceMime: "image/png",
                              sourceBase64: material.sourcePNG.base64EncodedString(),
                              sourceSHA256: sha256(material.sourcePNG),
                              algorithmVersion: material.algorithmVersion, recipe: recipe, capture: capture,
                              derived: maps, seamMetrics: material.seam, runtimeAdmitted: false,
                              link: linkToken.map(Link.init(token:)))
            return try encoder.encode(bundle)
        }

        var data = try encode()
        if data.count > maximumSize && includeOriginal {
            includeOriginal = false
            originalReason = "Original image omitted to keep the capture within 64 MiB"
            data = try encode()
        }
        if data.count > maximumSize && includeFallback {
            includeFallback = false
            fallbackReason = "Fallback image omitted to keep the capture within 64 MiB"
            data = try encode()
        }
        guard data.count <= maximumSize else { throw CaptureError.bundleTooLarge }
        return data
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct SourceImage {
    enum Origin: String { case camera, photos, files }
    let id: UUID
    let origin: Origin
    let primaryData: Data
    let fallbackData: Data?
    let image: UIImage
    let fallbackImage: UIImage?
    let confidence: ConfidenceMap?
    let constantColorRequested: Bool
    let constantColorCenterConfidence: Double?
    let capturedAt: Date

    init(origin: Origin, data: Data, fallback: Data? = nil, confidence: ConfidenceMap? = nil,
         constantColorRequested: Bool = false, centerConfidence: Float? = nil,
         capturedAt: Date = Date()) throws {
        guard let decoded = UIImage(data: data) else { throw CaptureError.invalidImage }
        self.id = UUID()
        self.origin = origin
        self.primaryData = data
        self.fallbackData = fallback
        self.image = try PerspectiveCropper.normalized(decoded)
        self.fallbackImage = try fallback.flatMap { UIImage(data: $0) }.map { try PerspectiveCropper.normalized($0) }
        if let confidence, let raw = decoded.cgImage {
            let rawAspect = Double(raw.width) / Double(raw.height)
            let mapAspect = Double(confidence.width) / Double(max(1, confidence.height))
            self.confidence = abs(rawAspect - mapAspect) < 0.03
                ? confidence.oriented(as: decoded.imageOrientation) : confidence
        } else {
            self.confidence = confidence
        }
        self.constantColorRequested = constantColorRequested
        if constantColorRequested, let centerConfidence, centerConfidence.isFinite {
            self.constantColorCenterConfidence = Double(min(1, max(0, centerConfidence)))
        } else {
            self.constantColorCenterConfidence = nil
        }
        self.capturedAt = capturedAt
    }

    func shouldUseFallback(for quad: PerspectiveQuad) -> Bool {
        constantColorRequested && !(confidence?.score(in: quad).adequate ?? false) && fallbackImage != nil
    }
    func selectedImage(for quad: PerspectiveQuad) -> UIImage {
        shouldUseFallback(for: quad) ? (fallbackImage ?? image) : image
    }
    func captureMode(for quad: PerspectiveQuad) -> String {
        if origin != .camera { return "estimated-albedo-\(origin.rawValue)" }
        if shouldUseFallback(for: quad) { return "estimated-albedo-constant-color-fallback" }
        if constantColorRequested && (confidence?.score(in: quad).adequate ?? false) {
            return "constant-color-high-confidence"
        }
        return "estimated-albedo-ordinary-photo"
    }
    var sanitizedOriginal: (bytes: Data, mime: String) {
        Self.privacyCheckedOriginal(data: primaryData, image: image)
    }

    var sanitizedFallback: (bytes: Data, mime: String)? {
        guard let fallbackData, let fallbackImage else { return nil }
        return Self.privacyCheckedOriginal(data: fallbackData, image: fallbackImage)
    }

    private static func privacyCheckedOriginal(data: Data, image: UIImage) -> (bytes: Data, mime: String) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let type = CGImageSourceGetType(source),
              let mime = UTType(type as String)?.preferredMIMEType,
              properties[kCGImagePropertyGPSDictionary as String] == nil else {
            // Image re-encoding removes all camera location metadata. Declare the
            // bytes as JPEG only when that encoding is actually produced.
            return (image.jpegData(compressionQuality: 0.98) ?? Data(), "image/jpeg")
        }
        return (data, mime)
    }
}
