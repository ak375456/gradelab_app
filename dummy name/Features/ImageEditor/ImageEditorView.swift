import SwiftUI

/// The still-image workspace: a picture, the Color tab, scopes, and export.
///
/// It is the same interface as the video editor with the parts a photograph does
/// not have taken out, not a different interface that resembles it. The panel
/// strip, the eight tools, the scope panel, the look strip, the preset grid and
/// the compare gesture are literally the same views — `GradingControls`,
/// `ScopePanel`, `GradeActionsMenu` — driven through `GradingModel`.
///
/// What is missing is missing on purpose: no transport, no timeline, no trim,
/// split, speed or audio, and no play button. There is nothing to play.
struct ImageEditorView: View {
    @ObservedObject var model: ImageEditorViewModel
    @ObservedObject private var gradeClipboard = GradeClipboard.shared
    let onBack: (ImageProject) -> Void
    let onSettingsChanged: (ImageProject, Bool) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var help = false
    @State private var comparePinned = false
    @State private var savingPreset = false
    @State private var infoSheet = false
    @State private var confirmsResetAll = false
    @AppStorage("imageEditor.previewHeight") private var storedPreviewHeight: Double = 0
    @AppStorage("imageEditor.inspectorWidth") private var storedInspectorWidth: Double = 0
    @AppStorage("imageEditor.scopeHeight") private var storedScopeHeight: Double = 0
    @GestureState private var holdingOriginal = false

    var body: some View {
        layout
            .background(AppColors.background.ignoresSafeArea())
            .foregroundStyle(AppColors.textPrimary)
            .preferredColorScheme(.dark)
            .buttonStyle(.plain)
            .numericEntryHost()
            .onChange(of: holdingOriginal) { _, value in model.setOriginalVisible(value || comparePinned) }
            .onChange(of: comparePinned) { _, value in model.setOriginalVisible(value || holdingOriginal) }
            .onChange(of: model.project) { _, project in onSettingsChanged(project, false) }
            .animation(.easeInOut(duration: 0.18), value: model.statusMessage)
            .onChange(of: scenePhase) { _, phase in
                model.handleScenePhase(active: phase == .active)
                if phase != .active {
                    comparePinned = false
                    model.setOriginalVisible(false)
                    onSettingsChanged(model.project, true)
                }
            }
            .onDisappear { model.setOriginalVisible(false) }
            .confirmationDialog("Reset all edits?", isPresented: $confirmsResetAll,
                                titleVisibility: .visible) {
                Button("Reset All Edits", role: .destructive) { model.resetAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every colour adjustment on this image goes back to neutral — look, curves, wheels, HSL and effects.")
            }
            .alert("Edit unavailable", isPresented: Binding(
                get: { model.editError != nil }, set: { if !$0 { model.editError = nil } })) {
                Button("OK", role: .cancel) { model.editError = nil }
            } message: { Text(model.editError ?? "") }
            .sheet(isPresented: $savingPreset) { SaveGradePresetSheet(model: model) }
            .sheet(isPresented: $model.showsExport) { ImageExportView(project: model.project) }
            .sheet(isPresented: $infoSheet) { ImageSourceInfoView(project: model.project) }
            .sheet(isPresented: $help) {
                VStack(alignment: .leading, spacing: 24) {
                    Label(model.selectedPanel.rawValue, systemImage: model.selectedPanel.symbol)
                        .font(.title2.weight(.semibold))
                    Text(model.selectedPanel.help).font(.body).foregroundStyle(AppColors.textSecondary)
                    Button("Got it") { help = false }.buttonStyle(.borderedProminent).tint(AppColors.accent)
                }
                .padding(28).presentationDetents([.medium])
                .presentationDragIndicator(.visible).preferredColorScheme(.dark)
            }
    }

    // MARK: - Layout

    private var layout: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                if geometry.size.width > geometry.size.height {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            preview
                            if scopesVisible {
                                WorkspaceDivider(
                                    orientation: .horizontal, label: "Resize the scopes",
                                    onResize: { delta in
                                        setScopeHeight(scopeHeight(geometry.size, regular: true) - delta, in: geometry.size)
                                    },
                                    onBegin: beginWorkspaceResize, onEnd: endWorkspaceResize,
                                    onReset: { storedScopeHeight = 0 })
                                ScopePanel(model: model, isRegularWidth: true,
                                           traceHeight: scopeHeight(geometry.size, regular: true))
                            }
                        }.frame(maxWidth: .infinity)
                        WorkspaceDivider(
                            orientation: .vertical, label: "Resize the tools panel",
                            onResize: { delta in
                                setInspectorWidth(inspectorWidth(geometry.size) - delta, in: geometry.size)
                            },
                            onBegin: beginWorkspaceResize, onEnd: endWorkspaceResize,
                            onReset: { storedInspectorWidth = 0 })
                        VStack(spacing: 0) { inspector; toolBar }
                            .frame(width: inspectorWidth(geometry.size))
                    }
                } else {
                    preview.frame(height: previewHeight(geometry.size))
                    WorkspaceDivider(
                        orientation: .horizontal, label: "Resize the preview",
                        onResize: { delta in setPreviewHeight(previewHeight(geometry.size) + delta, in: geometry.size) },
                        onBegin: beginWorkspaceResize, onEnd: endWorkspaceResize,
                        onReset: { storedPreviewHeight = 0 })
                    if scopesVisible {
                        WorkspaceDivider(
                            orientation: .horizontal, label: "Resize the scopes",
                            onResize: { delta in
                                setScopeHeight(scopeHeight(geometry.size, regular: false) - delta, in: geometry.size)
                            },
                            onBegin: beginWorkspaceResize, onEnd: endWorkspaceResize,
                            onReset: { storedScopeHeight = 0 })
                        ScopePanel(model: model, isRegularWidth: false,
                                   traceHeight: scopeHeight(geometry.size, regular: false))
                    }
                    inspector
                    toolBar
                }
            }
        }
    }

    private var scopesVisible: Bool { model.scopeSettings.isEnabled && !model.isPreparing }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 0) {
            Button { onBack(model.project) } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }.accessibilityLabel("Back")
            Text(model.project.displayName).font(.caption.weight(.medium))
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Button(action: model.undo) { Image(systemName: "arrow.uturn.backward").frame(width: 36, height: 44) }
                .disabled(!model.canUndo).accessibilityLabel("Undo")
            Button(action: model.redo) { Image(systemName: "arrow.uturn.forward").frame(width: 36, height: 44) }
                .disabled(!model.canRedo).accessibilityLabel("Redo")
            Menu {
                Button("Image information", systemImage: "info.circle") { infoSheet = true }
                // Confirmed, like every other action in the app that throws
                // work away. Disabled rather than confirmed-then-ignored when
                // the grade is already neutral, which is what `resetAll` does.
                Button("Reset all edits", systemImage: "arrow.counterclockwise", role: .destructive) {
                    confirmsResetAll = true
                }.disabled(!model.canGrade || model.settings == .neutral)
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                .accessibilityLabel("Options")
            Button { comparePinned = false; model.showsExport = true } label: {
                Text("Export").font(.caption.weight(.semibold)).fixedSize()
                    .frame(width: 68, height: 30)
                    .background(AppColors.accent, in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.black).frame(height: 44)
            }.fixedSize().disabled(model.isPreparing)
        }.padding(.trailing, 12)
    }

    // MARK: - Preview

    private var preview: some View {
        ZStack(alignment: .topLeading) {
            PreviewViewport(inspectionEnabled: !model.isPickingCurveHue && model.selectedPanel != .mask) {
                ZStack {
                    MetalPreviewView(
                        renderer: model.renderer, settings: model.settings,
                        showsOriginal: model.showsOriginal, isPlaying: false,
                        redrawTime: 0, frameUpdateID: 0,
                        isActive: scenePhase == .active && !model.showsExport)
                    if model.selectedPanel == .mask && !model.showsOriginal {
                        GradeMaskOverlay(model: model, displayedRect: model.renderer.displayedVideoRect)
                    }
                }
            }
            if model.isPreparing {
                Color.black
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if model.isPickingCurveHue { colorPickingLayer }
            if model.showsOriginal {
                Text("ORIGINAL").font(.caption2.weight(.semibold)).tracking(1.5)
                    .padding(10).background(.black.opacity(0.65), in: Capsule()).padding(14)
                    .allowsHitTesting(false)
            }
            VStack { HStack { Spacer(); scopesButton }; Spacer() }.padding(14)
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    // Label stays put — the ORIGINAL badge above states the
                    // state, and this pill sits under the thumb holding it.
                    Text("Hold to compare")
                        .font(.caption2).foregroundStyle(.white.opacity(model.showsOriginal ? 0.35 : 0.8))
                        .padding(8).background(.black.opacity(model.showsOriginal ? 0.2 : 0.4), in: Capsule())
                        .contentShape(Capsule())
                        .animation(.easeOut(duration: 0.12), value: model.showsOriginal)
                        .gesture(DragGesture(minimumDistance: 0)
                            .updating($holdingOriginal) { _, held, _ in held = true })
                }
            }.padding(12).accessibilityHidden(true)
            if let status = model.statusMessage {
                VStack {
                    Spacer()
                    Text(status).font(.caption.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.7), in: Capsule())
                        .foregroundStyle(AppColors.textPrimary)
                    Spacer()
                }
                .transition(.opacity).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .background(.black).frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityLabel("Image preview")
        .accessibilityAction(named: comparePinned ? "Show edited" : "Show original") { comparePinned.toggle() }
    }

    private var scopesButton: some View {
        Button { model.setScopesEnabled(!model.scopeSettings.isEnabled) } label: {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.black.opacity(0.65), in: Capsule())
                .foregroundStyle(model.scopeSettings.isEnabled ? AppColors.accent : AppColors.textSecondary)
        }
        .accessibilityLabel(model.scopeSettings.isEnabled ? "Hide scopes" : "Show scopes")
        .accessibilityAddTraits(model.scopeSettings.isEnabled ? .isSelected : [])
    }

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
                    .padding(.horizontal, AppSpacing.compact).padding(.vertical, AppSpacing.small)
                    .background(.black.opacity(0.7), in: Capsule())
                    .padding(.bottom, 44)
                }
        }
        .accessibilityLabel("Tap the picture to pick a colour")
    }

    // MARK: - Tools

    private var inspector: some View {
        GradingControls(model: model, onSaveGrade: { savingPreset = true })
    }

    private var toolBar: some View {
        HStack(spacing: 8) {
            Text("Color").font(.caption.weight(.medium)).foregroundStyle(AppColors.accent)
                .frame(minHeight: 44)
            Spacer()
            Button { help = true } label: {
                Image(systemName: "questionmark.circle").frame(width: 44, height: 44)
            }.accessibilityLabel("How to use \(model.selectedPanel.rawValue)")
            GradeActionsMenu(model: model, onSaveGrade: { savingPreset = true })
            Button { comparePinned.toggle() } label: {
                Image(systemName: "square.on.square").frame(width: 44, height: 44)
                    .foregroundStyle(comparePinned ? AppColors.accent : AppColors.textSecondary)
            }
            .accessibilityLabel(comparePinned ? "Show edited image" : "Compare with original")
            .accessibilityValue(comparePinned ? "Original" : "Edited")
            Button("Reset", action: model.resetPanel).font(.caption).frame(minWidth: 44, minHeight: 44)
        }
        .frame(height: 44).padding(.horizontal, 12)
    }

    // MARK: - Workspace sizing

    private func inspectorWidth(_ size: CGSize) -> CGFloat {
        let automatic = min(360, size.width * 0.46)
        return clampedInspectorWidth(storedInspectorWidth > 0 ? CGFloat(storedInspectorWidth) : automatic, in: size)
    }

    private func clampedInspectorWidth(_ value: CGFloat, in size: CGSize) -> CGFloat {
        let lower = min(260, size.width * 0.34)
        return min(max(value, lower), max(lower, min(620, size.width * 0.6)))
    }

    private func setInspectorWidth(_ value: CGFloat, in size: CGSize) {
        storedInspectorWidth = Double(clampedInspectorWidth(value, in: size))
    }

    private func previewHeight(_ size: CGSize) -> CGFloat {
        let automatic = size.height * (scopesVisible ? 0.34 : 0.48)
        return clampedPreviewHeight(storedPreviewHeight > 0 ? CGFloat(storedPreviewHeight) : automatic, in: size)
    }

    private func clampedPreviewHeight(_ value: CGFloat, in size: CGSize) -> CGFloat {
        let lower: CGFloat = 140
        return min(max(value, lower), max(lower, size.height * 0.72))
    }

    private func setPreviewHeight(_ value: CGFloat, in size: CGSize) {
        storedPreviewHeight = Double(clampedPreviewHeight(value, in: size))
    }

    private func scopeHeight(_ size: CGSize, regular: Bool) -> CGFloat {
        let automatic = ScopeLayout.automaticTraceHeight(isRegularWidth: regular)
        return clampedScopeHeight(storedScopeHeight > 0 ? CGFloat(storedScopeHeight) : automatic, in: size)
    }

    private func clampedScopeHeight(_ value: CGFloat, in size: CGSize) -> CGFloat {
        let lower: CGFloat = 90
        return min(max(value, lower), max(lower, size.height * 0.5))
    }

    private func setScopeHeight(_ value: CGFloat, in size: CGSize) {
        storedScopeHeight = Double(clampedScopeHeight(value, in: size))
    }

    /// A divider drag changes the drawable every frame; the renderer stands the
    /// spatial effects down for the length of it rather than reallocating.
    private func beginWorkspaceResize() { model.renderer.setInteractiveResize(true) }
    private func endWorkspaceResize() { model.renderer.setInteractiveResize(false) }
}
