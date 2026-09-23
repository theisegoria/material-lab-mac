import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum MaterialBundleError: LocalizedError {
    case tooLarge
    case invalidCapture(String)
    case duplicateCapture
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .tooLarge: "The capture bundle exceeds the 64 MiB local transfer limit."
        case .invalidCapture(let reason): "Invalid capture bundle: \(reason)"
        case .duplicateCapture: "A capture with this ID is already in the inbox."
        case .exportFailed(let reason): "Could not export material bundle: \(reason)"
        }
    }
}

struct CaptureInspection {
    let captureID: UUID
    let semanticLabel: String
    let category: String
    let sourcePNG: Data
    let sanitizedEnvelope: Data
}

enum MaterialBundle {
    static let maximumCaptureBytes = 64 * 1024 * 1024

    static func inspectCapture(_ data: Data) throws -> CaptureInspection {
        guard !data.isEmpty, data.count <= maximumCaptureBytes else {
            throw MaterialBundleError.tooLarge
        }
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["schemaVersion"] as? Int) == 1,
              (object["bundleKind"] as? String) == "pbr-capture",
              (object["runtimeAdmitted"] as? Bool) == false,
              let idString = object["captureId"] as? String,
              let captureID = UUID(uuidString: idString),
              let label = object["semanticLabel"] as? String,
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              label.count <= 240,
              let category = object["category"] as? String,
              !category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              category.count <= 120,
              let algorithmVersion = object["algorithmVersion"] as? String,
              !algorithmVersion.isEmpty, algorithmVersion.count <= 80,
              let recipe = object["recipe"] as? [String: Any],
              let capture = object["capture"] as? [String: Any],
              let derived = object["derived"] as? [String: Any],
              let seams = object["seamMetrics"] as? [String: Any],
              let mime = object["sourceMime"] as? String,
              mime == "image/png",
              let base64 = object["sourceBase64"] as? String,
              let source = Data(base64Encoded: base64),
              let expectedHash = object["sourceSHA256"] as? String
        else { throw MaterialBundleError.invalidCapture("required envelope fields are missing") }
        try verifyRecipe(recipe)
        try verifyCaptureMetadata(capture)
        try verifySeamMetrics(seams)
        let requiredMaps: Set<String> = [
            "albedo", "height", "normal", "roughness", "ao",
            "cavity", "convexity", "slope", "edge"
        ]
        guard requiredMaps.isSubset(of: Set(derived.keys)) else {
            throw MaterialBundleError.invalidCapture("required derived maps are missing")
        }
        guard !containsGPS(object) else {
            throw MaterialBundleError.invalidCapture("location metadata is not allowed")
        }
        try verifyDigest(source, expected: expectedHash, label: "source")
        let sourceSize = try verifyImage(source, mime: mime, maxSide: 4096, square: true)
        try verifyEmbeddedPhoto(capture, prefix: "original")
        try verifyEmbeddedPhoto(capture, prefix: "fallbackOriginal")
        do {
            let allowed = Set(MaterialMapKind.allCases.map(\.exportedName))
            for (name, raw) in derived {
                guard allowed.contains(name),
                      let record = raw as? [String: Any],
                      (record["mime"] as? String) == "image/png",
                      let encoded = record["base64"] as? String,
                      let bytes = Data(base64Encoded: encoded),
                      let digest = record["sha256"] as? String,
                      let width = record["width"] as? Int,
                      let height = record["height"] as? Int,
                      let format = record["pixelFormat"] as? String
                else { throw MaterialBundleError.invalidCapture("derived map metadata is incomplete") }
                try verifyDigest(bytes, expected: digest, label: name)
                let actual = try verifyImage(bytes, mime: "image/png", maxSide: 4096, square: true)
                guard actual.width == width, actual.height == height,
                      width == sourceSize.width, height == sourceSize.height
                else { throw MaterialBundleError.invalidCapture("\(name) dimensions mismatch") }
                if name == "height" {
                    guard format == "r16_unorm_png", actual.bitsPerComponent == 16 else {
                        throw MaterialBundleError.invalidCapture("height must be 16-bit grayscale PNG")
                    }
                } else {
                    guard format == (name == "albedo" ? "rgba8_srgb_png" : "rgba8_linear_png"),
                          actual.bitsPerComponent == 8
                    else { throw MaterialBundleError.invalidCapture("\(name) has unsupported pixel format") }
                }
            }
        }
        object.removeValue(forKey: "link")
        let sanitized = try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys]
        )
        guard sanitized.count <= maximumCaptureBytes else { throw MaterialBundleError.tooLarge }
        return CaptureInspection(
            captureID: captureID, semanticLabel: label,
            category: category,
            sourcePNG: source, sanitizedEnvelope: sanitized
        )
    }

    static func importCapture(_ data: Data) throws -> MaterialSource {
        let inspection = try inspectCapture(data)
        try MaterialLibrary.prepareDirectories()
        let base = MaterialLibrary.inbox.appendingPathComponent(
            inspection.captureID.uuidString.lowercased()
        )
        let captureURL = base.appendingPathExtension("pbrcapture")
        let imageURL = base.appendingPathExtension("png")
        let fm = FileManager.default
        guard !fm.fileExists(atPath: captureURL.path), !fm.fileExists(atPath: imageURL.path) else {
            throw MaterialBundleError.duplicateCapture
        }
        let temp = MaterialLibrary.inbox.appendingPathComponent(
            ".\(inspection.captureID.uuidString).tmp"
        )
        try fm.createDirectory(at: temp, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: temp) }
        let tempCapture = temp.appendingPathComponent(captureURL.lastPathComponent)
        let tempImage = temp.appendingPathComponent(imageURL.lastPathComponent)
        try inspection.sanitizedEnvelope.write(to: tempCapture, options: .atomic)
        try inspection.sourcePNG.write(to: tempImage, options: .atomic)
        try fm.moveItem(at: tempCapture, to: captureURL)
        do {
            try fm.moveItem(at: tempImage, to: imageURL)
        } catch {
            try? fm.removeItem(at: captureURL)
            throw error
        }
        return MaterialSource(
            id: "capture:\(inspection.captureID.uuidString.lowercased())",
            url: imageURL, semanticLabel: inspection.semanticLabel,
            category: inspection.category, origin: .cameraInbox,
            reviewStatus: "capture estimate",
            originalEnvelopeURL: captureURL
        )
    }

    private static func verifyRecipe(_ recipe: [String: Any]) throws {
        guard let preset = recipe["preset"] as? String, !preset.isEmpty,
              let polarity = recipe["heightPolarity"] as? Int,
              polarity == -1 || polarity == 1,
              recipe["tileWrap"] as? Bool != nil,
              recipe["bentNormal"] as? Bool != nil
        else { throw MaterialBundleError.invalidCapture("recipe is incomplete") }
        for key in ["heightStrength", "roughnessBase", "roughnessVariation", "aoRadiusPixels"] {
            guard let value = recipe[key] as? Double, value.isFinite else {
                throw MaterialBundleError.invalidCapture("recipe \(key) is missing or non-finite")
            }
        }
    }

    private static func verifyCaptureMetadata(_ capture: [String: Any]) throws {
        for key in ["capturedAt", "orientation", "colorProfile", "captureMode"] {
            guard let text = capture[key] as? String, !text.isEmpty, text.count <= 240 else {
                throw MaterialBundleError.invalidCapture("capture \(key) is missing")
            }
        }
        guard let crop = capture["crop"] as? [String: Any],
              Set(["topLeft", "topRight", "bottomRight", "bottomLeft"])
                .isSubset(of: Set(crop.keys))
        else { throw MaterialBundleError.invalidCapture("capture crop is missing") }
        for name in ["topLeft", "topRight", "bottomRight", "bottomLeft"] {
            guard let point = crop[name] as? [String: Any],
                  let x = point["x"] as? Double, x.isFinite, (0...1).contains(x),
                  let y = point["y"] as? Double, y.isFinite, (0...1).contains(y)
            else { throw MaterialBundleError.invalidCapture("capture crop point is invalid") }
        }
        if let raw = capture["constantColorCenterConfidence"] {
            guard let value = raw as? Double, value.isFinite, (0...1).contains(value) else {
                throw MaterialBundleError.invalidCapture("Constant Color center confidence is invalid")
            }
        }
    }

    private static func verifySeamMetrics(_ seams: [String: Any]) throws {
        for key in ["albedoValueDelta", "heightValueDelta", "heightGradientDelta"] {
            guard let value = seams[key] as? Double, value.isFinite, value >= 0 else {
                throw MaterialBundleError.invalidCapture("seam metric \(key) is missing or invalid")
            }
        }
    }

    private static func verifyEmbeddedPhoto(
        _ capture: [String: Any], prefix: String
    ) throws {
        let fields = ["Mime", "Base64", "SHA256", "Width", "Height"]
        guard fields.contains(where: { capture[prefix + $0] != nil }) else { return }
        guard let mime = capture[prefix + "Mime"] as? String,
              ["image/jpeg", "image/png", "image/heic"].contains(mime),
              let encoded = capture[prefix + "Base64"] as? String,
              let bytes = Data(base64Encoded: encoded),
              let digest = capture[prefix + "SHA256"] as? String,
              let width = capture[prefix + "Width"] as? Int,
              let height = capture[prefix + "Height"] as? Int
        else { throw MaterialBundleError.invalidCapture("\(prefix) photo metadata is incomplete") }
        try verifyDigest(bytes, expected: digest, label: prefix)
        let actual = try verifyImage(bytes, mime: mime, maxSide: 8192, square: false)
        guard actual.width == width, actual.height == height,
              actual.width * actual.height <= 50_000_000
        else { throw MaterialBundleError.invalidCapture("\(prefix) photo dimensions mismatch") }
    }

    private static func verifyDigest(_ data: Data, expected: String, label: String) throws {
        guard expected.count == 64,
              expected.allSatisfy({ $0.isHexDigit }),
              sha256(data).caseInsensitiveCompare(expected) == .orderedSame
        else { throw MaterialBundleError.invalidCapture("\(label) SHA-256 mismatch") }
    }

    private static func verifyImage(
        _ data: Data, mime: String, maxSide: Int, square: Bool
    ) throws -> (width: Int, height: Int, bitsPerComponent: Int) {
        if mime == "image/png" {
            guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
                throw MaterialBundleError.invalidCapture("PNG signature mismatch")
            }
        }
        let expectedType: String
        switch mime {
        case "image/png": expectedType = "public.png"
        case "image/jpeg": expectedType = "public.jpeg"
        case "image/heic": expectedType = "public.heic"
        default: throw MaterialBundleError.invalidCapture("unsupported image MIME")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              (CGImageSourceGetType(source) as String?) == expectedType,
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width >= 2, image.height >= 2,
              image.width <= maxSide, image.height <= maxSide,
              !square || image.width == image.height
        else { throw MaterialBundleError.invalidCapture("image failed full decode or dimension check") }
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
           containsGPS(properties) {
            throw MaterialBundleError.invalidCapture("embedded image location metadata is not allowed")
        }
        return (image.width, image.height, image.bitsPerComponent)
    }

    static func export(_ material: DerivedMaterial, into folder: URL) throws -> URL {
        let fm = FileManager.default
        let slug = material.source.semanticLabel.lowercased()
            .map { character -> Character in
                character.isLetter || character.isNumber ? character : "-"
            }
        let name = String(slug).replacingOccurrences(of: "--", with: "-")
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let final = folder.appendingPathComponent("\(name)-\(suffix).pbrmaterial", isDirectory: true)
        let temp = folder.appendingPathComponent(".material-lab-\(suffix).tmp", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: temp) }
        var mapManifest: [String: [String: Any]] = [:]
        for kind in MaterialMapKind.allCases {
            guard let map = material.maps[kind] else { continue }
            let filename = "\(kind.exportedName).png"
            let url = temp.appendingPathComponent(filename)
            try writePNG(map, to: url)
            let saved = try Data(contentsOf: url)
            mapManifest[kind.exportedName] = [
                "file": filename,
                "sha256": sha256(saved),
                "width": map.width,
                "height": map.height,
                "pixel_format": map.format == .rgba8SRGB ? "rgba8_srgb_png" : (map.format == .r16Linear ? "r16_unorm_png" : "rgba8_linear_png"),
                "provenance": provenance(for: kind, recipe: material.recipe)
            ]
        }
        let recipe = material.recipe
        let manifest: [String: Any] = [
            "schema_version": 1,
            "bundle_kind": "pbr-material-bundle",
            "algorithm_version": material.algorithmVersion,
            "material_id": "\(material.source.semanticLabel)-\(material.sourceSHA256.prefix(12))",
            "semantic_label": material.source.semanticLabel,
            "category": material.source.category,
            "source": [
                "path": material.source.url.lastPathComponent,
                "sha256": material.sourceSHA256,
                "color_space": "sRGB",
                "origin": material.source.origin.rawValue,
                "working_image": [
                    "width": 1024,
                    "height": 1024,
                    "crop": "center_square",
                    "resample": "CoreGraphics_high_quality",
                    "color_conversion": "tagged_input_to_sRGB_RGBA8",
                    "alpha": "straight_after_unpremultiply"
                ]
            ],
            "recipe": [
                "preset": recipe.preset.rawValue,
                "height_strength": recipe.heightStrength,
                "height_polarity": recipe.heightPolarity,
                "roughness_base": recipe.roughnessBase,
                "roughness_variation": recipe.roughnessVariation,
                "ao_radius_pixels": recipe.aoRadiusPixels,
                "tile_wrap": recipe.tileWrap,
                "assigned_metalness_enabled": recipe.assignedMetalnessEnabled,
                "assigned_metalness": recipe.assignedMetalness,
                "bent_normal_enabled": recipe.bentNormalEnabled,
                "relief_mask": recipe.reliefMaskURL?.lastPathComponent as Any,
                "height_override": recipe.heightOverrideURL?.lastPathComponent as Any
            ],
            "maps": mapManifest,
            "seam_metrics": [
                "height_value_delta": material.seams.heightValue,
                "height_gradient_delta": material.seams.heightGradient,
                "albedo_value_delta": material.seams.albedoValue
            ],
            "estimation_notice": "Geometry and reflectance maps are estimates, not measured surface properties.",
            "runtime_admitted": false
        ]
        var cleanManifest = manifest
        var recipeManifest = cleanManifest["recipe"] as! [String: Any]
        recipeManifest = recipeManifest.filter { !($0.value is NSNull) }
        if recipe.reliefMaskURL == nil { recipeManifest.removeValue(forKey: "relief_mask") }
        if recipe.heightOverrideURL == nil { recipeManifest.removeValue(forKey: "height_override") }
        cleanManifest["recipe"] = recipeManifest
        guard JSONSerialization.isValidJSONObject(cleanManifest) else {
            throw MaterialBundleError.exportFailed("manifest serialization")
        }
        let json = try JSONSerialization.data(withJSONObject: cleanManifest, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: temp.appendingPathComponent("manifest.json"), options: .atomic)
        try fm.moveItem(at: temp, to: final)
        return final
    }

    private static func writePNG(_ map: MaterialMapData, to url: URL) throws {
        let provider = CGDataProvider(data: map.bytes as CFData)
        let colorSpace: CGColorSpace?
        let bitmap: CGBitmapInfo
        let depth: Int
        let pixelDepth: Int
        if map.format == .r16Linear {
            colorSpace = CGColorSpaceCreateDeviceGray()
            bitmap = .byteOrder16Little
            depth = 16
            pixelDepth = 16
        } else {
            colorSpace = CGColorSpace(name: map.format == .rgba8SRGB
                                     ? CGColorSpace.sRGB : CGColorSpace.linearSRGB)
            bitmap = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
                .union(.byteOrder32Big)
            depth = 8
            pixelDepth = 32
        }
        guard let provider, let colorSpace,
              let image = CGImage(
                width: map.width, height: map.height,
                bitsPerComponent: depth, bitsPerPixel: pixelDepth,
                bytesPerRow: map.rowBytes, space: colorSpace,
                bitmapInfo: bitmap, provider: provider,
                decode: nil, shouldInterpolate: false,
                intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil
              )
        else { throw MaterialBundleError.exportFailed("PNG encoder rejected a map") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw MaterialBundleError.exportFailed("PNG encoder failed")
        }
    }

    private static func provenance(for kind: MaterialMapKind, recipe: MaterialRecipe) -> String {
        switch kind {
        case .albedo: "source_color_resampled_srgb"
        case .roughness: "artist_prior_with_estimated_variation"
        case .orm: recipe.assignedMetalnessEnabled
            ? "estimated_ao_roughness_plus_artist_assigned_metalness"
            : "unavailable_without_artist_assigned_metalness"
        case .height: recipe.heightOverrideURL == nil
            ? "pseudo_height_estimated_from_color"
            : "authored_height_override"
        default: recipe.heightOverrideURL == nil
            ? "derived_from_estimated_pseudo_height"
            : "derived_from_authored_height_override"
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func containsGPS(_ value: Any?) -> Bool {
        guard let value else { return false }
        if let dictionary = value as? [String: Any] {
            return dictionary.contains {
                $0.key.lowercased().contains("gps") ||
                $0.key.lowercased().contains("location") ||
                $0.key.lowercased().contains("latitude") ||
                $0.key.lowercased().contains("longitude") ||
                containsGPS($0.value)
            }
        }
        if let array = value as? [Any] { return array.contains(where: { containsGPS($0) }) }
        return false
    }
}
