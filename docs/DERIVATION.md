# Derivation model and provenance

Material Lab 1.0.0 is a deterministic, analytical image-to-map estimator. It accepts a color-managed, square, straight RGBA8 image in sRGB. The shared C++23 core converts sRGB channels to linear values for calculations and preserves the sRGB color image for albedo output.

## What the source can and cannot tell us

The height and normal of a photographed surface cannot be uniquely recovered from one color image. Lighting, pigment, specular reflection, shadows, and shape can create the same RGB pattern. MaterIA explicitly combines learned normal inference with integration and heuristic map construction; it also notes the difficulty of inferring roughness from a single observation. Material Lab therefore calls its geometry pseudo-height and its AO heightfield AO. Presets are editable priors, not material recognition.

References:

- [MaterIA: Single Image High-Resolution Material Capture in the Wild](https://perso.telecom-paristech.fr/boubek/papers/MaterIA/MaterIA_lowres.pdf)
- [Horizon-Based Ambient Occlusion](https://developer.download.nvidia.com/presentations/2008/SIGGRAPH/HBAO_SIG08b.pdf)
- [glTF 2.0 material texture conventions](https://github.com/KhronosGroup/glTF/blob/main/specification/2.0/Specification.adoc)

## Algorithm

1. Convert each source sRGB channel to linear light and compute Rec. 709 luminance.
2. Apply three separable box filters at radii 2, 8, and 24 pixels. Differences between the source and these scales form high, middle, and coarse relief signals. The chosen preset weights these bands. Flat is the default for unknown or painted materials and produces no inferred relief.
3. An optional 8-bit relief suppression mask scales inferred signal (0 removes it; 255 retains it). An optional authored 16-bit height replaces inference altogether. Otherwise the signal is scaled by a user-specified amplitude and polarity around neutral 0.5, then clamped and exported as normalized R16 height.
4. Centered differences of height form a normalized tangent-space normal. Encoding follows +Y / green-up tangent convention: as image V increases downwards, a rising height makes the encoded green channel decrease.
5. Eight azimuths with six samples per azimuth form a bounded heightfield horizon estimate. AO is 1 for an open surface. A visibility-weighted direction estimates an optional bent normal. This is a local, discrete approximation informed by HBAO, not a physically measured occlusion field or a direct implementation of the HBAO renderer.
6. A small local height average and gradient provide cavity, convexity, slope, and edge diagnostics.
7. Perceptual roughness begins with the selected material prior. Optional, bounded slope modulation adds restrained spatial variation. Metalness is never inferred: ORM is available only after explicit metalness assignment. The ORM channels are R = AO, G = perceptual roughness, B = assigned metalness.

The tile option wraps all local filters and samples. Value and first-gradient differences across opposite edges are reported separately for height; linear-light albedo edge differences are also reported. Wrapping a filter does not make a non-seamless source seamless.

## Exports

Albedo is sRGB PNG. Tangent normal is linear RGBA8 PNG with alpha 255. Roughness, AO, and diagnostic scalar maps are replicated grayscale linear RGBA8 PNGs with alpha 255. Height is normalized single-channel 16-bit PNG. Map and source hashes, algorithm version, recipe parameters, semantic label, map encodings, and provenance belong in the material manifest. A bundle should be reviewed before an engine-specific import.

The source alone does not determine intrinsic roughness, metalness, specular F0, emission, opacity, thickness, physical depth, or gameplay properties. Normal-variance filtering for rendering is an engine concern and is kept separate from authored roughness.

## Scope of validation

Synthetic tests check flat color, painted checkerboard, authored bump and pit, ramps, mask suppression, normal sign and length, ORM gating, cancellation, and malformed input. CLI validation checks manifest fields and map hashes. GUI, simulator, physical camera, and device link tests have distinct evidence levels; a build does not validate a real iPhone camera or network permission flow.
