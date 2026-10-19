# iPhone Color workspace

Settings → iPhone Color workspace switches between **Compact** (the default)
and **Classic**. This is a device preference, shared by video and photo Color
tools. It is not written into projects or undo history. Classic keeps the
existing workspace sizes and controls; switching does not overwrite them.

Compact is gated on the phone idiom and excluded from Mac. iPad, Mac, the
timeline, the main mode bar and other editing tools keep their existing layout.

- A single Color tool menu replaces the tool strip. Light and Color parameters
  are chosen through Adjust; the underlying grade sliders and keyframe lanes
  are shared with Classic.
- Scopes use a fixed compact trace. The scope menu switches the measurement;
  the settings button opens intensity, False Colour and Zebras controls.
  Expand opens a larger scope explicitly. Pro scope gating is unchanged.
- Expand Color controls gives the inspector more room and enlarges the curve
  graph. The preview remains visible and its inspection zoom does not change.
  Scopes return when the workspace is restored. Tapping Scopes while expanded
  restores the workspace directly.
- Portrait sizing reserves controls, playback and navigation before assigning
  height to the preview. Classic divider sizes do not affect this budget.

`PhoneColorWorkspaceTests` covers the preference, platform gating, phone-sized
layout bounds, photo controls and grade/undo preservation. Run it alongside
`EditorWorkspaceBudgetTests`, `ScopeAnalysisTests`, `ScopeColorSpaceTests`,
`ViewerAssistTests`, `AdvancedCurvesTests` and `DesktopOnlySurfaceTests`.

Physical-device acceptance still needs iPhone 15 portrait/landscape, larger
Dynamic Type, numeric entry, curve dragging, expanded controls, scope settings,
before/after and switching styles while editing. Check that the bottom mode bar
stays reachable and that returning to Timeline preserves its prior layout.
