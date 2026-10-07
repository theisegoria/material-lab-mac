import CryptoKit
import Foundation

/// Writes a full-resolution derivation as a .pbrmaterial bundle (every map as PNG plus manifest.json), the same
/// format as the Mac app and the CLI, so `material-lab --validate` accepts it and the shared exporter can turn it into
/// glTF, USDZ, Unreal, Unity and the other targets.
enum MaterialBundleWriter {
    struct Identity {
        let label: String
        let category: String
        let origin: SourceImage.Origin
        let captureMode: String
    }

    enum WriterError: LocalizedError {
        case previewOnly, missingMap(String), missingRelief
        var errorDescription: String? {
            switch self {
            case .previewOnly: "Derive at full resolution before exporting."
            case .missingMap(let name): "The \(name) map is missing from this derivation."
            case .missingRelief: "This derivation has no geometry diagnostics; derive it again."
            }
        }
    }

    /// Writes `name.pbrmaterial` into `folder` (which must exist) and returns its URL.
    static func write(_ material: DerivedMaterial, identity: Identity, into folder: URL, name: String) throws -> URL {
        guard !material.isPreview else { throw WriterError.previewOnly }
        guard let relief = material.relief else { throw WriterError.missingRelief }
        let fm = FileManager.default
        let final = folder.appending(path: "\(name).pbrmaterial", directoryHint: .isDirectory)
        let temp = folder.appending(path: ".\(name)-\(UUID().uuidString.prefix(8)).tmp", directoryHint: .isDirectory)
        try fm.createDirectory(at: temp, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: temp) }

        let recipe = material.recipe
        let learned = material.guideNormals != nil && recipe.guideNormalWeight > 0
        let repaired = material.repair != nil
        var maps: [String: Any] = [:]
        for kind in MaterialMapKind.allCases {
            let wanted = kind == .orm ? recipe.assignedMetalness != nil : kind == .bentNormal ? recipe.bentNormal : true
            guard wanted else { continue }
            guard let map = material.maps[kind], !map.png.isEmpty else { throw WriterError.missingMap(kind.exportedName) }
            let file = "\(kind.exportedName).png"
            try map.png.write(to: temp.appending(path: file), options: .atomic)
            maps[kind.exportedName] = [
                "file": file, "sha256": sha256(map.png), "width": map.width, "height": map.height,
                "pixel_format": map.pixelFormat,
                "provenance": provenance(kind, recipe: recipe, learned: learned, repaired: repaired,
                                         authored: material.authored)
            ] as [String: Any]
        }

        let sourceDigest = sha256(material.sourcePNG)
        var recipeManifest: [String: Any] = [
            "preset": priorName(recipe.preset),
            "height_strength": tidy(recipe.heightStrength),
            "height_polarity": Int(recipe.heightPolarity),
            "roughness_base": tidy(recipe.roughnessBase),
            "roughness_variation": tidy(recipe.roughnessVariation),
            "ao_radius_pixels": tidy(recipe.aoRadiusPixels),
            "tile_wrap": recipe.tileWrap,
            "assigned_metalness_enabled": recipe.assignedMetalness != nil,
            "assigned_metalness": tidy(recipe.assignedMetalness ?? 0),
            "bent_normal_enabled": recipe.bentNormal,
            "normal_strength": tidy(recipe.normalStrength),
            "normal_y_down": recipe.normalYDown,
            "ao_strength": tidy(recipe.aoStrength),
            "albedo_equalize": tidy(recipe.albedoEqualize),
            "seamless_blend": tidy(recipe.seamlessBlend),
            "seamless_mode": recipe.seamlessMode.rawValue,
            "albedo_repair": (material.repair?.mode ?? .off).rawValue,
            "guide_normal_weight": tidy(learned ? recipe.guideNormalWeight : 0)
        ]
        if let preset = recipe.materialPreset { recipeManifest["material_preset"] = preset }
        var manifest: [String: Any] = [
            "schema_version": 1,
            "bundle_kind": "pbr-material-bundle",
            "algorithm_version": material.algorithmVersion,
            "material_id": "\(identity.label)-\(sourceDigest.prefix(12))",
            "semantic_label": identity.label,
            "category": identity.category,
            "source": [
                "path": "perspective-corrected-crop.png",
                "sha256": sourceDigest,
                "color_space": "sRGB",
                "origin": identity.origin.rawValue,
                "capture_mode": identity.captureMode,
                "source_kind": material.authored.handMadeAlbedo ? "authored_albedo" : "photograph",
                "working_image": [
                    "width": material.resolution, "height": material.resolution,
                    "crop": "perspective_corrected_quad",
                    "color_conversion": "tagged_input_to_sRGB_RGBA8"
                ] as [String: Any]
            ] as [String: Any],
            "recipe": recipeManifest,
            "normal_convention": recipe.normalYDown ? "-Y" : "+Y",
            "maps": maps,
            "seam_metrics": [
                "height_value_delta": tidy(material.seam.heightValueDelta),
                "height_gradient_delta": tidy(material.seam.heightGradientDelta),
                "albedo_value_delta": tidy(material.seam.albedoValueDelta)
            ],
            "relief": [
                "height_span_tile_widths": tidy(relief.heightSpanTileWidths),
                "rms_slope": tidy(relief.rmsSlope),
                "learned_form_share": tidy(relief.learnedFormShare),
                "learned_detail_correlation": tidy(relief.learnedDetailCorrelation),
                "detail_polarity": relief.detailPolarity,
                "height_wrap_seam_ratio": tidy(relief.heightWrapSeamRatio)
            ] as [String: Any],
            "estimation_notice": "Geometry and reflectance maps are estimates, not measured surface properties.",
            "runtime_admitted": false
        ]
        if !material.authored.maps.isEmpty {
            manifest["authored_inputs"] = Dictionary(uniqueKeysWithValues: material.authored.maps.map { role, map in
                (role.rawValue, ["file": map.name, "sha256": map.sha256])
            })
        }
        if learned, let guide = material.guideNormals {
            manifest["guide_normals"] = [
                "estimator": guide.estimator, "contract": guide.contract, "weights_sha256": guide.weightsSHA256,
                "moge_commit": guide.mogeCommit, "model_file": guide.modelFile, "compute_units": guide.computeUnits,
                "work_resolution": guide.workResolution, "tiles": guide.tiles, "tiling": guide.tiling ?? "",
                "normals_sha256": guide.normalsSHA256
            ] as [String: Any]
        }
        if let repair = material.repair, let digests = material.repairDigests {
            func seam(_ s: AlbedoRepairResult.Seam) -> [String: Any] {
                ["pixel_x": tidy(s.pixelX), "pixel_y": tidy(s.pixelY), "tone_x": tidy(s.toneX),
                 "tone_y": tidy(s.toneY), "detail": tidy(s.detail)]
            }
            manifest["albedo_repair"] = [
                "mode": repair.mode.rawValue, "method": repair.method.rawValue,
                "band_fraction": tidy(repair.bandFraction), "cut_cost_ratio": tidy(repair.cutCostRatio),
                "offset_px": repair.offsetPx, "albedo_equalize": tidy(recipe.albedoEqualize),
                "source_sha256": sourceDigest,
                "source_rgba8_sha256": digests.sourceRGBA8, "repaired_rgba8_sha256": digests.repairedRGBA8,
                "seam_before": seam(repair.seamBefore), "seam_after": seam(repair.seamAfter),
                "seam_measure": repair.seamMeasure
            ] as [String: Any]
        }
        let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: temp.appending(path: "manifest.json"), options: .atomic)
        if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
        try fm.moveItem(at: temp, to: final)
        return final
    }

    static func priorName(_ preset: MaterialPreset) -> String {
        switch preset {
        case .coatedMetal: "coated-metal"
        case .bareMetal: "bare-metal"
        default: preset.rawValue
        }
    }

    private static func provenance(_ kind: MaterialMapKind, recipe: MaterialRecipe, learned: Bool, repaired: Bool,
                                   authored: AuthoredMaps) -> String {
        let maps = authored.maps
        switch kind {
        case .albedo where !repaired && authored.handMadeAlbedo: return "authored_albedo"
        case .normal where maps[.normal] != nil: return "authored_normal_map"
        case .roughness where maps[.roughness] != nil: return "authored_roughness_map"
        case .ao where maps[.ao] != nil: return "authored_ao_map"
        case .orm where maps[.metalness] != nil || maps[.roughness] != nil || maps[.ao] != nil:
            return "authored_and_estimated_channels"
        case .height where maps[.height] != nil: return "authored_height_override"
        case .height where maps[.normal] != nil: return "integrated_from_authored_normal_map"
        default: break
        }
        return switch kind {
        case .albedo: repaired ? "repaired_tileable_albedo_derived_from_source" : "source_color_resampled_srgb"
        case .roughness: "artist_prior_with_estimated_variation"
        case .orm: "estimated_ao_roughness_plus_artist_assigned_metalness"
        case .height: learned ? (recipe.preset == .flat ? "learned_normals" : "estimated_from_albedo_and_learned_normals")
                              : "pseudo_height_estimated_from_color"
        default: "derived_from_estimated_pseudo_height"
        }
    }

    /// Float parameters at their meaningful precision (0.22 rather than 0.2199999988).
    private static func tidy(_ value: Float) -> Double { Double(String(format: "%.6g", value)) ?? Double(value) }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
