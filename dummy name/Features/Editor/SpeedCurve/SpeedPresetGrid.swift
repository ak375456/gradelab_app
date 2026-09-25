import SwiftUI

/// The ramp presets, each showing the shape it will make.
///
/// A list of names cannot say what a ramp does. "Hero" and "Montage" are both
/// reasonable words for almost any curve, so a name on its own asks the user to
/// apply each one and watch what happens. The picture is the control: the tile
/// draws the rate the clip would actually play at, so the choice is made by
/// looking rather than by guessing.
///
/// Every curve here is sampled from a real `TimeMap`, the same one the big
/// editor draws and the compositor reads. A thumbnail drawn from the control
/// points instead would be a drawing of the intention rather than of the
/// result — and where the two differ, it is the result that plays.
struct SpeedPresetGrid: View {
    @ObservedObject var model: EditorViewModel
    /// Set when the user picks Custom, so the panel can open the curve editor.
    var onCustom: () -> Void

    private var remap: TimeRemap { model.selectedRemap }
    private var sourceDuration: TimelineTime {
        model.selectedClip?.sourceRange.duration ?? .zero
    }

    /// Which tile is lit.
    ///
    /// Custom is not a preset but a state: a clip with a curve that matches no
    /// preset has one the user built, and saying so is more useful than lighting
    /// nothing.
    private var selection: String {
        guard remap.isRamped else { return "none" }
        return remap.matchingPreset(sourceDuration: sourceDuration) ?? "custom"
    }

    /// Four across wherever there is room, three on a phone.
    ///
    /// Not `.adaptive`: a fixed count keeps the tiles the same size as each
    /// other and the labels on one line, and the sizes below are chosen so a
    /// curve is still legible at the smaller one.
    private var columns: [GridItem] {
        let count = AppPlatform.usesDesktopWorkspace ? 4 : 3
        return Array(repeating: GridItem(.flexible(), spacing: AppSpacing.compact), count: count)
    }

    private var tileHeight: CGFloat { AppPlatform.usesDesktopWorkspace ? 76 : 68 }

    var body: some View {
        LazyVGrid(columns: columns, spacing: AppSpacing.compact) {
            tile(id: "none", title: String(localized: "None")) {
                Image(systemName: "nosign")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(AppColors.textTertiary)
            } action: {
                model.resetSpeedCurve()
            }

            tile(id: "custom", title: String(localized: "Custom")) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(AppColors.accent)
            } action: {
                onCustom()
            }

            ForEach(TimeRemap.presets) { preset in
                tile(id: preset.id, title: preset.title) {
                    SpeedPresetCurve(speeds: preset.previewSpeeds())
                } action: {
                    model.applySpeedPreset(preset)
                }
                .help(preset.detail)
            }
        }
    }

    @ViewBuilder
    private func tile<Content: View>(id: String, title: String,
                                     @ViewBuilder content: () -> Content,
                                     action: @escaping () -> Void) -> some View {
        let isSelected = selection == id
        Button(action: action) {
            VStack(spacing: AppSpacing.xSmall) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppCornerRadius.card)
                        .fill(AppColors.surfaceRaised)
                    content()
                        .padding(AppSpacing.small)
                }
                .frame(height: tileHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: AppCornerRadius.card)
                        .stroke(isSelected ? AppColors.accent : .clear, lineWidth: 2)
                )
                Text(title)
                    .font(AppTypography.caption)
                    .foregroundStyle(isSelected ? AppColors.textPrimary : AppColors.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            // The label is part of the target, not decoration beside it: on a
            // phone the tile alone is under the 44pt a finger needs.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// One preset's curve, drawn small.
///
/// Deliberately not a shrunken copy of the editor's graph: at this size axis
/// labels and a grid are noise. What survives is the one thing the shape has to
/// be read against — where normal speed is — as a solid centre line, with the
/// two dashed rules marking the range the curve is drawn across so two tiles
/// can be compared to each other.
struct SpeedPresetCurve: View {
    let speeds: [Double]

    /// The band the drawing spans, in the editor's own axis units.
    ///
    /// Fixed rather than fitted to each preset: a curve normalised to its own
    /// extremes would draw a gentle ramp and a violent one exactly the same,
    /// which is the one comparison these tiles exist to support.
    private static let lowerFraction = SpeedCurveGeometry.fraction(forSpeed: 0.1)
    private static let upperFraction = SpeedCurveGeometry.fraction(forSpeed: 8)

    var body: some View {
        Canvas { context, size in
            guard speeds.count > 1, size.width > 2, size.height > 2 else { return }
            let span = max(0.0001, Self.upperFraction - Self.lowerFraction)

            func y(_ speed: Double) -> CGFloat {
                let fraction = (SpeedCurveGeometry.fraction(forSpeed: speed) - Self.lowerFraction) / span
                return size.height * (1 - CGFloat(min(max(fraction, 0), 1)))
            }

            for speed in [8.0, 0.1] {
                var rule = Path()
                rule.move(to: CGPoint(x: 0, y: y(speed)))
                rule.addLine(to: CGPoint(x: size.width, y: y(speed)))
                context.stroke(rule, with: .color(AppColors.textTertiary.opacity(0.45)),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            var centre = Path()
            centre.move(to: CGPoint(x: 0, y: y(1)))
            centre.addLine(to: CGPoint(x: size.width, y: y(1)))
            context.stroke(centre, with: .color(AppColors.textTertiary.opacity(0.7)), lineWidth: 1)

            var curve = Path()
            for (index, speed) in speeds.enumerated() {
                let x = size.width * CGFloat(index) / CGFloat(speeds.count - 1)
                let point = CGPoint(x: x, y: y(speed))
                if index == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
            }
            context.stroke(curve, with: .color(AppColors.warning),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}
