# Derivation model and provenance

Material Lab 1.2.0 is a deterministic, analytical image-to-map estimator. It accepts a color-managed, square, straight RGBA8 image in sRGB. The shared C++23 core converts sRGB channels to linear values for calculations. Unless the recipe asks for delighting or tiling, the albedo output is a byte-exact copy of the source.

## What the source can and cannot tell us

The height and normal of a photographed surface cannot be uniquely recovered from one color image. Lighting, pigment, specular reflection, shadows, and shape can create the same RGB pattern. MaterIA combines learned normal inference with integration and heuristic map construction. It also notes how hard it is to infer roughness from a single observation. Material Lab therefore calls its geometry pseudo-height and its AO heightfield AO. Presets are editable priors, not material recognition.

References:

- [MaterIA: Single Image High-Resolution Material Capture in the Wild](https://perso.telecom-paristech.fr/boubek/papers/MaterIA/MaterIA_lowres.pdf)
- Jimenez et al. 2016, *Practical Real-Time Strategies for Accurate Indirect Occlusion* (GTAO), and Intel's MIT-licensed [XeGTAO](https://github.com/GameTechDev/XeGTAO) reference for the bent-normal form
- Efros & Freeman 2001, *Image Quilting for Texture Synthesis and Transfer* (minimum-error boundary cut)
- Heitz & Neyret 2018, *High-Performance By-Example Noise using a Histogram-Preserving Blending Operator* (HPG)
- [glTF 2.0 material texture conventions](https://github.com/KhronosGroup/glTF/blob/main/specification/2.0/Specification.adoc)

## Algorithm (1.2.0)

1. **Source conditioning (optional, off by default).**
   - *Equalize* (`albedo_equalize`, 0–1) delights the image. It divides linear RGB by a smooth luminance field whose Gaussian scale is about 1/8 of the tile, pulls it toward the image mean luminance, and raises the gain to the chosen strength. Hue is preserved and the gain is clamped to 0.25–4×.
   - *Make tileable* (`seamless_blend`, 0–0.45 of the width per edge, sets the edge band) has two methods (`seamless_mode`):
     - **Seam cut** (default, `1`). This is a minimum-error boundary cut in the style of image quilting (Efros & Freeman 2001):
       - For each axis, the output uses an offset copy of the image near both opposite edges; the copy is continuous across the wrap. The original is used in the interior.
       - The offset is searched coarse-to-fine to align the texture with itself in the bands, for example a whole number of brick courses. The copy's own seam is kept outside the bands.
       - Each transition follows the lowest-difference path through its band, found by dynamic programming and feathered by only ±2 px.
       - Paths start and end at the same offset, so the other axis stays continuous.
       - Structured textures (brick, tiles, planks) keep crisp features instead of ghosted double edges. Pixels outside the bands are untouched.
     - **Blend** (`0`). A histogram-preserving half-period offset blend (Heitz & Neyret):
       - Each linear channel is Gaussianized through its empirical CDF.
       - Values are blended as `((1−w)·a + w·b) / √((1−w)² + w²)` and mapped back.
       - This preserves contrast in fine stochastic textures, such as noise, sand and grain, whose soft lighting drift would make a cut visible.
     - When a pattern's period does not divide the tile size, a defect somewhere is unavoidable. The cut hides it in one place; the blend spreads it as ghosting.
     - Comparison: [seam cut vs blend on brick](verification/tiling-seam-cut-vs-blend.png).
   - Equalize runs before tiling, so lighting gradients do not become seams. Pseudo-height uses the conditioned image.
2. **Relief bands.** Compute Rec. 709 luminance in linear light. Apply Gaussian-approximating filters (three box passes each) at scales equivalent to 2, 8, and 24 pixel boxes. The differences between successive scales form the high, middle, and coarse relief bands, and the chosen preset weights them. Flat is the default for unknown or painted materials; it produces no inferred relief.
3. **Height.** An optional 8-bit relief mask scales the inferred signal (0 removes it; 255 keeps it). An optional authored 16-bit height replaces inference altogether. Otherwise the signal is scaled by the amplitude and polarity around neutral 0.5, clamped, and exported as normalized R16 height.
4. **Normal.** A Scharr derivative of height, which is more rotationally symmetric than central differences, gives the tangent normal `normalize(−∂h/∂x·8s, −∂h/∂y·8s, 1)`, with `s = normal_strength`.
   - The default encoding is **+Y / green-up** (glTF, OpenGL, Blender). Image rows grow downward, so height that rises toward the bottom of the image faces up and encodes green > 128.
   - `normal_y_down` encodes −Y / green-down (DirectX, Unreal) by flipping only green.
   - **1.0.0 bundles** encoded green-down while claiming +Y. Re-derive them, or flip green on import.
5. **Ambient occlusion.** GTAO's cosine-weighted slice integral is evaluated on the heightfield, viewed from +Z:
   - Sampling: eight two-sided slices (16 horizon directions) and eight bilinear taps per side, placed exactly on each slice line.
   - Horizons are clamped to the normal's hemisphere.
   - Each pixel is normalized by its own unoccluded integral, so open planes of any slope are exactly 1.
   - The AO geometry sees height × 32 × `ao_strength` pixels. It is art-directable separately from the normal response. `ao_radius_pixels` bounds the horizon search.
   - The optional bent normal uses the analytic XeGTAO cosine-weighted form.
   - Every cosine and sine is derived through exact angle-addition identities. A polynomial acos (error < 7e-5 rad) supplies only the angle-linear term.
6. **Diagnostics.** A small Gaussian local height average and the gradient provide the cavity, convexity, slope, and edge maps.
7. **Roughness.** Perceptual roughness starts from the selected material prior. Optional variation follows local luminance micro-contrast, normalized to the image mean: grainy areas read rougher and smooth areas glossier. The image mean stays at the prior, and variation is bounded to ±0.25 × `roughness_variation`.
8. **Metalness.** Metalness is never inferred. ORM is available only after metalness is explicitly assigned. Its channels are R = AO, G = perceptual roughness, B = assigned metalness.

The tile option wraps all local filters and samples. Opposite-edge differences are reported separately: height value and first-gradient differences, and linear-light albedo differences. Wrapping a filter does not make a non-seamless source seamless; use `seamless_blend` for that.

The core derives in parallel across rows, using worker threads plus the calling thread. Results are bit-identical to a serial run, and the progress callback only runs on the calling thread. A 1024² stone derivation with bent normals takes about 0.1 s in an optimized build on an M5 (10 cores).

## Exports

- Albedo is an sRGB PNG.
- The tangent normal is a linear RGBA8 PNG with alpha 255. The manifest records its convention (`normal_convention`: `+Y` or `-Y`).
- Roughness, AO, and the diagnostic scalar maps are replicated grayscale linear RGBA8 PNGs with alpha 255.
- Height is a normalized single-channel 16-bit PNG.

The material manifest holds map and source hashes, the algorithm version, every recipe parameter, the semantic label, map encodings, and provenance. Review a bundle before any engine-specific import.

The source alone does not determine intrinsic roughness, metalness, specular F0, emission, opacity, thickness, physical depth, or gameplay properties. Normal-variance filtering for rendering is an engine concern and is kept separate from authored roughness.

## Learned geometry

Single-image SVBRDF estimators lead the state of the art in *quality*: ControlMat, MaterialPicker, DualMat, HiMat. None has permissively licensed weights, and they generate plausible maps rather than deterministic estimates. Material Lab therefore uses **MoGe-2 ViT-S normals** (MIT) as an optional guide input rather than a replacement for the analytic pipeline:

- The converted Core ML model returns +Y tangent normals for 518² tiles; tiles are blended at a working size of up to 1036² and resampled to the source ([contract and tiling](LEARNED_NORMALS.md)).
- The core converts the guide to slopes, removes the low-frequency tilt that scene-trained models add, integrates the slopes to height with a deterministic multigrid Poisson solver, and blends that height with the inferred height by `guide_normal_weight` (0 = analytic only, 1 = learned only). GTAO, cavity, roughness and every other map then use the blended geometry.
- The manifest records the model hashes, compute units and tiling, because Neural Engine fp16 output can vary by chip.

Alternatives that are use-restricted or unclear are avoided without legal review: Stable Diffusion-derived normal and delight models (OpenRAIL++ lineage), DSINE, non-commercial Depth Anything variants, and Marigold weights.

## Scope of validation

Core tests always run with assertions, including Release builds. They check:

- flat color, painted checkerboard, and authored bump and pit;
- the +Y ramp convention and the DirectX flip;
- zero normal strength;
- normal sign and length;
- unoccluded tilted planes, and pit occlusion;
- ORM gating and mask suppression;
- seam removal, and contrast preservation in the histogram blend zone;
- equalization of a lighting ramp;
- roughness following micro-contrast;
- threaded determinism at 1K;
- cancellation, malformed input, and out-of-range parameters.

CLI validation checks manifest fields and map hashes. GUI, simulator, physical camera, and device link tests have distinct evidence levels; a build does not validate a real iPhone camera or network permission flow.
