# Derivation model and provenance

Material Lab 1.3.0 is a deterministic, analytical image-to-map estimator. It accepts a color-managed, square, straight RGBA8 image in sRGB. The shared C++23 core converts sRGB channels to linear values for calculations. Unless the recipe asks for delighting or tiling, the albedo output is a byte-exact copy of the source.

## What the source can and cannot tell us

The height and normal of a photographed surface cannot be uniquely recovered from one color image. Lighting, pigment, specular reflection, shadows, and shape can create the same RGB pattern. MaterIA combines learned normal inference with integration and heuristic map construction. It also notes how hard it is to infer roughness from a single observation. Material Lab therefore calls its geometry pseudo-height and its AO heightfield AO. Presets are editable priors, not material recognition.

References:

- [MaterIA: Single Image High-Resolution Material Capture in the Wild](https://perso.telecom-paristech.fr/boubek/papers/MaterIA/MaterIA_lowres.pdf)
- Jimenez et al. 2016, *Practical Real-Time Strategies for Accurate Indirect Occlusion* (GTAO), and Intel's MIT-licensed [XeGTAO](https://github.com/GameTechDev/XeGTAO) reference for the bent-normal form
- Efros & Freeman 2001, *Image Quilting for Texture Synthesis and Transfer* (minimum-error boundary cut)
- Heitz & Neyret 2018, *High-Performance By-Example Noise using a Histogram-Preserving Blending Operator* (HPG)
- [glTF 2.0 material texture conventions](https://github.com/KhronosGroup/glTF/blob/main/specification/2.0/Specification.adoc)

## Algorithm (1.3.0)

Every spatial scale below is given in pixels at a **1024-pixel reference** and scales with the tile (`s = size / 1024`), so a 512² preview and a 4K export describe the same surface. This includes `ao_radius_pixels`.

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
2. **Relief cue.** Compute Rec. 709 luminance in linear light and take its logarithm (`log(L + 0.01)`). Shading multiplies albedo, so the log makes the same relief give the same cue on dark basalt and pale limestone; 1.2.0 used linear differences, which flattened dark materials. Gaussian-approximating filters (three box passes each) at 2, 8 and 24 reference pixels split it into high, middle and coarse bands, weighted by the preset (stone 1.0 / 1.2 / 0.7). Flat produces no inferred relief.
3. **Relief amplitude is a prior.** The inferred field is scaled so that its root-mean-square surface slope equals the preset target × `height_strength` / 0.22 (stone 0.30, organic 0.26, fabric 0.20, bare metal 0.09, coated metal 0.05). The photo decides the *shape*; the target decides how deep it is, independent of albedo contrast or resolution. `height_polarity` sets the sign.
4. **Learned geometry (optional).** With guide normals (MoGe-2, [learned normals](LEARNED_NORMALS.md)) and weight `w`:
   - The guide slopes are integrated to height with a multigrid Poisson solver, **periodic when tiling** (Neumann otherwise). The CLI already delivers a periodic guide field when tiling.
   - *Form* is the learned height band-limited to wavelengths between the **crossover** (Gaussian σ = 3 reference px, wavelength ≈ 16 px) and σ = tile/20. Longer wavelengths are estimator bias (bowls, tilt) or image composition and would repeat visibly in a tiled texture; shorter ones are beyond the estimator's resolution.
   - *Detail* is the albedo relief cue above the crossover. Its sign comes from the learned field: the two are correlated in the σ 3–8 px band, where both are reliable, and when |correlation| ≥ 0.1 the learned sign wins. Recessed dark pores and raised dark pebbles are therefore both handled.
   - The form's share of the slope energy is 3 × (the learned form's own rms slope) / target, capped at 0.7. An estimator that sees an almost flat surface contributes little form instead of having its noise amplified.
   - The fused field `(1 − w)·heuristic + w·(√share·form + √(1 − share)·detail)` is scaled to the target rms slope. This is a frequency split in height rather than reoriented normal mapping, so height, normals, AO and the diagnostics all describe one surface.
   - Flat preset: the learned band alone, in the estimator's own units.
5. **Geometry and height.** The optional 8-bit relief mask scales the geometry (0 removes it). `normal_strength` then scales the whole surface, so it changes normals, AO, the diagnostics and the recorded height span in every mode. An authored 16-bit height replaces inference and is exported byte-exact (full range = 8 reference px of depth × `normal_strength`). Estimated height is exported **range-normalized** to the full 16-bit range (lowest point 0, highest 65535; never clamped), and the manifest records `relief.height_span_tile_widths`, the depth between 0 and 1 in tile widths. A flat result is a constant 0.5.
6. **Normal.** A Scharr derivative of the geometry (pixels of depth) gives the tangent normal `normalize(−∂h/∂x, −∂h/∂y, 1)`.
   - The default encoding is **+Y / green-up** (glTF, OpenGL, Blender). Image rows grow downward, so height that rises toward the bottom of the image faces up and encodes green > 128.
   - `normal_y_down` encodes −Y / green-down (DirectX, Unreal) by flipping only green.
   - **1.0.0 bundles** encoded green-down while claiming +Y. Re-derive them, or flip green on import.
7. **Ambient occlusion.** GTAO's cosine-weighted slice integral is evaluated on the same geometry, viewed from +Z, deepened by 3 × `ao_strength` (a heightfield misses sub-texel occlusion and undercuts):
   - Sampling: eight two-sided slices (16 horizon directions) and eight bilinear taps per side, placed exactly on each slice line, out to `ao_radius_pixels` × s.
   - Horizons are clamped to the normal's hemisphere.
   - Each pixel is normalized by its own unoccluded integral, so open planes of any slope are exactly 1.
   - The optional bent normal uses the analytic XeGTAO cosine-weighted form.
   - Every cosine and sine is derived through exact angle-addition identities. A polynomial acos (error < 7e-5 rad) supplies only the angle-linear term.
8. **Diagnostics.** Curvature is the mean of the geometry minus its local average at 2 and 8 reference px, in reference pixels of depth. Cavity and convexity are its negative and positive parts × 1.5, edge its magnitude × 2.25, and slope is 2 × the gradient (tangent), clamped.
9. **Roughness.** Perceptual roughness starts at the prior (`roughness_base`) and varies with a standardized cue: concavity (crevices hold dust and weather matte; exposed convex faces are abraded smoother, weight 0.45), luminance micro-contrast (granular and broken surfaces scatter more, 0.35) and fine luminance relative to its surroundings (bright mineral facets and cleavage planes read glossier, −0.30). The roughness standard deviation is 0.25 × `roughness_variation` (default 0.3 for non-flat presets), clamped to the preset's physical range (stone 0.45–0.98, organic 0.35–0.95, fabric 0.6–1.0, coated metal 0.15–0.75, bare metal 0.08–0.6; the prior itself is always allowed). The mean stays at the prior unless clamping shifts it.
10. **Metalness.** Metalness is never inferred. ORM is available only after metalness is explicitly assigned. Its channels are R = AO, G = perceptual roughness, B = assigned metalness.

The tile option wraps all local filters, the Poisson solve and all samples. Opposite-edge differences are reported separately: height value and first-gradient differences, and linear-light albedo differences. Wrapping a filter does not make a non-seamless source seamless; use `seamless_blend` for that.

The core derives in parallel across rows, using worker threads plus the calling thread. Results are bit-identical to a serial run, and the progress callback only runs on the calling thread. A 1024² stone derivation with bent normals takes about 0.1 s in an optimized build on an M5 (10 cores); 4096² takes about 7 s.

### What changed from 1.2.0

| 1.2.0 | 1.3.0 |
| --- | --- |
| Learned height clamped to 0–1: plateaus and a flat normal map where it saturated; `normal_strength` had almost no effect | Geometry kept in pixels of depth, height range-normalized with its span recorded; `normal_strength` scales the surface in every mode |
| Guide weight 1 replaced all albedo detail by the smooth learned field; AO ~1, cavity black | Learned form + albedo detail split at a documented crossover; learned field orients the detail |
| Relief read from linear luminance: dark materials nearly flat | Log luminance and an explicit rms-slope prior per preset |
| Spatial scales in source pixels: a 4K texture had a quarter of the relief scale and AO radius of its 1K version | All scales at a 1024 reference |
| AO saw relief 4× deeper than the normals | AO sees the normal-map surface × 3 × `ao_strength` |
| Roughness ≈ constant (±0.01) | Cue-driven roughness within a preset range, std 0.25 × variation |

## Exports

- Albedo is an sRGB PNG.
- The tangent normal is a linear RGBA8 PNG with alpha 255. The manifest records its convention (`normal_convention`: `+Y` or `-Y`).
- Roughness, AO, and the diagnostic scalar maps are replicated grayscale linear RGBA8 PNGs with alpha 255.
- Height is a normalized single-channel 16-bit PNG.

The material manifest holds map and source hashes, the algorithm version, every recipe parameter, the semantic label, map encodings, and provenance. Review a bundle before any engine-specific import.

The source alone does not determine intrinsic roughness, metalness, specular F0, emission, opacity, thickness, physical depth, or gameplay properties. Normal-variance filtering for rendering is an engine concern and is kept separate from authored roughness.

## Learned geometry

Single-image SVBRDF estimators lead the state of the art in *quality*: ControlMat, MaterialPicker, DualMat, HiMat. None has permissively licensed weights, and they generate plausible maps rather than deterministic estimates. Material Lab therefore uses **MoGe-2 ViT-S normals** (MIT) as an optional guide input rather than a replacement for the analytic pipeline:

- The converted Core ML model returns +Y tangent normals for 518² tiles; tiles are blended at a working size of up to 2072² (wrap-padded and folded back when tiling) and resampled to the source ([contract and tiling](LEARNED_NORMALS.md)).
- The core integrates the guide slopes to height (periodic when tiling), keeps its reliable band as large-scale form, lets it orient the albedo-derived fine detail, and fuses both by `guide_normal_weight` (0 = analytic only, 1 = learned form and orientation with albedo detail). GTAO, cavity, roughness and every other map then use the fused geometry.
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
- roughness following micro-contrast, its spread following `roughness_variation`, and the preset range;
- periodic learned integration (no border frame, no wrap seam) and full-range height without clamping;
- learned detail orientation, fine-detail preservation in fused geometry, and `normal_strength` in learned mode;
- relief amplitude independent of albedo brightness and resolution, and AO radius scaling with the tile;
- threaded determinism at 1K and with guide normals;
- cancellation, malformed input, and out-of-range parameters.

CLI validation checks manifest fields and map hashes. GUI, simulator, physical camera, and device link tests have distinct evidence levels; a build does not validate a real iPhone camera or network permission flow.
