import SwiftUI

struct BackgroundRemovalPanel: View {
    @ObservedObject var model: EditorViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                modeButtons
                if let progress = model.backgroundAnalysisProgress { progressView(progress) }
                if let progress = model.backgroundTrackProgress { trackingProgress(progress) }
                if let message = model.backgroundAnalysisMessage {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message).font(.caption).foregroundStyle(AppColors.textSecondary)
                        if model.backgroundTrackLostTime != nil {
                            Button("Go to that frame and redraw", action: model.goToBackgroundTrackLostFrame)
                                .font(.caption.weight(.semibold)).foregroundStyle(AppColors.accent)
                                .frame(minHeight: 36)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if let settings = model.selectedBackgroundRemoval {
                    if settings.mode == .colorKey { colorControls(settings) }
                    if settings.mode == .lasso {
                        lassoControls(settings)
                        if model.canTrackBackgroundLasso { trackControls(settings) }
                    }
                    refineControls
                    edgeControls
                    viewControls
                    resetControls
                } else {
                    Text("Choose Auto for a one-tap cutout, Lasso to draw around the exact object you want, or Color for green and blue screen footage.")
                        .font(.subheadline).foregroundStyle(AppColors.textSecondary)
                }
            }
            .padding(20)
        }
        .scrollIndicators(.visible)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("REMOVE BACKGROUND").font(.caption.weight(.semibold)).tracking(1.2)
            Text("Cutout changes clip transparency. Color grading masks remain separate.")
                .font(.caption).foregroundStyle(AppColors.textSecondary)
        }
    }

    private var modeButtons: some View {
        HStack(spacing: 8) {
            modeButton("Auto", symbol: "person.crop.rectangle",
                       selected: model.selectedBackgroundRemoval?.mode == .automatic) {
                model.startAutomaticBackgroundRemoval()
            }
            modeButton("Lasso", symbol: "lasso",
                       selected: model.selectedBackgroundRemoval?.mode == .lasso || model.isDrawingBackgroundLasso) {
                model.armBackgroundLasso()
            }
            modeButton("Color", symbol: "eyedropper",
                       selected: model.selectedBackgroundRemoval?.mode == .colorKey) {
                model.useColorBackgroundRemoval()
            }
        }
    }

    private func modeButton(_ title: LocalizedStringKey, symbol: String, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 18, weight: .medium))
                Text(title).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 66)
            .background(selected ? AppColors.accent.opacity(0.18) : AppColors.surfaceRaised,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(selected ? AppColors.accent : AppColors.textPrimary)
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Lasso

    private func lassoControls(_ settings: BackgroundRemovalSettings) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("OUTLINE")
            if settings.lasso?.isDrawn == true {
                HStack(spacing: 8) {
                    actionButton("Redraw", symbol: "lasso.badge.sparkles",
                                 prominent: model.isDrawingBackgroundLasso, action: model.armBackgroundLasso)
                    actionButton("Clear", symbol: "xmark", action: model.clearBackgroundLasso)
                }
                Text("Everything outside the outline is removed. Turn on Invert to cut out the object instead.")
                    .font(.caption2).foregroundStyle(AppColors.textTertiary)
            } else {
                actionButton("Draw Lasso", symbol: "lasso", prominent: true, action: model.armBackgroundLasso)
                Text(model.isDrawingBackgroundLasso
                     ? "Trace around the object on the preview. The shape closes itself when you lift your finger."
                     : "Draw around the object you want to keep, the way you would in a photo editor.")
                    .font(.caption2).foregroundStyle(AppColors.textTertiary)
            }
        }
    }

    private func trackControls(_ settings: BackgroundRemovalSettings) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("TRACK OBJECT")
            if model.backgroundTrackProgress == nil {
                Picker("Direction", selection: $model.backgroundTrackDirection) {
                    Text("Both").tag(MaskTrackingDirection.both)
                    Text("Forward").tag(MaskTrackingDirection.forward)
                    Text("Backward").tag(MaskTrackingDirection.backward)
                }
                .pickerStyle(.segmented)
                .disabled(!model.canTrackBackgroundLasso)
                actionButton("Track Object", symbol: "scope", prominent: true,
                             action: model.trackBackgroundLasso)
                frameStepControls
                if settings.lasso?.isTracked == true {
                    Button("Clear Tracking", action: model.clearBackgroundLassoTracking)
                        .font(.caption.weight(.semibold)).foregroundStyle(AppColors.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(AppColors.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            Text(settings.lasso?.isTracked == true
                 ? "Step frame by frame to check the cutout. Where it drifts, redraw the lasso on that frame and track again from there."
                 : "Track once from this frame and the outline follows the object for the rest of the clip.")
                .font(.caption2).foregroundStyle(AppColors.textTertiary)
        }
    }

    private func actionButton(_ title: LocalizedStringKey, symbol: String, prominent: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(prominent ? AppColors.accent.opacity(0.18) : AppColors.surfaceRaised,
                            in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(prominent ? AppColors.accent : AppColors.textPrimary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Progress

    private func progressView(_ progress: BackgroundRemovalAnalysisProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView().controlSize(.small)
                Text(progress.preparing ? "Preparing analysis…" : "Analyzing Background")
                    .font(.caption.weight(.medium))
                Spacer()
                Text("\(Int(progress.fraction * 100))%").font(.caption.monospacedDigit())
            }
            if let total = progress.totalFrames {
                Text(progress.preparing
                     ? "Getting frame 1 of \(total) ready"
                     : "Frame \(min(max(progress.frames, 1), total)) of \(total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppColors.textSecondary)
            }
            ProgressView(value: progress.fraction)
            Button("Cancel", action: model.cancelBackgroundAnalysis)
                .font(.caption.weight(.semibold)).foregroundStyle(AppColors.accent)
                .frame(minHeight: 36)
        }
        .padding(12).background(AppColors.surfaceRaised,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func trackingProgress(_ progress: MaskTrackingProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView().controlSize(.small)
                Text("Tracking Object").font(.caption.weight(.medium))
                Spacer()
                Text("\(Int(progress.fraction * 100))%").font(.caption.monospacedDigit())
            }
            Text(progress.preparing ? "Preparing source frames"
                 : progress.direction == .backward ? "Backward · \(progress.frames) frames"
                 : "Forward · \(progress.frames) frames")
                .font(.caption.monospacedDigit()).foregroundStyle(AppColors.textSecondary)
            ProgressView(value: progress.fraction)
            Button("Stop", action: model.cancelBackgroundLassoTracking)
                .font(.caption.weight(.semibold)).foregroundStyle(AppColors.accent)
                .frame(minHeight: 36)
        }
        .padding(12).background(AppColors.accent.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Color

    private func colorControls(_ settings: BackgroundRemovalSettings) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("COLOR")
            Button(action: model.armBackgroundColorPicker) {
                HStack {
                    Image(systemName: "eyedropper")
                    Text("Pick Key Color")
                    Spacer()
                    Circle().fill(Color(red: settings.colorKey.color.red,
                                        green: settings.colorKey.color.green,
                                        blue: settings.colorKey.color.blue))
                        .frame(width: 24, height: 24).overlay(Circle().stroke(.white.opacity(0.4)))
                }.frame(minHeight: 44)
            }
            valueSlider("Similarity", model.backgroundRemovalBinding(\.colorKey.similarity), 0...100, reset: 38)
            valueSlider("Smoothness", model.backgroundRemovalBinding(\.colorKey.smoothness), 0...100, reset: 18)
            valueSlider("Spill", model.backgroundRemovalBinding(\.colorKey.spill), 0...100, reset: 35)
        }
    }

    // MARK: - Refine

    private var refineControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("REFINE")
            HStack(spacing: 8) {
                brushButton("Add", .add, symbol: "plus.circle")
                brushButton("Remove", .remove, symbol: "minus.circle")
            }
            if model.backgroundBrush != nil {
                valueSlider("Brush Size", $model.backgroundBrushSize, 0.005...0.20,
                            reset: 0.04, format: { "\(Int($0 * 1000) / 10)%" })
                valueSlider("Softness", $model.backgroundBrushSoftness, 0...1,
                            reset: 0.65, format: { "\(Int($0 * 100))%" })
                frameStepControls
                Text("Paint this frame, then use Next Frame to continue. Add is blue; Remove is red. A magnifier appears below your finger.")
                    .font(.caption2).foregroundStyle(AppColors.textTertiary)
            }
        }
    }

    private func brushButton(_ title: LocalizedStringKey, _ kind: BackgroundRemovalBrush,
                             symbol: String) -> some View {
        let selected = model.backgroundBrush == kind
        return Button {
            model.isDrawingBackgroundLasso = false; model.isPickingBackgroundColor = false
            model.backgroundBrush = selected ? nil : kind
        } label: {
            Label(title, systemImage: symbol).font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(selected ? AppColors.accent.opacity(0.18) : AppColors.surfaceRaised,
                            in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(selected ? AppColors.accent : AppColors.textPrimary)
        }
    }

    private var edgeControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("EDGE")
            valueSlider("Feather", model.backgroundRemovalBinding(\.feather), 0...100, reset: 0)
            valueSlider("Shift Edge", model.backgroundRemovalBinding(\.edgeShift), -100...100, reset: 0)
        }
    }

    /// One frame at a time, shared by Refine and Track. Checking a cutout is
    /// a frame-by-frame job in both cases: painting the next frame, or finding
    /// the frame where a track started to drift so it can be redrawn there.
    private var frameStepControls: some View {
        VStack(spacing: 7) {
            HStack {
                Text("CURRENT FRAME").font(.caption2.weight(.semibold)).tracking(0.8)
                Spacer()
                let rate = model.project.canvas.frameRate ?? model.project.metadata.bestFrameRate
                Text(TimecodeFormatter.frameString(from: model.timelineTime, frameRate: rate))
                    .font(.caption2.monospacedDigit()).foregroundStyle(AppColors.textSecondary)
            }
            HStack(spacing: 8) {
                Button { model.stepFrames(-1) } label: {
                    Label("Previous", systemImage: "chevron.left")
                        .frame(maxWidth: .infinity, minHeight: 42)
                }
                .accessibilityLabel("Previous frame")
                Button { model.stepFrames(1) } label: {
                    Label("Next", systemImage: "chevron.right")
                        .labelStyle(.titleAndIcon).frame(maxWidth: .infinity, minHeight: 42)
                }
                .accessibilityLabel("Next frame")
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppColors.accent)
            .background(AppColors.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var viewControls: some View {
        VStack(spacing: 0) {
            Toggle("Show Matte", isOn: $model.showsBackgroundMatte).frame(minHeight: 44)
            Toggle("Invert", isOn: model.backgroundRemovalBinding(\.isInverted)).frame(minHeight: 44)
        }
    }

    private var resetControls: some View {
        VStack(spacing: 8) {
            Button("Reset Refinement", action: model.resetBackgroundRefinement)
                .frame(maxWidth: .infinity, minHeight: 44).background(AppColors.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
            Button(role: .destructive, action: model.removeBackgroundRemoval) {
                Text("Remove Background Removal").frame(maxWidth: .infinity, minHeight: 44)
            }.background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        }.font(.subheadline.weight(.medium))
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.caption.weight(.semibold)).tracking(1).foregroundStyle(AppColors.textSecondary)
    }

    private func valueSlider(_ title: String, _ binding: Binding<Double>, _ range: ClosedRange<Double>,
                             reset: Double,
                             format: @escaping (Double) -> String = { "\(Int($0))" }) -> some View {
        let floatBinding = Binding<Float>(
            get: { Float(binding.wrappedValue) },
            set: { binding.wrappedValue = Double($0) })
        let span = range.upperBound - range.lowerBound
        return AdjustmentSlider(
            value: floatBinding, title: title,
            range: Float(range.lowerBound)...Float(range.upperBound),
            step: span <= 0.25 ? 0.001 : span <= 1 ? 0.01 : 1,
            neutralValue: Float(reset),
            valueFormatter: { format(Double($0)) })
    }
}
