import SwiftUI

/// Shared duration control. The readout spells out units; exact entry is in
/// seconds, as its dialog title states. Quick choices stay large enough to tap
/// in the narrow phone inspector and omit values that do not fit the clip.
struct DurationSliderRow: View {
    @AppStorage(DurationDisplayFormat.preferenceKey) private var format = DurationDisplayFormat.defaultValue
    static let wholeSecondSnapPoints: [Double] = [1, 2, 3, 4, 5]

    var title: String = String(localized: "Duration")
    let value: Double
    let range: ClosedRange<Double>
    let reset: Double
    var frameRate: Double? = nil
    var snapPoints: [Double] = []
    let change: (Double) -> Void
    let commit: (Double) -> Void
    let onEditingChanged: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.caption)
                Spacer(minLength: 8)
                NumericEntryLabel(title: String(localized: "\(title) (seconds)"),
                                  text: displayValue,
                                  value: value, range: range, tint: .primary, apply: commit)
                    .font(.caption.monospacedDigit())
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minHeight: 44)
            }
            ResettableSlider(value: Binding(get: { value }, set: change),
                             range: range, resetValue: reset, label: title,
                             onEditingChanged: onEditingChanged,
                             onReset: { commit(reset) }, snapPoints: snapPoints)
                .frame(minHeight: 44)
                .tint(AppColors.accent)
                .accessibilityValue(displayValue)
            if !snapPoints.isEmpty {
                HStack(spacing: 4) {
                    ForEach(snapPoints.filter { range.contains($0) }, id: \.self) { seconds in
                        Button { commit(seconds) } label: {
                            Text(DurationText.string(from: seconds))
                                .font(.caption.monospacedDigit())
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .foregroundStyle(abs(value - seconds) < 0.0005 ? AppColors.accent : AppColors.textSecondary)
                                .background(abs(value - seconds) < 0.0005 ? AppColors.accentMuted : Color.clear,
                                            in: RoundedRectangle(cornerRadius: AppCornerRadius.small))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(title), \(DurationText.string(from: seconds))")
                        .accessibilityAddTraits(abs(value - seconds) < 0.0005 ? .isSelected : [])
                    }
                }
            }
        }
    }

    private var displayValue: String {
        DurationText.string(from: value, format: format, frameRate: frameRate)
    }
}
