# Freehand mask editing and preview navigation

A tap selects a completed freehand anchor and reveals two curve handles. It does not change the outline. Drag a handle to curve the adjacent edge, or use Point Type → Smooth Point / Corner Point in the mask inspector. Delete Point is explicit and keeps at least three anchors. Point selection is editor state and clears when changing masks or clips.

During drawing, tap the first anchor to close the outline or use Done in the bar below the preview. Drawing guidance lives in the inspector so it cannot cover a sky or an edge of the picture.

Pinch about any point to zoom, and use two fingers to pan while a tool is active. Preview navigation stays available across tools. A dedicated bar below the picture contains the zoom menu (zoom out/in, presets and Fit), Scopes and Compare. Tap Compare to toggle the original or hold it for a temporary comparison. These controls never cover the picture or zoom with it. Fit is the 100% reference; releasing a pinch within 6% of Fit snaps to 100%. Zoom spans 50–800% and is inspection state only. Eyedroppers share the picture transform. Mask handles and their touch targets retain their screen size while zoomed.

Color → Local uses the legacy normalized-source mask geometry. Its outline rotates in source UVs before aspect fit and follows source orientation and evaluated layer placement, matching the existing preview/export shader without changing saved masks. The outer outline is the shape boundary; the inner dashed outline shows full coverage when feathered.

Freehand gestures render a transient project copy and commit on release, as one undo step. Starting viewport navigation discards the pending gesture; it cannot leave extra vertices, change existing animation or autosave a partial stroke. The renderer, overlay and tracking bounds use the same tessellated curve, capped at the existing 64-point budget. Tessellation is cached independently of animated position and scale, with bounded, synchronized storage. Optional incoming/outgoing handle offsets preserve old project decoding.

Tracking reuses pixel-buffer pool allocations and performs contrast lookup/interleave with Accelerate. Progress publishes at most ten times a second. Confidence, visibility and motion continuity checks stop tracking before a large jump or collapse is keyed. It remains an object-region tracker; real footage with weak texture or occlusion still needs review and occasional repositioning.

## Device acceptance

1. Draw a sky boundary up to all four frame edges. Verify no guidance covers the picture; finish with Done or by tapping the first anchor.
2. Tap an anchor repeatedly: it stays selected and the point count stays constant. Drag each curve handle, toggle Smooth/Corner, and undo each action.
3. Pinch midway through a stroke and midway through a handle drag. Verify no stray points or geometry changes are committed. Pan with two fingers without changing their separation.
4. At 400–800%, drag closely spaced anchors. The nearest anchor should respond, with comfortable touch targets and no movement threshold multiplied by zoom.
5. Switch between Masks, Transform, text/shape editing, background brushes and eyedroppers while zoomed. Verify zoom persists, tool coordinates stay aligned, and eyedroppers sample under the finger.
6. Zoom below and above 100%; verify snap on release, presets, and reset of both zoom and position. Check portrait/landscape, iPhone/iPad and Catalyst.
7. Track a curved mask forward/backward, then stop, continue and undo. Review across fast movement, VFR frames, occlusion and cuts. Export a short graded sample and compare its curved edge with the preview.
