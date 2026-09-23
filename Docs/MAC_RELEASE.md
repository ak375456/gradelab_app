# GradeLab for Mac

GradeLab now has a Mac Catalyst build using the same editor, Metal renderer, project format and StoreKit products as the iPhone/iPad app. Mac import detection also covers the iPad app running on an Apple silicon Mac.

## Run

Open `dummy name.xcodeproj`, select **GradeLab**, then select **My Mac (Mac Catalyst)** as the run destination. It is the only Mac destination the scheme offers: `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD` is `NO`, so **My Mac (Designed for iPad)** no longer appears in the list and the iPad build cannot be shipped to Macs by accident. The iOS 18 deployment target maps to macOS 15 for Catalyst. The Mac build is Apple-silicon-only (M1 and later). Debug and Release configurations build `arm64` and exclude `x86_64` for the macOS SDK, for both the app and its test target. Intel Macs cannot run this app. iPhone/iPad architectures are unchanged.

```sh
xcodebuild -project "dummy name.xcodeproj" -scheme GradeLab \
  -destination 'generic/platform=macOS,variant=Mac Catalyst' \
  CODE_SIGNING_ALLOWED=NO build
```

Use the normal signed Xcode Run action to launch the app. An unsigned build only verifies compilation. If Xcode cannot locate its Metal compiler, install the Metal Toolchain in Xcode Settings → Components.

## Import and export

- On Mac, **Import Videos** opens the system file browser and accepts multiple movies. **Import Photo** opens it for one image. Home also offers **Import from Photos**.
- Home shortcuts: **⌘O** for videos, **⇧⌘O** for a photo.
- The editor's Add Video, Video Overlay and Image Overlay actions use the file browser on Mac. Audio, custom LUT and font imports already use files.
- On iPhone/iPad, the primary actions still open Photos; Home also offers **Import from Files**.
- Video and image exports offer **Save to Files**, which opens the system destination picker. Share and Save to Photos remain available.
- Chosen source files are copied into project storage while security-scoped access is active. Originals are never moved. Reopening a project does not require the external drive or original file.
- Existing codec, colour-profile and image-format validation still applies; choosing a file does not bypass it.

## Release

Mac-only entitlements are in `Config/GradeLab-Mac.entitlements`: App Sandbox, user-selected file read/write, Photos library, and outgoing network access. The app retains `com.aftab.gradelab` as its bundle identifier rather than generating a `maccatalyst.` prefix. The icon catalog includes Mac resolutions from the existing GradeLab artwork.

1. In App Store Connect, add the **macOS** platform to the existing GradeLab app record. Check Mac availability and the existing in-app purchase configuration.
2. Confirm signing for the Mac destination under the existing development team. Increment the build number as required for the next upload.
3. Archive with **Any Mac (Mac Catalyst)** selected. In Organizer, validate and distribute the archive to App Store Connect.
4. Supply Mac screenshots, metadata and privacy details. Test the signed build through TestFlight before submitting it for review.

Apple references: [creating a Mac version of an iPad app](https://developer.apple.com/documentation/uikit/creating-a-mac-version-of-your-ipad-app), [adding a platform in App Store Connect](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-platforms/).

## Mac acceptance pass

- On the M1 Air, import a local MOV/MP4 and JPEG/HEIC/PNG, then import from an external drive or iCloud Drive.
- Cancel each picker; no error or project should appear. Try an unsupported source and verify the normal explanation.
- Import multiple videos, add video/image overlays and audio, grade, play, seek, resize the window, export and save to a chosen folder.
- Reopen saved projects after relaunch with the original media unavailable.
- Cancel the save panel and retry; confirm the exported movie/image opens from the chosen folder.
- Verify Photos import/save, Pro purchase and Restore Purchases in the signed sandbox build.
- Press every shortcut in the table below, including while a text field is focused and while a sheet is open, where they should stay inert.
- Place media from the bin all three ways, right-click a clip, and hide and reopen the bin across a relaunch.
- Recheck Photos import on iPhone/iPad.

Enabling Catalyst and passing a build is not App Store validation; signing, TestFlight and review remain release steps.

## Verification (2026-09-22)

- Initial Mac Catalyst verification passed for arm64 and x86_64, including Metal shaders; the later M-series-only change removes Intel from subsequent builds.
- Generic iOS device build passed.
- Three `FileMediaImportTests` passed on the Apple silicon Mac: movie copy/original preservation, rejection of a non-movie, and photo filename/durable storage.
- A normal ad-hoc signed Mac build passed with the production sandbox capabilities (plus Debug's debugger entitlement).
- UI smoke check: Finder import of the bundled `onboarding-1-before.mp4`, reopen the saved project, enter the editor, export HEVC, and save the resulting MOV through the native save panel. The generated file was moved to `/tmp/GradeLab-Mac-import-check.mov` after verification to keep it out of app resources.
- Distribution signing, App Store validation, purchases, external-drive/iCloud imports, and the full acceptance pass above still require release testing.

## Mac-only means `isMac`, not `usesDesktopWorkspace`

`AppPlatform.usesDesktopWorkspace` is `isMac || iPad`. It describes **room**, not platform: a timeline that stays visible beside a tool panel, transport actions laid out instead of folded into a menu. Those are iPad behaviours as much as Mac ones and are gated on it deliberately.

Everything on this page is gated on `AppPlatform.isMac`. Gating any of it on `usesDesktopWorkspace` put the entire Mac workspace onto iPad once — the media bin, the keyboard-shortcut menu, the Settings keyboard section, and a 40×36 add-media button where a finger needs 44. Before adding a Mac surface, ask which of the two it is.

**`buttonMaskRequired` does not make a gesture pointer-only.** It filters buttons, and a finger presses none, so a `UITapGestureRecognizer` set to `.secondary` still receives direct touches — which made every tap on a clip open the clip menu on iPad and iPhone. `allowedTouchTypes = [.indirectPointer]` is what actually restricts it. `DesktopOnlySurfaceTests` guards both halves.

## The Mac workspace

The Mac layout is not the iPad layout in a bigger window. A desktop window has width the tablet layout had no way to spend, and these three changes spend it.

**A media bin.** `MediaBinPanel` is a column of its own on the left, listing every asset in the project with a thumbnail, its kind, its length or pixel dimensions, and how many clips currently use it — so a source that was imported and never used is visible as such. Import buttons for video, photo and audio sit under the list. It appears where `AppPlatform.usesDesktopWorkspace` is true and the window is at least 1000 points wide; below that a third column would cost the picture more than the list returns. Drag its trailing edge to resize, ⇧⌘M or the header's **⋯ → Media Bin** to hide it. Width and visibility persist, like every other workspace size.

This changes what import means. A source lands in the bin once and is placed from there as many times as the edit wants: `EditorViewModel.placeAsset(_:as:)` adds a clip that references media the project already holds, so nothing is re-read or re-copied and `project.assets` is untouched. There are three ways to place one, and they differ deliberately:

| Gesture | Where it lands |
| --- | --- |
| Double-click a row, or its **+** button | End of the main video track |
| Drag a row onto the timeline | A new overlay layer, at the second it was dropped on |
| Drag a row onto the picture | A new overlay layer, at the playhead, selected with its handles up |
| Right-click → **Add as Overlay** | A new overlay layer, at the playhead |

A drop carries a position because the pointer chose one. The main track packs and ripples, so a position there would mean nothing — which is why the button appends instead.

**Import is one button, and the bin is a drop target.** `Import Media` opens one browser for movies, stills and audio together; `EditorViewModel.ImportedMediaKind` reads the file and routes it, so nobody has to classify their own rushes before the browser opens. Files dragged from the Finder onto the bin are imported the same way, several at once, under one undo entry. Files dropped on the *picture* are imported and then placed.

Crucially, `importIntoBin` does **not** touch the timeline. Import answers "what am I working with" and placing answers "where does it go"; running them together meant every import also edited the sequence, so bringing in six takes to choose between them left six clips to delete again. (`commit` had to learn that an assets-only change is a real change — it previously required the timeline or canvas to differ, and would have dropped the import silently.)

## Pictures are edited on the canvas

An image or video on an overlay layer now carries the same selection frame, drag, pinch and rotate handles that titles and shapes have had — `CanvasOverlay` gained a `VideoClip` initialiser whose bounds are the source fitted to the canvas, which is what the compositor draws before the clip's own transform. `CanvasPictureHandleTests` compares the handle geometry against `LayerCompositor.transform` corner by corner, including rotation, off-centre anchors and non-uniform scale, because an outline that is merely close reads as a bug the moment anything is rotated.

Main-track clips are deliberately excluded: that track is the background the rest of the frame sits on, and handles there would mean a stray drag across the picture moved the whole programme. It still transforms from the Transform tool.

## ⌘T types

⌘T — and every **Add text** button — opens the tool, creates a title and puts the cursor in it. With a title already selected it edits that one rather than stacking another on top. The selection change a new title causes used to close the text dock unconditionally; `startsTypingOnSelection` is what lets that one case open it instead.

## Dragging a divider no longer republishes the editor

`WorkspaceDivider` reports every two points of travel, and each report was written straight to `@AppStorage`. That is a UserDefaults write per step, which republished the whole editor mid-gesture: the Metal drawable resized, the timeline canvas re-laid out, and the panes lagged the handle rather than tracking it — visible as flicker, on Mac, iPad and iPhone alike. Sizes now move through `liveSizes`, a transient `@State` dictionary, and the defaults are written once when the handle is let go. `resetSize(_:)` clears the live value too, so a double-tap reset cannot be undone by the end of an in-flight gesture.

**Secondary click opens a clip's menu.** Holding a clip is how a touch screen asks for that menu; on a desktop the same gesture is a drag, so the timeline now takes a right-click — a trackpad two-finger tap, or a mouse's right button — and opens the clip options under the pointer. Implemented as a second `UITapGestureRecognizer` on `TimelineCanvas` with `buttonMaskRequired = .secondary`. Holding still drags, unchanged. Bin rows carry a `contextMenu`, which Catalyst maps to the same click.

**The mode bar spans the window.** It had been folded into the inspector's ~360-point column and scrolled, on the platform with the most width to give it. On Mac, at 900 points or wider, it runs the full width below everything else and all twelve tools show at once with their names. `spansModeBar(_:)` gates it on `AppPlatform.isMac`, so the iPad's approved landscape layout is untouched.

## Keyboard shortcuts

Every equivalent is defined once, as a `WorkspaceShortcut.Action` case in `dummy name/UI/Components/WorkspaceShortcuts.swift`. Home, both editors and the Settings list read those cases, so a key cannot end up documented as the one it used to be. Add a shortcut by adding a case there, then attaching the work at the screen that owns it.

It is reachable two ways: the keyboard icon in the video and photo editor headers opens a menu of the shortcuts available right now, with unavailable actions disabled, and **Settings → Keyboard → Keyboard shortcuts** lists all of them by screen whether or not they are currently live. Both appear wherever `AppPlatform.usesDesktopWorkspace` is true, which is Mac and iPad.

**The equivalents must not be attached to the menu's own buttons.** SwiftUI builds menu content lazily, so nothing inside a `Menu` is registered with UIKit until the menu has been opened. Measured on Mac Catalyst by walking the responder chain: a menu holding three `.keyboardShortcut` buttons produced **zero** `UIKeyCommand`s, which is why no editor shortcut did anything on Mac, while the same three on buttons in the view hierarchy produced three. They now ride on `keyOwners` inside `WorkspaceShortcutMenu` — zero-size buttons that are always in the hierarchy — and the menu shows each equivalent as a subtitle instead of binding it a second time, so every key keeps exactly one owner. `.disabled` still suppresses registration, so an unavailable action's key stays inert just as its menu entry is greyed out. Home's two buttons were never affected; they carry their equivalents directly.

Text fields keep their normal typing, cursor movement, cut/copy/paste and undo behavior; editor shortcuts pause while typing or while a modal workflow is open. Projects continue to autosave.

| Action | Shortcut |
| --- | --- |
| Import videos from Home / add video in editor | ⌘O |
| Import photo from Home / add image overlay in video editor | ⇧⌘O |
| Add audio in video editor | ⌥⌘O |
| Save project immediately | ⌘S |
| Export video or photo | ⌘E |
| Undo / redo | ⌘Z / ⇧⌘Z |
| Cut / copy / paste clip | ⌘X / ⌘C / ⌘V |
| Duplicate clip | ⌘D |
| Split at playhead | ⌘B |
| Delete selected clips | Delete |
| Play / pause | Space |
| Previous / next frame | ← / → |
| Back / forward 10 frames | ⇧← / ⇧→ |
| Add / remove marker | M |
| Toggle snapping | N |
| Compare original / edited | Backslash (\\) |
| Zoom timeline in / out | = / - |
| Show / hide the media bin | ⇧⌘M, or the sidebar button in the header |
| Split at the playhead (blade) | ⌘B, and ⌘K |
| Switch tool, in mode-bar order | ⌘1 … ⌘9, ⌘0 |
| Text tool | ⌘T (also ⌘2) |

Playback, clip and timeline shortcuts apply to the video editor. Photo editing supports save, export, undo/redo and compare. Cut and duplicate require a single editable clip; Delete uses the current multi-selection and the same lock checks as the on-screen controls.
