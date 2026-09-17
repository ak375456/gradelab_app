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
    @State private var colorMode = false
    @State private var textMode = false
    @State private var textSection = "Style"
    @State private var textAppearance = "Fill"
    @State private var typingText = false
    @FocusState private var textFocused: Bool
    @State private var keyboardOverlap: CGFloat = 0
    @State private var clipOptions = false
    @StateObject private var filmstrip = FilmstripStore()
    @State private var assetFrames: [UUID: [UIImage]] = [:]
    @State private var waveforms: [UUID: [Float]] = [:]
    @State private var audioMode = false
    @State private var audioPicker = false
    @State private var soundEffects = false
    @State private var audioURL: URL?
    @State private var mediaItem: PhotosPickerItem?
    @State private var mediaPicker = false
    @State private var importOverlay = false
    @State private var importImage = false
    @State private var layers = false
    @State private var transforms = false
    @ObservedObject private var warmup = CompositorWarmup.shared
    @State private var maskMode = false
    @State private var canvasTool = false
    /// The legacy single grading window, edited from Color → Local.
    private var localMaskMode: Bool { colorMode && model.selectedPanel == .mask }
    /// A power window is the grading context. The outline stays on the picture
    /// for every Color tool, not just the Masks tool, because that is when the
    /// user most needs to see which area a slider is about to change.
    private var maskedGradeMode: Bool {
        colorMode && (model.selectedMaskID != nil || model.selectedPanel == .masks)
    }
    @State private var speedTool = false
    @State private var transitionMode = false
    @State private var settingsSheet = false
    @AppStorage("editor.frameStep") private var frameStep = 2
    // Workspace sizes, in points. Zero means "automatic": the layout picks the
    // size it always did, so nothing changes until someone actually drags a
    // divider. Stored rather than remembered per session, because a workspace
    // someone has arranged should still be arranged tomorrow.
    @AppStorage("editor.inspectorWidth") private var storedInspectorWidth: Double = 0
    @AppStorage("editor.timelineHeight") private var storedTimelineHeight: Double = 0
    @AppStorage("editor.previewHeight") private var storedPreviewHeight: Double = 0
    @AppStorage("editor.scopeHeight") private var storedScopeHeight: Double = 0
    @State private var markers = false
    @State private var help = false
    @State private var comparePinned = false
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
                                    onReset: { storedScopeHeight = 0 })
                                ScopePanel(model: model, isRegularWidth: true,
                                           traceHeight: scopeHeight(geometry.size, regular: true))
                            }
                            // iPad has enough room to keep the editing context
                            // visible beside every inspector, like a desktop
                            // NLE. Phone landscape keeps the compact behaviour
                            // so its preview is not squeezed by two panels.
                            let showsTimeline = UIDevice.current.userInterfaceIdiom == .pad
                                || (!colorMode && !transforms && !canvasTool && !speedTool)
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
                                    onReset: { storedTimelineHeight = 0 })
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
                            onReset: { storedInspectorWidth = 0 })
                        VStack(spacing: 0) { inspector; modeBar }
                            .frame(width: inspectorWidth(geometry.size))
                    }
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
                        onReset: { storedPreviewHeight = 0 })
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
                            onReset: { storedScopeHeight = 0 })
                        ScopePanel(model: model, isRegularWidth: false,
                                   traceHeight: scopeHeight(geometry.size, regular: false))
                    }
                    transport
                    if !colorMode && !transforms && !canvasTool && !speedTool { timeline(height: automaticTimelineHeight) }
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

    private func inspectorWidth(_ size: CGSize) -> CGFloat {
        let automatic = min(360, size.width * 0.46)
        return clampedInspectorWidth(storedInspectorWidth > 0 ? CGFloat(storedInspectorWidth) : automatic, in: size)
    }

    private func clampedInspectorWidth(_ value: CGFloat, in size: CGSize) -> CGFloat {
        // The floor is a fraction as well as a number, so a narrow window - an
        // iPhone in landscape, an iPad sharing the screen - cannot end up with
        // a panel wide enough to leave no picture beside it.
        let lower = min(260, size.width * 0.34)
        return min(max(value, lower), max(lower, min(620, size.width * 0.6)))
    }

    private func setInspectorWidth(_ value: CGFloat, in size: CGSize) {
        storedInspectorWidth = Double(clampedInspectorWidth(value, in: size))
    }

    private func timelineHeight(_ size: CGSize) -> CGFloat {
        clampedTimelineHeight(
            storedTimelineHeight > 0 ? CGFloat(storedTimelineHeight) : automaticTimelineHeight, in: size)
    }

    private func clampedTimelineHeight(_ value: CGFloat, in size: CGSize) -> CGFloat {
        let lower: CGFloat = 76
        return min(max(value, lower), max(lower, size.height * 0.6))
    }

    private func setTimelineHeight(_ value: CGFloat, in size: CGSize) {
        storedTimelineHeight = Double(clampedTimelineHeight(value, in: size))
    }

    private func previewHeight(_ size: CGSize) -> CGFloat {
        let automatic = size.height * (colorMode
            ? (scopesVisible ? 0.30 : 0.43)
            : model.project.timeline.tracks.count > 1 ? 0.38 : 0.48)
        return clampedPreviewHeight(
            storedPreviewHeight > 0 ? CGFloat(storedPreviewHeight) : automatic, in: size)
    }

    private func clampedPreviewHeight(_ value: CGFloat, in size: CGSize) -> CGFloat {
        // The floor keeps the picture recognisable; the ceiling keeps at least
        // a usable strip of tools on screen, so a drag can never hide the
        // controls that would undo it.
        let lower: CGFloat = 140
        return min(max(value, lower), max(lower, size.height * 0.72))
    }

    private func setPreviewHeight(_ value: CGFloat, in size: CGSize) {
        storedPreviewHeight = Double(clampedPreviewHeight(value, in: size))
    }

    private func scopeHeight(_ size: CGSize, regular: Bool) -> CGFloat {
        let automatic = ScopeLayout.automaticTraceHeight(isRegularWidth: regular)
        return clampedScopeHeight(
            storedScopeHeight > 0 ? CGFloat(storedScopeHeight) : automatic, in: size)
    }

    private func clampedScopeHeight(_ value: CGFloat, in size: CGSize) -> CGFloat {
        // A scope narrower than this is unreadable as an instrument; taller
        // than half the window and it stops being a second opinion on the
        // picture and starts replacing it.
        let lower: CGFloat = 90
        return min(max(value, lower), max(lower, size.height * 0.5))
    }

    private func setScopeHeight(_ value: CGFloat, in size: CGSize) {
        storedScopeHeight = Double(clampedScopeHeight(value, in: size))
    }

    /// A drag changes the drawable every frame. Telling the renderer means the
    /// spatial effects stage stands down for the length of it rather than
    /// reallocating two drawable-sized surfaces per frame.
    private func beginWorkspaceResize() {
        model.renderer.setInteractiveResize(true)
    }

    private func endWorkspaceResize() {
        model.renderer.setInteractiveResize(false)
    }

    private var editorInputs: some View {
        editorLayout
        // Keep the editing workspace at its authored size while the software
        // keyboard floats over it. Only the text dock moves above the keyboard;
        // the canvas and its framing do not jump or shrink.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .overlay(alignment: .bottom) {
            if typingText {
                textInputDock
                    .padding(.bottom, keyboardOverlap)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .numericEntryHost()
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            keyboardOverlap = max(0, UIScreen.main.bounds.maxY-frame.minY)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardOverlap = 0 }
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
        .fileImporter(isPresented: $audioPicker, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url): audioURL = url
            case .failure(let error): model.editError = error.localizedDescription
            }
        }
        .task(id: audioURL) {
            guard let audioURL else { return }
            await model.addAudio(audioURL)
            self.audioURL = nil
        }
        .photosPicker(isPresented: $mediaPicker, selection: $mediaItem, matching: importImage ? .images : .videos, preferredItemEncoding: .current)
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
            typingText = false; textFocused = false
            if case .text = model.selectedItem {
                openTextTool()
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
        .sheet(isPresented: $model.showsExport) { ExportView(project: model.project, settings: model.settings) }
        .sheet(isPresented: $savingPreset) { SaveGradePresetSheet(model: model) }
        .sheet(item: $clipExport) { project in
            ExportView(project: project,
                       settings: project.timeline.firstVideoClip?.gradeSettings ?? .neutral)
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

    private var header: some View {
        HStack(spacing: 0) {
            Button { model.playback.pause(); onBack(model.project) } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }.accessibilityLabel("Back")
            Text(model.project.displayName).font(.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Button(action: model.undo) { Image(systemName: "arrow.uturn.backward").frame(width: 36, height: 44) }
                .disabled(!model.canUndo).accessibilityLabel("Undo")
            Button(action: model.redo) { Image(systemName: "arrow.uturn.forward").frame(width: 36, height: 44) }
                .disabled(!model.canRedo).accessibilityLabel("Redo")
            Menu {
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
                    if model.pickCurveHue(atViewPoint: point) { CurveHaptics.add() }
                }
                .overlay(alignment: .bottom) {
                    HStack(spacing: AppSpacing.small) {
                        Image(systemName: "eyedropper")
                        Text("Tap a colour in the picture")
                        Button("Cancel") { model.isPickingCurveHue = false }
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

    private var preview: some View {
        ZStack(alignment: .topLeading) {
            PreviewViewport(inspectionEnabled: model.selectedText == nil && !model.isPickingCurveHue && !maskMode && !localMaskMode && !maskedGradeMode) {
                ZStack {
                MetalPreviewView(renderer: model.renderer, settings: model.settings,
                             showsOriginal: model.showsOriginal, isPlaying: model.playback.isPlaying,
                             redrawTime: model.playback.currentTime, frameUpdateID: model.playback.frameUpdateID,
                             isActive: scenePhase == .active && !model.showsExport)
                    if !typingText { TextCanvasControls(model: model, editContent: { typingText = true }) }
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
                }
            }
            if model.isPreparingTimeline || !model.hasMedia {
                Color.black
                if model.isPreparingTimeline { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { Text("Timeline is empty").font(.subheadline).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            if model.isPickingCurveHue { colorPickingLayer }
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
                if UIDevice.current.userInterfaceIdiom == .pad {
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
            .frame(width: UIDevice.current.userInterfaceIdiom == .pad ? 40 : 44,
                   height: UIDevice.current.userInterfaceIdiom == .pad ? 36 : 44)
        }
        .accessibilityLabel("Add media")
        .disabled(model.isImporting || !warmup.isReady)
    }

    @ViewBuilder private var addMediaActions: some View {
        Button("Sound effects", systemImage: "waveform.badge.plus") {
            model.playback.pause(); soundEffects = true
        }
        Button("Add audio from Files", systemImage: "waveform") { audioPicker = true }
        Button("Add video after selection", systemImage: "film") {
            importImage = false; importOverlay = false; mediaPicker = true
        }
        Button("Add video overlay", systemImage: "square.3.layers.3d") {
            importImage = false; importOverlay = true; mediaPicker = true
        }
        Button("Add image overlay", systemImage: "photo") {
            importImage = true; importOverlay = true; mediaPicker = true
        }
        Button("Add text", systemImage: "textformat") { openTextTool(); model.addText() }
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
    /// tracks that exist, capped so it never crowds out the picture.
    private var automaticTimelineHeight: CGFloat {
        min(audioMode || textMode ? 156 : 230,
            model.project.timeline.tracks.reduce(CGFloat(36)) { $0 + ($1.kind == .text ? 38 : 76) })
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
                    onSelect: { id in
                        model.selectClip(id: id)
                        if id == nil { colorMode = false; maskMode = false }
                    },
                    onSelectMany: { ids in
                        model.selectClips(ids)
                        if model.selectionContainsOnlyText { openTextTool() }
                        else { activate(.timeline) }
                    },
                    onSelectTransition: { id in openTransitionTool(id: id) },
                    onDragSelect: { model.selectClip(id: $0, seek: false) },
                    onOptions: { model.selectClip(id: $0, seek: false); clipOptions = true },
                    onMoveClipToLayer: model.moveClipToLayer,
                    onEdit: model.editTiming,
                    onBeginEdit: model.playback.pause,
                    onBeginSeek: model.playback.beginSeeking,
                    onSeek: { model.seekTimeline(to: $0, finishing: false) },
                    onEndSeek: { model.seekTimeline(to: $0, finishing: true) })
                    .frame(height: height)
                    .allowsHitTesting(!model.isPreparingTimeline)
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

    /// The bar's nine tools, in the order they are drawn.
    ///
    /// The modes themselves are still the eight `@State` booleans the rest of
    /// this view reads. This only gives the bar a single list to draw and a
    /// single place to switch, instead of nine buttons each clearing seven
    /// flags by hand — which is how a tool used to end up half switched.
    private enum EditorMode: String, CaseIterable, Identifiable {
        case timeline, text, audio, color, transform, mask, speed, transition, canvas

        var id: String { rawValue }

        var title: String {
            switch self {
            case .timeline: return String(localized: "Timeline")
            case .text: return String(localized: "Text")
            case .audio: return String(localized: "Audio")
            case .color: return String(localized: "Color")
            case .transform: return String(localized: "Transform")
            case .mask: return String(localized: "Mask")
            case .speed: return String(localized: "Speed")
            case .transition: return String(localized: "Transition")
            case .canvas: return String(localized: "Canvas")
            }
        }

        var symbol: String {
            switch self {
            case .timeline: return "rectangle.split.3x1"
            case .text: return "textformat"
            case .audio: return "waveform"
            case .color: return "camera.filters"
            case .transform: return "crop.rotate"
            case .mask: return "circle.dashed"
            case .speed: return "speedometer"
            case .transition: return "rectangle.2.swap"
            case .canvas: return "aspectratio"
            }
        }

        /// Tools that cannot run until the compositing shaders have been built.
        var needsCompositor: Bool {
            switch self {
            case .text, .audio, .transform, .mask, .transition: return true
            case .timeline, .color, .speed, .canvas: return false
            }
        }
    }

    private var activeMode: EditorMode {
        if textMode { return .text }
        if audioMode { return .audio }
        if colorMode { return .color }
        if transforms { return .transform }
        if maskMode { return .mask }
        if speedTool { return .speed }
        if transitionMode { return .transition }
        if canvasTool { return .canvas }
        return .timeline
    }

    /// Sets all eight flags from one value, so no tool can be left half on.
    private func activate(_ mode: EditorMode) {
        textMode = mode == .text
        audioMode = mode == .audio
        colorMode = mode == .color
        transforms = mode == .transform
        maskMode = mode == .mask
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
            return "Still preparing effects — first run only."
        }
        switch mode {
        case .timeline, .canvas, .text, .audio:
            return nil
        case .color, .transform:
            if model.selectedClip == nil { return "Select a clip in the timeline first." }
            return model.canGrade ? nil : "This clip can’t be graded."
        case .mask:
            if model.selectedClip == nil { return "Select a clip in the timeline first." }
            return model.canEditSelection ? nil : "This clip is locked."
        case .speed:
            return model.canChangeSpeed ? nil : "Select a video clip to change its speed."
        case .transition:
            return model.canUseTransitions ? nil : "Transitions need two clips meeting at the playhead."
        }
    }

    /// Switching order matters: each case keeps the sequence the individual
    /// buttons used, because which side of the switch `flushGradeHistory` falls
    /// on decides how the undo entries either side of it are grouped.
    private func select(_ mode: EditorMode) {
        if let reason = unavailableReason(for: mode) { model.showStatus(reason); return }
        switch mode {
        case .text: openTextTool()
        case .transition: openTransitionTool()
        case .timeline, .color, .speed, .canvas:
            activate(mode); model.flushGradeHistory()
        case .audio:
            activate(mode); model.beginAudioEditing()
        case .transform:
            activate(mode); model.beginTransformEditing()
        case .mask:
            activate(mode); model.beginLayerMaskEditing()
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
                    Button { model.addText() } label: { Label("Add text", systemImage: "plus").font(.caption.weight(.medium)).frame(minHeight: 44) }
                        .disabled(model.isPreparingTimeline)
                }.padding(.horizontal, 20)
                ScrollView {
                    if case .text = model.selectedItem {
                        TextToolPanel(model: model, editContent: { model.selectClip(id: model.selectedClipID); typingText = true },
                                      section: $textSection, appearance: $textAppearance).id(model.selectedClipID)
                            .disabled(!model.canEditSelection)
                    } else {
                        Text("Add a title or select a text clip in the timeline to edit it.")
                            .font(.subheadline).foregroundStyle(AppColors.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    }
                }.scrollIndicators(.visible)
            }
        }
        else if speedTool { SpeedPanel(model: model) }
        else if maskMode { LayerMaskPanel(model: model) }
        else if transforms { LiveTransformPanel(model: model) }
        else if canvasTool { CanvasTools(model: model) }
        else if colorMode && model.canGrade { controls }
        else {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        Button(action: model.pasteClip) { Image(systemName: "doc.on.clipboard").frame(width: 44, height: 44) }
                            .accessibilityLabel("Paste").disabled(model.clipboard == nil)
                        Button(role: .destructive) { model.deleteClip() } label: { Image(systemName: "trash").frame(width: 44, height: 44) }
                            .accessibilityLabel(model.selectedAudio == nil ? "Delete clip and close gaps" : "Delete audio clip").disabled(!model.canEditSelection)
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
                    }, addAudio: { audioPicker = true }, showTracks: { layers = true },
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
        GradingControls(model: model, onSaveGrade: { savingPreset = true })
    }

    private func openTextTool() {
        model.flushGradeHistory()
        activate(.text)
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

    private var textInputDock: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Edit text").font(.caption.weight(.semibold))
                Spacer()
                Button("Done") { typingText = false }.font(.subheadline.weight(.semibold)).frame(minHeight: 44)
            }
            TextEditor(text: Binding(get: { model.selectedText?.text ?? "" }, set: { text in model.editText { $0.text = text } }))
                .focused($textFocused).font(.body).scrollContentBackground(.hidden)
                .frame(height: 84).padding(.horizontal, 6)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("Text content")
        }.padding(.horizontal, 16).padding(.bottom, 8)
            .background(AppColors.background)
    }

    @ViewBuilder private var clipOptionActions: some View {
        if let id = model.selectedClipID, model.project.timeline.videoClip(id: id) != nil {
            Button("Export this clip") {
                model.playback.pause()
                comparePinned = false
                clipExport = SingleClipExport.isolate(clipID: id, in: model.project)
                if clipExport == nil {
                    model.editError = "This clip could not be prepared for export on its own."
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
