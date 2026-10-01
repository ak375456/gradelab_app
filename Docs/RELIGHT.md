# Relight

Relight adds virtual lights to recorded footage that react to the apparent
shape of the scene. A key placed on the right brightens the surfaces that face
right and leaves the ones facing away alone; a spot falls off across a face; a
rim light from behind catches silhouettes. It does this from an **estimate** of
the scene's geometry — relative depth, surface orientation and a confidence for
both — not from a 3D reconstruction, and nothing in the feature claims
otherwise.

It lives in the Color tab as the **Relight** tool (⇧⌘L), beside Noise.

---

## How it works

```
decode ─► input transform ─► noise reduction ─► RELIGHT ─► look + grade ─► effects ─► output
                                                  ▲
                         depth cache (per source frame, background analysis)
```

### 1. Scene analysis (once per clip, in the background)

`Core/Relight/RelightAnalyzer.swift` reads the clip's source range in order,
on a detached task — never on the main thread, never during playback or
export rendering:

* **Per frame** (`RelightAnalysisGPU`): the frame is reduced to the analysis
  grid (224–384 px on the long edge, by quality and device) as a display-referred
  picture and its luminance; motion against the previous frame is measured both
  ways with the *same* pyramidal block-matching kernels noise reduction uses
  (`nrDownsampleLuma`, `nrFlowSearch`, `nrFlowSmooth`).
* **Cuts** inside a clip are found with noise reduction's `SceneSignature`;
  depth is never carried across one.
* **Keyframes** (every 4–10 frames, more often where motion tracking fails) run
  an estimator:
  * **Core ML depth model** when one is installed (see below) — best on every
    kind of scene.
  * **Built-in scene geometry** otherwise: Vision person segmentation,
    foreground-instance masks and face landmarks on a ground-plane prior.
    Subjects become rounded forms, faces ellipsoids with a nose. Strongest on
    people; honest (low confidence) elsewhere.
* **Temporal stabilisation** (`RelightTemporalFusion`): every frame carries the
  previous depth forward along the measured motion, with a forward/backward
  consistency check deciding per pixel how far the carried value can be
  trusted. At a keyframe the new estimate is first aligned (scale + offset — monocular
  depth is affine-ambiguous) to the carried depth, then only part of the
  difference is taken and spread over the following frames. Stored depth is
  normalised against a slowly moving range. The result does not flicker.
* **Progressive**: analysis starts at the playhead and runs to the end of the
  clip, then fills in from the start, so the frame you are looking at is lit
  within moments. Lights work on whatever has been analysed.
* **Thermal**: at `.serious` the device gets breathing room and fewer
  estimates; at `.critical` analysis pauses until it cools, and says so.

### 2. The depth cache

`RelightDepthStore` keeps depth as **rebuildable cache data**, outside the
project document:

```
Library/Caches/GradeLab/Relight/v1/<media identity>/<fast|high>/<frame>.depth
```

One LZFSE-compressed file per stored frame (≈15 per second of source), at
analysis resolution: 16-bit nearness + 8-bit confidence. The media identity is
the file's name, size and modification date, so two clips of one file share
analysis and a replaced file can never be paired with stale depth. Depth is
indexed by **source frame**, so splits, trims, speed ramps, freezes and reversed
clips all read the depth of the picture they actually show.

The project stores only the lights, their keyframes, the scene settings, and a
small `RelightAnalysisReference` (analysis version, media identity, quality).
The system may purge the cache; the cost is a re-analysis.

### 3. Rendering (`Core/Rendering/RelightStage.swift`, `Metal/RelightShaders.metal`)

One stage serves the preview, the exporter and the layer compositor:

1. The frame into the grade's representation (Rec.709-encoded RGB for SDR;
   linear BT.2020 working space, diffuse white 1.0, for HLG and Apple Log).
2. **Joint bilateral upsampling** of the two stored depth frames either side of
   this moment, guided by the frame's own luminance, so silhouettes stay sharp.
3. **Normals** from depth slope, one-sided at depth breaks, rotated into the
   upright picture; then smoothed twice, edge-aware (fine for hard light, broad
   for soft light).
4. **Lighting** in linear light, as **stops**: N·L with softness wrap, distance
   falloff (point/spot), cone (spot), optional Light + Shading, conservative
   specular, light wrap, all weighted by confidence. Preserve Highlights is a
   smooth shoulder toward the representation's ceiling (SDR white, HLG peak, a
   few stops of Log latitude) — never a clamp. Protect Blacks keeps the deepest
   shadows from lifting. Strength and the optional mask blend the result.

Moving a light changes only uniforms. Depth is never recomputed for a light
change.

### 4. Paths

* **Direct preview / export**: after noise reduction, before the grade.
* **Layer compositor** (transforms, several tracks, transitions, ramps,
  keyframed grades): every layer is relit before it is graded and composited —
  SDR, HLG and Apple Log.
* **Export** always draws at **High** quality with full geometry. Before the
  first frame is written, any relit clip without complete High-quality depth is
  analysed (the export sheet shows *Analyzing Scene for Relight*).
* **Show Original** (hold the picture, or `\`) bypasses Relight with the rest of
  the grade.

---

## Using it

* **Add a light** (Directional, Point, Spot) or apply a preset (Soft Key, Warm
  Sunset, Cool Moonlight, Side Light, Top Light, Rim Light, Dramatic, Soft
  Fill). Up to six lights per clip. Adding the first light starts analysis.
* **Drag lights on the picture.** A point light shows its reach ring (drag the
  knob to change it); a spot shows its cone and aim point; a directional light
  sits on a disk — centre is light from the camera, the ring is pure side light,
  outside the ring is light from behind.
* **Right-click / long-press a light** for Duplicate, Disable, Reset, Delete.
* **Keyboard** (Mac, iPad with keyboard), with a light selected in Relight:
  ←/→/↑/↓ move it, ⇧ moves 10×, ⌥ moves finely, ⌫ deletes, ⌘D duplicates.
  Outside Relight the same keys keep their timeline meaning.
* Every light value has a **keyframe diamond** and uses the project's keyframe
  engine (clip-local times, moves with trims, splits and speed changes).
  Direction animates the short way round the circle.
* **Affect** limits Relight to one of the clip's masks (Color › Masks) — the
  same window, feather, tracking and colour qualifier. Relight has no mask
  system of its own.
* **Preview quality** (Fast / High) is a device preference. Export is always
  High.
* Every drag, slider gesture or run of key presses is **one undo step**.

---

## Adding a Core ML depth model (recommended)

The built-in estimator needs nothing installed but is strongest on people. For
much better depth on every scene, add Apple's Core ML build of **Depth Anything
V2 Small** (Apache-2.0):

1. Download `DepthAnythingV2SmallF16.mlpackage` from Apple's Core ML models
   page (developer.apple.com/machine-learning/models) or the
   `apple/coreml-depth-anything-v2-small` repository on Hugging Face.
2. Put it anywhere inside the `dummy name/` source folder (for example
   `dummy name/Resources/Models/`). The app target uses a synchronized folder,
   so Xcode adds it and compiles it into the bundle as a `.mlmodelc`.
3. Build and run. The Relight panel's analysis line changes to *Core ML depth
   model*. Re-analyse clips that were analysed with the built-in estimator.

Any compiled model whose name contains "depth" and that takes an image input is
picked up; a model reporting distance instead of nearness is detected and read
inverted. A model can also be placed (compiled, `.mlmodelc`) in
`Application Support/GradeLab/Models/`. Note that the Depth Anything V2 *Base*
and *Large* weights are **not** Apache-licensed.

---

## Limitations (deliberate and known)

* **An estimate, not a scan.** Relight shapes light on surfaces; it does not
  cast shadows, and it cannot see what the camera could not. Glass, mirrors,
  hair, smoke and heavy motion blur get low confidence and a gentle, mostly
  flat response.
* **Built-in estimator** is weakest on scenes without people (architecture,
  landscapes, products). Install a Core ML depth model for those.
* **HLG transitions**: in an HDR (HLG) project, the two clips inside a
  transition are drawn without Relight for the transition's length. SDR and
  Apple Log transitions are relit.
* **Scopes and the eyedroppers** read the frame before Relight.
* **Stills** are not supported: depth is estimated across a shot and carried
  along motion.
* Only Apple Log / Apple Log 2 are importable Log formats in GradeLab, so other
  vendors' Log curves are out of scope here too.
* Relight is not behind the Pro paywall in this build.
* Future work the architecture leaves room for (not implemented): captured
  LiDAR/TrueDepth depth (`RelightEstimatorKind.captured` is reserved), cast
  shadows from a reconstructed proxy, area lights, HDRI environment light,
  material separation, and several Relight instances per clip.

---

## Testing checklist

Unit tests: `GradeLabTests/RelightTests.swift` (persistence and back-compat,
keyframes and azimuth wrap, colour temperature neutrality, intensity response,
depth-plane format, cache bracketing across cuts, temporal fusion, the shader
uniform layout).

On device:

1. **Portrait interview** — Soft Key; drag the key around the face; the lit side
   should follow the face's form, not a circle. Hold `\` to compare.
2. **Walking subject / handheld** — play through; lighting should stay attached
   to surfaces without flicker or swimming.
3. **Clip with a hard cut inside it** — no depth bleeding across the cut.
4. **Low light / noisy footage** with Noise Reduction on — Relight after NR, no
   amplified noise pattern in the light.
5. **HLG clip** — added light rolls into highlight headroom smoothly, no SDR
   clipping; Preserve Highlights at 0 vs 100.
6. **Apple Log clip** — light applied in linear working space, then the look.
7. **Negative light** — intensity −60 on a fill side darkens without greying.
8. **Speed ramp, reverse, split** — light stays on the right frames.
9. **Keyframes** — animate a light moving across a shot; scrub and play.
10. **Mask** — Affect › a tracked face mask; only the face is relit.
11. **Transform / multi-track / transition project** — Relight visible through
    the compositor; export matches preview.
12. **Export** — with depth missing, export analyses first, then writes a file
    matching the preview (High quality).
13. **Performance** — light drags stay interactive (geometry drops resolution
    during a drag); analysis pauses when the device is hot.
14. **iPhone** — bottom panel sections (Lights / Adjust / Scene), large handles.
    **iPad** — side inspector, pointer/Pencil hover highlights handles.
    **Mac** — right-click menus and keyboard nudges.
15. **Undo** — a drag, a slider gesture and a run of arrow presses each undo in
    one step.
