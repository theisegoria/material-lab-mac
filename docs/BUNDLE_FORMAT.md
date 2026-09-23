# Material Lab bundle formats

Two formats have different jobs and intentionally different extensions.

| Extension | Shape | Producer | Use |
| --- | --- | --- | --- |
| .pbrcapture | One bounded UTF-8 JSON file | Material Capture for iPhone | Original/cropped photo, capture metadata, on-device derivation, Files/AirDrop import, and direct local transfer to Mac |
| .pbrmaterial | Directory containing manifest.json and PNG maps | Material Lab for Mac or CLI | Reviewed, editable derivation export for a game or DCC import adapter |

A Mac import validates a .pbrcapture file, saves it in the separate camera inbox, and may re-derive/export a .pbrmaterial package. Files/AirDrop and the direct local link use the same capture schema. Only the local-link copy adds an ephemeral link token.

## Capture envelope, schema version 1

The required JSON fields are schemaVersion, bundleKind, captureId (UUID), semanticLabel, category, sourceMime (image/png), sourceBase64 (canonical corrected square PNG), sourceSHA256 (hash of decoded PNG bytes), algorithmVersion, recipe, capture, derived, seamMetrics, and runtimeAdmitted=false. The capture metadata records orientation, color profile, capture mode, crop, quality diagnostics, and Constant Color confidence where present. An optional privacy-scrubbed primary original has originalMime, originalBase64, originalSHA256, originalWidth, and originalHeight; originalOmissionReason explains its absence when captured but too large. A Constant Color fallback photo, when captured, uses fallbackOriginalMime, fallbackOriginalBase64, fallbackOriginalSHA256, fallbackOriginalWidth, and fallbackOriginalHeight; fallbackOmissionReason explains why it could not be embedded. fallbackUsed says whether low confidence caused the fallback to supply the cropped source image. Every embedded original has its own hash and decoded dimensions. The nine required derived roles are albedo, height, normal, roughness, AO, cavity, convexity, slope, and edge; bent normal and ORM are optional. Each map records MIME, pixel encoding, dimensions, provenance, bytes, and SHA-256. No GPS metadata is exported.

The framed local link sends one four-byte big-endian byte count, then UTF-8 JSON of at most 64 MiB. The Mac validates the frame bound and all declared hashes before asking for per-capture approval. A successful atomic inbox write produces a framed acknowledgement. Invalid, duplicate, expired, denied, and interrupted transfers must not create a completed inbox item.

## Material export, schema version 1

The manifest holds a semantic label and stable material ID; source hash, color-space and origin; algorithm version; complete recipe; map filename, hash, dimensions, encoding, and per-map provenance; seam metrics; and runtime_admitted=false. Each PNG file is checked against its manifest hash by the CLI validator. The albedo is sRGB RGBA8, normal and scalar maps are linear RGBA8, and height is R16 UNorm. ORM exists only if metalness was assigned. When a local pre-upscaler runs, `source.sha256` identifies the original input, `source.processed_sha256` identifies the image used for derivation, and `source.pre_upscale` records the executable and argument hashes, output dimensions, and, when the tool emits one, a receipt with its original JSON bytes and SHA-256. The validator checks these saved claims for internal consistency; the temporary processed image is not retained in the bundle, so an independently supplied processed image is needed to recompute its hash. Source and capture provenance must distinguish authored height from estimated pseudo-height and a user-selected roughness prior from measured roughness.

A game-specific cooker adapter is free to consume selected maps. Material Lab itself does not place them in a runtime catalog.
