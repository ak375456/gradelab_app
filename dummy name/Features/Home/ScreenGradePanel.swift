//
//  ScreenGradePanel.swift
//  GradeLab
//
//  Three grading controls, pointed at the app instead of at a clip.
//

import SwiftUI

/// The controls behind `GradeLabMark`.
///
/// It expands in place under the header rather than arriving as a sheet,
/// because the thing being graded is the screen behind it: a sheet would cover
/// the only preview there is. The sliders are the app's real `AdjustmentSlider`
/// — same 44pt rail you can hit anywhere along its width, same neutral detent
/// with its haptic, same double-tap reset, same VoiceOver adjustment — so the
/// first grading control a new user touches behaves exactly like the ones
/// waiting for them in the editor.
struct ScreenGradePanel: View {
    @Binding var grade: HomeScreenGrade
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.compact) {
            header

            Text("Only this screen. Your footage, the editor and every export stay neutral.")
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, AppSpacing.xSmall)

            AdjustmentSlider(
                value: $grade.hue,
                title: "Hue",
                range: HomeScreenGrade.hueRange,
                step: 5,
                tint: grade.accent,
                valueFormatter: Self.degrees
            )

            AdjustmentSlider(
                value: $grade.vibrance,
                title: "Vibrance",
                range: HomeScreenGrade.vibranceRange,
                step: 5,
                tint: grade.accent,
                valueFormatter: AdjustmentValueFormatters.percent()
            )

            AdjustmentSlider(
                value: $grade.lift,
                title: "Lift",
                range: HomeScreenGrade.liftRange,
                step: 5,
                tint: grade.accent,
                valueFormatter: AdjustmentValueFormatters.percent()
            )
        }
        .padding(AppSpacing.large)
        .appSurface(
            cornerRadius: AppCornerRadius.prominent,
            fill: grade.surface,
            border: grade.accent.opacity(0.30)
        )
    }

    private var header: some View {
        HStack(spacing: AppSpacing.small) {
            Text("SCREEN GRADE")
                .font(AppTypography.sectionLabel)
                .tracking(1.15)
                .foregroundStyle(grade.accent)

            Spacer(minLength: AppSpacing.small)

            Button {
                withAnimation(.snappy(duration: 0.28)) { grade = .neutral }
            } label: {
                Text("Reset")
                    .font(AppTypography.caption.weight(.medium))
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(grade.isNeutral)
            .opacity(grade.isNeutral ? 0.35 : 1)
            .accessibilityHint("Returns this screen to GradeLab's own colours")

            Button(action: onClose) {
                Image(systemName: "chevron.up")
                    .font(AppTypography.caption.weight(.semibold))
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close screen grade")
        }
    }

    /// Degrees around the wheel, signed, because the useful fact about a hue
    /// rotation is which way and how far it has gone from stock.
    private static let degrees: (Float) -> String = { value in
        abs(value) < 0.5 ? "0°" : String(format: "%+.0f°", locale: .current, Double(value))
    }
}
