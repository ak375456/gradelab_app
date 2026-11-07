import SwiftUI

/// The saved choice updates open duration controls through AppStorage, without
/// touching the project, undo history, or the preview/export timebase.
struct DurationDisplaySettingsLink: View {
    @AppStorage(DurationDisplayFormat.preferenceKey) private var format = DurationDisplayFormat.defaultValue
    var frameRate: Double? = nil

    var body: some View {
        Section {
            NavigationLink {
                DurationDisplaySettings(frameRate: frameRate)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "clock")
                        .font(.title3).foregroundStyle(AppColors.accent)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Duration display").font(.subheadline.weight(.medium))
                        Text(format.title).font(.caption).foregroundStyle(AppColors.textSecondary)
                        Text(DurationText.string(from: 0.96, format: format, frameRate: frameRate))
                            .font(.caption.monospacedDigit()).foregroundStyle(AppColors.accent)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            }
            .accessibilityIdentifier("settings.durationDisplay")
        } header: {
            Text("Time display")
        } footer: {
            Text("Choose how durations are shown in text, transitions, audio and other editing tools.")
        }
    }
}

struct DurationDisplaySettings: View {
    @AppStorage(DurationDisplayFormat.preferenceKey) private var format = DurationDisplayFormat.defaultValue
    var frameRate: Double? = nil

    private var knownFrameRate: Double? { DurationText.validFrameRate(frameRate) }
    private var exampleFrameRate: Double { knownFrameRate ?? 60 }

    var body: some View {
        Form {
            Section {
                ForEach(DurationDisplayFormat.allCases) { option in
                    DurationDisplayOptionRow(option: option, selected: format == option,
                                             frameRate: exampleFrameRate) { format = option }
                }
            } header: {
                Text("Format")
            } footer: {
                Text("Each example shows the same duration: 1.25 seconds. Your choice is saved for all projects.")
            }

            Section {
                Label {
                    Text(frameRateExplanation)
                        .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "film").foregroundStyle(AppColors.accent)
                }
                Label {
                    Text("Tap a duration value to enter exact seconds in any display format.")
                        .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "keyboard").foregroundStyle(AppColors.accent)
                }
            } header: {
                Text("Reading the values")
            } footer: {
                Text("Timeline position keeps its frame timecode. Your edits and exports keep the same timing.")
            }
        }
        .navigationTitle("Duration display")
        .navigationBarTitleDisplayMode(.inline)
        .tint(AppColors.accent)
    }

    private var frameRateExplanation: String {
        guard let knownFrameRate,
              let label = VideoMetadata.frameRateLabel(forFrameRate: knownFrameRate) else {
            return String(localized: "Frame examples use 60 FPS. When a project's frame rate is unknown, duration labels use milliseconds.")
        }
        let last = DurationText.string(from: (Double(max(1, Int(knownFrameRate.rounded()))) - 1) / knownFrameRate,
                                       format: .secondsAndFrames, frameRate: knownFrameRate)
        let next = DurationText.string(from: 1, format: .secondsAndFrames, frameRate: knownFrameRate)
        return String(localized: "This project uses \(label). The frame counter rolls from \(last) to \(next).")
    }
}

struct DurationDisplayOptionRow: View {
    let option: DurationDisplayFormat
    let selected: Bool
    let frameRate: Double
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    Text(option.title).font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(selected ? AppColors.accent : AppColors.textTertiary)
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(true)
                }
                Text(option.explanation).font(.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(DurationText.string(from: 1.25, format: option, frameRate: frameRate))
                    .font(AppTypography.numeric).foregroundStyle(AppColors.accent)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(AppColors.accentMuted, in: RoundedRectangle(cornerRadius: AppCornerRadius.small))
                if option == .secondsAndFrames,
                   let label = VideoMetadata.frameRateLabel(forFrameRate: frameRate) {
                    Text(label).font(.caption2).foregroundStyle(AppColors.textSecondary)
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings.durationDisplay.\(option.rawValue)")
    }
}
