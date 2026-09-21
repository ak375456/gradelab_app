import UIKit

/// Everything drawn around the clips: lanes, the ruler, markers, transition
/// handles, the snap indicator and the playhead.
///
/// Each entry point takes resolved geometry rather than the timeline itself,
/// for the same reason `TimelineClipRenderer` does — a new kind of row or
/// overlay marker can reuse these without the renderer learning about it.
struct TimelineChromeRenderer {
    let context: CGContext
    let canvas: CGRect
    let geometry: TimelineViewport
    /// Left edge of the scrolling content: the track headers sit to the left
    /// of it and nothing else may draw underneath them.
    let contentLeft: CGFloat

    private var contentRect: CGRect {
        CGRect(x: contentLeft, y: 0, width: max(0, canvas.width - contentLeft), height: canvas.height)
    }

    // MARK: - Lanes

    /// The empty channel behind a row, so a track reads as a lane that
    /// continues past its last clip rather than as floating rectangles.
    func drawLane(_ rect: CGRect, isDropTarget: Bool = false) {
        let visible = rect.intersection(contentRect)
        guard visible.width > 0, visible.height > 0 else { return }
        context.saveGState()
        context.addPath(UIBezierPath(roundedRect: visible, cornerRadius: TimelineMetrics.clipCornerRadius).cgPath)
        context.setFillColor(TimelineTheme.lane.cgColor)
        context.fillPath()
        if isDropTarget {
            context.addPath(UIBezierPath(roundedRect: visible.insetBy(dx: 1, dy: 1),
                                         cornerRadius: TimelineMetrics.clipCornerRadius).cgPath)
            context.setStrokeColor(TimelineTheme.accent.withAlphaComponent(0.85).cgColor)
            context.setLineWidth(1.5)
            context.setLineDash(phase: 0, lengths: [5, 4])
            context.strokePath()
        }
        context.restoreGState()
    }

    // MARK: - Ruler

    /// Labels above, ticks below, at a density the zoom actually resolves.
    /// Clipped to the content area so nothing prints over the track headers.
    func drawRuler(scale: TimelineRulerScale, duration: Double) {
        let band = CGRect(x: 0, y: 0, width: canvas.width, height: TimelineMetrics.rulerHeight)
        context.saveGState()
        context.setFillColor(TimelineTheme.background.cgColor)
        context.fill(band)
        context.clip(to: CGRect(x: contentLeft, y: 0,
                                width: max(0, canvas.width - contentLeft),
                                height: TimelineMetrics.rulerHeight))

        let start = max(0, geometry.seconds(at: contentLeft, duration: duration) - scale.major)
        let end = min(duration + scale.major, geometry.seconds(at: canvas.width, duration: duration) + scale.major)
        let baseline = TimelineMetrics.rulerHeight - 1
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: TimelineTheme.textSecondary
        ]

        scale.forEachTick(from: start, to: end) { time, kind in
            let x = (geometry.x(for: time)).rounded() + 0.5
            guard x >= contentLeft - 40, x <= canvas.width + 40 else { return }
            let top: CGFloat
            let color: UIColor
            switch kind {
            case .major: top = baseline - 11; color = UIColor(white: 0.52, alpha: 1)
            case .minor: top = baseline - 6; color = UIColor(white: 0.32, alpha: 1)
            case .frame: top = baseline - 3.5; color = UIColor(white: 0.24, alpha: 1)
            }
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: x, y: top))
            context.addLine(to: CGPoint(x: x, y: baseline))
            context.strokePath()

            guard kind == .major else { return }
            let label = scale.label(for: time) as NSString
            let size = label.size(withAttributes: labelAttributes)
            // Centred over its tick, and dropped entirely rather than nudged
            // when it would not fit: a label slid inside the content edge
            // would sit over a time it does not belong to.
            let origin = x - size.width / 2
            guard origin >= contentLeft else { return }
            label.draw(at: CGPoint(x: origin, y: 3), withAttributes: labelAttributes)
        }

        context.setFillColor(TimelineTheme.separator.cgColor)
        context.fill(CGRect(x: contentLeft, y: TimelineMetrics.rulerHeight - 0.5,
                            width: canvas.width - contentLeft, height: 0.5))
        context.restoreGState()
    }

    // MARK: - Markers and transitions

    func drawMarker(at x: CGFloat) {
        guard x >= contentLeft else { return }
        let y = TimelineMetrics.rulerHeight - 22
        context.setFillColor(TimelineTheme.markerFill.cgColor)
        context.move(to: CGPoint(x: x, y: y))
        context.addLine(to: CGPoint(x: x + 5, y: y + 5))
        context.addLine(to: CGPoint(x: x, y: y + 10))
        context.addLine(to: CGPoint(x: x - 5, y: y + 5))
        context.closePath()
        context.fillPath()
    }

    func drawTransition(at point: CGPoint, isSelected: Bool) {
        guard point.x >= contentLeft - 14 else { return }
        let radius: CGFloat = isSelected ? 10 : 8
        context.saveGState()
        context.setShadow(offset: .zero, blur: 4, color: UIColor.black.withAlphaComponent(0.8).cgColor)
        let diamond = CGMutablePath()
        diamond.move(to: CGPoint(x: point.x, y: point.y - radius))
        diamond.addLine(to: CGPoint(x: point.x + radius, y: point.y))
        diamond.addLine(to: CGPoint(x: point.x, y: point.y + radius))
        diamond.addLine(to: CGPoint(x: point.x - radius, y: point.y))
        diamond.closeSubpath()
        context.addPath(diamond)
        context.setFillColor((isSelected ? TimelineTheme.accent : UIColor(white: 0.92, alpha: 1)).cgColor)
        context.fillPath()
        context.addPath(diamond)
        context.setStrokeColor(UIColor.black.withAlphaComponent(0.8).cgColor)
        context.setLineWidth(1.5)
        context.strokePath()
        context.restoreGState()
    }

    // MARK: - Snapping

    /// The subtle cyan line that says an edge has just latched onto something.
    /// Drawn the full height of the rows so it is visible whichever row the
    /// edge belongs to.
    func drawSnapIndicator(at x: CGFloat) {
        guard x >= contentLeft - 1, x <= canvas.maxX + 1 else { return }
        context.saveGState()
        context.setShadow(offset: .zero, blur: 5, color: TimelineTheme.accentBright.withAlphaComponent(0.7).cgColor)
        context.setFillColor(TimelineTheme.accentBright.withAlphaComponent(0.85).cgColor)
        context.fill(CGRect(x: x - 0.75, y: TimelineMetrics.rulerHeight - 6,
                            width: 1.5, height: canvas.height - TimelineMetrics.rulerHeight + 6))
        context.restoreGState()
        // Small caps top and bottom, the visual shorthand for a magnet latch.
        context.setFillColor(TimelineTheme.accentBright.cgColor)
        for y in [TimelineMetrics.rulerHeight - 6, canvas.height - 3] {
            context.fill(CGRect(x: x - 3, y: y, width: 6, height: 3))
        }
    }

    /// The insertion line shown while a clip is being dragged into a gap.
    func drawInsertionLine(x: CGFloat, top: CGFloat, height: CGFloat) {
        context.saveGState()
        context.setFillColor(TimelineTheme.accent.cgColor)
        context.fill(CGRect(x: x - 1.5, y: top, width: 3, height: height))
        context.restoreGState()
    }

    func drawMarquee(_ rect: CGRect) {
        context.saveGState()
        context.setFillColor(TimelineTheme.accent.withAlphaComponent(0.12).cgColor)
        context.fill(rect)
        context.setStrokeColor(TimelineTheme.accent.withAlphaComponent(0.95).cgColor)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [5, 3])
        context.stroke(rect.insetBy(dx: 0.75, dy: 0.75))
        context.restoreGState()
    }

    // MARK: - Playhead

    private static let bubbleAttributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
        .foregroundColor: UIColor.white
    ]

    /// `mm:ss.t` — the precision a bubble this size can actually carry, and
    /// what the reference design shows. The transport keeps the full
    /// frame-accurate timecode.
    static func bubbleText(for seconds: Double) -> String {
        let clamped = max(0, seconds)
        let total = Int(clamped)
        let tenths = Int((clamped - Double(total)) * 10)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours > 0
            ? String(format: "%d:%02d:%02d.%d", hours, minutes, total % 60, tenths)
            : String(format: "%02d:%02d.%d", minutes, total % 60, tenths)
    }

    /// A thin white line with a round grab knob and a floating timecode
    /// bubble. Called last, so it is always above clips, waveforms and lanes.
    func drawPlayhead(at x: CGFloat, time: Double, isScrubbing: Bool) {
        let line = x.rounded() + 0.5
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 0), blur: 3,
                          color: UIColor.black.withAlphaComponent(0.85).cgColor)
        context.setFillColor(TimelineTheme.playheadLine.cgColor)
        context.fill(CGRect(x: line - TimelineMetrics.playheadWidth / 2,
                            y: TimelineMetrics.timecodeBubbleHeight,
                            width: TimelineMetrics.playheadWidth,
                            height: canvas.height - TimelineMetrics.timecodeBubbleHeight))
        context.restoreGState()

        // Knob, sitting on the ruler's baseline where a finger can find it.
        let knobCentre = CGPoint(x: line, y: TimelineMetrics.rulerHeight - 1)
        let radius = TimelineMetrics.playheadKnobRadius + (isScrubbing ? 1 : 0)
        context.setFillColor(TimelineTheme.playheadLine.cgColor)
        context.fillEllipse(in: CGRect(x: knobCentre.x - radius, y: knobCentre.y - radius,
                                       width: radius * 2, height: radius * 2))
        context.setStrokeColor(TimelineTheme.background.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(1.5)
        context.strokeEllipse(in: CGRect(x: knobCentre.x - radius, y: knobCentre.y - radius,
                                         width: radius * 2, height: radius * 2))

        drawTimecodeBubble(text: Self.bubbleText(for: time), centeredAt: line)
    }

    private func drawTimecodeBubble(text: String, centeredAt x: CGFloat) {
        let string = text as NSString
        let size = string.size(withAttributes: Self.bubbleAttributes)
        let width = size.width + 18
        let height = TimelineMetrics.timecodeBubbleHeight
        let origin = min(max(contentLeft, x - width / 2), max(contentLeft, canvas.width - width))
        let bubble = CGRect(x: origin, y: 0, width: width, height: height)
        context.saveGState()
        context.addPath(UIBezierPath(roundedRect: bubble, cornerRadius: height / 2).cgPath)
        context.setFillColor(TimelineTheme.playheadBubble.cgColor)
        context.fillPath()
        string.draw(at: CGPoint(x: bubble.midX - size.width / 2, y: bubble.midY - size.height / 2),
                    withAttributes: Self.bubbleAttributes)
        context.restoreGState()
    }
}
