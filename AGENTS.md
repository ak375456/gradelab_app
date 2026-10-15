# GradeLab working context

UI/UX is my priority.

This is a native SwiftUI/Metal iOS and Mac Catalyst app, not a Flutter project.
Start with `README.md` for the code map, build commands and implementation
boundaries. Read the relevant technical document in `Docs/` when working on
masks, audio, Relight or the Mac workspace.

- Reuse `dummy name/UI/DesignSystem/` and shared components. Check narrow and
  wide layouts, comfortable touch targets, unobstructed previews and gesture
  coexistence. Mac-only changes must not accidentally replace iPad behavior.
- Preserve preview/export parity, saved-project compatibility and one undo
  entry per editing gesture. Validate with focused existing tests and relevant
  host harnesses; device interaction still needs a physical-device check.
- Preserve app assets, test fixtures, LUT/audio sources and compiled resources.
  Some bundled LUT sources are absent; compiling into the shared output folder
  can delete those existing resources. Follow `LUTSources/Curated/README.md`.
- Use `SWIFT_EMIT_LOC_STRINGS=NO` for verification builds unless string-catalog
  regeneration is part of the requested work.
- The hidden `.claude/worktrees/` checkout contains unfinished edits. Do not
  treat it as the current source tree or discard it during ordinary cleanup.
- Finished marketing assets are in `/Users/aftab/Desktop/GradeLab Marketing/`.
  Put new screenshots, social exports and release copy there when requested;
  avoid accumulating generated media or historical update drafts in this repo.
- Read current version/build and access policy from the project and source code,
  rather than treating old marketing copy as product behavior.
