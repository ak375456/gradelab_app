import SwiftUI

/// Clip speed, presented like the other adjustment tools rather than as a menu.
///
/// The slider is logarithmic: each step doubles or halves the rate, so 1× sits
/// exactly in the middle and 0.5× and 2× are the same distance from it. A linear
/// slider would squash everything below 1× into the first fifth of the track and
/// make slow motion almost unselectable.
struct SpeedPanel: View {
    @ObservedObject var model: EditorViewModel

    /// Slider position: log10 of the speed, so -1 is 0.1×, 0 is 1× and +1 is 10×.
    private var position: Binding<Float> {
        Binding(
            get: { Float(ClipSpeed.sliderPosition(for: model.selectedSpeed)) },
            set: { model.setSpeed(ClipSpeed.speed(atSliderPosition: Double($0)), live: true) }
        )
    }

    private var speed: Double { model.selectedSpeed }

    private var sourceSeconds: Double {
        guard let clip = model.selectedClip else { return 0 }
        return clip.sourceRange.duration.seconds
    }

    private var timelineSeconds: Double {
        model.selectedClip?.placement.duration.seconds ?? 0
    }

    var body: some View {
        // Scrolls so a small screen can never push the tool bar off the bottom
        // and strand the user in this panel.
        ScrollView {
        VStack(spacing: 14) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(ClipSpeed.presets, id: \.self) { preset in
                        Button { model.setSpeed(preset) } label: {
                            Text(ClipSpeed.label(preset))
                                .font(.subheadline)
                                .padding(.horizontal, 14).frame(height: 40)
                                .background(isCurrent(preset) ? AppColors.surfaceRaised : .clear, in: Capsule())
                                .overlay(Capsule().stroke(
                                    isCurrent(preset) ? AppColors.textPrimary.opacity(0.35) : .clear, lineWidth: 1))
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

            HStack(spacing: 6) {
                Image(systemName: "clock").font(.caption2)
                Text(durationSummary)
                Spacer(minLength: 8)
                if model.selectedSpeed != ClipSpeed.normal {
                    Button("Reset") { model.setSpeed(ClipSpeed.normal) }
                        .font(.caption).frame(height: 44)
                }
            }
            .font(.caption).foregroundStyle(AppColors.textSecondary)

            Divider().overlay(AppColors.textTertiary.opacity(0.3))

            Toggle(isOn: Binding(
                get: { model.smoothsMotion },
                set: { model.setSmoothsMotion($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smooth motion").font(.subheadline)
                    Text(model.smoothsMotion
                         ? "Blending between source frames."
                         : "Each source frame is held.")
                        .font(.caption2).foregroundStyle(AppColors.textSecondary)
                }
            }
            .disabled(!model.canSmoothMotion)
            .frame(minHeight: 44)

            if let reason = model.smoothingUnavailableReason {
                Text(reason)
                    .font(.caption2).foregroundStyle(AppColors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Blends adjacent frames instead of repeating them, which removes the stepping in slow motion on footage that was not shot at a high frame rate. Fast movement softens rather than gaining detail — no new frames are invented.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("Audio follows the clip and keeps its pitch. Later clips shift to stay in step.")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20).padding(.bottom, 12)
        .disabled(!model.canChangeSpeed)
        .opacity(model.canChangeSpeed ? 1 : 0.5)
        }
        .scrollIndicators(.visible)
        // Leaving the tool must not strand a pending rebuild, or the player
        // keeps a composition that no longer matches the timeline.
        .onDisappear { model.settlePendingSpeedEdit() }
    }

    /// Compared with a tolerance: the slider produces continuous values, so an
    /// exact match would almost never light a preset up.
    private func isCurrent(_ preset: Double) -> Bool {
        abs(speed - preset) < 0.005
    }

    private var durationSummary: String {
        guard model.selectedClip != nil else { return String(localized: "No clip selected") }
        return String(format: String(localized: "%.2fs source · %.2fs on the timeline"), locale: .current, sourceSeconds, timelineSeconds)
    }
}
