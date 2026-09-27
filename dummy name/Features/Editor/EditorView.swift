import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct EditorView: View {
    @ObservedObject var model: EditorViewModel
    /// The session's grade clipboard, observed so Paste Grade enables itself
    /// the moment a grade is copied.
    @ObservedObject private var gradeClipboard = GradeClipboard.shared
    let onBack: (VideoProject) -> Void
    let onShowSource: () -> Void
    let onSettingsChanged: (VideoProject, Bool) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var colorMode = false
    @State private var textMode = false
    @State private var textSection = "Style"
    @State private var textAppearance = "Fill"
    @State private var shapeMode = false
    @State private var shapeSection = "Shape"
    @State private var shapeAppearance = "Fill"
    @State private var typingText = false
    @State private var textAnimationSlot: TextAnimationSlot = .incoming
    @FocusState private var textFocused: Bool
    @State private var keyboardOverlap: CGFloat = 0
    @State private var clipOptions = false
    @StateObject private var filmstrip = FilmstripStore()
    @State private var assetFrames: [UUID: [UIImage]] = [:]
    @State private var waveforms: [UUID: [Float]] = [:]
    @State private var audioMode = false
    @State private var soundEffects = false
    @State private var audioURL: URL?
    @State private var mediaItem: MediaImportSource?
    /// The Photos picker, which is how video and stills are chosen everywhere
    /// but Mac. Files go through `fileRequest` instead.
    @State private var mediaPicker = false
    /// What the editor's one file browser was last opened for, and whether it
    /// is open. One browser, because a second `fileImporter` anywhere in this
    /// screen would stop the first from ever presenting — see
    /// `sideFileImporter`, which is what keeps the font and look importers in
    /// the tool panels working.
    @State private var fileRequest: FileImportRequest = .bin
    @State private var showsFileImporter = false
    /// Set just before an edit that creates a title, so the selection change it
    /// causes opens the text dock instead of closing it.
    @State private var startsTypingOnSelection = false
    @State private var importOverlay = false
    @State private var importImage = false
    @State private var layers = false
    @State private var transforms = false
    @ObservedObject private var warmup = CompositorWarmup.shared
    @State private var maskMode = false
    @State private var matteMode = false
    @State private var backgroundMode = false
    @State private var canvasTool = false
    /// The legacy single grading window, edited from Color → Local.
    private var localMaskMode: Bool { colorMode && model.selectedPanel == .mask }
    /// A power window is the grading context. The outline stays on the picture
    /// for every Color tool, not just the Masks tool, because that is when the
    /// user most needs to see which area a slider is about to change.
    private var maskedGradeMode: Bool {
        colorMode && (model.selectedMaskID != nil || model.selectedPanel == .masks)
    }
    /// The overlay also stays up for a finished lasso with no tool armed: the
    /// outline is the selection, so hiding it would leave the user guessing
    /// what is about to be cut — and, once tracked, unable to watch it hold on
    /// the object while scrubbing.
    private var backgroundInteractionActive: Bool {
        backgroundMode && (backgroundToolArmed
                           || model.selectedBackgroundRemoval?.lasso?.isDrawn == true)
    }
    /// A cutout tool currently owns the one-finger drag over the picture: the
    /// lasso is being traced, a refinement brush is down, or a colour is being
    /// picked off the frame.
    private var backgroundToolArmed: Bool {
        backgroundMode && (model.backgroundBrush != nil || model.isDrawingBackgroundLasso
                           || model.isPickingBackgroundColor)
    }
    /// What the preview lets the user do with the picture.
    ///
    /// A cutout tool keeps the pinch, because tracing an edge is exactly when
    /// magnification is worth the most; everything else that draws on the
    /// picture — text and shape handles, mask windows, the eyedropper — still
    /// holds the viewport at 1x so a drag cannot mean two things at once.
    private var previewInteraction: PreviewInteraction {
        if backgroundToolArmed { return .pinchOnly }
        let drawsOnPicture = model.selectedText != nil || model.selectedShape != nil
            || model.evaluatedMediaOverlay != nil
            || model.isPickingCurveHue || model.isPickingWarpColor || model.isPickingMaskQualifier
            || maskMode || localMaskMode || maskedGradeMode
        return drawsOnPicture ? .off : .full
    }
    @State private var speedTool = false
    /// One-shot: the Speed tool was opened by the ramp shortcut, so it should
    /// come up showing the curve rather than the constant-speed slider.
    @State private var opensSpeedRamp = false
    @State private var transitionMode = false
    @State private var settingsSheet = false
    @AppStorage("editor.frameStep") private var frameStep = 2
    // Workspace sizes, in points. Zero means "automatic": the layout picks the
    // size it always did, so nothing changes until someone actually drags a
    // divider. Stored rather than remembered per session, because a workspace
    // someone has arranged should still be arranged tomorrow.
    @AppStorage("editor.inspectorWidth") private var storedInspectorWidth: Double = 0
    /// The media bin's width, and whether it is showing at all. Both are part of
    /// how someone has arranged their workspace rather than part of the
    /// document, so they outlive the session like every other size here.
    @AppStorage("editor.mediaBinWidth") private var storedMediaBinWidth: Double = 0
    @AppStorage("editor.showsMediaBin") private var showsMediaBin = true
    @AppStorage("editor.timelineHeight") private var storedTimelineHeight: Double = 0
    @AppStorage("editor.previewHeight") private var storedPreviewHeight: Double = 0
    @AppStorage("editor.scopeHeight") private var storedScopeHeight: Double = 0
    /// Which pane a size belongs to, so one pair of accessors can stand in
    /// front of all five `@AppStorage` values.
    private enum WorkspacePane: Hashable { case inspector, mediaBin, timeline, preview, scope }
    @State private var isResizing = false
    /// The sizes a divider is currently dragging.
    ///
    /// Held here rather than written straight through to `@AppStorage`. A
    /// divider reports every two points of travel, and each of those was a
    /// UserDefaults write that republished the whole editor mid-gesture: the
    /// Metal drawable resized, the timeline canvas re-laid out, and the panes
    /// lagged the handle instead of tracking it — the visible flicker, on every
    /// platform. Now the gesture moves `@State` and the defaults are written
    /// once, when the handle is let go.
    @State private var liveSizes: [WorkspacePane: Double] = [:]
    @State private var markers = false
    @State private var help = false
    @State private var comparePinned = false
    /// Timeline zoom in points per second, and whether the magnet is on. Both
    /// are how someone has set their workspace up rather than part of the
    /// document, so they persist across sessions and across projects.
    @AppStorage("editor.timelineZoom") private var timelineZoom: Double = 48
    @AppStorage("editor.timelineSnapping") private var timelineSnapping = true
    /// Clip name and length chips. Set in Settings, because they are a reading
    /// preference rather than something to toggle mid-edit.
    @AppStorage("timeline.showsClipNames") private var showsClipNames = true
    @AppStorage("timeline.showsClipDurations") private var showsClipDurations = true
    /// The canvas outline over the preview. A reading preference rather than
    /// part of the document, so it is set in Settings and kept across projects.
    @AppStorage("preview.showsCanvasEdge") private var showsCanvasEdge = true
    /// True while the preview is being pinched, so the cutout tools can tell a
    /// zoom from a stroke.
    @State private var previewPinching = false
    @State private var gradeScrollPosition = ScrollPosition(y: 0)
    @State private var colorInfo = false
    @State private var confirmsResetAll = false
    @State private var savingPreset = false
    /// The isolated one-clip project waiting to be exported, if any. A separate
    /// document from the open one: exporting a clip never edits the timeline.
    @State private var clipExport: GradeProject?
    @GestureState private var holdingOriginal = false

    private var editorLayout: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                if geometry.size.width > geometry.size.height {
                    // Wide layout: preview and timeline on the left, tools on
                    // the right, with a draggable edge on each boundary.
                    HStack(spacing: 0) {
                        // A desktop window has the width to keep the project's
                        // media on screen beside the edit. Narrow windows — a
                        // phone in landscape, an iPad sharing the screen — do
                        // not, and a third column there would cost the picture
                        // more than the list is worth.
                        if mediaBinVisible(geometry.size) {
                            MediaBinPanel(
                                assets: model.project.assets,
                                usageCounts: model.assetUsageCounts,
                                assetFrames: assetFrames,
                                isEnabled: !model.isPreparingTimeline && !model.isImporting && warmup.isReady,
                                onImport: { requestFiles(.bin) },
                                onPlace: { model.placeAsset($0, as: $1) },
                                onImportFiles: { urls in Task { await model.importIntoBin(urls) } })
                                .equatable()
                                .frame(width: mediaBinWidth(geometry.size))
                            WorkspaceDivider(
                                orientation: .vertical,
                                label: "Resize the media bin",
                                onResize: { delta in
                                    // The handle is on the bin's trailing edge,
                                    // so dragging right widens it.
                                    setMediaBinWidth(mediaBinWidth(geometry.size) + delta, in: geometry.size)
                                },
                                onBegin: beginWorkspaceResize,
                                onEnd: endWorkspaceResize,
                                onReset: { resetSize(.mediaBin) })
                        }
                        VStack(spacing: 0) {
                            preview
                            if scopesVisible {
                                WorkspaceDivider(
                                    orientation: .horizontal,
                                    label: "Resize the scopes",
                                    onResize: { delta in
                                        setScopeHeight(scopeHeight(geometry.size, regular: true) - delta,
                                                       in: geometry.size)
                                    },
                                    onBegin: beginWorkspaceResize,
                                    onEnd: endWorkspaceResize,
                                    onReset: { resetSize(.scope) })
                                ScopePanel(model: model, isRegularWidth: true,
                                           traceHeight: scopeHeight(geometry.size, regular: true))
                            }
                            // iPad has enough room to keep the editing context
                            // visible beside every inspector, like a desktop
                            // NLE. Phone landscape keeps the compact behaviour
                            // so its preview is not squeezed by two panels.
                            let showsTimeline = AppPlatform.usesDesktopWorkspace
                                || (!colorMode && !transforms && !canvasTool && !speedTool && !backgroundMode)
                            if showsTimeline {
                                WorkspaceDivider(
                                    orientation: .horizontal,
                                    label: "Resize the timeline",
                                    onResize: { delta in
                                        // The handle sits above the bottom
                                        // block, so dragging up gives the
                                        // timeline the space.
                                        setTimelineHeight(timelineHeight(geometry.size) - delta, in: geometry.size)
                                    },
                                    onBegin: beginWorkspaceResize,
                                    onEnd: endWorkspaceResize,
                                    onReset: { resetSize(.timeline) })
                            }
                            transport
                            if showsTimeline { timeline(height: timelineHeight(geometry.size)) }
                        }.frame(maxWidth: .infinity)
                        WorkspaceDivider(
                            orientation: .vertical,
                            label: "Resize the tools panel",
                            onResize: { delta in
                                // The handle is on the panel's leading edge:
                                // dragging left widens it.
                                setInspectorWidth(inspectorWidth(geometry.size) - delta, in: geometry.size)
                            },
                            onBegin: beginWorkspaceResize,
                            onEnd: endWorkspaceResize,
                            onReset: { resetSize(.inspector) })
                        VStack(spacing: 0) {
                            inspector
                            // On Mac the bar spans the window instead (below),
                            // where twelve tools fit without scrolling.
                            if !spansModeBar(geometry.size) { modeBar }
                        }
                        .frame(width: inspectorWidth(geometry.size))
                    }
                    // A desktop window is wider than the tool bar needs, and the
                    // bar was being folded into a 360-point column and scrolled
                    // — the one place the extra width was worth the most. Across
                    // the window every tool is one click away, with its name.
                    if spansModeBar(geometry.size) { modeBar }
                } else {
                    // Tall layout: one edge, between the picture and everything
                    // below it. Dragging up is how a tool panel that needs the
                    // room - curves especially - gets it.
                    preview.frame(height: previewHeight(geometry.size))
                    WorkspaceDivider(
                        orientation: .horizontal,
                        label: "Resize the preview",
                        onResize: { delta in
                            setPreviewHeight(previewHeight(geometry.size) + delta, in: geometry.size)
                        },
                        onBegin: beginWorkspaceResize,
                        onEnd: endWorkspaceResize,
                        onReset: { resetSize(.preview) })
                    if scopesVisible {
                        WorkspaceDivider(
                            orientation: .horizontal,
                            label: "Resize the scopes",
                            onResize: { delta in
                                setScopeHeight(scopeHeight(geometry.size, regular: false) - delta,
                                               in: geometry.size)
                            },
                            onBegin: beginWorkspaceResize,
                            onEnd: endWorkspaceResize,
                            onReset: { resetSize(.scope) })
                        ScopePanel(model: model, isRegularWidth: false,
                                   traceHeight: scopeHeight(geometry.size, regular: false))
                    }
                    transport
                    if showsTimelineInTallLayout {
                        timeline(height: compactTimelineHeight(geometry.size))
                        // The handle sits UNDER the timeline here, where the
                        // wide layout puts it above: dragging down gives the
                        // timeline the room and dragging up hands it to the tool
                        // panel, which is what someone shortening the timeline to
                        // reach a control below it is actually asking for.
                        WorkspaceDivider(
                            orientation: .horizontal,
                            label: "Resize the timeline",
                            onResize: { delta in
                                setCompactTimelineHeight(compactTimelineHeight(geometry.size) + delta,
                                                         in: geometry.size)
                            },
                            onBegin: beginWorkspaceResize,
                            onEnd: endWorkspaceResize,
                            onReset: { resetSize(.timeline) })
                    }
                    inspector
                    modeBar
                }
            }
        }
        .background(AppColors.background.ignoresSafeArea()).foregroundStyle(AppColors.textPrimary)
        .preferredColorScheme(.dark)
        .buttonStyle(.plain)
    }

    // MARK: - Workspace sizing

    // Every size is clamped against the geometry it is about to be used in, not
    // just when it is stored. iPad multitasking can hand this view a third of
    // the screen a moment after it was full width, and a panel remembered at
    // 600 points would otherwise leave nothing for the picture.

    private func storedSize(_ pane: WorkspacePane) -> Double {
        if let live = liveSizes[pane] { return live }
        switch pane {
        case .inspector: return storedInspectorWidth
        case .mediaBin: return storedMediaBinWidth
        case .timeline: return storedTimelineHeight
        case .preview: return storedPreviewHeight
        case .scope: return storedScopeHeight
        }
    }

    private func setStoredSize(_ pane: WorkspacePane, _ value: Double) {
        if isResizing { liveSizes[pane] = value } else { writeStoredSize(pane, value) }
    }

    private func writeStoredSize(_ pane: WorkspacePane, _ value: Double) {
        switch pane {
        case .inspector: storedInspectorWidth = value
        case .mediaBin: storedMediaBinWidth = value
        case .timeline: storedTimelineHeight = value
        case .preview: storedPreviewHeight = value
        case .scope: storedScopeHeight = value
        }
    }

    /// Double tap on a handle: back to the automatic size, and drop any live
    /// value so the reset is not undone by the end of an in-flight gesture.
    private func resetSize(_ pane: WorkspacePane) {
        liveSizes[pane] = nil
        writeStoredSize(pane, 0)
    }

    /// The bin needs its own width and still has to leave a workable picture
    /// and inspector beside it, so it appears only once the window is wide
    /// enough to seat all three.
    private func mediaBinVisible(_ size: CGSize) -> Bool {
        showsMediaBin && AppPlatform.isMac && size.width >= 1000
    }

    /// Whether the mode bar runs the full width of the window rather than
    /// sitting under the inspector. Mac only: an iPad's landscape layout is the
    /// one the user approved, and its width does not buy the same room.
    private func spansModeBar(_ size: CGSize) -> Bool {
        AppPlatform.isMac && size.width >= 900
    }

    private func mediaBinWidth(_ size: CGSize) -> CGFloat {
        clampedMediaBinWidth(storedSize(.mediaBin) > 0 ? CGFloat(storedSize(.mediaBin)) : 232, in: size)
    }

    private func clampedMediaBinWidth(_ value: CGFloat, in size: CGSize) -> CGFloat {
        let lower: CGFloat = 180
        return min(max(value, lower), max(lower, min(380, size.width * 0.28)))
    }

    private func setMediaBinWidth(_ value: CGFloat, in size: CGSize) {
        setStoredSize(.mediaBin, Double(clampedMediaBinWidth(value, in: size)))
    }

    private func inspectorWidth(_ size: CGSize) -> CGFloat {
        let automatic = min(360, size.width * 0.46)
        return clampedInspectorWidth(storedSize(.inspector) > 0 ? CGFloat(storedSize(.inspector)) : automatic, in: size)
    }

    private func clampedInspectorWidth(_ value: CGFloat, in size: CGSize) -> CGFloat {
        // The floor is a fraction as well as a number, so a narrow window - an
        // iPhone in landscape, an iPad sharing the screen - cannot end up with
        // a panel wide enough to leave no picture beside it.
        let lower = min(260, size.width * 0.34)
        return min(max(value, lower), max(lower, min(620, size.width * 0.6)))
    }

    private func setInspectorWidth(_ value: CGFloat, in size: CGSize) {
        setStoredSize(.inspector, Double(clampedInspectorWidth(value, in: size)))
    }

    private func timelineHeight(_ size: CGSize) -> CGFloat {
        clampedTimelineHeight(
            storedSize(.timeline) > 0 ? CGFloat(storedSize(.timeline)) : automaticTimelineHeight, in: size)
    }

    private func clampedTimelineHeight(_ value: CGFloat, in size: CGSize) -> CGFloat {
        let lower: CGFloat = 76
        return min(max(value, lower), max(lower, size.height * 0.6))
    }

    private func setTimelineHeight(_ value: CGFloat, in size: CGSize) {
        setStoredSize(.timeline, Double(clampedTimelineHeight(value, in: size)))
    }

    /// The timeline's height in the TALL layout, where it shares the window with
    /// the picture above it and the tool panel below rather than sitting beside
    /// a panel of its own.
    ///
    /// Clamped whether or not anyone has dragged it. The automatic height is a
    /// wish — enough room for the rows that exist — and on a phone it is a wish
    /// the window cannot always grant. Granting it anyway pushes the mode bar,
    /// and the first-run notice under it, off the bottom of the screen.
    private func compactTimelineHeight(_ size: CGSize) -> CGFloat {
        let wanted = storedSize(.timeline) > 0 ? CGFloat(storedSize(.timeline)) : automaticTimelineHeight
        return clampedCompactTimelineHeight(wanted, in: size)
    }

    /// The floor keeps a toolbar, a ruler and one row readable. The ceiling is
    /// whatever the window has left once the picture and the fixed chrome below
    /// have taken theirs, so the timeline gives up height — and scrolls — rather
    /// than displacing the controls that would shrink it again.
    private func clampedCompactTimelineHeight(_ value: CGFloat, in size: CGSize) -> CGFloat {
        let lower = EditorWorkspaceBudget.minimumTimeline
        let ceiling = EditorWorkspaceBudget.timelineCeiling(
            height: size.height, previewHeight: previewHeight(size),
            showsWarmupNotice: !warmup.isReady)
        return min(max(value, lower), max(lower, ceiling))
    }

    private func setCompactTimelineHeight(_ value: CGFloat, in size: CGSize) {
        setStoredSize(.timeline, Double(clampedCompactTimelineHeight(value, in: size)))
    }

    private func previewHeight(_ size: CGSize) -> CGFloat {
        // The shares below the timeline's own are deliberately modest. The
        // timeline now carries its own toolbar, and a picture taking half the
        // window leaves it too little to show a ruler and a whole row.
        let automatic = size.height * (colorMode
            ? (scopesVisible ? 0.30 : 0.43)
            : model.project.timeline.tracks.count > 1 ? 0.36 : 0.40)
        return clampedPreviewHeight(
            storedSize(.preview) > 0 ? CGFloat(storedSize(.preview)) : automatic, in: size)
    }

    private func clampedPreviewHeight(_ value: CGFloat, in size: CGSize) -> CGFloat {
        // The floor keeps the picture recognisable; the ceiling keeps a usable
        // timeline and the whole mode bar on screen, so a drag can never hide
        // the controls that would undo it. A height stored before this ceiling
        // existed is corrected on the way out rather than on the way in, which
        // is what repairs a workspace someone had already dragged too far.
        let lower: CGFloat = 140
        let ceiling = EditorWorkspaceBudget.previewCeiling(
            height: size.height, floor: lower, showsTimeline: showsTimelineInTallLayout,
            showsWarmupNotice: !warmup.isReady)
        return min(max(value, lower), max(lower, ceiling))
    }

    /// Whether the tall layout is currently showing a timeline under the
    /// picture. The tools that take the whole panel hide it, and the picture is
    /// welcome to that room when they do.
    private var showsTimelineInTallLayout: Bool {
        !colorMode && !transforms && !canvasTool && !speedTool && !backgroundMode
    }

    private func setPreviewHeight(_ value: CGFloat, in size: CGSize) {
        setStoredSize(.preview, Double(clampedPreviewHeight(value, in: size)))
    }

    private func scopeHeight(_ size: CGSize, regular: Bool) -> CGFloat {
        let automatic = ScopeLayout.automaticTraceHeight(isRegularWidth: regular)
        return clampedScopeHeight(
            storedSize(.scope) > 0 ? CGFloat(storedSize(.scope)) : automatic, in: size)
    }

    private func clampedScopeHeight(_ value: CGFloat, in size: CGSize) -> CGFloat {
        // A scope narrower than this is unreadable as an instrument; taller
        // than half the window and it stops being a second opinion on the
        // picture and starts replacing it.
        let lower: CGFloat = 90
        return min(max(value, lower), max(lower, size.height * 0.5))
    }

    private func setScopeHeight(_ value: CGFloat, in size: CGSize) {
        setStoredSize(.scope, Double(clampedScopeHeight(value, in: size)))
    }

    /// A drag changes the drawable every frame. Telling the renderer means the
    /// spatial effects stage stands down for the length of it rather than
    /// reallocating two drawable-sized surfaces per frame.
    private func beginWorkspaceResize() {
        isResizing = true
        model.renderer.setInteractiveResize(true)
    }

    private func endWorkspaceResize() {
        isResizing = false
        // One write per pane for the whole gesture, rather than one every two
        // points of travel.
        for (pane, value) in liveSizes { writeStoredSize(pane, value) }
        liveSizes = [:]
        model.renderer.setInteractiveResize(false)
    }

    /// What the one file browser was asked for, which is also how its result
    /// is routed: the bin takes everything, the others take one kind.
    private enum FileImportRequest {
        case bin
        case audio
        case media(images: Bool)

        var contentTypes: [UTType] {
            switch self {
            case .bin: [.movie, .image, .audio]
            case .audio: [.audio]
            case .media(let images): images ? [.image] : [.movie]
            }
        }

        /// Only the bin imports in bulk: the others put one thing on the
        /// timeline and would have nowhere to put a second.
        var allowsMultipleSelection: Bool {
            if case .bin = self { true } else { false }
        }
    }

    private func requestFiles(_ request: FileImportRequest) {
        fileRequest = request
        showsFileImporter = true
    }

    /// Video and stills come from Files on Mac and from Photos everywhere else,
    /// which is the same split `MediaImportPicker` makes for the Home screen.
    private func requestMedia(images: Bool, overlay: Bool) {
        importImage = images
        importOverlay = overlay
        if AppPlatform.isMac { requestFiles(.media(images: images)) } else { mediaPicker = true }
    }

    private var editorInputs: some View {
        editorLayout
        .overlay(alignment: .bottom) {
            if typingText {
                textInputDock
                    .padding(.bottom, keyboardOverlap)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Keep the editing workspace at its authored size while the software
        // keyboard floats over it. Only the text dock moves above the keyboard;
        // the canvas and its framing do not jump or shrink.
        //
        // Applied AFTER the overlay, which is the whole point: with it applied
        // first, the dock was still inside the keyboard's safe area, so SwiftUI
        // lifted it by the keyboard height and `keyboardOverlap` lifted it
        // again. That double lift put the dock a full keyboard above the
        // keyboard in portrait and clean off the top of the screen in
        // landscape, where the keyboard is most of the window.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .numericEntryHost()
        // Tracked ONLY while the text dock is up, because the dock's padding is
        // the only thing that reads it.
        //
        // Without that guard this republished on every keyboard frame change
        // from anywhere in the editor, and each write rebuilt the whole body -
        // preview, timeline, filmstrips and inspector. The font search field is
        // the one other place that raises a keyboard here, and raising it
        // installs the `.keyboard` toolbar below, which is itself a frame
        // change; the rebuild then re-evaluated that toolbar. A keyboard also
        // changes frame on nearly every keystroke as the candidate bar comes
        // and goes, so searching for a font rebuilt the editor per character.
        // That is what froze the app, and why making the font list cheap did
        // not help on its own.
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard typingText, let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let overlap = Self.keyboardOverlap(ofScreenFrame: frame)
            guard overlap != keyboardOverlap else { return }
            keyboardOverlap = overlap
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            if keyboardOverlap != 0 { keyboardOverlap = 0 }
        }
        .toolbar { ToolbarItemGroup(placement: .keyboard) {
            if !typingText { Spacer(); Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) } }
        } }
        .confirmationDialog("Reset all edits?", isPresented: $confirmsResetAll, titleVisibility: .visible) {
            Button("Reset All Edits", role: .destructive) { model.resetAll() }
            Button("Cancel", role: .cancel) {}
        } message: { Text(resetAllMessage) }
        .confirmationDialog("Clip options", isPresented: $clipOptions, titleVisibility: .visible) {
            clipOptionActions
            Button("Cancel", role: .cancel) {}
        }
        .alert("Edit unavailable", isPresented: Binding(get: { model.editError != nil }, set: { if !$0 { model.editError = nil } })) {
            Button("OK", role: .cancel) { model.editError = nil }
        } message: { Text(model.editError ?? "") }
        .task(id: model.project.assets) {
            for asset in model.project.assets where assetFrames[asset.id] == nil {
                guard asset.videoMetadata != nil || asset.stillImage != nil else { continue }
                if asset.stillImage != nil {
                    if let image = ImageImportService.thumbnail(asset.url) { assetFrames[asset.id] = [UIImage(cgImage: image)] }
                    continue
                }
                let store = FilmstripStore()
                await store.load(url: asset.url, range: asset.sourceRange)
                guard !Task.isCancelled else { return }
                assetFrames[asset.id] = store.frames
            }
        }
        .task(id: model.project.assets) {
            for asset in model.project.assets where asset.stillImage == nil && (asset.videoMetadata?.hasAudio == true || asset.audioName != nil) && waveforms[asset.id] == nil {
                do { waveforms[asset.id] = try await AudioWaveformStore.shared.load(asset) }
                catch is CancellationError { return }
                catch { waveforms[asset.id] = [] }
            }
        }
        // One browser for the whole screen, on a branch of its own. The editor
        // used to chain three — the bin's, audio's, and the one inside
        // `MediaImportPicker` — and SwiftUI presents only the outermost, so
        // Import Media and Add audio from Files opened nothing at all.
        .sideFileImporter(isPresented: $showsFileImporter,
                          allowedContentTypes: fileRequest.contentTypes,
                          allowsMultipleSelection: fileRequest.allowsMultipleSelection) { result in
            switch result {
            case .success(let urls):
                switch fileRequest {
                case .bin: Task { await model.importIntoBin(urls) }
                case .audio: audioURL = urls.first
                case .media: if let url = urls.first { mediaItem = .file(url) }
                }
            case .failure(let error):
                let cocoa = error as NSError
                if cocoa.domain != NSCocoaErrorDomain || cocoa.code != NSUserCancelledError {
                    model.editError = error.localizedDescription
                }
            }
        }
        .task(id: audioURL) {
            guard let audioURL else { return }
            await model.addAudio(audioURL)
            self.audioURL = nil
        }
        .modifier(PhotoImportPicker(isPresented: $mediaPicker, images: importImage,
                                    onSelection: { mediaItem = $0.first }))
        .task(id: mediaItem) {
            guard let mediaItem else { return }
            if importImage { await model.addImage(mediaItem) }
            else { await model.addMedia(mediaItem, overlay: importOverlay) }
            self.mediaItem = nil
        }
        .sheet(isPresented: $layers) { LayerControls(model: model).presentationDetents([.medium, .large]) }
        .sheet(isPresented: $settingsSheet) { EditorSettings() }
        .sheet(isPresented: $markers) { MarkerControls(model: model).presentationDetents([.medium]) }
        .sheet(isPresented: $soundEffects) {
            SoundEffectBrowser { url in audioURL = url }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    var body: some View {
        editorInputs
        .onChange(of: holdingOriginal) { _, value in model.setOriginalVisible(value || comparePinned) }
        .onChange(of: comparePinned) { _, value in model.setOriginalVisible(value || holdingOriginal) }
        .animation(.easeInOut(duration: 0.18), value: model.statusMessage)
        .onChange(of: model.project) { _, project in onSettingsChanged(project, false) }
        .onChange(of: model.selectedClipID, initial: true) { _, _ in
            // A title that was just created to be typed into opens the dock;
            // every other selection change closes it.
            let startsTyping = startsTypingOnSelection && model.selectedText != nil
            startsTypingOnSelection = false
            typingText = startsTyping; textFocused = startsTyping
            if case .text = model.selectedItem {
                openTextTool()
            } else if case .shape = model.selectedItem {
                openShapeTool()
            } else if model.selectedAudio != nil {
                activate(.audio)
                model.beginAudioEditing()
            }
        }
        .onChange(of: typingText) { _, typing in
            textFocused = typing
            if typing { model.playback.pause() }
            else { model.flushGradeHistory() }
        }
        .onChange(of: scenePhase) { _, phase in
            model.handleScenePhase(active: phase == .active)
            if phase != .active { comparePinned = false; model.setOriginalVisible(false); onSettingsChanged(model.project, true) }
        }
        .onDisappear { model.stopMaskTracking(); model.playback.pause(); model.setOriginalVisible(false) }
        .sheet(isPresented: $model.showsExport, onDismiss: model.resumePreviewAfterExport) {
            ExportView(project: model.project, settings: model.settings)
                .onAppear { model.suspendPreviewForExport() }
        }
        .sheet(isPresented: $savingPreset) { SaveGradePresetSheet(model: model) }
        .sheet(item: $clipExport, onDismiss: model.resumePreviewAfterExport) { project in
            ExportView(project: project,
                       settings: project.timeline.firstVideoClip?.gradeSettings ?? .neutral)
                .onAppear { model.suspendPreviewForExport() }
        }
        .sheet(isPresented: $help) {
            VStack(alignment: .leading, spacing: 24) {
                Label(model.selectedPanel.rawValue, systemImage: model.selectedPanel.symbol).font(.title2.weight(.semibold))
                Text(model.selectedPanel.help).font(.body).foregroundStyle(AppColors.textSecondary)
                Button("Got it") { help = false }.buttonStyle(.borderedProminent).tint(AppColors.accent)
            }.padding(28).presentationDetents([.medium]).presentationDragIndicator(.visible).preferredColorScheme(.dark)
        }
    }

    /// Names what the reset will actually clear. The Color controls edit the
    /// selected mask's local grade when there is one, so the wording has to
    /// follow the same context rather than always claiming the whole clip.
    private var resetAllMessage: String {
        model.selectedMaskID == nil
            ? String(localized: "Every colour adjustment on this clip goes back to neutral — look, curves, wheels, HSL and effects. The timeline, text and transforms are not affected.")
            : String(localized: "Every colour adjustment on the selected mask goes back to neutral. The clip's own grade is not affected.")
    }

    private var shortcutsEnabled: Bool {
        !typingText && !model.showsExport && clipExport == nil && !savingPreset && !help
            && !settingsSheet && !layers && !markers && !soundEffects && !showsFileImporter && !mediaPicker
            && !clipOptions && !confirmsResetAll && !colorInfo && model.editError == nil
    }

    private var workspaceShortcuts: [WorkspaceShortcut] {
        let ready = !model.isPreparingTimeline && !model.isImporting
        let canImport = ready && warmup.isReady
        let singleSelection = model.selectedClipIDs.count == 1 && model.selectedItem != nil
        return [
            .init(.addVideo, isEnabled: canImport) { requestMedia(images: false, overlay: false) },
            .init(.addImageOverlay, isEnabled: canImport) { requestMedia(images: true, overlay: true) },
            .init(.addAudio, isEnabled: canImport) { requestFiles(.audio) },
            .init(.saveProject) {
                model.flushGradeHistory(); onSettingsChanged(model.project, true)
            },
            .init(.export, isEnabled: ready && model.hasMedia) {
                model.playback.pause(); comparePinned = false; model.showsExport = true
            },
            .init(.playPause, isEnabled: ready && model.hasMedia, run: model.playback.togglePlayback),
            .init(.previousFrame, isEnabled: ready && model.hasMedia) { model.stepFrames(-1) },
            .init(.nextFrame, isEnabled: ready && model.hasMedia) { model.stepFrames(1) },
            .init(.backTenFrames, isEnabled: ready && model.hasMedia) { model.stepFrames(-10) },
            .init(.forwardTenFrames, isEnabled: ready && model.hasMedia) { model.stepFrames(10) },
            .init(.undo, isEnabled: ready && model.canUndo, run: model.undo),
            .init(.redo, isEnabled: ready && model.canRedo, run: model.redo),
            .init(.cutClip, isEnabled: ready && singleSelection && model.canEditSelection) { model.deleteClip(cutting: true) },
            .init(.copyClip, isEnabled: singleSelection, run: model.copyClip),
            .init(.pasteClip, isEnabled: ready && model.clipboard != nil, run: model.pasteClip),
            .init(.duplicateClip, isEnabled: ready && singleSelection && model.canEditSelection, run: model.duplicateClip),
            .init(.splitAtPlayhead, isEnabled: ready && model.canSplit && model.canEditSelection, run: model.split),
            .init(.deleteClips, isEnabled: ready && model.canEditSelection) { model.deleteClip() },
            .init(.toggleMarker, isEnabled: ready, run: model.toggleMarker),
            .init(.toggleSnapping) { timelineSnapping.toggle() },
            .init(.compareOriginal, isEnabled: model.hasMedia) { comparePinned.toggle() },
            .init(.zoomInTimeline) { timelineZoom = TimelineZoomScale.stepped(timelineZoom, by: 1.8) },
            .init(.zoomOutTimeline) { timelineZoom = TimelineZoomScale.stepped(timelineZoom, by: 1 / 1.8) },
            .init(.toggleMediaBin) { showsMediaBin.toggle() },
            // Deliberately enabled even for a tool that is not available yet.
            // `select` answers with the reason, exactly as tapping the tab
            // does; a key that silently does nothing would explain less.
            .init(.toolTimeline, isEnabled: ready) { select(.timeline) },
            .init(.toolText, isEnabled: ready, run: addTextAndType),
            .init(.toolShape, isEnabled: ready) { select(.shape) },
            .init(.toolAudio, isEnabled: ready) { select(.audio) },
            .init(.toolColor, isEnabled: ready) { select(.color) },
            .init(.toolTransform, isEnabled: ready) { select(.transform) },
            .init(.toolMask, isEnabled: ready) { select(.mask) },
            .init(.toolMatte, isEnabled: ready) { select(.matte) },
            .init(.toolBackground, isEnabled: ready) { select(.background) },
            .init(.toolSpeed, isEnabled: ready) { select(.speed) },
            // R opens the Speed tool already in Ramp mode, which is what a
            // desktop editor reaching for a key wants — not the tool with a
            // slider on it and another click to go.
            .init(.speedRamp, isEnabled: ready && model.canChangeSpeed) {
                select(.speed); opensSpeedRamp = true
            },
            .init(.resetSpeed, isEnabled: ready && model.canChangeSpeed) {
                model.setSpeed(ClipSpeed.normal)
                model.resetSpeedCurve()
            }
        ]
    }

    private var header: some View {
        HStack(spacing: 0) {
            Button { model.playback.pause(); onBack(model.project) } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }.accessibilityLabel("Back")
            if AppPlatform.isMac {
                Button { showsMediaBin.toggle() } label: {
                    Image(systemName: showsMediaBin ? "sidebar.leading" : "sidebar.left")
                        .frame(width: 36, height: 44)
                        .foregroundStyle(showsMediaBin ? AppColors.accent : AppColors.textSecondary)
                }
                .accessibilityLabel(showsMediaBin ? "Hide the media bin" : "Show the media bin")
                .help(showsMediaBin ? "Hide the media bin" : "Show the media bin")
            }
            Text(model.project.displayName).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            // Mac only. On a touch iPad a keyboard menu is a button that
            // explains keys the device has no way to press.
            if AppPlatform.isMac {
                WorkspaceShortcutMenu(shortcuts: workspaceShortcuts, isEnabled: shortcutsEnabled)
            }
            Button(action: model.undo) { Image(systemName: "arrow.uturn.backward").frame(width: 36, height: 44) }
                .disabled(!model.canUndo).accessibilityLabel("Undo")
            Button(action: model.redo) { Image(systemName: "arrow.uturn.forward").frame(width: 36, height: 44) }
                .disabled(!model.canRedo).accessibilityLabel("Redo")
            Menu {
                if AppPlatform.isMac {
                    Toggle(isOn: $showsMediaBin) { Label("Media Bin", systemImage: "tray.full") }
                }
                Button("Settings", systemImage: "gearshape") { settingsSheet = true }
                Button("Source information", systemImage: "info.circle", action: onShowSource)
                // Confirmed, like every other action in the app that throws
                // work away. Disabled rather than confirmed-then-ignored when
                // the grade is already neutral, which is what `resetAll` does.
                Button("Reset all edits", systemImage: "arrow.counterclockwise", role: .destructive) {
                    confirmsResetAll = true
                }.disabled(!model.canGrade || model.settings == .neutral)
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("Options")
            Button { model.playback.pause(); comparePinned = false; model.showsExport = true } label: {
                Text("Export").font(.caption.weight(.semibold)).fixedSize()
                    .frame(width: 68, height: 30).background(AppColors.accent, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.black).frame(height: 44)
            }.fixedSize()
                .disabled(model.isPreparingTimeline || !model.hasMedia)
        }.padding(.trailing, 12)
    }

    /// Scopes are a grading instrument, so the panel follows Color mode. Leaving
    /// it up in other modes would take space from the timeline for a reading
    /// nobody is acting on.
    private var scopesVisible: Bool {
        colorMode && model.scopeSettings.isEnabled && model.hasMedia && !typingText
    }

    private var scopesButton: some View {
        Button { model.setScopesEnabled(!model.scopeSettings.isEnabled) } label: {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.black.opacity(0.65), in: Capsule())
                .foregroundStyle(model.scopeSettings.isEnabled ? AppColors.accent : AppColors.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.scopeSettings.isEnabled ? "Hide scopes" : "Show scopes")
        .accessibilityAddTraits(model.scopeSettings.isEnabled ? .isSelected : [])
    }

    /// Armed eyedropper: a tap anywhere on the picture samples the graded
    /// frame under it. Zoom is suspended while it is up, so the point the
    /// finger lands on is the point that gets sampled.
    private var colorPickingLayer: some View {
        GeometryReader { proxy in
            Color.white.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    let point = CGPoint(x: location.x / max(proxy.size.width, 1),
                                        y: location.y / max(proxy.size.height, 1))
                    // One armed eyedropper at a time, and the same layer
                    // serves both: the tap, the hint and the suspended zoom are
                    // identical whichever tool asked for the colour.
                    let picked = model.isPickingWarpColor
                        ? model.pickWarpColor(atViewPoint: point)
                        : model.pickCurveHue(atViewPoint: point)
                    if picked { CurveHaptics.add() }
                }
                .overlay(alignment: .bottom) {
                    HStack(spacing: AppSpacing.small) {
                        Image(systemName: "eyedropper")
                        Text("Tap a colour in the picture")
                        Button("Cancel") {
                            model.isPickingCurveHue = false
                            model.isPickingWarpColor = false
                        }
                            .font(AppTypography.caption.weight(.semibold))
                            .foregroundStyle(AppColors.accent)
                    }
                    .font(AppTypography.caption)
                    .padding(.horizontal, AppSpacing.compact)
                    .padding(.vertical, AppSpacing.small)
                    .background(.black.opacity(0.7), in: Capsule())
                    .padding(.bottom, 44)
                }
        }
        .accessibilityLabel("Tap the picture to pick a colour")
    }

    /// The same eyedropper, aimed at the selected mask's colour qualifier.
    ///
    /// A second layer rather than a mode on the first: the two pickers write to
    /// different places, and sharing one would mean deciding which panel the tap
    /// belonged to at the moment of the tap.
    private var qualifierPickingLayer: some View {
        GeometryReader { proxy in
            Color.white.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    let point = CGPoint(x: location.x / max(proxy.size.width, 1),
                                        y: location.y / max(proxy.size.height, 1))
                    guard let id = model.selectedMaskID else {
                        model.isPickingMaskQualifier = false
                        return
                    }
                    if model.pickMaskQualifier(id, atViewPoint: point) { CurveHaptics.add() }
                }
                .overlay(alignment: .bottom) {
                    HStack(spacing: AppSpacing.small) {
                        Image(systemName: "eyedropper")
                        Text("Tap the colour to select")
                        Button("Cancel") { model.isPickingMaskQualifier = false }
                            .font(AppTypography.caption.weight(.semibold))
                            .foregroundStyle(AppColors.accent)
                    }
                    .font(AppTypography.caption)
                    .padding(.horizontal, AppSpacing.compact)
                    .padding(.vertical, AppSpacing.small)
                    .background(.black.opacity(0.7), in: Capsule())
                    .padding(.bottom, 44)
                }
        }
        .accessibilityLabel("Tap the picture to select a colour")
    }

    /// A media-bin drag is over the picture.
    @State private var isCanvasDropTarget = false

    private var preview: some View {
        ZStack(alignment: .topLeading) {
            PreviewViewport(interaction: previewInteraction,
                            onPinchChanged: { previewPinching = $0 }) {
                ZStack {
                MetalPreviewView(renderer: model.renderer, settings: model.settings,
                             showsOriginal: model.showsOriginal, isPlaying: model.playback.isPlaying,
                             redrawTime: model.playback.currentTime, frameUpdateID: model.playback.frameUpdateID,
                             isActive: scenePhase == .active && !model.showsExport)
                    // Inside the viewport, so the edge zooms with the picture it
                    // belongs to. Hidden while the original is held, which is a
                    // look at the untouched frame and wants nothing over it.
                    if showsCanvasEdge && model.hasMedia && !model.showsOriginal {
                        CanvasEdgeOverlay(canvas: model.project.canvas)
                    }
                    if !typingText { OverlayCanvasControls(model: model, editContent: { typingText = true }) }
                    if localMaskMode && !model.showsOriginal {
                        GradeMaskOverlay(model: model, displayedRect: model.renderer.displayedVideoRect)
                    }
                    // Power windows. Shown whenever a mask is the grading
                    // context, not only while the Masks tool happens to be
                    // open — otherwise moving an exposure slider for a face
                    // would give no sign of which face.
                    if maskedGradeMode && !model.showsOriginal {
                        MaskOverlay(model: model, displayedRect: model.renderer.displayedVideoRect)
                    }
                    if maskMode {
                        LayerMaskOverlay(model: model, displayedRect: model.renderer.displayedVideoRect)
                    }
                    if backgroundInteractionActive {
                        BackgroundRemovalOverlay(model: model,
                                                 displayedRect: model.renderer.displayedVideoRect,
                                                 isZooming: previewPinching)
                    }
                }
            }
            if model.isPreparingTimeline || !model.hasMedia {
                Color.black
                if model.isPreparingTimeline { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { Text("Timeline is empty").font(.subheadline).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            if isCanvasDropTarget {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(AppColors.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
            if model.isPickingCurveHue || model.isPickingWarpColor { colorPickingLayer }
            if model.isPickingMaskQualifier { qualifierPickingLayer }
            if model.showsOriginal {
                Text("ORIGINAL").font(.caption2.weight(.semibold)).tracking(1.5)
                    .padding(10).background(.black.opacity(0.65), in: Capsule()).padding(14)
                    .allowsHitTesting(false)
            } else if model.previewStatus.projectMode.isAppleLog {
                // Log footage that has been correctly managed looks like an
                // ordinary picture, which is the point — but it also means
                // nothing on screen says the source is Log. The badge says it,
                // rather than leaving a flat preview to imply it.
                Button { colorInfo = true } label: {
                    Text(model.previewStatus.projectMode.badge).font(.caption2.weight(.semibold)).tracking(1.2)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.black.opacity(0.65), in: Capsule())
                        .foregroundStyle(AppColors.accent)
                }.buttonStyle(.plain).padding(14)
                    .accessibilityLabel("Source is Apple Log. Tap for details.")
            } else if model.previewStatus.projectMode.isHDR {
                let _ = model.displayStateID
                Button { colorInfo = true } label: {
                    Text(model.previewStatus.badge).font(.caption2.weight(.semibold)).tracking(1.2)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.black.opacity(0.65), in: Capsule())
                        .foregroundStyle(model.previewStatus.showingHDR ? AppColors.accent : AppColors.textSecondary)
                }.buttonStyle(.plain).padding(14)
                    .accessibilityLabel("Colour mode: \(model.previewStatus.badge). Tap for details.")
            }
            if !model.playback.isReady && model.playback.errorMessage == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // The label stays put while the original is on screen: the
            // ORIGINAL badge above already says which picture this is, and this
            // pill is under the thumb holding it. It recedes instead, so the
            // state is stated once rather than twice.
            VStack { Spacer(); HStack { Spacer(); Text("Hold to compare")
                    .font(.caption2).foregroundStyle(.white.opacity(model.showsOriginal ? 0.35 : 0.8))
                    .padding(8).background(.black.opacity(model.showsOriginal ? 0.2 : 0.4), in: Capsule())
                    .contentShape(Capsule())
                    .animation(.easeOut(duration: 0.12), value: model.showsOriginal)
                    .gesture(DragGesture(minimumDistance: 0).updating($holdingOriginal) { _, held, _ in held = true })
                } }.padding(12).accessibilityHidden(true)
            if colorMode && model.hasMedia {
                VStack { HStack { Spacer(); scopesButton } ; Spacer() }.padding(14)
            }
            if let status = model.statusMessage {
                VStack {
                    Spacer()
                    Text(status)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.7), in: Capsule())
                        .foregroundStyle(AppColors.textPrimary)
                    Spacer()
                }
                .transition(.opacity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }.background(.black).frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        .alert("Colour mode", isPresented: $colorInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text([
                "Project: \(model.previewStatus.projectMode.badge)",
                model.previewStatus.detail,
                model.colorSupport.notice
            ].compactMap { $0 }.joined(separator: "\n\n"))
        }
            .accessibilityLabel("Video preview")
            .accessibilityAction(named: comparePinned ? "Show edited" : "Show original") { comparePinned.toggle() }
            // Dropping on the picture is how you say "put this in the frame".
            // It lands as its own layer at the playhead, already selected, so
            // the handles are on it the moment the pointer lets go. Files from
            // the Finder are imported first and then placed the same way.
            //
            // `onDrop` rather than `dropDestination`, because two different
            // payloads arrive here: a bin row carries the asset's id as text,
            // and the Finder carries file URLs.
            .onDrop(of: AppPlatform.isMac ? [.fileURL, .text] : [],
                    isTargeted: $isCanvasDropTarget) { providers in
                guard AppPlatform.isMac, !model.isPreparingTimeline,
                      !model.isImporting, warmup.isReady else { return false }
                return acceptCanvasDrop(providers)
            }
    }

    private func acceptCanvasDrop(_ providers: [NSItemProvider]) -> Bool {
        // Files first: a Finder drag also answers to plain text, and reading it
        // as text would place nothing.
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if !files.isEmpty {
            let group = DispatchGroup()
            let collected = URLBox()
            for provider in files {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { collected.append(url) }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                Task { await model.importAndPlaceOnCanvas(collected.urls) }
            }
            return true
        }
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: String.self) }) else { return false }
        _ = provider.loadObject(ofClass: String.self) { text, _ in
            guard let text, let assetID = MediaBinEntry.assetID(fromDrag: text) else { return }
            Task { @MainActor in model.placeAsset(assetID, as: .overlay) }
        }
        return true
    }

    private var transport: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button { model.stepFrames(-max(1, min(120, frameStep))) } label: { Image(systemName: "backward.end").frame(width: 44, height: 44) }
                    .accessibilityLabel("Back \(frameStep) frames").disabled(model.isPreparingTimeline)
                Button(action: model.playback.togglePlayback) {
                    Image(systemName: model.playback.isPlaying ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
                }.accessibilityLabel(model.playback.isPlaying ? "Pause" : "Play")
                    .disabled(model.isPreparingTimeline || !model.hasMedia)
                Button { model.stepFrames(max(1, min(120, frameStep))) } label: { Image(systemName: "forward.end").frame(width: 44, height: 44) }
                    .accessibilityLabel("Forward \(frameStep) frames").disabled(model.isPreparingTimeline)
                let frameRate = model.project.canvas.frameRate ?? model.project.metadata.bestFrameRate
                // One Text, not two, and never compressed. As two views the
                // position and the duration were separate layout units, so on a
                // narrow phone SwiftUI shrank them ahead of the Spacer and broke
                // a timecode across lines mid-value — "00:00:01:" above "08".
                // Concatenation keeps the two-tone styling while making the
                // whole readout indivisible; the priority and fixed size mean
                // the trailing Spacer gives up its width first, which is what
                // it is there for.
                (Text(TimecodeFormatter.frameString(from: model.timelineTime, frameRate: frameRate))
                 + Text(" / ").foregroundStyle(AppColors.textSecondary)
                 + Text(TimecodeFormatter.frameString(
                    from: model.project.timeline.duration.seconds, frameRate: frameRate))
                    .foregroundStyle(AppColors.textSecondary))
                    .font(.caption.monospacedDigit())
                    // lineLimit stops the wrap outright; layoutPriority makes
                    // the Spacer yield its width first; minimumScaleFactor is
                    // the last resort on a narrow phone, where shrinking a
                    // point or two beats truncating a timecode to "00:00:0…".
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(1)
                    .accessibilityLabel("Position \(TimecodeFormatter.frameString(from: model.timelineTime, frameRate: frameRate)) of \(TimecodeFormatter.frameString(from: model.project.timeline.duration.seconds, frameRate: frameRate))")
                Spacer(minLength: 0)
                if AppPlatform.usesDesktopWorkspace {
                    persistentTimelineActions
                    previewQualityButton
                } else {
                    timelineActionsMenu
                }
                Button { comparePinned.toggle() } label: {
                    Image(systemName: "square.on.square").frame(width: 44, height: 44)
                        .foregroundStyle(comparePinned ? AppColors.accent : AppColors.textSecondary)
                }.accessibilityLabel(comparePinned ? "Show edited video" : "Compare with original")
                    .accessibilityValue(comparePinned ? "Original" : "Edited")
            }.padding(.horizontal, 8)
            if let error = model.playback.errorMessage { Text(error).font(.caption).foregroundStyle(AppColors.warning).padding(8) }
        }
    }

    /// Editing commands belong to the timeline, not to whichever inspector is
    /// open. iPad can keep the three primary commands visible; a phone exposes
    /// the same commands from one compact menu so the preview keeps its room.
    private var persistentTimelineActions: some View {
        HStack(spacing: 0) {
            addMediaMenu
            Button(action: model.split) {
                Image(systemName: "scissors").frame(width: 40, height: 36)
            }
            .accessibilityLabel("Split at playhead")
            .disabled(!model.canSplit)
            Button(action: openTransitionTool) {
                Image(systemName: "rectangle.2.swap").frame(width: 40, height: 36)
            }
            .accessibilityLabel("Add transition at playhead")
            .disabled(!model.canUseTransitions || !warmup.isReady)
            // Delete belongs beside the other editing commands rather than in
            // the inspector below, which is where it used to be: the inspector
            // changes with the tool, and deleting a clip does not.
            Button(role: .destructive) { model.deleteClip() } label: {
                Image(systemName: "trash")
                    // A pointer can hit 40x36; a finger needs 44, and iPad is a
                    // finger even when its window is desktop-sized.
                    .frame(width: AppPlatform.isMac ? 40 : 44,
                           height: AppPlatform.isMac ? 36 : 44)
            }
            .accessibilityLabel(model.selectedClipIDs.count > 1
                                ? "Delete \(model.selectedClipIDs.count) clips" : "Delete clip")
            .disabled(model.selectedClipID == nil || !model.canEditSelection)
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(AppColors.textSecondary)
        .background(AppColors.surfaceRaised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var addMediaMenu: some View {
        Menu { addMediaActions } label: {
            Group {
                if model.isImporting { ProgressView() }
                else { Image(systemName: "plus") }
            }
            // A pointer can hit 40x36; a finger needs 44, and iPad is a
            // finger even when its window is desktop-sized.
            .frame(width: AppPlatform.isMac ? 40 : 44,
                   height: AppPlatform.isMac ? 36 : 44)
        }
        .accessibilityLabel("Add media")
        .disabled(model.isImporting || !warmup.isReady)
    }

    @ViewBuilder private var addMediaActions: some View {
        Button("Sound effects", systemImage: "waveform.badge.plus") {
            model.playback.pause(); soundEffects = true
        }
        Button("Add audio from Files", systemImage: "waveform") { requestFiles(.audio) }
        Button("Add video after selection", systemImage: "film") {
            requestMedia(images: false, overlay: false)
        }
        Button("Add video overlay", systemImage: "square.3.layers.3d") {
            requestMedia(images: false, overlay: true)
        }
        Button("Add image overlay", systemImage: "photo") {
            requestMedia(images: true, overlay: true)
        }
        Button("Add text", systemImage: "textformat", action: addTextAndType)
        Button("Add shape", systemImage: "square.on.circle") { openShapeTool(); model.addShape() }
    }

    private var timelineActionsMenu: some View {
        Menu {
            Menu("Add", systemImage: "plus") { addMediaActions }
                .disabled(model.isImporting || !warmup.isReady)
            Button("Split at playhead", systemImage: "scissors", action: model.split)
                .disabled(!model.canSplit)
            Button("Add transition", systemImage: "rectangle.2.swap", action: openTransitionTool)
                .disabled(!model.canUseTransitions || !warmup.isReady)
            Divider()
            Button("Paste", systemImage: "doc.on.clipboard", action: model.pasteClip)
                .disabled(model.clipboard == nil)
            Button("Add or remove marker", systemImage: "bookmark", action: model.toggleMarker)
            if model.selectedClipID != nil {
                if model.selectedClipIDs.count == 1 {
                    Menu("Clip options", systemImage: "ellipsis") { clipOptionActions }
                }
                Button(role: .destructive) { model.deleteClip() } label: {
                    Label(model.selectedClipIDs.count > 1
                          ? "Delete \(model.selectedClipIDs.count) clips" : "Delete clip",
                          systemImage: "trash")
                }.disabled(!model.canEditSelection)
            }
            Divider()
            Picker("Playback quality", selection: Binding(
                get: { model.playback.previewQuality },
                set: { model.playback.previewQuality = $0 }
            )) {
                ForEach(PreviewQuality.allCases) { quality in
                    Text(quality.title).tag(quality)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
        }
        .accessibilityLabel("Timeline actions")
        .disabled(model.isPreparingTimeline)
    }

    /// Preview resolution while playing. It changes nothing about the project,
    /// the paused picture or the export, so it sits in the transport with the
    /// other playback controls rather than among the grading tools.
    private var previewQualityButton: some View {
        Menu {
            Picker("Preview quality", selection: Binding(
                get: { model.playback.previewQuality },
                set: { model.playback.previewQuality = $0 }
            )) {
                ForEach(PreviewQuality.allCases) { quality in
                    Text(quality.title).tag(quality)
                }
            }
            Text("Applies while playing only. Paused, the picture is always at the project's own resolution, and export is unaffected.")
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "speedometer").font(.system(size: 11))
                Text(model.playback.previewQuality.badge).font(.caption2.weight(.medium))
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(AppColors.surfaceRaised, in: Capsule())
            .foregroundStyle(model.playback.isPlayingReduced ? AppColors.accent : AppColors.textSecondary)
            .frame(height: 44)
        }
        .fixedSize()
        .accessibilityLabel("Playback preview quality")
        .accessibilityValue(model.playback.previewQuality.title)
    }

    /// The height the timeline takes when nobody has resized it: enough for the
    /// tracks that exist plus its own controls, capped so it never crowds out
    /// the picture.
    private var automaticTimelineHeight: CGFloat {
        TimelineToolbar<EmptyView>.height
            + min(audioMode || textMode || shapeMode ? 156 : 230,
                  model.project.timeline.tracks.reduce(TimelineMetrics.rowsTop) {
                      $0 + $1.resolvedHeight.points(for: $1.kind) + TimelineMetrics.rowGap
                  })
    }

    /// Track types the timeline can gain. Grouped by what the new row holds, so
    /// another kind later — an adjustment layer, a nested sequence — is a new
    /// section here rather than a new menu.
    @ViewBuilder private var addTrackActions: some View {
        Section("Video") {
            Button("Video clip", systemImage: "film") {
                requestMedia(images: false, overlay: false)
            }
            Button("Video overlay", systemImage: "square.3.layers.3d") {
                requestMedia(images: false, overlay: true)
            }
            Button("Image overlay", systemImage: "photo") {
                requestMedia(images: true, overlay: true)
            }
        }
        Section("Audio") {
            Button("Sound effects", systemImage: "waveform.badge.plus") {
                model.playback.pause(); soundEffects = true
            }
            Button("Audio from Files", systemImage: "waveform") { requestFiles(.audio) }
        }
        Section("Overlays") {
            Button("Text", systemImage: "textformat", action: addTextAndType)
            Button("Shape", systemImage: "square.on.circle") { openShapeTool(); model.addShape() }
        }
    }

    private func timeline(height: CGFloat) -> some View {
        VStack(spacing: 0) {
                TimelineView(clips: model.project.timeline.items.compactMap(TimelineDisplayClip.init), tracks: model.project.timeline.tracks, markers: model.project.timeline.markers,
                    transitions: model.project.timeline.transitions,
                    keyframeTimes: model.selectedClipKeyframeTimes,
                    assets: model.project.assets, assetFrames: assetFrames, waveforms: waveforms, sourceRange: model.project.primaryAsset.sourceRange,
                    minimumDuration: model.project.canvas.frameDuration?.seconds ?? 0.01, name: model.project.displayName,
                    currentTime: model.timelineTime, selectedID: model.selectedClipID,
                    selectedIDs: model.selectedClipIDs,
                    selectedTransitionID: model.selectedTransitionID,
                    thumbnails: filmstrip.frames,
                    pixelsPerSecond: timelineZoom,
                    isSnappingEnabled: timelineSnapping,
                    showsClipNames: showsClipNames,
                    showsClipDurations: showsClipDurations,
                    onZoomChange: { timelineZoom = $0 },
                    onSelect: { id in
                        model.selectClip(id: id)
                        if id == nil { colorMode = false; maskMode = false }
                    },
                    onSelectMany: { ids in
                        model.selectClips(ids)
                        if model.selectionContainsOnlyText { openTextTool() }
                        else if model.selectionContainsOnlyShapes { openShapeTool() }
                        else { activate(.timeline) }
                    },
                    onSelectTransition: { id in openTransitionTool(id: id) },
                    onDragSelect: { model.selectClip(id: $0, seek: false) },
                    onOptions: { model.selectClip(id: $0, seek: false); clipOptions = true },
                    onDropAsset: { assetID, time in model.placeAsset(assetID, as: .overlay(at: time)) },
                    onMoveClipToLayer: model.moveClipToLayer,
                    onToggleTrackVisibility: { model.toggleTrack($0, lock: false) },
                    onToggleTrackLock: { model.toggleTrack($0, lock: true) },
                    onToggleTrackMute: model.toggleTrackMute,
                    onSetTrackHeight: model.setTrackHeight,
                    onSetWaveformSize: model.setWaveformSize,
                    onEdit: model.editTiming,
                    onTrimMany: model.trimClips,
                    onBeginEdit: model.playback.pause,
                    onBeginSeek: model.playback.beginSeeking,
                    onSeek: { model.seekTimeline(to: $0, finishing: false) },
                    onEndSeek: { model.seekTimeline(to: $0, finishing: true) })
                    .frame(height: max(60, height - TimelineToolbar<EmptyView>.height))
                    .allowsHitTesting(!model.isPreparingTimeline)
            TimelineToolbar(
                pixelsPerSecond: $timelineZoom,
                isSnappingEnabled: $timelineSnapping,
                canSplit: model.canSplit,
                onSplit: model.split,
                addTrackMenu: { addTrackActions })
                .disabled(model.isPreparingTimeline)
            if filmstrip.unavailable {
                Text("Filmstrip unavailable · seeking still works").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var modeBar: some View {
        VStack(spacing: 0) {
            modeButtons
            // Shown rather than letting someone tap Transform and meet a frozen
            // picture with nothing on screen to explain it. The compositing
            // shaders take real time to compile the first time they are built on
            // a device — measured at about a minute on an A16 — and the system
            // caches the result, so this appears once after installing and never
            // again.
            if !warmup.isReady {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Preparing layers, transforms and effects… first run only")
                        .font(.caption2)
                        .foregroundStyle(AppColors.textTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: - Mode bar

    /// The bar's ten tools, in the order they are drawn.
    ///
    /// The modes themselves are still the eight `@State` booleans the rest of
    /// this view reads. This only gives the bar a single list to draw and a
    /// single place to switch, instead of nine buttons each clearing seven
    /// flags by hand — which is how a tool used to end up half switched.
    private enum EditorMode: String, CaseIterable, Identifiable {
        case timeline, text, shape, audio, color, transform, mask, matte, background, speed, transition, canvas

        var id: String { rawValue }

        var title: String {
            switch self {
            case .timeline: return String(localized: "Timeline")
            case .text: return String(localized: "Text")
            case .shape: return String(localized: "Shape")
            case .audio: return String(localized: "Audio")
            case .color: return String(localized: "Color")
            case .transform: return String(localized: "Transform")
            case .mask: return String(localized: "Mask")
            case .matte: return String(localized: "Matte")
            case .background: return String(localized: "Remove BG")
            case .speed: return String(localized: "Speed")
            case .transition: return String(localized: "Transition")
            case .canvas: return String(localized: "Canvas")
            }
        }

        var symbol: String {
            switch self {
            case .timeline: return "rectangle.split.3x1"
            case .text: return "textformat"
            case .shape: return "square.on.circle"
            case .audio: return "waveform"
            case .color: return "camera.filters"
            case .transform: return "crop.rotate"
            case .mask: return "circle.dashed"
            case .matte: return "square.on.square.dashed"
            case .background: return "person.crop.rectangle"
            case .speed: return "speedometer"
            case .transition: return "rectangle.2.swap"
            case .canvas: return "aspectratio"
            }
        }

        /// Tools that cannot run until the compositing shaders have been built.
        var needsCompositor: Bool {
            switch self {
            case .text, .shape, .audio, .transform, .mask, .matte, .background, .transition: return true
            case .timeline, .color, .speed, .canvas: return false
            }
        }
    }

    private var activeMode: EditorMode {
        if textMode { return .text }
        if shapeMode { return .shape }
        if audioMode { return .audio }
        if colorMode { return .color }
        if transforms { return .transform }
        if maskMode { return .mask }
        if matteMode { return .matte }
        if backgroundMode { return .background }
        if speedTool { return .speed }
        if transitionMode { return .transition }
        if canvasTool { return .canvas }
        return .timeline
    }

    /// Sets all eight flags from one value, so no tool can be left half on.
    private func activate(_ mode: EditorMode) {
        textMode = mode == .text
        shapeMode = mode == .shape
        audioMode = mode == .audio
        colorMode = mode == .color
        transforms = mode == .transform
        maskMode = mode == .mask
        matteMode = mode == .matte
        backgroundMode = mode == .background
        // The matte view is a debug view, so leaving the tool takes it with it
        // rather than leaving the preview showing coverage during a colour edit.
        if mode != .matte { model.endTrackMatteEditing() }
        if mode != .background {
            model.showsBackgroundMatte = false
            model.backgroundBrush = nil
            model.isDrawingBackgroundLasso = false
            model.isPickingBackgroundColor = false
        }
        canvasTool = mode == .canvas
        speedTool = mode == .speed
        transitionMode = mode == .transition
    }

    /// Why a tool cannot be used at this moment, or nil when it can.
    ///
    /// The bar says these out loud on tap instead of grouping a tool out in
    /// silence. A dimmed control with no stated reason is what makes people
    /// think an app is broken, and five of these nine can be unavailable.
    private func unavailableReason(for mode: EditorMode) -> String? {
        // Checked first: it is temporary, and it covers most of the list at once.
        if mode.needsCompositor && !warmup.isReady {
            return String(localized: "Still preparing effects — first run only.")
        }
        switch mode {
        case .timeline, .canvas, .text, .shape, .audio:
            return nil
        case .color, .transform:
            if model.selectedClip == nil { return String(localized: "Select a clip in the timeline first.") }
            return model.canGrade ? nil : String(localized: "This clip can’t be graded.")
        case .mask:
            if model.selectedClip == nil { return String(localized: "Select a clip in the timeline first.") }
            return model.canEditSelection ? nil : String(localized: "This clip is locked.")
        case .matte:
            // Wrapped at the call site: the return type is `String`, and a bare
            // literal in a `String`-typed expression is never extracted for
            // translation.
            if model.selectedItem == nil { return String(localized: "Select a layer in the timeline first.") }
            if model.selectedItem?.isCompositable != true {
                return String(localized: "An audio clip has no picture to cut.")
            }
            return model.canEditSelection ? nil : String(localized: "This layer is locked.")
        case .background:
            if model.selectedClip == nil { return String(localized: "Select a video or image clip first.") }
            return model.canEditSelection ? nil : String(localized: "This clip is locked.")
        case .speed:
            return model.canChangeSpeed ? nil : String(localized: "Select a video clip to change its speed.")
        case .transition:
            return model.canUseTransitions ? nil : String(localized: "Transitions need two clips meeting at the playhead.")
        }
    }

    /// Switching order matters: each case keeps the sequence the individual
    /// buttons used, because which side of the switch `flushGradeHistory` falls
    /// on decides how the undo entries either side of it are grouped.
    private func select(_ mode: EditorMode) {
        if let reason = unavailableReason(for: mode) { model.showStatus(reason); return }
        switch mode {
        case .text: openTextTool()
        case .shape: openShapeTool()
        case .transition: openTransitionTool()
        case .timeline, .color, .speed, .canvas:
            activate(mode); model.flushGradeHistory()
        case .audio:
            activate(mode); model.beginAudioEditing()
        case .transform:
            activate(mode); model.beginTransformEditing()
        case .mask:
            activate(mode); model.beginLayerMaskEditing()
        case .matte:
            activate(mode); model.beginTrackMatteEditing()
        case .background:
            activate(mode); model.beginBackgroundRemovalEditing()
        }
    }

    private func modeTab(_ mode: EditorMode) -> some View {
        let selected = activeMode == mode
        let unavailable = unavailableReason(for: mode) != nil
        return Button { select(mode) } label: {
            VStack(spacing: 2) {
                Image(systemName: mode.symbol).font(.system(size: 15, weight: .medium))
                Text(mode.title).font(.system(size: 9, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 7)
            .frame(minWidth: 46)
            .frame(height: 44)
            .background(selected ? AppColors.accent.opacity(0.16) : .clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .foregroundStyle(selected ? AppColors.accent : AppColors.textSecondary)
            // Unavailable rather than disabled: it still takes a tap, and
            // answers it with the reason.
            .opacity(unavailable ? 0.4 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .id(mode)
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(unavailableReason(for: mode) ?? "")
    }

    /// The tools that belong to the open panel. Pinned outside the scroll view
    /// so they are always on screen: behind nine scrolling tabs they were off
    /// the end of the bar and, in Color, that hid Reset and the grade actions
    /// entirely.
    private var modeActions: some View {
        HStack(spacing: 0) {
            Rectangle().fill(AppColors.border)
                .frame(width: AppSpacing.hairline, height: 26)
                .padding(.horizontal, 4)
            if colorMode {
                Button { help = true } label: {
                    Image(systemName: "questionmark.circle").frame(width: 38, height: 44)
                }.accessibilityLabel("How to use \(model.selectedPanel.rawValue)")
                GradeActionsMenu(model: model, onSaveGrade: { savingPreset = true })
                Button("Reset", action: model.resetPanel)
                    .font(.caption.weight(.medium)).frame(minWidth: 40, minHeight: 44)
            } else {
                Button { layers = true } label: {
                    Image(systemName: "square.3.layers.3d").frame(width: 38, height: 44)
                }.accessibilityLabel("Layers")
            }
        }
        // Matched to the tab icons rather than left at body size, which is what
        // an unstyled Image falls back to now that the bar sets no font itself.
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(AppColors.textSecondary)
        .padding(.trailing, 8)
    }

    private var modeButtons: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(EditorMode.allCases) { modeTab($0) }
                    }
                    .padding(.horizontal, 8)
                }
                .scrollIndicators(.hidden)
                // Nine tools do not fit any phone, so the bar says so: the ends
                // fade instead of cutting off square, which reads as "this
                // continues" where a hairline indicator under a 44-point strip
                // does not.
                .mask(
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.035),
                        .init(color: .black, location: 0.945),
                        .init(color: .clear, location: 1)
                    ], startPoint: .leading, endPoint: .trailing)
                )
                // Switching tools from anywhere else — selecting a text clip,
                // opening a transition from the timeline — must not leave the
                // tool that is now open scrolled off the bar.
                .onChange(of: activeMode, initial: true) { _, mode in
                    withAnimation(.easeOut(duration: 0.22)) { proxy.scrollTo(mode, anchor: .center) }
                }
            }
            modeActions
        }
        .frame(height: 52)
    }

    @ViewBuilder private var inspector: some View {
        if transitionMode { TransitionPanel(model: model) }
        else if textMode {
            VStack(spacing: 0) {
                HStack {
                    Text("Text").font(.caption.weight(.semibold))
                    Spacer()
                    Button(action: addTextAndType) { Label("Add text", systemImage: "plus").font(.caption.weight(.medium)).frame(minHeight: 44) }
                        .disabled(model.isPreparingTimeline)
                }.padding(.horizontal, 20)
                ScrollView {
                    if case .text = model.selectedItem {
                        TextToolPanel(model: model, editContent: { model.selectClip(id: model.selectedClipID); typingText = true },
                                      section: $textSection, appearance: $textAppearance,
                                      animationSlot: $textAnimationSlot).id(model.selectedClipID)
                            .disabled(!model.canEditSelection)
                    } else {
                        Text("Add a title or select a text clip in the timeline to edit it.")
                            .font(.subheadline).foregroundStyle(AppColors.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    }
                }.scrollIndicators(.visible)
            }
        }
        else if shapeMode {
            VStack(spacing: 0) {
                HStack {
                    Text("Shape").font(.caption.weight(.semibold))
                    Spacer()
                    Menu {
                        ForEach(ShapeKind.allCases) { kind in
                            Button(kind.title) { openShapeTool(); model.addShape(kind) }
                        }
                    } label: {
                        Label("Add shape", systemImage: "plus").font(.caption.weight(.medium)).frame(minHeight: 44)
                    }
                    .disabled(model.isPreparingTimeline)
                    .accessibilityLabel("Add shape")
                }.padding(.horizontal, 20)
                ScrollView {
                    if case .shape = model.selectedItem {
                        ShapeToolPanel(model: model, section: $shapeSection, appearance: $shapeAppearance)
                            .id(model.selectedClipID)
                            .disabled(!model.canEditSelection)
                    } else {
                        Text("Add a shape or select a shape clip in the timeline to edit it.")
                            .font(.subheadline).foregroundStyle(AppColors.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    }
                }.scrollIndicators(.visible)
            }
        }
        else if speedTool { SpeedPanel(model: model, opensRamp: $opensSpeedRamp) }
        else if maskMode { LayerMaskPanel(model: model) }
        else if matteMode { TrackMattePanel(model: model) }
        else if backgroundMode { BackgroundRemovalPanel(model: model) }
        else if transforms { LiveTransformPanel(model: model) }
        else if canvasTool { CanvasTools(model: model) }
        else if colorMode && model.canGrade { controls }
        else {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        Button(action: model.pasteClip) { Image(systemName: "doc.on.clipboard").frame(width: 44, height: 44) }
                            .accessibilityLabel("Paste").disabled(model.clipboard == nil)
                        // Split lives in the timeline's own toolbar, beside
                        // Snap and the zoom. A second scissors a few points
                        // below it was the same command twice. Delete now sits
                        // in that same toolbar wherever there is room for it,
                        // so it is only repeated here on a phone, where the
                        // toolbar folds into a menu instead.
                        if !AppPlatform.usesDesktopWorkspace {
                            Button(role: .destructive) { model.deleteClip() } label: { Image(systemName: "trash").frame(width: 44, height: 44) }
                                .accessibilityLabel(model.selectedAudio == nil ? "Delete clip and close gaps" : "Delete audio clip").disabled(!model.canEditSelection)
                        }
                        Button { model.toggleMarker() } label: { Image(systemName: "bookmark").frame(width: 44, height: 44) }
                            .accessibilityLabel("Add or remove marker at playhead")
                            .contextMenu { Button("Show / delete markers") { markers = true } }
                        Menu {
                            clipOptionActions
                        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                            .accessibilityLabel("Clip options")
                            .disabled(model.selectedClipID == nil || model.selectedClipIDs.count != 1)
                    }.font(.subheadline).frame(minHeight: 44)
                }.frame(height: 44).scrollIndicators(.hidden).disabled(model.isPreparingTimeline)
                if audioMode {
                    AudioToolPanel(model: model, addSoundEffect: {
                        model.playback.pause(); soundEffects = true
                    }, addAudio: { requestFiles(.audio) }, showTracks: { layers = true },
                        waveformUnavailable: model.selectedAudio.map { waveforms[$0.assetID]?.isEmpty == true } ?? false)
                } else {
                    Text("Hold, then drag sideways to move · Drag vertically for a layer · Drag edges to trim")
                        .font(.caption).foregroundStyle(AppColors.textSecondary)
                }
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.top, 8)
        }
    }

    private var controls: some View {
        GradingControls(model: model, onSaveGrade: { savingPreset = true },
                        scrollPosition: $gradeScrollPosition)
    }

    private func openTextTool() {
        model.flushGradeHistory()
        activate(.text)
    }

    /// ⌘T, and every Add text button: open the tool, make a title, and put the
    /// cursor in it. Reaching for the text tool and then having to find a
    /// second button before a single character can be typed is a step nobody
    /// wants; with a title already selected this edits that one instead of
    /// stacking another on top of it.
    private func addTextAndType() {
        openTextTool()
        if model.selectedText != nil {
            typingText = true
        } else {
            startsTypingOnSelection = true
            model.addText()
        }
    }

    private func openShapeTool() {
        model.flushGradeHistory()
        activate(.shape)
    }

    private func openTransitionTool() {
        model.flushGradeHistory()
        activate(.transition)
        model.prepareTransitionPanel()
    }

    private func openTransitionTool(id: UUID) {
        model.flushGradeHistory()
        activate(.transition)
        model.selectTransition(id)
    }

    /// How far the keyboard reaches into this app's own window, in points.
    ///
    /// Measured against the window rather than the screen. In Split View or
    /// Stage Manager the window is not the screen, and a screen-relative
    /// measurement lifts the dock by the distance to the bottom of the display
    /// instead of the distance to the bottom of the app.
    private static func keyboardOverlap(ofScreenFrame frame: CGRect) -> CGFloat {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) else { return 0 }
        let local = window.convert(frame, from: window.screen.coordinateSpace)
        // A floating or undocked keyboard does not sit on the bottom edge, so
        // there is nothing to lift the dock out from under.
        guard local.maxY >= window.bounds.maxY - 1 else { return 0 }
        return max(0, window.bounds.maxY - local.minY)
    }

    private var textInputDock: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Edit text").font(.caption.weight(.semibold))
                Spacer()
                Button("Done") { typingText = false }.font(.subheadline.weight(.semibold)).frame(minHeight: 44)
            }
            TextEditor(text: Binding(get: { model.selectedText?.text ?? "" }, set: { text in model.editText { $0.text = text } }))
                .focused($textFocused).font(.body).scrollContentBackground(.hidden)
                // Short in a compact-height window: on a phone in landscape the
                // keyboard leaves barely a third of the screen, and a dock
                // authored for portrait would take the rest of it.
                .frame(height: verticalSizeClass == .compact ? 52 : 84).padding(.horizontal, 6)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("Text content")
        }.padding(.horizontal, 16).padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .background(AppColors.background)
    }

    @ViewBuilder private var clipOptionActions: some View {
        if let id = model.selectedClipID, model.project.timeline.videoClip(id: id) != nil {
            Button("Export this clip") {
                model.playback.pause()
                comparePinned = false
                clipExport = SingleClipExport.isolate(clipID: id, in: model.project)
                if clipExport == nil {
                    model.editError = String(localized: "This clip could not be prepared for export on its own.")
                }
            }
        }
        Button("Copy", action: model.copyClip)
        Button("Cut") { model.deleteClip(cutting: true) }
        Button("Duplicate", action: model.duplicateClip)
        Button("Trim start to playhead") { if let id = model.selectedClipID { model.editTiming(id: id, operation: .trimStart, seconds: model.timelineTime) } }
        Button("Trim end to playhead") { if let id = model.selectedClipID { model.editTiming(id: id, operation: .trimEnd, seconds: model.timelineTime) } }
        if model.selectedClip?.embeddedAudio != nil {
            Button("Separate audio", systemImage: "waveform", action: model.separateAudio).disabled(!model.canEditSelection)
        }
    }

}
