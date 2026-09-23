# Material Lab bundle formats

Two formats have different jobs and intentionally different extensions.

| Extension | Shape | Producer | Use |
| --- | --- | --- | --- |
| .pbrcapture | One bounded UTF-8 JSON file | Material Capture for iPhone | Original/cropped photo, capture metadata, on-device derivation, Files/AirDrop import, and direct local transfer to Mac |
| .pbrmaterial | Directory containing manifest.json and PNG maps | Material Lab for Mac or CLI | Reviewed, editable derivation export for a game or DCC import adapter |

A Mac import validates a .pbrcapture file, saves it in the separate camera inbox, and may re-derive/export a .pbrmaterial package. Files/AirDrop and the direct local link use the same capture schema. Only the local-link copy adds an ephemeral link token.

## Capture envelope, schema version 1

The required JSON fields are schemaVersion, bundleKind, captureId (UUID), semanticLabel, category, sourceMime (image/png), sourceBase64 (canonical corrected square PNG), sourceSHA256 (hash of decoded PNG bytes), algorithmVersion, recipe, capture, derived, seamMetrics, and runtimeAdmitted=false. The capture metadata records orientation, color profile, capture mode, crop, quality diagnostics, and Constant Color confidence where present. An optional privacy-scrubbed original has its own MIME, dimensions, base64, and SHA-256. Derived maps each record MIME, pixel encoding, dimensions, provenance, bytes, and SHA-256. No GPS metadata is exported.

The framed local link sends one four-byte big-endian byte count, then UTF-8 JSON of at most 64 MiB. The Mac validates the frame bound and all declared hashes before asking for per-capture approval. A successful atomic inbox write produces a framed acknowledgement. Invalid, duplicate, expired, denied, and interrupted transfers must not create a completed inbox item.

## Material export, schema version 1

The manifest holds a semantic label and stable material ID; source hash, color-space and origin; algorithm version; complete recipe; map filename, hash, dimensions, encoding, and per-map provenance; seam metrics; and runtime_admitted=false. Each PNG file is checked against its manifest hash by the CLI validator. The albedo is sRGB RGBA8, normal and scalar maps are linear RGBA8, and height is R16 UNorm. ORM exists only if metalness was assigned. Source and capture provenance must distinguish authored height from estimated pseudo-height and a user-selected roughness prior from measured roughness.

A game-specific cooker adapter is free to consume selected maps. Material Lab itself does not place them in a runtime catalog.
