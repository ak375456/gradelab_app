# Editor stabilization

Select one unlocked video clip, open **Stabilize**, and choose **Analyze &
Stabilize**. Analysis runs on-device and can be canceled without applying a
partial result. It pauses playback but does not replace or transcode the original.
Analysis, enabling stabilization, smoothness editing and stabilized export require
GradeLab Pro. Free accounts see the standard Pro paywall on Analyze or Enable;
they can disable a saved effect and export without it. Active saved stabilization
is detected by the shared export policy, including copied/imported projects.
Access is checked again before an analysis result is applied.
Smoothness adjusts correction strength; double-tap restores 80%, and tapping
the value permits exact entry. Each drag is one undo entry. The Before toggle
only bypasses this clip's stabilization in preview; it never changes saved or
exported settings. Leaving the tool clears it.

The source-time correction table persists with the clip. Trims, copies, splits,
timeline moves, reverse and speed ramps evaluate the same table through the
existing source-time map. Extending beyond the analyzed source range disables
the effect for that clip and asks for another analysis. Replacing media clears
the source-dependent analysis. Projects with no stabilization field remain
compatible. Photos and camera capture use their existing paths.

## Motion and rendering

`Core/Stabilization/StabilizationAnalysis.swift` streams native luminance through the existing bounded
tracking decoder/converter, at up to 60 measurements per source second and a
960-pixel analysis long edge. It retains two frames plus the motion table,
not a movie's worth of decoded images. `Core/Timeline/VideoStabilization.swift`
owns the persisted corrections and smoothing. A pass is capped at 120,000 measurements;
longer clips require splitting. Decoder errors propagate; untrustworthy image
registrations break the camera path into independent segments.

Vision translational registration prealigns each pair before homographic
refinement. Only global translation and roll survive the fit: zoom, shear and
perspective are not used to warp the picture. Bounds, plausible motion,
projective-fit residual and source-luminance correlation reject bad estimates.
This is image-based global stabilization, not gyro-based rolling-shutter repair
or object locking. Strong foreground motion, parallax, severe blur and missing
detail still need review.

A symmetric Gaussian local-linear fit sees past/future frames and preserves
constant pan velocity, including at clip ends. Corrections taper at registration
breaks rather than interpolating across cuts. One fixed crop covers the entire
correction path, avoiding per-frame zoom pumping. If full correction would need
more than 1.35× zoom, the whole path is attenuated consistently. Stronger shake
therefore retains some motion rather than consuming most of the picture.

The SDR compositor transforms/crops the source-local graded and masked image
before authored placement. HDR and Apple Log use the same correction through
source-sampling uniforms, with a separate fitted-picture bounds test. Both
preview and export, transitions, layer masks, background cutouts and track-matte
coverage use these paths. Original audio and timing are untouched. Source-space
editing handles follow the correction as well as preferred orientation and
authored placement. Sampled slow motion holds each source frame's correction;
blended/flow frames and subsampled high-rate footage interpolate it.

## Verification

`StabilizationTests` covers pan preservation, shake rejection, crop bounds
through interpolated motion and different aspect ratios, crop limits, persistence,
source-time mapping, oriented SDR/Metal sampling and real Vision registration.
`StabilizationWorkflowTests` writes a known shaky movie, runs production analysis,
reads its composited preview, exports H.264 and checks motion reduction and pixel
agreement within codec tolerance. `StabilizationPanelTests` renders narrow/wide
panels and accessibility text sizes. HDR and Apple Log tests exercise corrected
source sampling in the real shaders, including tiled Log rendering.

Use `SWIFT_EMIT_LOC_STRINGS=NO` for verification builds. Physical-device acceptance
must still check handheld pans/walking, low light, foreground subjects, cuts,
portrait/landscape, 4K/60, HDR/Log, audio sync, mask interactions, cancel/undo,
thermal behavior, and iPhone/iPad/Mac layouts. Image tests cannot establish
real-world perceived smoothness or sustained device performance.
