# Material Lab: marketing copy

Three products share one derivation engine:

- **Material Lab** for Mac (App Store, A$9.99).
- **Material Capture** for iPhone (App Store, A$9.99).
- **material-lab**, the free command-line tool (GitHub and Homebrew).

Every claim below is implemented and tested in the current build. Claims that can only be proven on a real iPhone are listed in the last section; check them on a device before they go on a store page.

---

## One-liners

- **Material Lab:** Turn any photo into a game-ready PBR material, on your Mac.
- **Material Capture:** Scan real surfaces into PBR materials with your iPhone.
- **material-lab CLI:** Photo-to-PBR from the command line. Free.

## App Store fields

**Material Lab (Mac)**
- Subtitle (30): `Photos to PBR materials`
- Promotional text (170): `Turn a photo into albedo, height, normal, roughness and AO maps, then export to Unreal, Unity, Godot, Blender, glTF, USDZ and more. Everything runs on your Mac.`
- Keywords (100): `pbr,texture,material,normal map,albedo,gltf,usdz,unreal,unity,godot,blender,substance,3d,game,photogrammetry`

**Material Capture (iPhone)**
- Subtitle (30): `Scan surfaces into PBR`
- Promotional text (170): `Photograph a wall, floor or fabric and get a full PBR material in seconds: albedo, height, normal, roughness and AO. Uses LiDAR depth on Pro iPhones. No account, no cloud.`
- Keywords (100): `pbr,texture,scan,material,lidar,normal map,albedo,gltf,usdz,ar,3d,game,unreal,unity,blender,godot`

---

## Long description: Material Lab for Mac

Photograph a surface, and Material Lab builds the whole material: albedo, 16-bit height, normal, roughness, ambient occlusion, and cavity, convexity, slope and edge masks, plus an optional bent normal and packed ORM. A 1K material takes about a tenth of a second on Apple silicon, and every slider updates the maps live.

**Start from a material, not a blank slate.** Choose from 39 tuned materials (red brick, cobblestones, polished marble, concrete, stucco, glazed tile, wood planks, tree bark, gravel, moss, denim, leather, brushed and rusted steel, copper, plastic and more), then refine. Basic mode shows the controls most materials need; Advanced shows every parameter. A dot marks anything you've changed, and a double-click resets it.

**Geometry that reads the right way round.** Learned geometry runs Microsoft's MoGe-2 normal estimator on the Neural Engine and fuses it with the photo's own detail, so mortar reads as recessed between bricks and grout sits below the tiles, even when the joints are paler than the surface.

**Seamless by design.** Repair Albedo rebuilds the photo itself so it tiles on both axes. It cuts copies in along the least visible seam instead of smearing the edges, measures the seam before and after, and switches to a contrast-preserving blend for fine grain.

**Bring your own art.** Mark a source as a hand-painted albedo, and drop in your own height, normal, roughness, occlusion or metalness maps. Material Lab fills in the rest so everything agrees, and records what you authored.

**See it before you ship it.**
- A pixel loupe and histogram for every map.
- A relit view with a light you can drag.
- A 3×3 tile check with seam guides.
- A wipe compare against the source photo, or against a version you pinned earlier.
- A real-time 3D preview on a sphere, cube or plane, in Studio, Overcast or Sunset lighting, with adjustable tiling.

**Export anywhere.** One click writes the `.pbrmaterial` bundle plus any of:
- glTF binary (.glb)
- USDZ
- MaterialX
- Unreal Engine (DirectX normals, packed ORM)
- Unity URP / Built-in
- Unity HDRP (mask map)
- Godot
- Blender
- Substance 3D
- Roblox
- Minecraft (LabPBR resource pack)

**Built for real workflows.**
- A Batch Queue with per-item status, retry and a JSON report.
- Saved recipes, and undo for every edit.
- Shortcuts and Spotlight actions ("Derive a material with Material Lab").
- `.pbrmaterial` bundles open with a double-click and show material thumbnails in Finder.
- Open in New Window, to compare two materials side by side.

**Private and local.** No account and no cloud: your photos and materials never leave your Mac. Captures from Material Capture on iPhone arrive over an encrypted local link that you approve one by one.

**In English and Japanese.**

## Long description: Material Capture for iPhone

Point your iPhone at a wall, floor, rug or rock and turn it into a PBR material on the spot.

**A camera made for materials.**
- A square framing guide, a level that turns green when you're parallel to the surface, glare and exposure hints, and automatic corner detection.
- **Constant Color** cancels ambient light on supported iPhones.
- **Flash pair** does the same job on iPhones without Constant Color: it takes a photo with and without the flash and keeps only the flash's light.
- **LiDAR depth** on Pro iPhones shapes the surface from real measured depth.
- **Apple ProRAW**, developed neutrally, for the truest colour.

**The full material, on the phone.**
- Albedo, height, normal, roughness and AO, from 512² up to 4K, with live previews.
- A relit view and a 3D sphere, cube or tile.
- **AR Quick Look** to place the material on a real wall.
- 39 starting materials, learned geometry on the Neural Engine, seamless albedo repair, and your own maps from Photos or Files.
- Big derivations keep running in the background if you switch apps.

**Export straight to your engine.** Save the bundle plus glTF, USDZ, MaterialX, Unreal, Unity, Godot, Blender, Substance, Roblox or Minecraft files to Files. You can also send the capture to Material Lab on your Mac over an encrypted, approved local link.

**Your library, your device.** Every capture is kept with its crop and recipe, with undo and saved recipes. Shortcuts can derive materials from any photo. Photos are scrubbed of location before anything leaves the app. No account, no cloud. English and Japanese.

## The free CLI: material-lab

```sh
brew tap theisegoria/material-lab-cli https://github.com/theisegoria/material-lab-cli
brew trust theisegoria/material-lab-cli
brew install material-lab
```

The same engine for pipelines:

- `--preset red-brick` (39 presets) and recipe files.
- `--learned` geometry with the bundled MoGe-2 model.
- `--repair-albedo auto`.
- Your own maps: `--authored`, `--normal-map`, `--height-map` and more.
- `--export` / `--also-export` to all 11 formats.
- Catalog batches with `--jobs` and JSON `--report`s.
- `--watch` folders.
- `--info`, `--contact-sheet` and `--diff` for inspection.
- A strict `--validate` for every bundle.

Apple silicon, macOS 15 or later.

---

## How it works (for technical audiences)

**One engine, three products.** A deterministic C++23 core derives every map identically in the Mac app, the iPhone app and the CLI. Every bundle records exactly how it was made: the recipe, the source and map hashes, the learned-model identity, seam measures and relief diagnostics.

- **Relief from shading, done right.** Shading multiplies albedo, so relief cues are read from *log* luminance in linear light. The same bump gives the same cue on dark basalt and pale limestone. Cues are split into three frequency bands, and every spatial scale is defined at a 1024-pixel reference, so a 512² preview and a 4K export describe the same surface.
- **Physically scaled relief.** Relief amplitude is set by a per-material target slope rather than by photo contrast, so depth is consistent across images and resolutions. Height is integrated with a multigrid Poisson solver that becomes periodic when the material tiles.
- **Learned geometry, fused rather than pasted.** MoGe-2 normals are tiled across the image with overlap and two orientations per tile, then integrated to height. Large-scale *form* comes from the network. Fine *detail* comes from the photo, with its sign (raised or recessed) decided where the two agree. Because the fusion happens in height, the normals, AO and diagnostics all describe one surface.
- **LiDAR depth as geometry.** The photo's depth map is back-projected through the camera's calibrated intrinsics. The surface plane is fitted, and surface normals are expressed in that plane's own tangent frame, so a wall shot at an angle still reads flat and only real relief remains.
- **Flash/no-flash albedo.** The two photos are aligned by homographic registration. Ambient light is subtracted in linear light, scaled by each shot's exposure, and the flash's fall-off is fitted and divided out. What remains is surface colour without shadows or uneven lighting.
- **Ambient occlusion.** GTAO-style horizon integration (Jimenez et al. 2016) over 16 directions, normalized so open planes are exactly unoccluded, with an analytic bent normal.
- **Roughness that follows the surface.** Concavity, micro-contrast and facet brightness vary roughness within the material's physical range, around the artist's chosen value.
- **Seamless tiling.** An image-quilting minimum-error boundary cut (Efros & Freeman 2001), with a coarse-to-fine offset search that aligns repeating elements such as brick courses. For fine stochastic textures there is a histogram-preserving blend (Heitz & Neyret 2018). Seams are measured before and after in linear-light luminance.
- **Exports that respect each engine's conventions.** OpenGL or DirectX normals, ORM, HDRP mask-map and LabPBR packing, per-pixel metalness, MaterialX `standard_surface`, and 64-byte-aligned USDZ that passes Apple's AR checks.

**Honest by design.** Every derived map is an estimate from photographs, and the bundle says so. Nothing is marked as engine-ready until you've reviewed it.

---

## Verify on a device before publishing these claims

These are implemented and pass simulated tests, but haven't been run on real hardware here:

- LiDAR depth capture on a Pro iPhone, and how it looks with real sensor noise.
- Flash pair on an iPhone without Constant Color: alignment of handheld shots and flash fall-off on real surfaces.
- Apple ProRAW development.
- Background continuation of 2K and 4K derivations.
- AR Quick Look placement.
- The capture coach (it needs a working camera).
- "About a tenth of a second for 1K" was measured on an M5 Mac; check iPhone timings before quoting them for the iPhone.
