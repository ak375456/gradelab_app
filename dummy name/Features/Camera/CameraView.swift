#if !targetEnvironment(macCatalyst)
import AVFoundation
import SwiftUI
import UIKit

struct CameraView: View {
    let onClose: () -> Void
    let onRecording: (CameraRecording) -> Void
    @StateObject private var model: CameraViewModel
    @State private var recordingToEdit: CameraRecording?
    @State private var presentedRecording: CameraRecording?
    @Environment(\.scenePhase) private var scenePhase

    @MainActor init(model: CameraViewModel? = nil, onClose: @escaping () -> Void,
         onRecording: @escaping (CameraRecording) -> Void) {
        _model = StateObject(wrappedValue: model ?? CameraViewModel())
        self.onClose = onClose
        self.onRecording = onRecording
    }

    var body: some View {
        CameraWorkspace(model: model, onClose: onClose)
            .task {
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                if let orientation = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.interfaceOrientation {
                    switch orientation {
                    case .landscapeRight: model.updateOrientation(.landscapeLeft)
                    case .landscapeLeft: model.updateOrientation(.landscapeRight)
                    case .portraitUpsideDown: model.updateOrientation(.portraitUpsideDown)
                    default: model.updateOrientation(.portrait)
                    }
                }
                model.updateOrientation(UIDevice.current.orientation)
                await model.start()
            }
            .onDisappear {
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
                model.stop()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                model.updateOrientation(UIDevice.current.orientation)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { model.suspend() }
                else if phase == .active { Task { await model.start() } }
            }
            .onChange(of: model.completedRecording) { _, recording in presentedRecording = recording }
            .sheet(item: $presentedRecording, onDismiss: {
                #if DEBUG
                print("Camera destination dismissed: scene=\(scenePhase), app=\(UIApplication.shared.applicationState.rawValue)")
                #endif
                model.dismissRecordingChoice()
                if let recording = recordingToEdit {
                    recordingToEdit = nil
                    onRecording(recording)
                } else if UIApplication.shared.applicationState == .active { Task { await model.start() } }
            }) { recording in
                CameraRecordingChoice(model: model, recording: recording, onEdit: {
                    recordingToEdit = recording
                    presentedRecording = nil
                }, onContinue: { presentedRecording = nil })
            }
            .keepsScreenAwake(model.phase == .ready || model.isRecording)
    }
}

/// The workspace is independent of permission/session startup so compact and
/// wide layouts can be exercised without asking a test runner for a camera.
struct CameraWorkspace: View {
    @ObservedObject var model: CameraViewModel
    @ObservedObject private var store = ProStore.shared
    let onClose: () -> Void
    @AppStorage("camera.proControls") private var proControls = false
    @AppStorage("camera.rulerSounds") private var rulerSounds = false
    @State private var tool: CameraTool = .looks
    @State private var lookSearch = ""
    @State private var showsPanel = false
    @State private var focusIndicator: CGPoint?
    @State private var scopeExpanded = false
    @State private var showsFormat = false
    @State private var pinchStart: Double?
    @Environment(\.dynamicTypeSize) private var typeSize

    init(model: CameraViewModel, onClose: @escaping () -> Void, initialTool: CameraTool = .looks,
         initiallyExpanded: Bool = false, scopeInitiallyExpanded: Bool = false) {
        self.model = model
        self.onClose = onClose
        _tool = State(initialValue: initialTool)
        _showsPanel = State(initialValue: initiallyExpanded)
        _scopeExpanded = State(initialValue: scopeInitiallyExpanded)
    }

    var body: some View {
        GeometryReader { geometry in
            let columns = geometry.size.width > geometry.size.height && geometry.size.width >= 650
            if model.interfaceHidden {
                preview.ignoresSafeArea()
                    .overlay(alignment: .topTrailing) {
                        interfaceToggle.padding(.trailing, 12).padding(.top, 6)
                    }
            } else {
                VStack(spacing: 0) {
                    header
                    AppDivider()
                    if columns {
                        HStack(spacing: 0) {
                            VStack(spacing: 0) { status; preview }
                            AppDivider().rotationEffect(.degrees(90)).frame(width: 1)
                            VStack(spacing: 0) {
                                toolSelector(isExpanded: true, collapsible: false)
                                ScrollView { panel.padding(AppSpacing.standard) }
                                recordBar
                            }
                            .frame(width: typeSize.isAccessibilitySize ? 340 : 290)
                            .background(AppColors.surface)
                        }
                    } else {
                        status
                        preview
                        toolSelector(isExpanded: showsPanel, collapsible: true)
                        if showsPanel {
                            ScrollView { panel.padding(.horizontal, AppSpacing.standard).padding(.vertical, AppSpacing.compact) }
                                .frame(height: min(typeSize.isAccessibilitySize ? 250 : 170, geometry.size.height * 0.28))
                                .background(AppColors.surface)
                        }
                        recordBar
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AppColors.editorBackground.ignoresSafeArea())
        .foregroundStyle(AppColors.textPrimary)
        .preferredColorScheme(.dark)
        .statusBarHidden(model.interfaceHidden)
        .onChange(of: model.assist) { _, _ in model.refreshPreview() }
        .onChange(of: model.grade) { _, _ in model.refreshPreview() }
        .onChange(of: model.scopeSettings) { _, _ in model.refreshScopes() }
        .onChange(of: showsPanel) { _, shown in if shown { scopeExpanded = false } }
        .onChange(of: model.notice) { _, notice in
            if notice != nil {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    if model.notice == notice { model.notice = nil }
                }
            }
        }
        .onChange(of: model.isRecording) { _, recording in if recording { showsPanel = false } }
        .onChange(of: model.canZoom) { _, allowed in if !allowed { pinchStart = nil; model.endZoomGesture() } }
        .onChange(of: proControls) { _, enabled in if !enabled && tool.isManual { tool = .looks; showsPanel = false } }
        .sheet(isPresented: $showsFormat) { CameraFormatSheet(model: model) }
        .paywallSheet($model.paywallFeature)
        .onChange(of: store.hasPro) { _, entitled in
            if entitled { model.paywallFeature = nil }
        }
        .alert("Camera", isPresented: Binding(get: { model.message != nil && model.completedRecording == nil && model.phase != .unavailable },
                                             set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) { model.message = nil }
        } message: { Text(model.message ?? "") }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 16, weight: .medium))
                    .frame(width: 44, height: 44).cameraGlass(radius: 14)
            }.accessibilityLabel("Close camera").disabled(!model.canClose)
            VStack(alignment: .leading, spacing: 4) {
                Text("Camera").font(AppTypography.headline).lineLimit(1).minimumScaleFactor(0.65)
                if model.isRecording { recordingTime }
                else {
                    Text(model.configuration?.selected.profile == .appleLog ? String(localized: "APPLE LOG · EDITABLE") : String(localized: "ORIGINAL · EDITABLE"))
                        .font(.system(size: 8, weight: .semibold)).tracking(0.9)
                        .foregroundStyle(AppColors.textTertiary).lineLimit(1).minimumScaleFactor(0.6)
                }
            }
            Spacer(minLength: 4)
            CameraModePicker(pro: $proControls)
            interfaceToggle
        }
        .buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 6)
        .reservedRegionHeader()
    }

    private var interfaceToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { model.toggleInterface() }
        } label: {
            Image(systemName: model.interfaceHidden ? "eye" : "eye.slash")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AppColors.textSecondary)
                .frame(width: 44, height: 44).cameraGlass(radius: 22)
                .overlay(alignment: .bottomLeading) {
                    if model.interfaceHidden && model.isRecording {
                        Circle().fill(.red).frame(width: 6, height: 6).padding(5)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(!model.interfaceHidden && model.renderer == nil)
        .accessibilityLabel(model.interfaceHidden ? String(localized: "Show camera controls") : String(localized: "Hide camera controls"))
        .accessibilityHint(model.interfaceHidden ? String(localized: "Restores settings, guides and recording controls") : String(localized: "Shows a clean preview while keeping your camera settings"))
        .accessibilityValue(model.interfaceHidden && model.isRecording ? String(localized: "Recording") : "")
    }

    private var status: some View {
        HStack(spacing: 8) {
            lensMenu
            Spacer(minLength: 0)
            Button { showsFormat = true } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.configuration?.selected.title ?? "1080p · 30 fps")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        Text("\(model.configuration?.codec.title ?? "HEVC") · \(model.configuration?.selected.profile.badge ?? "SDR")")
                            .font(.system(size: 8, weight: .medium)).foregroundStyle(AppColors.textSecondary)
                    }.lineLimit(1).minimumScaleFactor(0.65)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }.padding(.horizontal, 12).frame(minHeight: 44).cameraGlass()
            }
            .disabled(model.configuration == nil || model.isRecording)
            .accessibilityLabel("Recording format, \(model.configuration?.selected.title ?? String(localized: "Preparing"))")
            .accessibilityHint("Opens resolution, frame rate, color profile and codec")
            if model.telemetry.isHot { CameraHeatIndicator() }
        }
        .buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 6)
    }

    private var lensMenu: some View {
        Menu {
            ForEach(model.configuration?.lenses ?? []) { lens in
                Button { model.reconfigure(lensID: lens.id) } label: {
                    Label(lens.name, systemImage: lens.isFront ? "person.crop.rectangle" : "camera")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(CameraGeometry.zoomLabel(model.displayedZoom)).monospacedDigit().foregroundStyle(AppColors.accent)
                Text(model.currentLens?.name ?? String(localized: "Main")).lineLimit(1).minimumScaleFactor(0.7)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }.font(.system(size: 11, weight: .medium)).padding(.horizontal, 10)
                .frame(minHeight: 44).cameraGlass()
        }
        .disabled(!model.canConfigure).accessibilityLabel("Choose camera lens")
    }

    @ViewBuilder private var recordingTime: some View {
        if model.isRecording {
            HStack(spacing: 5) {
                Circle().fill(.red).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(Duration.seconds(model.telemetry.elapsed).formatted(.time(pattern: .minuteSecond)))
                    .monospacedDigit().foregroundStyle(.red)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Recording elapsed time")
            .accessibilityValue(Duration.seconds(model.telemetry.elapsed).formatted(.time(pattern: .minuteSecond)))
        }
    }

    private var preview: some View {
        GeometryReader { geometry in
            let rect = CameraGeometry.fittedRect(image: model.previewSize, in: geometry.size)
            ZStack {
                Color.black
                if let renderer = model.renderer {
                    MetalPreviewView(renderer: renderer, settings: model.grade, showsOriginal: false,
                        isPlaying: true, redrawTime: 0, frameUpdateID: 0,
                        isActive: model.phase == .ready || model.isRecording)
                        .accessibilityLabel("Live camera preview. Tap to focus and meter exposure.")
                    if !model.interfaceHidden { CameraGuidesOverlay(settings: model.guides, image: rect) }
                    if model.guides.level, !model.interfaceHidden, rect.height > 150 {
                        CameraHorizonView(monitor: model.level)
                            .scaleEffect(min(1, rect.width / 144))
                            .position(x: rect.midX, y: rect.midY)
                    }
                    if let focusIndicator, !model.interfaceHidden {
                        RoundedRectangle(cornerRadius: 5).stroke(AppColors.accent, lineWidth: 1.5)
                            .frame(width: 54, height: 54).position(focusIndicator).allowsHitTesting(false)
                    }
                }
                if model.phase == .denied || model.phase == .unavailable || model.phase == .interrupted {
                    unavailable
                } else if model.renderer == nil {
                    VStack(spacing: 12) {
                        ProgressView().tint(.white)
                        Text(model.phase == .authorizing ? String(localized: "Preparing camera access…") : String(localized: "Starting camera…"))
                            .font(AppTypography.caption).foregroundStyle(AppColors.textSecondary)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard rect.contains(location), !model.controls.manualFocus, model.renderer != nil else { return }
                model.focus(at: location, bounds: geometry.size)
                focusIndicator = location
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    if focusIndicator == location { focusIndicator = nil }
                }
            }
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                guard model.canZoom, model.renderer != nil else { return }
                if pinchStart == nil { pinchStart = model.zoomFactor }
                model.setZoom((pinchStart ?? 1) * value.magnification, gesture: true)
            }.onEnded { _ in pinchStart = nil; model.endZoomGesture() })
            .overlay(alignment: .top) {
                if model.configuration != nil, !model.interfaceHidden {
                    VStack(spacing: 6) {
                        CameraLiveDashboard(model: model, pro: proControls, selected: showsPanel && tool.isManual ? tool : nil) { selected in
                            withAnimation(.easeInOut(duration: 0.18)) {
                                proControls = true; tool = selected; showsPanel = true
                            }
                        }
                        if model.assist.mode != .off {
                            Text("\(model.assist.mode.title) · displayed image")
                                .font(.system(size: 9)).foregroundStyle(.white.opacity(0.8))
                                .padding(6).cameraGlass(radius: 8).allowsHitTesting(false)
                        }
                    }.padding(8)
                }
            }
            .overlay(alignment: geometry.size.height > 320 ? .trailing : .bottomTrailing) {
                if model.renderer != nil, !scopeExpanded, !model.interfaceHidden {
                    CameraZoomControls(model: model, vertical: geometry.size.height > 320).padding(8)
                }
            }
            .overlay(alignment: .topLeading) {
                if model.scopeSettings.isEnabled, model.renderer != nil, !model.interfaceHidden, geometry.size.height > 150,
                   model.phase == .ready || model.isRecording {
                    let frame = CameraScopeLayout.frame(in: rect, viewport: geometry.size, expanded: scopeExpanded, topInset: 74)
                    CameraScopesView(model: model, expanded: scopeExpanded, showsIntensity: frame.height >= 170) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            scopeExpanded.toggle()
                            if scopeExpanded { showsPanel = false }
                        }
                    }
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                }
            }
            .overlay(alignment: .top) {
                if let notice = model.notice, !model.interfaceHidden {
                    Label(notice, systemImage: "checkmark.circle.fill")
                        .font(AppTypography.callout).padding(12)
                        .background(AppColors.surfaceRaised, in: Capsule()).padding(8)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var unavailable: some View {
        VStack(spacing: 12) {
            Image(systemName: model.phase == .denied ? "camera.fill" : "camera.badge.ellipsis").font(.title)
            Text(model.phase == .denied ? String(localized: "Camera access") : String(localized: "Camera paused")).font(AppTypography.headline)
            Text(model.phase == .denied ? model.permissionMessage : model.message ?? String(localized: "The camera was interrupted. Resume when you’re ready."))
                .font(AppTypography.caption).foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if model.phase == .denied {
                AppButton("Open Settings", systemImage: "gearshape") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            } else {
                AppButton("Resume Camera", systemImage: "arrow.clockwise") { Task { await model.start() } }
            }
        }.padding(24).frame(maxWidth: 380)
    }

    private func toolSelector(isExpanded: Bool, collapsible: Bool) -> some View {
        let showsSoundControl = isExpanded && tool.isManual
        return HStack(spacing: 8) {
            ForEach([CameraTool.looks, .assist]) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if tool == item && collapsible { showsPanel.toggle() }
                        else { tool = item; showsPanel = true }
                    }
                } label: {
                    Label(item.title, systemImage: item.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .foregroundStyle(tool == item && isExpanded ? AppColors.accent : AppColors.textSecondary)
                        .padding(.horizontal, showsSoundControl ? 8 : 12).frame(minWidth: 44, minHeight: 44)
                        .background(tool == item && isExpanded ? AppColors.accentMuted : .clear, in: Capsule())
                }.accessibilityAddTraits(tool == item && isExpanded ? .isSelected : [])
            }
            Spacer(minLength: 0)
            if showsSoundControl {
                Button { rulerSounds.toggle() } label: {
                    Image(systemName: rulerSounds ? "speaker.wave.1" : "speaker.slash")
                        .foregroundStyle(rulerSounds ? AppColors.accent : AppColors.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Sound effects")
                .accessibilityValue(rulerSounds ? String(localized: "On") : String(localized: "Off"))
            }
            if isExpanded && collapsible {
                Button { withAnimation(.easeInOut(duration: 0.18)) { showsPanel = false } } label: {
                    Image(systemName: "chevron.down").frame(width: 44, height: 44)
                }.accessibilityLabel("Collapse camera controls")
            }
        }
        .buttonStyle(.plain).padding(.horizontal, 8).padding(.vertical, 2)
        .background(AppColors.background)
    }

    @ViewBuilder private var panel: some View {
        switch tool {
        case .looks: looksPanel
        case .exposure: exposurePanel
        case .whiteBalance: whiteBalancePanel
        case .focus: focusPanel
        case .assist: assistPanel
        }
    }

    private var looksPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search looks", text: $lookSearch)
                .textFieldStyle(.plain).font(AppTypography.callout)
                .padding(10).background(AppColors.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Search camera looks").disabled(model.isRecording)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    lookButton(name: String(localized: "Original"), selected: model.currentLook == nil, premium: false) { model.selectLook(nil) }
                    ForEach(model.looks.filter { lookSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(lookSearch) }) { look in
                        lookButton(name: look.name, selected: model.currentLook?.id == look.id,
                                   premium: ProAccessPolicy.requiresPro(look)) { model.selectLook(look) }
                    }
                }
            }.scrollIndicators(.hidden).disabled(!model.canConfigure)
            ForEach([GradeParameter.saturation, .vibrance]) { parameter in
                cameraSlider(parameter.title, value: Binding(get: {
                    Double(model.grade[keyPath: parameter.keyPath])
                }, set: { model.setCreativeColor(parameter, value: Float($0)) }), range: -100...100,
                    label: parameter.formatted(model.grade[keyPath: parameter.keyPath]))
            }.disabled(!model.canConfigure)
            HStack {
                Text("Color stays editable").font(AppTypography.caption).foregroundStyle(AppColors.textSecondary)
                Spacer()
                Button("Reset color") {
                    model.setCreativeColor(.saturation, value: 0)
                    model.setCreativeColor(.vibrance, value: 0)
                }.font(AppTypography.caption).frame(minHeight: 44)
                    .disabled(!model.canConfigure || (model.grade.saturation == 0 && model.grade.vibrance == 0))
            }
            Text("The original is recorded. Your look stays editable in GradeLab. Pro looks require Pro at export.")
                .font(.caption2).foregroundStyle(AppColors.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func lookButton(name: String, selected: Bool, premium: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: selected ? "checkmark.circle.fill" : "camera.filters")
                    .font(.system(size: 18)).foregroundStyle(selected ? AppColors.accent : AppColors.textSecondary)
                Text(name).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                if premium { Text("PRO").font(.system(size: 8, weight: .bold)).foregroundStyle(ProStyle.gold) }
            }
            .frame(width: 100, height: 66)
            .background(selected ? AppColors.accentMuted : AppColors.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? AppColors.accent : AppColors.border, lineWidth: 1))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var exposurePanel: some View {
        VStack(spacing: 12) {
            controlMode("Exposure", manual: Binding(get: { model.controls.manualExposure }, set: model.setManualExposure))
                .disabled(model.configuration?.limits.supportsExposure != true)
            if model.controls.manualExposure, let limits = model.configuration?.limits, let fps = model.configuration?.selected.fps {
                let shutterRange = limits.shutterRange(fps: fps)
                cameraRuler("ISO", value: control(\.iso), scale: .iso(limits.iso)) { "\(Int($0.rounded()))" }
                HStack {
                    Text("Shutter").font(AppTypography.headline)
                    Spacer(minLength: 8)
                    Picker("Shutter unit", selection: Binding(get: { model.shutterUnit }, set: model.setShutterUnit)) {
                        ForEach(CameraShutterUnit.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).frame(width: 150)
                }.frame(minHeight: 44)
                if model.shutterUnit == .angle {
                    let degreesPerSecond = Double(fps) * 360
                    let angleRange = (shutterRange.lowerBound * degreesPerSecond)...(shutterRange.upperBound * degreesPerSecond)
                    cameraRuler("Shutter angle", value: Binding(get: {
                        CameraGeometry.shutterAngle(model.controls.shutterSeconds, fps: fps)
                    }, set: model.setShutterAngle),
                        scale: .init(range: angleRange, step: 5, labelEvery: 6)) { angle in
                        let seconds = angle / degreesPerSecond
                        return "\(CameraGeometry.angleLabel(seconds, fps: fps)) · \(CameraGeometry.shutterLabel(seconds))"
                    }
                } else {
                    cameraRuler("Shutter speed", value: Binding(get: { model.controls.shutterSeconds }, set: model.setShutterSpeed),
                                scale: .shutter(shutterRange, fps: fps), format: CameraGeometry.shutterLabel)
                }
                HStack(spacing: 8) {
                    ForEach([90, 180, 360], id: \.self) { angle in
                        Button { model.setShutterAngle(Double(angle)) } label: {
                            Text("\(angle)°").frame(maxWidth: .infinity, minHeight: 44)
                                .cameraGlass(radius: 10)
                        }.buttonStyle(.plain).accessibilityLabel("Set \(angle) degree shutter")
                    }
                }.font(AppTypography.caption)
            } else {
                cameraRuler("Exposure", value: control(\.exposureBias),
                            scale: .init(range: model.configuration?.limits.bias ?? -2...2, step: 0.1, labelEvery: 5)) {
                    String(format: "%+.1f EV", $0)
                }
                Text("ISO \(Int(model.telemetry.iso)) · \(CameraGeometry.shutterLabel(model.telemetry.shutter))")
                    .font(AppTypography.caption).foregroundStyle(AppColors.textSecondary)
            }
            Menu {
                ForEach(CameraFlicker.allCases) { flicker in
                    Button { model.setFlicker(flicker) } label: {
                        if model.controls.flicker == flicker { Label(flicker.title, systemImage: "checkmark") }
                        else { Text(flicker.title) }
                    }
                    .disabled(flicker != .off && flicker.duration(fps: model.configuration?.selected.fps ?? 30,
                        range: model.configuration?.limits.shutterRange(fps: model.configuration?.selected.fps ?? 30) ?? (1.0 / 8000)...(1.0 / 30)) == nil)
                }
            } label: { guideMenuLabel("Flicker reduction", value: model.controls.flicker.title, symbol: "lightbulb") }
                .buttonStyle(.plain)
                .disabled(model.configuration?.limits.supportsExposure != true)
            Text(model.controls.flicker == .off
                 ? String(localized: "Angle follows frame rate. Flicker presets lock exposure to whole lighting cycles.")
                 : String(localized: "\(model.controls.flicker.title) · \(CameraGeometry.shutterLabel(model.controls.shutterSeconds)). ISO is manual. Some LEDs may still flicker."))
                .font(.caption2).foregroundStyle(AppColors.textTertiary).fixedSize(horizontal: false, vertical: true)
        }.font(AppTypography.callout).tint(AppColors.accent)
            .disabled(model.phase != .ready && model.phase != .recording)
    }

    private var whiteBalancePanel: some View {
        VStack(spacing: 12) {
            controlMode("White balance", manual: Binding(get: { model.controls.manualWhiteBalance }, set: model.setManualWhiteBalance))
                .disabled(model.configuration?.limits.supportsWhiteBalance != true)
            Group {
                cameraRuler("Temperature", value: control(\.temperature) {
                    model.controls.manualWhiteBalance ? nil : model.telemetry.temperature
                }, scale: .init(range: 2500...10000, step: 100, labelEvery: 5)) { "\(Int($0.rounded())) K" }
                cameraRuler("Tint", value: control(\.tint) {
                    model.controls.manualWhiteBalance ? nil : model.telemetry.tint
                }, scale: .init(range: -100...100, step: 1, labelEvery: 5)) { String(format: "%+.0f", $0) }
            }
            .disabled(model.configuration?.limits.supportsWhiteBalance != true)
            Text("Lock to keep color consistent throughout a take.").font(.caption2).foregroundStyle(AppColors.textTertiary)
        }.font(AppTypography.callout).tint(AppColors.accent)
            .disabled(model.phase != .ready && model.phase != .recording)
    }

    private var focusPanel: some View {
        VStack(spacing: 12) {
            controlMode("Focus", manual: Binding(get: { model.controls.manualFocus }, set: model.setManualFocus))
                .disabled(model.configuration?.limits.supportsFocus != true)
            cameraRuler("Near → Far", value: control(\.focus) {
                model.controls.manualFocus ? nil : model.telemetry.focus
            }, scale: .init(range: 0...1, step: 0.01, labelEvery: 5)) { String(format: "%.0f%%", $0 * 100) }
                .disabled(!model.controls.manualFocus)
            CameraPeakingControls(assist: $model.assist)
            Text(model.configuration?.limits.supportsFocus == false
                 ? String(localized: "This lens has fixed focus.")
                 : String(localized: "Tap the picture to focus automatically, or lock focus and adjust it here."))
                .font(.caption2).foregroundStyle(AppColors.textTertiary)
        }.font(AppTypography.callout).tint(AppColors.accent)
            .disabled(model.phase != .ready && model.phase != .recording)
    }

    private var assistPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Composition guides").font(AppTypography.headline)
            Menu {
                Picker("Grid", selection: $model.guides.grid) {
                    ForEach(CameraGrid.allCases) { grid in Text(grid.title).tag(grid) }
                }
            } label: { guideMenuLabel("Grid", value: model.guides.grid.title, symbol: "grid") }
            Menu {
                Picker("Frame", selection: $model.guides.frame) {
                    ForEach(CameraFrameGuide.allCases) { frame in Text(frame.title).tag(frame) }
                }
            } label: { guideMenuLabel("Frame", value: model.guides.frame.title, symbol: "aspectratio") }
            Toggle("Center crosshair", isOn: $model.guides.center)
            Toggle("90% safe area", isOn: $model.guides.safeArea)
            Toggle("Horizon level", isOn: $model.guides.level).disabled(!model.level.isAvailable)
            if !model.level.isAvailable {
                Text("Motion sensing is unavailable on this device.").font(.caption2).foregroundStyle(AppColors.textTertiary)
            }
            AppDivider()
            Text("Exposure & monitoring").font(AppTypography.headline)
            Picker("Exposure aid", selection: $model.assist.mode) {
                ForEach(ViewerAssist.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            if model.assist.mode == .zebras {
                cameraSlider("Zebra threshold", value: $model.assist.zebraThreshold, range: 50...100,
                             label: "\(Int(model.assist.zebraThreshold))%")
            }
            Toggle("Live scope", isOn: $model.scopeSettings.isEnabled)
            CameraPeakingControls(assist: $model.assist)
            Text("Guides help you compose. They never crop the recording. Exposure aids measure the displayed look.")
                .font(.caption2).foregroundStyle(AppColors.textTertiary).fixedSize(horizontal: false, vertical: true)
        }.font(AppTypography.callout).tint(AppColors.accent).buttonStyle(.plain)
    }

    private func guideMenuLabel(_ title: LocalizedStringKey, value: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: symbol)
            Spacer(minLength: 0)
            Text(value).foregroundStyle(AppColors.accent)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
        }.font(AppTypography.callout).padding(.horizontal, 12).frame(minHeight: 44).cameraGlass(radius: 10)
    }

    private func controlMode(_ title: LocalizedStringKey, manual: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Text(title).font(AppTypography.headline)
            Spacer(minLength: 0)
            Picker(title, selection: manual) {
                Text("Auto").tag(false)
                Text("Manual").tag(true)
            }.pickerStyle(.segmented).frame(width: 150)
        }.frame(minHeight: 44)
    }

    private func control(_ keyPath: WritableKeyPath<CameraControls, Double>, autoValue: @escaping () -> Double? = { nil }) -> Binding<Double> {
        Binding(get: { autoValue() ?? model.controls[keyPath: keyPath] }, set: {
            var controls = model.controls
            if !controls.manualWhiteBalance && (keyPath == \.temperature || keyPath == \.tint) {
                controls.temperature = model.telemetry.temperature
                controls.tint = model.telemetry.tint
                controls.manualWhiteBalance = true
            }
            controls[keyPath: keyPath] = $0
            model.controls = controls
            model.applyControls()
        })
    }

    private func cameraRuler(_ title: LocalizedStringKey, value: Binding<Double>, scale: CameraRulerScale,
                             format: @escaping (Double) -> String) -> some View {
        CameraRulerPicker(title: title, value: value, scale: scale,
                          feedbackEnabled: model.phase == .ready && !model.checkingRecordingAccess,
                          soundsEnabled: rulerSounds, format: format)
    }

    private func cameraSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, label: String) -> some View {
        VStack(spacing: 2) {
            HStack { Text(LocalizedStringKey(title)); Spacer(); Text(label).monospacedDigit().foregroundStyle(AppColors.textSecondary) }
                .font(AppTypography.caption)
            Slider(value: value, in: range).frame(minHeight: 44).accessibilityLabel(Text(LocalizedStringKey(title))).accessibilityValue(label)
        }
    }

    private var recordBar: some View {
        VStack(spacing: 5) {
            HStack(spacing: 12) {
                CameraAudioMeter(levels: model.telemetry.audioDB, hasAudio: model.configuration?.hasAudio == true,
                                 microphone: model.telemetry.microphone, onEnableAudio: {
                        if model.configuration?.hasAudio == false,
                           let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    })
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { Task { await model.toggleRecording() } } label: {
                    ZStack {
                        Circle().stroke(.white.opacity(0.9), lineWidth: 3).frame(width: 66, height: 66)
                        if model.phase == .starting || model.phase == .finishing || model.checkingRecordingAccess { ProgressView().tint(.white) }
                        else {
                            RoundedRectangle(cornerRadius: model.phase == .recording ? 5 : 28)
                                .fill(.red).frame(width: model.phase == .recording ? 26 : 54, height: model.phase == .recording ? 26 : 54)
                        }
                    }.frame(width: 76, height: 76).contentShape(Circle())
                }
                .overlay(alignment: .bottom) {
                    if !store.hasPro && !model.isRecording { ProBadge(compact: true).offset(y: 2) }
                }
                .buttonStyle(.plain).disabled((!model.canRecord && model.phase != .recording) || model.checkingRecordingAccess)
                .accessibilityLabel(model.phase == .recording ? String(localized: "Stop recording") : store.hasPro ? String(localized: "Start recording") : String(localized: "Unlock camera recording with Pro"))
                CameraStorageIndicator(estimate: model.recordingEstimate, freeBytes: model.telemetry.freeBytes)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if model.phase == .finishing {
                Text("Saving original…").font(.caption2).foregroundStyle(AppColors.textTertiary)
            }
        }
        .padding(.horizontal, AppSpacing.standard).padding(.vertical, AppSpacing.small)
        .background(AppColors.background)
    }
}

enum CameraTool: String, CaseIterable, Identifiable {
    case looks, exposure, whiteBalance, focus, assist
    var id: String { rawValue }
    var isManual: Bool { self == .exposure || self == .whiteBalance || self == .focus }
    var title: String {
        switch self {
        case .looks: String(localized: "Looks")
        case .exposure: String(localized: "Exposure")
        case .whiteBalance: String(localized: "WB")
        case .focus: String(localized: "Focus")
        case .assist: String(localized: "Guides")
        }
    }
    var symbol: String {
        switch self {
        case .looks: "camera.filters"; case .exposure: "plusminus.circle"
        case .whiteBalance: "thermometer.medium"; case .focus: "viewfinder"; case .assist: "viewfinder.rectangular"
        }
    }
}

#endif
