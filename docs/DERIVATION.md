# Derivation model and provenance

Material Lab 1.5.0 is a deterministic, analytical image-to-map estimator. It accepts a color-managed, square, straight RGBA8 image in sRGB. The shared C++23 core converts sRGB channels to linear values for calculations. Unless the recipe asks for delighting, tiling or albedo repair, the albedo output is a byte-exact copy of the source.

## What the source can and cannot tell us

The height and normal of a photographed surface cannot be uniquely recovered from one color image. Lighting, pigment, specular reflection, shadows, and shape can create the same RGB pattern. MaterIA combines learned normal inference with integration and heuristic map construction. It also notes how hard it is to infer roughness from a single observation. Material Lab therefore calls its geometry pseudo-height and its AO heightfield AO. Presets are editable priors, not material recognition.

References:

- [MaterIA: Single Image High-Resolution Material Capture in the Wild](https://perso.telecom-paristech.fr/boubek/papers/MaterIA/MaterIA_lowres.pdf)
- Jimenez et al. 2016, *Practical Real-Time Strategies for Accurate Indirect Occlusion* (GTAO), and Intel's MIT-licensed [XeGTAO](https://github.com/GameTechDev/XeGTAO) reference for the bent-normal form
- Efros & Freeman 2001, *Image Quilting for Texture Synthesis and Transfer* (minimum-error boundary cut)
- Heitz & Neyret 2018, *High-Performance By-Example Noise using a Histogram-Preserving Blending Operator* (HPG)
- [glTF 2.0 material texture conventions](https://github.com/KhronosGroup/glTF/blob/main/specification/2.0/Specification.adoc)

## Algorithm (1.5.0)

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
   - *Albedo repair* (`albedo_repair`, 1.4.0; CLI `--repair-albedo off|blend|quilt|auto`) is the explicit mode for a source that does not tile, for example an image whose wrap was hidden by an edge blend that left a smeared strip and a tone step. It always repairs both axes over a band of `seamless_blend` (0.12 of the tile per edge when unset), and the repaired albedo becomes both the exported albedo and the image every derived map and the learned estimator see.
     - **Quilt** is the seam cut above with these changes: the copy offset is searched within 3/8–5/8 of the tile (duplicated elements sit far from their twins); the cut cost includes the difference in local contrast, so a sharp region is not joined to a soft one; the cut stays in the inner half of the band, so the strip along the old wrap is replaced rather than threaded; the image is split at σ = max(4 reference px, band/8), with detail following the cut (feathered ±3 reference px) and the low band following the same cut feathered at its own scale, so tone differences never form a step and one region's low band is never paired with another's detail (which reads as a milky haze); and an axis is never skipped.
     - **Blend** is the histogram-preserving blend above, using the copy alone over the outer half of the band and blending across the inner half only.
     - **Auto** quilts, then measures the cut's visibility: its mean mismatch divided by that of ordinary neighbouring pixels in the band. Up to 4 the quilt is kept; above it auto uses the blend. Quilt is preferred because the blend softens and ghosts large discrete elements such as leaves, twigs and pebbles; on nine seamed 4K terrain albedos the quilt looked as good or better wherever it was kept.
     - Seam measures before and after (linear-light luminance) are recorded: *pixel* (opposite-edge step / mean adjacent step), *tone* (the same after a σ 8 reference-px blur, which exposes a lighting or colour step that an edge blend hides at pixel scale) and *detail* (fine contrast within 24 reference px of either wrap line / elsewhere; below 1 means a smeared strip).
   - Equalize runs before tiling, so lighting gradients do not become seams. Pseudo-height uses the conditioned image.
2. **Relief cue.** Compute Rec. 709 luminance in linear light and take its logarithm (`log(L + 0.01)`). Shading multiplies albedo, so the log makes the same relief give the same cue on dark basalt and pale limestone; 1.2.0 used linear differences, which flattened dark materials. Gaussian-approximating filters (three box passes each) at 2, 8 and 24 reference pixels split it into high, middle and coarse bands, weighted by the preset (stone 1.0 / 1.2 / 0.7). Flat produces no inferred relief; with `substrate_relief` > 0 (1.5.0, CLI `--substrate-relief`, default 0) it gets a deterministic, image-seeded periodic noise at ~1.4 and ~10 reference px, scaled to an rms slope of 0.035 × `substrate_relief` — the unevenness of printed film, paint or cover glass, never the artwork.
3. **Relief amplitude is a prior.** The inferred field is scaled so that its root-mean-square surface slope equals the preset target × `height_strength` / 0.22 (stone 0.30, organic 0.26, fabric 0.20, coated metal 0.12, bare metal 0.09). The photo decides the *shape*; the target decides how deep it is, independent of albedo contrast or resolution. `height_polarity` sets the sign. Coated metal (1.4.0) weights the bands 0.6 / 0.5 / 0.15 so panel seams become grooves with width, deep enough for GTAO; at 1.3.0's 0.05 target a panelled deck had AO ≈ 0.99.
3a. **Mid-scale relief floor (1.5.0).** Seams, fasteners, chips and dents (4–30 mm) are what remains of a surface a few metres away; a photograph's relief cue is dominated by grain, which averages flat there. The physical scale comes from `tile_metres` (CLI `--tile-metres`; 0 = unknown, taken as 1 m). When the 4–30 mm band (difference of Gaussians at σ 2 mm and 15 mm, at most a 1/8 of the tile) carries less than `mid_relief_share` of the rms slope (default 0.35, 0 off, flat 0), the photo's own band, oriented as the albedo detail, is added (secant search on its amplitude, ≤ 5 steps) until it does, and the surface returns to its previous rms slope: the preset prior still sets the amplitude, only its distribution over scales changes. The manifest records the share before and after (`relief.mid_relief_share_before/after`). It runs after the learned fusion, so it applies with and without guide normals.
4. **Learned geometry (optional).** With guide normals (MoGe-2, [learned normals](LEARNED_NORMALS.md)) and weight `w`:
   - The guide slopes are integrated to height with a multigrid Poisson solver, **periodic when tiling** (Neumann otherwise). The CLI already delivers a periodic guide field when tiling.
   - *Form* is the learned height band-limited to wavelengths between the **crossover** (Gaussian σ = 3 reference px, wavelength ≈ 16 px) and σ = tile/20. Longer wavelengths are estimator bias (bowls, tilt) or image composition and would repeat visibly in a tiled texture; shorter ones are beyond the estimator's resolution.
   - *Detail* is the albedo relief cue above the crossover. Its sign comes from the learned field: the two are correlated in the σ 3–8 px band, where both are reliable, and when |correlation| ≥ 0.1 the learned sign wins. Recessed dark pores and raised dark pebbles are therefore both handled.
   - The form's share of the slope energy is 3 × (the learned form's own rms slope) / target, capped at 0.7. An estimator that sees an almost flat surface contributes little form instead of having its noise amplified.
   - The fused field `(1 − w)·heuristic + w·(√share·form + √(1 − share)·detail)` is scaled to the target rms slope. This is a frequency split in height rather than reoriented normal mapping, so height, normals, AO and the diagnostics all describe one surface.
   - Flat preset: the learned band alone, in the estimator's own units.
   - `height_polarity` −1 inverts the learned form and the learned-oriented detail as well (1.4.0; 1.3.0 ignored polarity at guide weight 1). The manifest's `relief.detail_polarity` is the sign actually applied to albedo detail.
5. **Geometry and height.** The optional 8-bit relief mask scales the geometry (0 removes it). `normal_strength` then scales the whole surface, so it changes normals, AO, the diagnostics and the recorded height span in every mode. An authored 16-bit height replaces inference and is exported byte-exact (full range = 8 reference px of depth × `normal_strength`). Estimated height is exported **range-normalized**: the 0.5–99.5 % range of the geometry maps linearly onto 0.01–0.99, and the few outlying pits and peaks are compressed (monotonic, never clamped) into the outer 1 % at each end (1.5.0; 1.3.0–1.4.0 mapped the extreme points to 0 and 65535, so a handful of pits set the depth of the whole tile). The manifest records `relief.height_span_tile_widths`, the depth of a unit height step in the linear bulk, in tile widths. A flat result is a constant 0.5.
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
9. **Roughness.** Perceptual roughness starts at the prior (`roughness_base`) and varies with a standardized cue: concavity (crevices hold dust and weather matte; exposed convex faces are abraded smoother, weight 0.45), luminance micro-contrast (granular and broken surfaces scatter more, 0.35) and fine luminance relative to its surroundings (bright mineral facets and cleavage planes read glossier, −0.30). The roughness standard deviation is 0.25 × `roughness_variation` (default 0.3 for non-flat presets), clamped to the preset's physical range (stone 0.45–0.98, organic 0.35–0.95, fabric 0.6–1.0, coated metal 0.15–0.75, bare metal 0.08–0.6; the prior itself is always allowed). The mean stays at the prior unless clamping shifts it. **Albedo independence (1.5.0):** every cue is read from the photograph, so dark paint would otherwise always be rough. When the correlation of roughness with luminance (blurred at 2 reference px) exceeds `roughness_albedo_limit` in magnitude (default 0.45, 1 off; CLI `--roughness-albedo-limit`), the luminance-explained part is scaled down to the limit with the residual taking the remaining variance, keeping the mean, the standard deviation and the sign; `relief.roughness_albedo_correlation_before/after` record it.
10. **Metalness.** Metalness is never inferred. ORM is available only after metalness is explicitly assigned. Its channels are R = AO, G = perceptual roughness, B = assigned metalness.

The tile option wraps all local filters, the Poisson solve and all samples. Opposite-edge differences are reported separately: height value and first-gradient differences, and linear-light albedo differences. Wrapping a filter does not make a non-seamless source seamless; use `seamless_blend` for that.

The core derives in parallel across rows, using worker threads plus the calling thread. Results are bit-identical to a serial run, and the progress callback only runs on the calling thread. A 1024² stone derivation with bent normals takes about 0.1 s in an optimized build on an M5 (10 cores); 4096² takes about 7 s.

### What changed from 1.4.0

- Mid-scale relief floor (`mid_relief_share`, `tile_metres`): grain-dominated photos keep 4–30 mm relief at the same rms slope. A 256² stone test image goes from a 0.27 to a 0.35 share at an unchanged 0.30 rms slope.
- Roughness/albedo decorrelation (`roughness_albedo_limit`): the same image's roughness/luminance correlation −0.65 → −0.45, mean and spread kept.
- Robust height range with compressed tails: outliers no longer set the tile's height depth.
- Flat-preset substrate relief (`substrate_relief`, off by default).
- New manifest fields are optional (absent means the preset defaults); the CLI and the Mac app record them. Defaults change 1.4.0 output for every non-flat preset; set `--mid-relief-share 0 --roughness-albedo-limit 1` for the 1.4.0 relief and roughness distribution (the height range is always robust).

### What changed from 1.3.0

- Explicit albedo repair (`albedo_repair`) with repaired-albedo provenance, hashes and seam measures; the CLI runs learned inference on the repaired albedo.
- `height_polarity` flips learned relief.
- Coated metal relief target 0.05 → 0.12 and band weights 0.65 / 0.25 / 0 → 0.6 / 0.5 / 0.15.
- Legacy `seamless_blend` without `albedo_repair` is unchanged.

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

## Material operations (CLI 1.4.0)

Layering, variants and larger tiles start from derived materials, not photos (`core/src/MaterialOps.cpp`; C API under "Material operations" in `PBRMaterialLab.h`). Each builds a new albedo, relief, roughness and metalness, then re-derives every geometry-dependent map with `PBRLabDerive`, passing the relief as an authored height and the roughness and metalness as authored maps. Normals, AO, cavity, convexity, slope, edge, bent normal and ORM therefore agree with the new relief, and the derivation algorithm (1.5.0) is unchanged. Reliefs are handled in physical units: a bundle's height times its `relief.height_span_tile_widths`. The re-derivation sets `normal_strength` so the new height spans the new depth (8/1024 tile widths per unit). A relief deeper than 1/8 of the tile is refused.

### Layers

`top` over `base` through a mask, at the base's size (a top of another size is resampled, bilinear and wrapped):

- `height`: top where the base is high, `smoothstep(threshold ± softness)` of the base's normalised height. `invert` puts it in the hollows instead (dust, water, moss in mortar).
- `slope`: top where the base is steep. Steepness is the slope angle / 90°, from the base relief (wrapped central differences). Inverted, the top sits on flat ground (snow, sand).
- `noise`: seeded value-noise fBm, five octaves, with an integer number of cells per tile (`scale`) so it tiles. `contrast` is applied about 0.5, then the smoothstep.
- `image`: a painted mask, grey values as data (255 = top). It is resampled to the base size and mapped by a linear ramp over `threshold ± softness`, so the defaults (0.5 ± 0.5) use it as painted.

`height_blend` (0..0.95) adds the height-aware term inside the transition: with mask m and normalised heights hT, hB, the top weight is `clamp(0.5 + (m + d·4m(1−m)·(hT − hB) − 0.5) / (1 − d))`. The higher layer wins where the mask is undecided and the edge sharpens, but the top is always fully present where m = 1 and absent where m = 0. With d = 0 the weight is the mask.

The weight w blends:

- albedo in linear light, and alpha;
- roughness and metalness linearly (a material without ORM has metalness 0);
- the reliefs, each measured from its own lowest point.

Normals are re-derived from the blended relief by default. `normal_blend = reoriented` instead blends each pixel's normal from the base normal to the reoriented-normal blend (Barré-Brisebois and Hill) of the top's normal map onto it, keeping the top's own fine normal detail; AO and the diagnostics still come from the blended relief.

### Variants

A seed draws, in a fixed order with splitmix64, uniform shifts within the given maxima: hue rotation about the grey axis in linear light (default ±6°), chroma (±8 %) and brightness (±6 %) scales, a roughness offset (±0.05) and a relief-depth scale (±15 %). A random tile offset (tileable materials) and, if asked, a quarter turn and mirror are applied identically to every map before the re-derivation, so the normals follow the rotation. The same seed gives the same variant on every machine. `--variant-strength` scales all the maxima.

### Larger tiles

`--large-tile 2|4` synthesises a 2×2 or 4×4 area that tiles at its own size without the source's period, by histogram-preserving tiling and blending (Heitz and Neyret, "High-Performance By-Example Noise using a Histogram-Preserving Blending Operator", 2018):

- A periodic lattice of squares, `1/patch` per source tile (default 2), each split into two triangles. Every vertex draws a random integer offset into the (tileable) source.
- Each output pixel reads the source at its three vertices' offsets, with barycentric weights raised to `sharpness` (default 4) and normalised.
- Albedo R, G, B, roughness, height (16-bit) and metalness are each Gaussianised through their own histogram. The three samples are blended and divided by the weights' L2 norm, so the variance is kept, then mapped back through the inverse histogram: the output keeps each map's histogram. Alpha is blended linearly.
- Every map uses the same offsets and weights, so albedo, relief and roughness stay registered.
- The relief keeps its physical depth: the span in tile widths of the larger tile is divided by the tile count. `ao_radius_pixels` is divided and `tile_metres` multiplied by it, so AO keeps its physical radius.

Like any patch-based method, it suits stochastic surfaces (stone, concrete, plaster, ground, fabric weave) best. Strongly structured ones (brick courses, tiles, planks) are scrambled at patch edges; use `--large-tile-patch 1` (whole-tile patches) or variants for those. Each channel is Gaussianised separately, without the original's PCA decorrelation, so rare colour combinations can shift slightly.

## Learned geometry

Single-image SVBRDF estimators lead the state of the art in *quality*: ControlMat, MaterialPicker, DualMat, HiMat. None has permissively licensed weights, and they generate plausible maps rather than deterministic estimates. Material Lab therefore uses **MoGe-2 ViT-S normals** (MIT) as an optional guide input rather than a replacement for the analytic pipeline:

- The converted Core ML model returns +Y tangent normals for 518² tiles; tiles are blended at a working size of up to 2072² (wrap-padded and folded back when tiling) and resampled to the source ([contract and tiling](LEARNED_NORMALS.md)).
- The core integrates the guide slopes to height (periodic when tiling), keeps its reliable band as large-scale form, lets it orient the albedo-derived fine detail, and fuses both by `guide_normal_weight` (0 = analytic only, 1 = learned form and orientation with albedo detail). GTAO, cavity, roughness and every other map then use the fused geometry.
- The manifest records the model hashes, compute units and tiling, because Neural Engine fp16 output can vary by chip.

Alternatives that are use-restricted or unclear are avoided without legal review: Stable Diffusion-derived normal and delight models (OpenRAIL++ lineage), DSINE, non-commercial Depth Anything variants, and Marigold weights.

## Measured form (LiDAR depth)

`PBRLabInput.guide_normals_measured` marks guide normals as measured surface slopes (back-projected depth) rather than a learned estimate. The algorithm version is unchanged: without the flag, output is identical to 1.5.0.

- The form band keeps wavelengths up to a quarter of the tile (instead of a twentieth). The caller has already removed the surface plane.
- The form keeps its measured slope and its own sign. It is not rescaled to the preset's target slope, and `height_polarity` does not flip it.
- Albedo detail is scaled to fill the rest of the target slope, `sqrt(max(target² − form², (0.35·target)²))`, so the photo always adds some fine detail.
- `PBRLabDerivationInfo.measured_form_rms_slope` reports the measured form's rms slope.

On iPhone, Material Capture streams unfiltered LiDAR depth while the user frames the shot. When the shutter is pressed it averages the frames of the preceding second (`DepthStack`):

- Frames more than 12 mm (mean) away from the newest one are dropped as taken before the phone settled.
- Each pixel takes a median-centred robust mean of its readings.
- Confidence falls with how few frames saw the pixel and how far the readings scatter beyond the expected noise (4 mm + 0.5 % of range). Pixels below 0.3 confidence become holes.

The averaged depth is stored beside the capture (`depth.mld`), because re-embedding edited depth in the photo would drop the camera calibration. With learned geometry on as well, slopes below the depth's resolution come from MoGe-2 and the rest from LiDAR. The crop's real width and height come from straight-line fits along the grid rows and columns of the back-projected crop. That width is the tile size whenever the recipe's own Tile size is 0. Bundles record all of this in a top-level `depth` section, including `height_span_mm`.

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
