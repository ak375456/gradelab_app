import SwiftUI

/// The Noise tool.
///
/// Two sections that are deliberately not merged into one "amount": temporal
/// and spatial reduction remove noise by completely different means and fail in
/// completely different ways, and a colorist balancing them is doing the most
/// important thing in this panel. Luma and chroma are separate for the same
/// reason.
struct NoiseReductionPanel<Model: GradingModel>: View {
    @ObservedObject var model: Model
    /// The timeline editor, when that is what is being graded. Auto and the
    /// status line need a decoded frame and a device to measure on, neither of
    /// which the protocol has or should have.
    private var editor: EditorViewModel? { model as? EditorViewModel }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ProPanelNotice(feature: .noiseReduction)
            if editor?.noiseStatus.unavailableInComposite == true { compositeNotice }
            presets
            temporal
            spatial
            quality
            footer
        }
    }

    /// Shown when the project's structure has moved it onto the layer
    /// compositor, where the engine does not run.
    private var compositeNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Not applied to this project", systemImage: "exclamationmark.triangle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppColors.accent)
            Text("Noise reduction runs on a single graded clip. This project also transforms, layers or blends its clips, which is composited separately — so the settings below are saved with the project but are not part of this preview or an export of it.")
                .font(.caption2).foregroundStyle(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AppColors.accent.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Presets and Auto

    @ViewBuilder
    private var presets: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(NoiseReduction.Preset.allCases) { preset in
                        Button(preset.title) { model.applyNoisePreset(preset) }
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14).frame(height: 38)
                            .background(AppColors.surfaceRaised, in: Capsule())
                            .contentShape(Capsule())
                            .foregroundStyle(AppColors.textPrimary)
                            .buttonStyle(.plain)
                            .disabled(!model.canGrade)
                    }
                }.padding(.horizontal, 1)
            }.frame(height: 42).scrollIndicators(.hidden)

            if let editor {
                Button {
                    editor.measureNoiseAndSuggest()
                } label: {
                    HStack(spacing: 8) {
                        if editor.isMeasuringNoise {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "wand.and.stars")
                        }
                        Text("Auto")
                        Spacer(minLength: 0)
                        Text("Measure this frame")
                            .font(.caption2).foregroundStyle(AppColors.textSecondary)
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 44)
                    .background(AppColors.accent.opacity(0.16),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(AppColors.accent)
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!model.canGrade || editor.isMeasuringNoise)
                if let profile = editor.noiseProfile {
                    Text(profile.summary)
                        .font(.caption2).foregroundStyle(AppColors.textSecondary)
                }
                Text("Auto reads the frame you are on and suggests a starting point. Every value it writes is an ordinary one you can drag.")
                    .font(.caption2).foregroundStyle(AppColors.textTertiary)
            }
        }
    }

    // MARK: Temporal

    @ViewBuilder
    private var temporal: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("TEMPORAL", isOn: model.noiseBinding(\.isTemporalEnabled),
                          enabled: capability?.supportsTemporal ?? true)
            if capability?.supportsTemporal == false {
                Text("This device does not have the memory to hold several frames of this project at once. Spatial reduction is still available.")
                    .font(.caption2).foregroundStyle(AppColors.textSecondary)
            } else {
                frameCount
                ForEach(NoiseReductionParameter.section(.temporal)) { parameter in
                    slider(parameter)
                }
                toggle("Motion Compensation", model.noiseBinding(\.isMotionCompensated),
                       detail: "Estimates the movement between frames and lines them up before combining them. Without it this is frame averaging, which is what produces trails. Turn it off only for a locked-off shot.")
            }
        }
    }

    @ViewBuilder
    private var frameCount: some View {
        let available = capability?.availableFrames ?? TemporalFrameCount.allCases
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Frames").font(AppTypography.bodyEmphasized)
                Spacer()
                if let editor {
                    Text(editor.noiseStatus.summary)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(editor.noiseStatus.isWaitingForFrames
                                         ? AppColors.accent : AppColors.textSecondary)
                }
            }
            HStack(spacing: 8) {
                ForEach(available) { count in
                    Button(count.title) {
                        model.editNoiseReduction { $0.frames = count; $0.isTemporalEnabled = true }
                        model.flushGradeHistory()
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(model.noiseReduction.frames == count
                                ? AppColors.accent.opacity(0.18) : AppColors.surfaceRaised,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(model.noiseReduction.frames == count
                                     ? AppColors.accent : AppColors.textPrimary)
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.noiseReduction.frames == count ? .isSelected : [])
                }
            }
            Text(model.noiseReduction.frames.detail)
                .font(.caption2).foregroundStyle(AppColors.textTertiary)
            if capability?.reduces(model.noiseReduction) == true {
                Text("This device is rendering the widest window it can hold. The project keeps the setting you chose.")
                    .font(.caption2).foregroundStyle(AppColors.accent)
            }
            if editor?.noiseStatus.previewIsReduced == true {
                Text("Combining frames needs the preview at the project's own resolution, so it pauses while the transport is running. Stop the playhead — or set Preview Quality to Full — to see it. Export is unaffected.")
                    .font(.caption2).foregroundStyle(AppColors.accent)
            }
        }
    }

    // MARK: Spatial

    @ViewBuilder
    private var spatial: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("SPATIAL", isOn: model.noiseBinding(\.isSpatialEnabled), enabled: true)
            ForEach(NoiseReductionParameter.section(.spatial)) { parameter in
                slider(parameter)
            }
            toggle("Protect Edges", model.noiseBinding(\.protectsEdges),
                   detail: "Keeps the filter from reaching across a real edge. Black text on a white wall stays sharp however far the radius is pushed.")
        }
    }

    // MARK: Quality

    @ViewBuilder
    private var quality: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("QUALITY").font(.caption.weight(.semibold)).tracking(1.2)
            HStack(spacing: 8) {
                ForEach(NoiseReductionQuality.allCases) { option in
                    Button(option.title) {
                        model.editNoiseReduction { $0.quality = option }
                        model.flushGradeHistory()
                    }
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(model.noiseReduction.quality == option
                                ? AppColors.accent.opacity(0.18) : AppColors.surfaceRaised,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(model.noiseReduction.quality == option
                                     ? AppColors.accent : AppColors.textPrimary)
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.noiseReduction.quality == option ? .isSelected : [])
                }
            }
            Text(model.noiseReduction.quality.detail)
                .font(.caption2).foregroundStyle(AppColors.textTertiary)
        }
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.hasNoiseReduction {
                Button("Reset noise reduction") { model.resetNoiseReduction() }
                    .font(.caption.weight(.medium)).frame(minHeight: 36)
                    .disabled(!model.canGrade)
            }
            Text("Judge this at 100% or closer, and hold the picture to compare. At preview size a denoiser always looks better than it is.")
                .font(.caption2).foregroundStyle(AppColors.textSecondary)
            Text("Export always renders at high quality and uses the same engine the preview does, so the file matches what you tuned.")
                .font(.caption2).foregroundStyle(AppColors.textSecondary)
        }
    }

    // MARK: Pieces

    private var capability: NoiseReductionCapability? { editor?.noiseCapability }

    private func sectionHeader(_ title: String, isOn: Binding<Bool>, enabled: Bool) -> some View {
        HStack {
            Text(title).font(.caption.weight(.semibold)).tracking(1.2)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .disabled(!model.canGrade || !enabled)
                .accessibilityLabel(title)
        }
    }

    private func toggle(_ title: LocalizedStringKey, _ binding: Binding<Bool>,
                        detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: binding)
                .font(.subheadline)
                .disabled(!model.canGrade)
            Text(detail).font(.caption2).foregroundStyle(AppColors.textTertiary)
        }
    }

    private func slider(_ parameter: NoiseReductionParameter) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            AdjustmentSlider(
                value: model.noiseStrengthBinding(parameter),
                title: parameter.name,
                range: NoiseReduction.strengthRange,
                step: 1,
                neutralValue: parameter.neutralValue,
                valueFormatter: { String(format: "%.0f", locale: .current, $0) })
            .disabled(!model.canGrade)
            if model.noiseReduction[keyPath: parameter.keyPath] != parameter.neutralValue {
                Text(parameter.detail)
                    .font(.caption2).foregroundStyle(AppColors.textSecondary)
            }
        }
    }
}
