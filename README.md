# GradeLab

Native SwiftUI video and photo color grading for iPhone, iPad and Mac Catalyst.
UI/UX is the priority: keep the picture usable, reuse the shared controls and
design tokens, and check both compact and wide layouts when changing the editor.

## Open and verify

Open `dummy name.xcodeproj` and select the shared **GradeLab** scheme. The app
targets iOS 18+ and macOS 15+ through Mac Catalyst on Apple silicon. The starter
container name is retained; the app target, product and module are GradeLab.
Read version/build numbers from the project settings instead of release notes.

```sh
# Compile the app and tests for iOS; this does not execute device tests.
xcodebuild -project "dummy name.xcodeproj" -scheme GradeLab \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO \
  SWIFT_EMIT_LOC_STRINGS=NO build-for-testing

# Example focused test run on this Mac; select tests relevant to the change.
xcodebuild -project "dummy name.xcodeproj" -scheme GradeLab \
  -destination 'platform=macOS,variant=Mac Catalyst' CODE_SIGNING_ALLOWED=NO \
  SWIFT_EMIT_LOC_STRINGS=NO \
  -only-testing:GradeLabTests/MaskViewportTests test
```

`SWIFT_EMIT_LOC_STRINGS=NO` prevents validation builds from rewriting the string
catalog. Unsigned builds verify compilation; signing, physical-device gestures,
playback/export performance and App Store validation require their own checks.
`Scripts/` contains host regression harnesses for grading, LUTs, curves,
Apple Log, sequences, shot matching, noise reduction and audio.

## Code map

| Location | Responsibility |
| --- | --- |
| `dummy name/App/` | App coordination, imports and editor/project lifecycle |
| `dummy name/Features/Editor/` | Video workspace, tool panels, timeline UI, preview gestures and editor transactions |
| `dummy name/Features/ImageEditor/` | Photo workspace and export UI |
| `dummy name/UI/` | Shared design system, controls, layout and keyboard shortcuts |
| `dummy name/Core/Projects/`, `Core/Images/` | Video/photo documents, persistence and still-image decoding |
| `dummy name/Core/Timeline/` | Tracks, clips, compositing, keyframes, speed, transitions, text/shapes and audio scheduling |
| `dummy name/Core/Grading/`, `Core/Rendering/`, `dummy name/Metal/` | Grade models, uniforms, Metal preview and shared shader stages |
| `dummy name/Core/Tracking/`, `Core/BackgroundRemoval/`, `Core/NoiseReduction/`, `Core/Relight/` | Analysis, tracking, cached mattes/depth and temporal processing |
| `dummy name/Core/Import/`, `Core/Video/`, `Core/Playback/`, `Core/Export/` | Media inspection, decoding, playback and export |
| `dummy name/Core/LUT/`, `Core/Purchases/` | LUT parsing/catalog/import and StoreKit access policy |
| `GradeLabTests/` | Model, rendering, media/export and UI layout regression tests |
| `Scripts/`, `Tools/LUTGenerator/` | Validation and resource generation tools |
| `LUTSources/`, `SoundSources/` | Master resource inputs; preserve alongside compiled app resources |
| `gradelab-site/` | Support, privacy and terms website source; URLs are used by the app |

Paths beginning with `Core/` in the table are relative to `dummy name/`.
Xcode uses synchronized groups for `dummy name/` and `GradeLabTests/`; files
placed inside those trees may become app/test inputs automatically.

## Implementation boundaries

- Video and photos share `GradeSettings` and Metal grading functions. Preserve
  preview/export parity across direct rendering and SDR, HDR and Apple Log layer
  compositors; a UI-only result is insufficient for an effect change.
- `VideoProject` owns the timeline and assets; `ImageProject` owns photo editing.
  Preserve Codable compatibility, clip-relative keyframes, undo/redo and autosave.
- Color masks apply local grades; layer masks change transparency. They are
  different tools. Freehand edits use a transient draft and commit once per
  gesture; point selection must not delete an anchor.
- Preview zoom is inspection state, separate from clip transforms. Tools and
  eyedroppers share its coordinate transform. Mask handles keep their screen
  size while zoomed; guidance belongs outside the picture.
- Tagged Rec.709 SDR, HLG/BT.2020 and original Apple Log have explicit color
  paths. Keep unsupported/ambiguous inputs explicit; do not silently reinterpret
  Apple Log 2, PQ/HDR10 or missing export metadata.
- LUT filenames are persisted identities. Clean display names without renaming
  existing identities. `LUTAsset` and `ProCatalog` define catalog/access; all
  looks can be previewed and Pro restrictions are checked for export.
- Some older bundled `.gclut` files have no matching text source. The compiler
  removes orphan outputs: **do not run a full LUT rebuild into the shared resource
  folder blindly**. Compile additions to a temporary directory and copy their
  outputs. See [curated LUT provenance and procedure](LUTSources/Curated/README.md).
- Use `AppPlatform.isMac` for Mac-only behavior. `usesDesktopWorkspace` includes
  iPad. Native Objective-C gesture handlers should use GradeLab-specific selector
  names to avoid collisions with UIKit selectors during upload validation.

## Detailed context

- [Freehand masks, preview zoom, tracking and device acceptance](Docs/MASK_EDITING.md)
- [Audio processing, preview/export behavior and tests](Docs/AUDIO_TOOLS.md)
- [Relight architecture, models, limitations and validation](Docs/RELIGHT.md)
- [Mac workspace, platform distinctions, shortcuts and release procedure](Docs/MAC_RELEASE.md)
- [LUT import format and naming](LUTSources/Imported/HOW_TO_ADD_LUTS.md)
- [LUT generator implementation](Tools/LUTGenerator/README.md)

## Marketing files

Finished App Store images, social carousel, previews and brand references live
outside this repository at **`/Users/aftab/Desktop/GradeLab Marketing/`**. Its
README indexes the assets. Keep generated marketing exports and per-release
promotional copy there so this workspace stays focused on the app and technical
context. Old release drafts, duplicate exports and legacy tool caches were
removed from the working tree; tracked history remains available in Git.
