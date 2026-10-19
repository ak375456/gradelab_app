# iPhone Color workspace

Settings → iPhone Color workspace switches between **Compact** (the default)
and **Classic**. This is a device preference, shared by video and photo Color
tools. It is not written into projects or undo history. Classic keeps the
existing workspace sizes and controls; switching does not overwrite them.

Compact is gated on the phone idiom and excluded from Mac. iPad, Mac, the
timeline, the main mode bar and other editing tools keep their existing layout.

- On first opening a ready Compact Color workspace, a small alert explains the
  top ••• menu → Settings → iPhone Color workspace path ("Editor settings" in
  photos). Open Settings goes directly to that screen; Got it continues editing.
  Either action remembers the acknowledgment across projects, photo/video
  editors and launches. Classic, iPad and Mac do not trigger it. Existing sheets,
  error dialogs and media preparation take priority; the notice waits until the
  Compact workspace is available.
- A single Color tool menu replaces the tool strip. Light and Color parameters
  show the active adjustment's name (for example Exposure or Temperature) in
  their selector. Each has its own symbol and a small color accent; native
  selection checkmarks remain separate from those icons. The header moves to
  two rows for larger text or longer labels. The underlying grade sliders and
  keyframe lanes are shared with Classic.
- Scopes use a fixed compact trace. The scope menu switches the measurement;
  the settings button opens intensity, False Colour and Zebras controls.
  Expand opens a larger scope explicitly. Pro scope gating is unchanged.
- Expand Color controls gives the inspector more room and enlarges the curve
  graph. The preview remains visible and its inspection zoom does not change.
  Scopes return when the workspace is restored. Tapping Scopes while expanded
  restores the workspace directly.
- Drag the divider below the viewer to balance the picture and controls,
  including while controls are expanded. Double-tap it to restore automatic
  sizing. Normal and expanded Compact sizes are remembered separately as
  proportions, shared by video and photo Color tools. Drag updates are transient;
  preferences are written only when the interaction ends. The renderer's
  interactive-resize hooks bracket the drag, as in Classic.
- Portrait sizing reserves controls, playback and navigation before assigning
  height to the preview. Stored proportions are clamped to keep a usable viewer
  and scrollable inspector when scopes or the available screen size change.
  Classic divider sizes do not affect this budget.

`PhoneColorWorkspaceTests` covers the preference, platform gating, phone-sized
layout bounds, photo controls and grade/undo preservation. Run it alongside
`EditorWorkspaceBudgetTests`, `ScopeAnalysisTests`, `ScopeColorSpaceTests`,
`ViewerAssistTests`, `AdvancedCurvesTests` and `DesktopOnlySurfaceTests`.

Physical-device acceptance still needs iPhone 15 portrait/landscape, larger
Dynamic Type, numeric entry, curve dragging, divider dragging/reset, expanded
controls, scope settings, before/after and switching styles while editing. Check
that the bottom mode bar stays reachable and that returning to Timeline
preserves its prior layout.
