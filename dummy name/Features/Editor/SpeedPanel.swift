import SwiftUI

/// Clip speed: one rate, or a curve.
///
/// The engine underneath is the same everywhere — `TimeRemap` on the clip and
/// `TimeMap` doing the conversion — and so is the vocabulary. What changes is
/// the shape of the workspace, because the three devices are not the same room:
///
/// - **Mac** gets everything at once. The curve is large and permanent, the
///   numbers are typeable, points answer to a right-click, and nothing that
///   matters is more than one click away.
/// - **iPad** keeps the curve beside the picture rather than over it, sized for
///   a Pencil, with the settings underneath.
/// - **iPhone** shows one rate and a button. Ramping opens a dedicated editor
///   that takes the whole screen, because a curve squeezed into an inspector
///   column is not a curve anyone can edit.
struct SpeedPanel: View {
    @ObservedObject var model: EditorViewModel
    /// Set by the ⇧-free R shortcut: open straight into Ramp. A one-shot, so
    /// the panel does not keep forcing the mode every time it redraws.
    var opensRamp: Binding<Bool> = .constant(false)
    @StateObject private var editor = SpeedEditorModel()
    @Environment(\.requestNumericEntry) private var requestNumericEntry

    private var isMac: Bool { AppPlatform.isMac }
    private var isPad: Bool { !isMac && AppPlatform.usesDesktopWorkspace }
    private var isPhone: Bool { !AppPlatform.usesDesktopWorkspace }

    private var speed: Double { model.selectedSpeed }
    private var remap: TimeRemap { model.selectedRemap }

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.standard) {
                modeSelector

                if editor.showsRamp {
                    if isPhone { phoneRampSummary } else { rampWorkspace }
                } else {
                    constantControls
                }

                Divider().overlay(AppColors.separator)
                timeControls
                Divider().overlay(AppColors.separator)
                interpolationControls
                audioControls
                durationSummary
            }
            .padding(.horizontal, AppSpacing.large)
            .padding(.bottom, AppSpacing.compact)
            .disabled(!model.canChangeSpeed)
            .opacity(model.canChangeSpeed ? 1 : 0.5)
        }
        .scrollIndicators(.visible)
        .onAppear {
            editor.showsRamp = model.isSelectionRamped || opensRamp.wrappedValue
            opensRamp.wrappedValue = false
        }
        .onChange(of: opensRamp.wrappedValue) { _, requested in
            guard requested else { return }
            editor.showsRamp = true
            opensRamp.wrappedValue = false
        }
        .onChange(of: model.selectedClipID) { _, _ in
            editor.selection.removeAll()
            editor.clearTransientState()
            editor.showsRamp = model.isSelectionRamped
        }
        // Leaving the tool must not strand a pending rebuild, or the player
        // keeps a composition that no longer matches the timeline.
        .onDisappear { model.settlePendingSpeedEdit() }
        .sheet(isPresented: $editor.showsPhoneEditor) {
            PhoneSpeedEditor(model: model, editor: editor)
        }
    }

    // MARK: - Mode

    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Text("Speed").font(AppTypography.sectionLabel)
                .foregroundStyle(AppColors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Picker("Speed", selection: Binding(
                get: { editor.showsRamp },
                set: { editor.showsRamp = $0 }
            )) {
                Text("Constant").tag(false)
                Text("Ramp").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(minHeight: 44)
        }
    }

    // MARK: - Constant

    private var constantControls: some View {
        VStack(spacing: AppSpacing.compact) {
            ScrollView(.horizontal) {
                HStack(spacing: AppSpacing.small) {
                    ForEach(ClipSpeed.presets, id: \.self) { preset in
                        Button { model.setSpeed(preset) } label: {
                            Text(ClipSpeed.label(preset))
                                .font(AppTypography.secondary)
                                .padding(.horizontal, 14).frame(height: 40)
                                .background(isCurrent(preset) ? AppColors.surfaceRaised : .clear, in: Capsule())
                                .overlay(Capsule().stroke(
                                    isCurrent(preset) ? AppColors.textPrimary.opacity(0.35) : .clear, lineWidth: 1))
                                // An unselected chip's background is clear, and
                                // SwiftUI does not hit-test clear: without this
                                // only the digits themselves take the click.
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(isCurrent(preset) ? AppColors.textPrimary : AppColors.textSecondary)
                        .accessibilityAddTraits(isCurrent(preset) ? .isSelected : [])
                    }
                }.padding(.horizontal, 2)
            }.frame(height: 44).scrollIndicators(.hidden)

            AdjustmentSlider(
                value: position,
                title: String(localized: "Speed"),
                range: Float(ClipSpeed.sliderRange.lowerBound)...Float(ClipSpeed.sliderRange.upperBound),
                step: 0.005,
                neutralValue: 0,
                valueFormatter: { ClipSpeed.label(ClipSpeed.speed(atSliderPosition: Double($0))) }
            )

            if speed != ClipSpeed.normal {
                Button("Reset") { model.setSpeed(ClipSpeed.normal) }
                    .font(AppTypography.caption).frame(height: 44)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// Slider position: log10 of the speed, so 1× sits exactly in the middle.
    private var position: Binding<Float> {
        Binding(
            get: { Float(ClipSpeed.sliderPosition(for: speed)) },
            set: { model.setSpeed(ClipSpeed.speed(atSliderPosition: Double($0)), live: true) }
        )
    }

    /// Compared with a tolerance: the slider produces continuous values, so an
    /// exact match would almost never light a preset up.
    private func isCurrent(_ preset: Double) -> Bool { abs(speed - preset) < 0.005 }

    // MARK: - Ramp, on a device with room for it

    private var rampWorkspace: some View {
        VStack(spacing: AppSpacing.compact) {
            presets
            SpeedCurveView(model: model, editor: editor, height: isMac ? 280 : 220)
            rampActions
            if let point = selectedPoint { pointControls(point) }
        }
    }

    /// The phone shows what the ramp is and a way in. It does not try to be the
    /// editor.
    private var phoneRampSummary: some View {
        VStack(spacing: AppSpacing.compact) {
            presets
            SpeedCurveView(model: model, editor: editor, height: 120)
                .allowsHitTesting(false)
                .opacity(0.9)
            Button {
                editor.showsPhoneEditor = true
            } label: {
                Label("Open Speed Editor", systemImage: "arrow.up.left.and.arrow.down.right")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var rampActions: some View {
        HStack(spacing: AppSpacing.small) {
            Button {
                model.addSpeedPoint()
            } label: {
                Label("Add Point", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .disabled(model.playheadInSelectedClip == nil)
            Button {
                model.resetSpeedCurve()
            } label: {
                Label("Reset", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .disabled(remap.points.isEmpty)
        }
        .font(AppTypography.caption)
        .buttonStyle(.bordered)
    }

    private var selectedPoint: SpeedPoint? {
        guard let id = editor.selectedPoint, let clip = model.selectedClip else { return nil }
        return clip.resolvedRemap.points.first { $0.id == id }
    }

    @ViewBuilder
    private func pointControls(_ point: SpeedPoint) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            HStack {
                Text("Selected Point").font(AppTypography.sectionLabel)
                    .foregroundStyle(AppColors.textSecondary)
                Spacer()
                // Typing the number is how a desktop user sets an exact rate.
                // Everywhere else it is still offered — it is faster than
                // dragging for a round value on any device.
                Button {
                    requestNumericEntry(String(localized: "Speed %"),
                                        value: point.speed * 100,
                                        range: ClipSpeed.minimum * 100...ClipSpeed.maximum * 100) { value in
                        model.moveSpeedPoint(point.id, toTimeline: nil, speed: value / 100)
                    }
                } label: {
                    Text(ClipSpeed.percentLabel(point.speed))
                        .font(AppTypography.numeric)
                        .padding(.horizontal, AppSpacing.small).frame(height: 32)
                        .background(AppColors.surfaceRaised, in: RoundedRectangle(cornerRadius: AppCornerRadius.small))
                }
                .buttonStyle(.plain)
                .disabled(!requestNumericEntry.isAvailable)
            }

            Picker("Transition", selection: Binding(
                get: { point.interpolation },
                set: { model.setSpeedPointInterpolation(point.id, to: $0) }
            )) {
                ForEach(SpeedInterpolation.allCases) { Text($0.title).tag($0) }
            }
            .modifier(AdaptivePickerStyle(menu: isMac))
            .frame(minHeight: 44)

            Button(role: .destructive) {
                model.removeSpeedPoint(point.id)
                editor.selection.removeAll()
            } label: {
                Label("Delete Point", systemImage: "trash").frame(minHeight: 44)
            }
            .font(AppTypography.caption)
        }
        .padding(AppSpacing.compact)
        .background(AppColors.surface, in: RoundedRectangle(cornerRadius: AppCornerRadius.card))
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Text("Presets").font(AppTypography.sectionLabel)
                .foregroundStyle(AppColors.textSecondary)
            // A preset is nothing but a set of ordinary points: everything it
            // leaves behind is as editable as a point placed by hand, and
            // nothing records that one was used.
            SpeedPresetGrid(model: model) {
                editor.showsRamp = true
                if isPhone { editor.showsPhoneEditor = true }
            }
        }
    }

    // MARK: - Freeze and reverse

    /// The two edits that are about time rather than about rate.
    ///
    /// Together rather than inside Ramp, because both apply just as much to a
    /// clip at one constant speed — freezing a frame in the middle of an
    /// untouched shot is one of the most common things anyone does here, and
    /// making it a ramp feature would hide it behind a mode switch.
    private var timeControls: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Text("Time").font(AppTypography.sectionLabel)
                .foregroundStyle(AppColors.textSecondary)

            HStack(spacing: AppSpacing.small) {
                Button {
                    model.freezeFrame()
                } label: {
                    Label("Freeze Frame", systemImage: "snowflake")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(!model.canFreezeAtPlayhead)
                Button {
                    model.setReversed(!remap.reverses)
                } label: {
                    Label("Reverse", systemImage: "arrow.uturn.left")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .tint(remap.reverses ? AppColors.accent : nil)
            }
            .font(AppTypography.caption)
            .buttonStyle(.bordered)

            if remap.reverses {
                Text("The clip plays backwards. Its sound is silent — audio cannot be reversed without rendering it, so it is muted rather than left running forwards under a picture that is not.")
                    .font(AppTypography.caption).foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !model.canFreezeAtPlayhead && model.canChangeSpeed {
                Text(model.playheadInSelectedClip == nil
                     ? "Move the playhead into the clip to freeze a frame."
                     : "This frame is already held.")
                    .font(AppTypography.caption).foregroundStyle(AppColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(model.selectedFreezes, id: \.freeze.id) { entry in
                freezeRow(entry.freeze, at: entry.timelineOffset)
            }
        }
    }

    /// One hold: where it is, how long it lasts, and a way to remove it.
    ///
    /// A slider rather than a stepper because the length of a hold is judged by
    /// watching it, not by typing it — and it is live, so the timeline resizes
    /// under the drag and the change lands as one undo entry.
    private func freezeRow(_ freeze: FreezeSegment, at offset: TimelineTime) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
            HStack {
                Image(systemName: "snowflake").font(AppTypography.caption)
                    .foregroundStyle(AppColors.accent)
                Text(TimecodeText.short(offset.seconds))
                    .font(AppTypography.caption).monospacedDigit()
                Spacer()
                Text(String(format: String(localized: "%.2fs"), locale: .current,
                            freeze.duration.seconds))
                    .font(AppTypography.numeric)
                Button(role: .destructive) {
                    model.removeFreeze(freeze.id)
                } label: {
                    Image(systemName: "trash").frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove freeze")
            }
            Slider(
                value: Binding(
                    get: { freeze.duration.seconds },
                    set: { model.setFreezeDuration(freeze.id, to: $0, live: true) }
                ),
                in: FreezeSegment.minimumDuration...FreezeSegment.maximumDuration
            ) { editing in
                if !editing { model.settlePendingSpeedEdit() }
            }
            .frame(minHeight: 44)
        }
        .padding(.horizontal, AppSpacing.small)
        .padding(.vertical, AppSpacing.xSmall)
        .background(AppColors.surface, in: RoundedRectangle(cornerRadius: AppCornerRadius.small))
    }

    // MARK: - Shared settings

    private var interpolationControls: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Text("Frame Interpolation").font(AppTypography.sectionLabel)
                .foregroundStyle(AppColors.textSecondary)
            Picker("Frame Interpolation", selection: Binding(
                get: { remap.frameInterpolation },
                set: { model.setFrameInterpolation($0) }
            )) {
                ForEach(FrameInterpolation.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(minHeight: 44)
            .disabled(!model.canInterpolateFrames)

            Text(remap.frameInterpolation.detail)
                .font(AppTypography.caption).foregroundStyle(AppColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !model.canInterpolateFrames {
                Text("Change the speed first. At normal speed every frame already lands on a source frame, so there is nothing between two frames to make.")
                    .font(AppTypography.caption).foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if remap.frameInterpolation == .opticalFlow {
                Picker("Optical Flow Quality", selection: Binding(
                    get: { remap.opticalFlowQuality },
                    set: { model.setOpticalFlowQuality($0) }
                )) {
                    ForEach(OpticalFlowQuality.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(minHeight: 44)
                Text("Preview keeps the timeline responsive. High is used for export either way.")
                    .font(AppTypography.caption).foregroundStyle(AppColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var audioControls: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            Text("Audio").font(AppTypography.sectionLabel)
                .foregroundStyle(AppColors.textSecondary)
            Picker("Audio", selection: Binding(
                get: { remap.audioBehaviour },
                set: { model.setRetimedAudioBehaviour($0) }
            )) {
                ForEach(RetimedAudioBehaviour.allCases) { Text($0.title).tag($0) }
            }
            .modifier(AdaptivePickerStyle(menu: !isMac))
            .frame(minHeight: 44)
            Text("Audio follows the speed curve. Later clips shift to stay in step.")
                .font(AppTypography.caption).foregroundStyle(AppColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var durationSummary: some View {
        HStack(spacing: AppSpacing.xSmall) {
            Image(systemName: "clock").font(AppTypography.caption)
            Text(summaryText)
            Spacer(minLength: AppSpacing.small)
        }
        .font(AppTypography.caption)
        .foregroundStyle(AppColors.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summaryText: String {
        guard let clip = model.selectedClip else { return String(localized: "No clip selected") }
        return String(format: String(localized: "%.2fs source · %.2fs on the timeline"),
                      locale: .current,
                      clip.sourceRange.duration.seconds, clip.placement.duration.seconds)
    }
}

/// A menu on one platform and the platform default on the other.
///
/// Written as a modifier rather than a ternary because `pickerStyle` takes a
/// concrete type: `isMac ? .menu : .automatic` is two different types and does
/// not compile. Two branches over the same content is the whole trick.
private struct AdaptivePickerStyle: ViewModifier {
    let menu: Bool
    func body(content: Content) -> some View {
        if menu { AnyView(content.pickerStyle(.menu)) }
        else { AnyView(content.pickerStyle(.segmented)) }
    }
}
