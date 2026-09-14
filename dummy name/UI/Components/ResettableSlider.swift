import SwiftUI

/// Every slider in the app behaves the same way: double-tap resets it to its default.
///
/// `AdjustmentSlider` (the grading controls) implements the same gesture against its own
/// neutral detent; this covers the plain `Slider`s everywhere else so the rule has no gaps.
struct ResettableSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// Where a double tap sends the value. Ignored when `onReset` is supplied.
    var resetValue: Double
    var label: String
    var onEditingChanged: (Bool) -> Void = { _ in }
    /// Lets a caller route the reset through its own rules — the keyframe rows use this so a
    /// reset on an animated property writes a keyframe instead of the base value.
    var onReset: (() -> Void)?

    @State private var resetFeedback = 0

    var body: some View {
        Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
            .accessibilityLabel(label)
            .accessibilityHint("Double tap to reset")
            .accessibilityAction(named: Text("Reset \(label)"), reset)
            // A single tap does nothing on a plain slider, so requiring two taps here cannot
            // swallow anything; dragging the thumb is unaffected.
            .highPriorityGesture(TapGesture(count: 2).onEnded(reset))
            .sensoryFeedback(.impact(weight: .light, intensity: 0.65), trigger: resetFeedback)
    }

    private func reset() {
        if let onReset { onReset() }
        else { value = min(range.upperBound, max(range.lowerBound, resetValue)) }
        resetFeedback += 1
    }
}
