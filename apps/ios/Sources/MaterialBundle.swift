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
        /// Learned guide-normal provenance; present only when `recipe.guideNormalWeight > 0`.
        var guideNormals: GuideNormalsProvenance? = nil
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

    static let maximumSize = 64 * 1024 * 1024

    /// Builds the .pbrcapture JSON. CPU-heavy (hashing, base64, metadata scrubbing): call off the main actor.
    /// Each export or send gets a fresh `captureId`, so re-sending after a recipe change is not a duplicate.
    static func make(source: SourceImage, quad: PerspectiveQuad, label: String, category: String,
                     recipe: MaterialRecipe, material: DerivedMaterial, linkToken: String? = nil,
                     captureId: UUID = UUID()) throws -> Data {
        guard !material.isPreview, !material.sourcePNG.isEmpty else {
            throw CaptureError.derivationFailed("Derive full-resolution maps before export")
        }
        guard recipe == material.recipe, (recipe.guideNormalWeight > 0) == (material.guideNormals != nil) else {
            throw CaptureError.derivationFailed("The recipe changed or learned normals are missing; derive again before export")
        }
        let original = try source.sanitizedOriginal()
        let fallback: SanitizedImage?
        var fallbackReason: String?
        if source.fallbackData != nil && source.fallbackImage == nil {
            fallback = nil
            fallbackReason = "Fallback image could not be decoded"
        } else {
            fallback = try source.sanitizedFallback()
        }
        let mode = source.captureMode(for: quad)
        let maps = Dictionary(uniqueKeysWithValues: material.maps.map { kind, map in
            (kind.exportedName, DerivedMapRecord(mime: "image/png", base64: map.png.base64EncodedString(),
                                                 sha256: sha256(map.png), width: map.width, height: map.height,
                                                 pixelFormat: map.pixelFormat,
                                                 provenance: kind.provenance(recipe: material.recipe,
                                                                             guided: material.guideNormals != nil)))
        })
        let sourceBase64 = material.sourcePNG.base64EncodedString()
        let sourceHash = sha256(material.sourcePNG)
        // Base64 grows by a third; an image larger than this cannot fit the frame with its maps.
        let maximumEmbeddableImageSize = 48 * 1024 * 1024
        var includeOriginal = original.bytes.count <= maximumEmbeddableImageSize
        var includeFallback = fallback.map { $0.bytes.count <= maximumEmbeddableImageSize } ?? false
        var originalReason: String? = includeOriginal ? nil : "Original image exceeds the 64 MiB capture limit"
        if fallback != nil && !includeFallback { fallbackReason = "Fallback image exceeds the 64 MiB capture limit" }
        // Hash and encode each embedded image exactly once, however many size attempts follow.
        let originalBase64 = includeOriginal ? original.bytes.base64EncodedString() : nil
        let originalHash = includeOriginal ? sha256(original.bytes) : nil
        let fallbackBase64 = includeFallback ? fallback?.bytes.base64EncodedString() : nil
        let fallbackHash = includeFallback ? fallback.map { sha256($0.bytes) } : nil
        let confidenceSummary = source.confidence?.score(in: quad)
        let capturedAt = ISO8601DateFormatter().string(from: source.capturedAt)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        func encode() throws -> Data {
            let capture = Capture(capturedAt: capturedAt,
                                  orientation: "up after correction", colorProfile: "sRGB",
                                  captureMode: mode, confidenceSummary: confidenceSummary,
                                  constantColorCenterConfidence: source.constantColorCenterConfidence,
                                  crop: quad,
                                  originalMime: includeOriginal ? original.mime : nil,
                                  originalBase64: includeOriginal ? originalBase64 : nil,
                                  originalSHA256: includeOriginal ? originalHash : nil,
                                  originalWidth: includeOriginal ? original.width : nil,
                                  originalHeight: includeOriginal ? original.height : nil,
                                  imageQuality: material.quality,
                                  fallbackUsed: source.shouldUseFallback(for: quad),
                                  originalOmissionReason: originalReason,
                                  fallbackOriginalMime: includeFallback ? fallback?.mime : nil,
                                  fallbackOriginalBase64: includeFallback ? fallbackBase64 : nil,
                                  fallbackOriginalSHA256: includeFallback ? fallbackHash : nil,
                                  fallbackOriginalWidth: includeFallback ? fallback?.width : nil,
                                  fallbackOriginalHeight: includeFallback ? fallback?.height : nil,
                                  fallbackOmissionReason: fallbackReason,
                                  guideNormals: material.guideNormals)
            let bundle = Self(schemaVersion: 1, bundleKind: "pbr-capture", captureId: captureId,
                              semanticLabel: label, category: category, sourceMime: "image/png",
                              sourceBase64: sourceBase64, sourceSHA256: sourceHash,
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

struct SanitizedImage {
    let bytes: Data
    let mime: String
    let width: Int
    let height: Int
}

struct SourceImage: @unchecked Sendable {
    enum Origin: String, Codable { case camera, photos, files }

    /// Imports larger than this are refused before decoding.
    static let maximumImportBytes = 120 * 1024 * 1024
    /// Longest side of the decoded working image; ample for a 4096² crop of typical captures.
    static let maximumWorkingPixels = 6048
    static let displayPixels = 1600

    let id: UUID
    let origin: Origin
    let primaryData: Data
    let fallbackData: Data?
    /// Upright, size-capped working image.
    let image: CGImage
    /// Upright copy for on-screen editing and rectangle detection.
    let displayImage: CGImage
    let fallbackImage: CGImage?
    let confidence: ConfidenceMap?
    /// Confidence as delivered by the camera, before orientation; persisted for restore.
    let rawConfidence: ConfidenceMap?
    let constantColorRequested: Bool
    let constantColorCenterConfidence: Double?
    let capturedAt: Date

    var size: CGSize { CGSize(width: image.width, height: image.height) }

    init(origin: Origin, data: Data, fallback: Data? = nil, confidence: ConfidenceMap? = nil,
         constantColorRequested: Bool = false, centerConfidence: Float? = nil,
         capturedAt: Date = Date(), id: UUID = UUID()) throws {
        guard data.count <= Self.maximumImportBytes else { throw CaptureError.importTooLarge }
        let decoded = try Self.decode(data, maxPixels: Self.maximumWorkingPixels)
        self.id = id
        self.origin = origin
        self.primaryData = data
        self.fallbackData = fallback
        self.image = decoded.image
        self.displayImage = (try? Self.decode(data, maxPixels: Self.displayPixels).image) ?? decoded.image
        self.fallbackImage = fallback.flatMap { try? Self.decode($0, maxPixels: Self.maximumWorkingPixels).image }
        self.rawConfidence = confidence
        if let confidence, confidence.height > 0, decoded.rawHeight > 0 {
            let rawAspect = Double(decoded.rawWidth) / Double(decoded.rawHeight)
            let mapAspect = Double(confidence.width) / Double(confidence.height)
            // A map whose aspect does not match the sensor image cannot be placed reliably.
            self.confidence = abs(rawAspect - mapAspect) < 0.03 ? confidence.oriented(as: decoded.orientation) : nil
        } else {
            self.confidence = nil
        }
        self.constantColorRequested = constantColorRequested
        if constantColorRequested, let centerConfidence, centerConfidence.isFinite {
            self.constantColorCenterConfidence = Double(min(1, max(0, centerConfidence)))
        } else {
            self.constantColorCenterConfidence = nil
        }
        self.capturedAt = capturedAt
    }

    struct Decoded {
        let image: CGImage
        let rawWidth: Int
        let rawHeight: Int
        let orientation: CGImagePropertyOrientation
    }

    /// Decodes the primary image upright and downsampled in one pass (8-bit, no full-size intermediate).
    static func decode(_ data: Data, maxPixels: Int) throws -> Decoded {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { throw CaptureError.invalidImage }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let rawWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let rawHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)
            .flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) } ?? .up
        guard rawWidth > 0, rawHeight > 0 else { throw CaptureError.invalidImage }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixels, max(rawWidth, rawHeight))
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw CaptureError.invalidImage
        }
        return Decoded(image: image, rawWidth: rawWidth, rawHeight: rawHeight, orientation: orientation)
    }

    func shouldUseFallback(for quad: PerspectiveQuad) -> Bool {
        constantColorRequested && !(confidence?.score(in: quad).adequate ?? false) && fallbackImage != nil
    }
    func selectedImage(for quad: PerspectiveQuad) -> CGImage {
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

    func sanitizedOriginal() throws -> SanitizedImage { try PrivacyScrubber.scrub(primaryData) }
    func sanitizedFallback() throws -> SanitizedImage? { try fallbackData.map(PrivacyScrubber.scrub) }
}

/// Rewrites every image in a container keeping only an allow-list of metadata (orientation; ICC and
/// dimensions are intrinsic). Location, maker notes, serial numbers, IPTC/XMP and owner fields are dropped.
enum PrivacyScrubber {
    static func scrub(_ data: Data) throws -> SanitizedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source),
              CGImageSourceGetCount(source) > 0 else { throw CaptureError.metadataScrubFailed }
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(type as String)
        if writable, let copied = copyWithAllowList(source, type: type), let result = verified(copied) {
            return result
        }
        // Lossless copy unavailable or incomplete: re-encode pixels with only the orientation tag.
        let outputType = writable ? type : UTType.jpeg.identifier as CFString
        if let encoded = reencode(source, type: outputType), let result = verified(encoded) {
            return result
        }
        throw CaptureError.metadataScrubFailed
    }

    private static func allowListMetadata(_ source: CGImageSource, index: Int) -> CGImageMetadata {
        let metadata = CGImageMetadataCreateMutable()
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        if let orientation = properties?[kCGImagePropertyOrientation] as? NSNumber {
            CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary,
                                                         kCGImagePropertyTIFFOrientation, orientation)
        }
        return metadata
    }

    private static func copyWithAllowList(_ source: CGImageSource, type: CFString) -> Data? {
        let output = NSMutableData()
        let count = CGImageSourceGetCount(source)
        guard let destination = CGImageDestinationCreateWithData(output, type, count, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: allowListMetadata(source, index: CGImageSourceGetPrimaryImageIndex(source)),
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeGPS: true,
            kCGImageMetadataShouldExcludeXMP: true
        ]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
            error?.release()
            return nil
        }
        return output.length > 0 ? output as Data : nil
    }

    private static func reencode(_ source: CGImageSource, type: CFString) -> Data? {
        let output = NSMutableData()
        let count = CGImageSourceGetCount(source)
        guard let destination = CGImageDestinationCreateWithData(output, type, count, nil) else { return nil }
        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.97,
                                            kCGImageMetadataShouldExcludeGPS: true]
            if let orientation = properties?[kCGImagePropertyOrientation] { options[kCGImagePropertyOrientation] = orientation }
            CGImageDestinationAddImage(destination, image, options as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination), output.length > 0 else { return nil }
        return output as Data
    }

    private static let forbiddenDictionaries: [CFString] = [
        kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyMakerAppleDictionary,
        kCGImagePropertyMakerCanonDictionary, kCGImagePropertyMakerNikonDictionary,
        kCGImagePropertyMakerFujiDictionary, kCGImagePropertyMakerOlympusDictionary,
        kCGImagePropertyMakerPentaxDictionary, kCGImagePropertyMakerMinoltaDictionary,
        kCGImagePropertyExifAuxDictionary
    ]
    private static let forbiddenExif: [CFString] = [
        kCGImagePropertyExifBodySerialNumber, kCGImagePropertyExifLensSerialNumber,
        kCGImagePropertyExifCameraOwnerName, kCGImagePropertyExifUserComment, kCGImagePropertyExifMakerNote,
        kCGImagePropertyExifImageUniqueID
    ]
    private static let forbiddenTIFF: [CFString] = [
        kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright, kCGImagePropertyTIFFHostComputer,
        kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFImageDescription
    ]
    private static let forbiddenXMPPrefixes = ["exifEX", "aux", "photoshop", "Iptc4xmpCore", "Iptc4xmpExt",
                                               "dc", "xmpRights", "exif:GPS"]

    /// Re-reads the output and returns it only if no forbidden metadata survived.
    private static func verified(_ data: Data) -> SanitizedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source),
              let mime = UTType(type as String)?.preferredMIMEType else { return nil }
        for index in 0..<CGImageSourceGetCount(source) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            if forbiddenDictionaries.contains(where: { properties[$0] != nil }) { return nil }
            if properties.keys.contains(where: { ($0 as String).hasPrefix("{Maker") }) { return nil }
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            if forbiddenExif.contains(where: { exif[$0] != nil }) { return nil }
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            if forbiddenTIFF.contains(where: { tiff[$0] != nil }) { return nil }
            if let metadata = CGImageSourceCopyMetadataAtIndex(source, index, nil),
               let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] {
                for tag in tags {
                    let prefix = CGImageMetadataTagCopyPrefix(tag).map { $0 as String } ?? ""
                    let name = CGImageMetadataTagCopyName(tag).map { $0 as String } ?? ""
                    if forbiddenXMPPrefixes.contains(prefix) || forbiddenXMPPrefixes.contains("\(prefix):\(name)")
                        || name.hasPrefix("GPS") { return nil }
                }
            }
        }
        let primary = CGImageSourceGetPrimaryImageIndex(source)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, primary, nil) as? [CFString: Any] ?? [:]
        guard let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        return SanitizedImage(bytes: data, mime: mime, width: width, height: height)
    }
}
