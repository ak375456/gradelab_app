//
//  AdjustmentSlider.swift
//  GradeLab
//
//  A precision grading control with a neutral detent. The bound value is updated
//  for every drag event so renderers can respond without an intermediate commit.
//

import SwiftUI

extension AdjustmentSlider where Accessory == EmptyView {
    /// The plain slider. Every control that has nothing to put beside its
    /// read-out uses this and is unchanged by the accessory slot existing.
    init(
        value: Binding<Float>,
        title: String,
        range: ClosedRange<Float>,
        step: Float,
        neutralValue: Float = 0,
        valueFormatter: @escaping (Float) -> String
    ) {
        self.init(value: value, title: title, range: range, step: step,
                  neutralValue: neutralValue, valueFormatter: valueFormatter) { EmptyView() }
    }
}

struct AdjustmentSlider<Accessory: View>: View {
    @Binding private var value: Float

    let title: String
    let range: ClosedRange<Float>
    let step: Float
    let neutralValue: Float
    let valueFormatter: (Float) -> String
    /// Sits at the end of the header row, beside the read-out. The keyframe
    /// diamond goes here, so an animatable grading control is the ordinary
    /// slider with one more thing in it rather than a second kind of slider.
    let accessory: Accessory

    @State private var isDragging = false
    @State private var neutralDetentArmed = true
    @State private var horizontalDragDecision: Bool?
    @State private var neutralFeedbackTrigger = 0
    @State private var resetFeedbackTrigger = 0

    @ScaledMetric(relativeTo: .caption) private var endpointLabelHeight: CGFloat = 16
    @Environment(\.requestNumericEntry) private var requestNumericEntry

    init(
        value: Binding<Float>,
        title: String,
        range: ClosedRange<Float>,
        step: Float,
        neutralValue: Float = 0,
        valueFormatter: @escaping (Float) -> String,
        @ViewBuilder accessory: () -> Accessory
    ) {
        _value = value
        self.title = title
        self.range = range
        self.step = abs(step)
        self.neutralValue = min(max(neutralValue, range.lowerBound), range.upperBound)
        self.valueFormatter = valueFormatter
        self.accessory = accessory()
    }

    var body: some View {
        VStack(spacing: AppSpacing.small) {
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.compact) {
                Text(title)
                    .font(AppTypography.bodyEmphasized)
                    .foregroundStyle(AppColors.textPrimary)

                Spacer(minLength: AppSpacing.compact)

                // Tap the read-out to type an exact value the drag cannot land on.
                NumericEntryLabel(title: title, text: valueFormatter(value), value: Double(value),
                                  range: Double(range.lowerBound)...Double(range.upperBound),
                                  tint: isNeutral(value) ? AppColors.textSecondary : AppColors.accent) { typed in
                    value = quantized(Float(typed))
                }
                .font(AppTypography.numeric)
                .accessibilityHidden(true)

                accessory
            }

            sliderRail
            endpointLabels
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(valueFormatter(value)))
        .accessibilityHint(Text("Swipe up or down to adjust. Use the Reset action to return to neutral."))
        .accessibilityAdjustableAction(adjustForAccessibility)
        .accessibilityAction(named: Text("Reset \(title)"), resetToNeutral)
        .accessibilityAction(named: Text("Enter \(title) value")) {
            requestNumericEntry(title, value: Double(value),
                                range: Double(range.lowerBound)...Double(range.upperBound)) { value = quantized(Float($0)) }
        }
        .sensoryFeedback(.selection, trigger: neutralFeedbackTrigger)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.65), trigger: resetFeedbackTrigger)
    }

    private var sliderRail: some View {
        GeometryReader { geometry in
            let sideInset: CGFloat = 10
            let railWidth = max(geometry.size.width - (sideInset * 2), 1)
            let currentX = sideInset + xPosition(for: value, width: railWidth)
            let neutralX = sideInset + xPosition(for: neutralValue, width: railWidth)
            let activeStart = min(currentX, neutralX)
            let activeWidth = max(abs(currentX - neutralX), 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppColors.controlTrack)
                    .frame(height: 4)
                    .offset(x: sideInset)
                    .padding(.trailing, sideInset * 2)

                Capsule()
                    .fill(AppColors.accent)
                    .frame(width: activeWidth, height: 4)
                    .offset(x: activeStart)

                Rectangle()
                    .fill(AppColors.textTertiary)
                    .frame(width: 1, height: 14)
                    .offset(x: neutralX - 0.5)
                    .accessibilityHidden(true)

                Circle()
                    .fill(AppColors.textPrimary)
                    .frame(width: isDragging ? 20 : 18, height: isDragging ? 20 : 18)
                    .overlay {
                        Circle()
                            .strokeBorder(AppColors.editorBackground.opacity(0.72), lineWidth: 2)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .offset(x: currentX - (isDragging ? 10 : 9))
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .highPriorityGesture(
                TapGesture(count: 2)
                    .onEnded(resetToNeutral)
            )
            .simultaneousGesture(
                // A short threshold leaves double-tap reset and vertical scrolling undisturbed.
                DragGesture(minimumDistance: 6, coordinateSpace: .local)
                    .onChanged { gesture in
                        if horizontalDragDecision == nil {
                            horizontalDragDecision = abs(gesture.translation.width)
                                >= abs(gesture.translation.height)
                        }

                        guard horizontalDragDecision == true else { return }
                        isDragging = true
                        updateValue(for: gesture.location.x - sideInset, railWidth: railWidth)
                    }
                    .onEnded { _ in
                        isDragging = false
                        neutralDetentArmed = true
                        horizontalDragDecision = nil
                    }
            )
        }
        .frame(height: 44)
    }

    private var endpointLabels: some View {
        GeometryReader { geometry in
            let sideInset: CGFloat = 10
            let railWidth = max(geometry.size.width - (sideInset * 2), 1)
            let neutralX = sideInset + xPosition(for: neutralValue, width: railWidth)

            ZStack {
                HStack {
                    endpointText(for: range.lowerBound)
                    Spacer(minLength: AppSpacing.standard)
                    endpointText(for: range.upperBound)
                }

                if neutralValue > range.lowerBound, neutralValue < range.upperBound {
                    endpointText(for: neutralValue)
                        .position(
                            x: min(max(neutralX, 24), max(geometry.size.width - 24, 24)),
                            y: endpointLabelHeight / 2
                        )
                }
            }
        }
        .frame(height: endpointLabelHeight)
        .accessibilityHidden(true)
    }

    private func endpointText(for endpoint: Float) -> some View {
        Text(valueFormatter(endpoint))
            .font(AppTypography.caption)
            .foregroundStyle(AppColors.textTertiary)
            .monospacedDigit()
            .lineLimit(1)
    }

    private func xPosition(for rawValue: Float, width: CGFloat) -> CGFloat {
        guard range.upperBound > range.lowerBound else { return 0 }
        let boundedValue = min(max(rawValue, range.lowerBound), range.upperBound)
        let progress = (boundedValue - range.lowerBound) / (range.upperBound - range.lowerBound)
        return CGFloat(progress) * width
    }

    private func updateValue(for xPosition: CGFloat, railWidth: CGFloat) {
        guard railWidth > 0, range.upperBound > range.lowerBound else { return }

        let progress = Float(min(max(xPosition / railWidth, 0), 1))
        let rawValue = range.lowerBound + progress * (range.upperBound - range.lowerBound)
        var updatedValue = quantized(rawValue)

        let detentDistance = neutralDetentDistance(railWidth: railWidth)
        let reachesNeutralDetent = abs(rawValue - neutralValue) <= detentDistance

        if reachesNeutralDetent {
            updatedValue = neutralValue

            if neutralDetentArmed, !isNeutral(value) {
                neutralFeedback()
                neutralDetentArmed = false
            }
        } else if abs(updatedValue - neutralValue) > detentDistance * 1.6 {
            neutralDetentArmed = true
        }

        value = updatedValue
    }

    private func quantized(_ rawValue: Float) -> Float {
        if rawValue <= range.lowerBound { return range.lowerBound }
        if rawValue >= range.upperBound { return range.upperBound }

        guard step > 0 else {
            return min(max(rawValue, range.lowerBound), range.upperBound)
        }

        // Anchor the lattice at neutral so positive and negative adjustments remain symmetric.
        let numberOfSteps = ((rawValue - neutralValue) / step).rounded()
        let steppedValue = neutralValue + numberOfSteps * step
        return min(max(steppedValue, range.lowerBound), range.upperBound)
    }

    private func neutralDetentDistance(railWidth: CGFloat) -> Float {
        let valuePerPoint = (range.upperBound - range.lowerBound) / Float(max(railWidth, 1))
        return max(step * 0.5, valuePerPoint * 8)
    }

    private func isNeutral(_ candidate: Float) -> Bool {
        let tolerance = max(step * 0.25, Float.ulpOfOne * 8)
        return abs(candidate - neutralValue) <= tolerance
    }

    private func resetToNeutral() {
        guard abs(value - neutralValue) > Float.ulpOfOne * 8 else { return }

        value = neutralValue
        neutralDetentArmed = false
        resetFeedbackTrigger += 1
    }

    private func neutralFeedback() {
        neutralFeedbackTrigger += 1
    }

    private func adjustForAccessibility(_ direction: AccessibilityAdjustmentDirection) {
        let accessibilityStep = step > 0 ? step : (range.upperBound - range.lowerBound) / 100
        let previousValue = value
        let proposedValue: Float

        switch direction {
        case .increment:
            proposedValue = min(value + accessibilityStep, range.upperBound)
        case .decrement:
            proposedValue = max(value - accessibilityStep, range.lowerBound)
        @unknown default:
            return
        }

        let crossesNeutral = (previousValue < neutralValue && proposedValue > neutralValue)
            || (previousValue > neutralValue && proposedValue < neutralValue)
        value = crossesNeutral ? neutralValue : proposedValue

        if isNeutral(value), !isNeutral(previousValue) {
            neutralFeedback()
        }
    }
}

enum AdjustmentValueFormatters {
    static func signed(fractionDigits: Int = 0, zero: String = "0") -> (Float) -> String {
        { value in
            guard abs(value) > Float.ulpOfOne else { return zero }
            let digits = max(fractionDigits, 0)
            return String(format: "%+.\(digits)f", locale: .current, Double(value))
        }
    }

    static func percent(fractionDigits: Int = 0) -> (Float) -> String {
        { value in
            guard abs(value) > Float.ulpOfOne else { return "0%" }
            let digits = max(fractionDigits, 0)
            return String(format: "%+.\(digits)f%%", locale: .current, Double(value))
        }
    }
}
