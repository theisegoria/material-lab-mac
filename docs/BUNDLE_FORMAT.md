# Material Lab bundle formats

Two formats have different jobs and intentionally different extensions.

| Extension | Shape | Producer | Use |
| --- | --- | --- | --- |
| .pbrcapture | One bounded UTF-8 JSON file | Material Capture for iPhone | Original/cropped photo, capture metadata, on-device derivation, Files/AirDrop import, and direct local transfer to Mac |
| .pbrmaterial | Directory containing manifest.json and PNG maps | Material Lab for Mac or CLI | Reviewed, editable derivation export for a game or DCC import adapter |

A Mac import validates a .pbrcapture file, saves it in the separate camera inbox, and may re-derive/export a .pbrmaterial package. Files/AirDrop and the direct local link use the same capture schema. Only the local-link copy adds an ephemeral link token.

## Algorithm versions and recipe fields

Both formats carry the core algorithm version (`algorithm_version` / `algorithmVersion`). Validators accept `1.0.0`, `1.1.0`, `1.2.0`, `1.3.0` and `1.4.0`. A field introduced by a version is required from that version on:

| Since | `.pbrmaterial` recipe (snake_case) | `.pbrcapture` recipe (camelCase) | Range |
| --- | --- | --- | --- |
| 1.1.0 | `normal_strength` | `normalStrength` | 0–16 |
| 1.1.0 | `normal_y_down` (bool) | `normalYDown` (bool) | — |
| 1.1.0 | `ao_strength` | `aoStrength` | 0–4 |
| 1.1.0 | `albedo_equalize` | `albedoEqualize` | 0–1 |
| 1.1.0 | `seamless_blend` | `seamlessBlend` | 0–0.45 |
| 1.2.0 | `guide_normal_weight` | `guideNormalWeight` | 0–1 |
| 1.2.0 (optional) | `seamless_mode` | `seamlessMode` | `"cut"` or `"blend"`; absent means `"blend"` |

Algorithm 1.3.0 keeps the recipe fields but changes three meanings: `ao_radius_pixels` is in pixels of a 1024² reference (it scales with the tile), `height_strength` scales a per-preset target rms surface slope instead of a luminance difference, and `normal_strength` scales the whole estimated surface (normals, AO, diagnostics and the height span). Estimated height is **range-normalized** (lowest point 0, highest 65535) instead of centred on 0.5, so a 1.3.0 `.pbrmaterial` manifest must carry a top-level `relief` object:

| Field | Range | Meaning |
| --- | --- | --- |
| `height_span_tile_widths` | ≥ 0 | Depth between height 0 and 1, in tile widths (multiply by the tile's world size for displacement). 0 means no relief (height is a constant 0.5). For an authored height it is the depth the core assumed for its full range. |
| `rms_slope` | ≥ 0 | Root-mean-square surface slope (tangent) of the derived geometry. |
| `learned_form_share` | 0–1 | Share of slope energy taken from learned form (0 without guide normals). |
| `learned_detail_correlation` | −1–1 | Correlation of learned and albedo relief in the σ 3–8 px band. |
| `detail_polarity` | ±1 | Sign applied to albedo-derived fine relief (+1 = bright raised). |
| `height_wrap_seam_ratio` | ≥ 0 | Mean opposite-edge height step divided by the mean adjacent step; about 1 means the height tiles without a visible seam. Use it instead of `seam_metrics.height_value_delta`, whose scale now depends on the relief. |

### Albedo repair (1.4.0)

`recipe.albedo_repair` is `"off"`, `"blend"`, `"quilt"` or `"auto"` (absent means off; values other than off need 1.4.0). When it is not off, the albedo is **derived data**, not the source: `maps.albedo.provenance` is `repaired_tileable_albedo_derived_from_source`, and a top-level `albedo_repair` object is required:

| Field | Meaning |
| --- | --- |
| `mode` | Equal to `recipe.albedo_repair`. |
| `method` | `quilt` or `blend`, the method applied (auto records its choice). |
| `band_fraction` | Band per edge, fraction of the tile (0.12 when `seamless_blend` was 0). |
| `cut_cost_ratio` | Quilt cut visibility (cut mismatch / neighbouring-pixel mismatch); auto keeps the quilt at ≤ 4. |
| `offset_px` | `[x, y]` offsets of the copy used on each axis. |
| `albedo_equalize` | Delighting applied before the repair. |
| `source_sha256` | Hash of the source file (the processed file after a pre-upscale), equal to `source.sha256` / `source.processed_sha256`. |
| `source_rgba8_sha256`, `repaired_rgba8_sha256` | Hashes of the decoded source and repaired RGBA8 pixels. |
| `seam_before`, `seam_after` | Wrap-seam measures of linear-light luminance: `pixel_x`, `pixel_y`, `tone_x`, `tone_y`, `detail` ([derivation](DERIVATION.md)). |
| `seam_measure` | `linear_light_luminance_v1`. |

Validators reject a repaired material without this object, with a mismatched mode, method or source hash, malformed hashes or seam measures, or without the repaired-albedo provenance, and reject the object when the recipe says off. Bundles without repair are unchanged apart from `recipe.albedo_repair: "off"`.

Validators reject a 1.3.0 or later material without a valid `relief` and validate one on any version when present. `.pbrcapture` envelopes do not carry it.

From 1.1.0 on, a material manifest also records `normal_convention` (`+Y` or `-Y`, matching `normal_y_down`). **Algorithm 1.0.0 normal and bent-normal maps are green-down even though they are labelled +Y.** Validators print a warning for these bundles; re-derive them or flip green. When `guide_normal_weight > 0`, the manifest has a top-level `guide_normals` provenance object ([learned normals](LEARNED_NORMALS.md)). Validators reject a guide weight without provenance, and provenance without a guide weight.

## Capture envelope, schema version 1

The required JSON fields are schemaVersion, bundleKind, captureId (UUID), semanticLabel, category, sourceMime (image/png), sourceBase64 (canonical corrected square PNG), sourceSHA256 (hash of decoded PNG bytes), algorithmVersion, recipe, capture, derived, seamMetrics, and runtimeAdmitted=false. The capture metadata records orientation, color profile, capture mode, crop, quality diagnostics, and Constant Color confidence where present. An optional privacy-scrubbed primary original has originalMime, originalBase64, originalSHA256, originalWidth, and originalHeight; originalOmissionReason explains its absence when captured but too large. A Constant Color fallback photo, when captured, uses fallbackOriginalMime, fallbackOriginalBase64, fallbackOriginalSHA256, fallbackOriginalWidth, and fallbackOriginalHeight; fallbackOmissionReason explains why it could not be embedded. fallbackUsed says whether low confidence caused the fallback to supply the cropped source image. Every embedded original has its own hash and decoded dimensions. The nine required derived roles are albedo, height, normal, roughness, AO, cavity, convexity, slope, and edge; bent normal and ORM are optional. Each map records MIME, pixel encoding, dimensions, provenance, bytes, and SHA-256. No GPS metadata is exported.

The framed local link sends one four-byte big-endian byte count, then UTF-8 JSON of at most 64 MiB. The Mac validates the frame bound and all declared hashes before asking for per-capture approval. A successful atomic inbox write produces a framed acknowledgement. Invalid, duplicate, expired, denied, and interrupted transfers must not create a completed inbox item.

## Material export, schema version 1

The manifest holds a semantic label and stable material ID; source hash, color-space and origin; algorithm version; complete recipe; map filename, hash, dimensions, encoding, and per-map provenance; seam metrics; and runtime_admitted=false. Each PNG file is checked against its manifest hash by the CLI validator. The albedo is sRGB RGBA8, normal and scalar maps are linear RGBA8, and height is R16 UNorm. ORM exists only if metalness was assigned. When a local pre-upscaler runs, `source.sha256` identifies the original input, `source.processed_sha256` identifies the image used for derivation, and `source.pre_upscale` records the executable and argument hashes, output dimensions, and, when the tool emits one, a receipt with its original JSON bytes and SHA-256. The validator checks these saved claims for internal consistency; the temporary processed image is not retained in the bundle, so an independently supplied processed image is needed to recompute its hash. Source and capture provenance must distinguish authored height from estimated pseudo-height and a user-selected roughness prior from measured roughness.

A game-specific cooker adapter is free to consume selected maps. Material Lab itself does not place them in a runtime catalog.
