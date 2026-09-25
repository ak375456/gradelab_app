import CoreGraphics
import Foundation

/// The maths the speed graph is drawn and dragged in, shared by every platform.
///
/// Nothing here knows about touches, pointers or SwiftUI. iPhone, iPad and Mac
/// all place a point at the same coordinate for the same speed, which is what
/// makes a ramp look the same wherever it was made.
struct SpeedCurveGeometry {
    /// The drawing area, already inset for the axis labels.
    let plot: CGRect
    /// The clip's whole timeline length.
    let duration: TimelineTime

    // MARK: - Vertical: speed

    /// Where the graph stops being fine-grained and starts compressing.
    ///
    /// The useful part of a speed graph is the slow half and the first few
    /// multiples of normal; 800% and 1600% matter far less per percent than
    /// 40% does. Splitting the axis at 4× and giving everything below it three
    /// quarters of the height keeps slow motion draggable at all, instead of
    /// squeezing the entire range 6%–400% into the bottom fifth because 1600%
    /// is technically representable.
    static let knee = 4.0
    static let kneeFraction = 0.75

    /// 0 at the bottom of the plot (slowest), 1 at the top (fastest).
    static func fraction(forSpeed speed: Double) -> Double {
        let value = ClipSpeed.clamped(speed)
        let low = log10(ClipSpeed.minimum), high = log10(ClipSpeed.maximum)
        let kneeLog = log10(knee), current = log10(value)
        if current <= kneeLog {
            guard kneeLog > low else { return 0 }
            return (current - low) / (kneeLog - low) * kneeFraction
        }
        guard high > kneeLog else { return kneeFraction }
        return kneeFraction + (current - kneeLog) / (high - kneeLog) * (1 - kneeFraction)
    }

    static func speed(forFraction fraction: Double) -> Double {
        let f = min(max(fraction, 0), 1)
        let low = log10(ClipSpeed.minimum), high = log10(ClipSpeed.maximum)
        let kneeLog = log10(knee)
        if f <= kneeFraction {
            guard kneeFraction > 0 else { return ClipSpeed.minimum }
            return ClipSpeed.clamped(pow(10, low + (f / kneeFraction) * (kneeLog - low)))
        }
        let above = (f - kneeFraction) / (1 - kneeFraction)
        return ClipSpeed.clamped(pow(10, kneeLog + above * (high - kneeLog)))
    }

    func y(forSpeed speed: Double) -> CGFloat {
        plot.maxY - plot.height * CGFloat(Self.fraction(forSpeed: speed))
    }

    func speed(forY y: CGFloat) -> Double {
        guard plot.height > 0 else { return ClipSpeed.normal }
        return Self.speed(forFraction: Double((plot.maxY - y) / plot.height))
    }

    /// The rates the graph rules and labels. Chosen rather than generated, so
    /// the lines land on numbers a person recognises.
    static let gridSpeeds: [Double] = [0.1, 0.25, 0.5, 1, 2, 4, 8, 16]

    // MARK: - Horizontal: time

    func x(forOffset offset: TimelineTime) -> CGFloat {
        let total = duration.seconds
        guard total > 0 else { return plot.minX }
        let fraction = min(max(offset.seconds / total, 0), 1)
        return plot.minX + plot.width * CGFloat(fraction)
    }

    func offset(forX x: CGFloat) -> TimelineTime {
        guard plot.width > 0 else { return .zero }
        let fraction = Double(min(max((x - plot.minX) / plot.width, 0), 1))
        return (try? TimelineTime.seconds(duration.seconds * fraction)) ?? .zero
    }

    func point(atOffset offset: TimelineTime, speed: Double) -> CGPoint {
        CGPoint(x: x(forOffset: offset), y: y(forSpeed: speed))
    }

    // MARK: - The drawn curve

    /// The curve as points across the plot, sampled from the map rather than
    /// from the speed points.
    ///
    /// Reading the map is what makes the drawing honest: it shows the rate the
    /// clip will actually play at, including the flat runs outside the first and
    /// last point and anything the rate limits clamped. A curve drawn straight
    /// from the authored points would show a ramp the clip does not have.
    func curve(from map: TimeMap, samples: Int = 240) -> [CGPoint] {
        guard plot.width > 1, duration.seconds > 0 else { return [] }
        let count = max(2, min(samples, Int(plot.width)))
        return (0...count).compactMap { step in
            let fraction = Double(step) / Double(count)
            guard let offset = try? TimelineTime.seconds(duration.seconds * fraction) else { return nil }
            return CGPoint(x: plot.minX + plot.width * CGFloat(fraction),
                           y: y(forSpeed: map.speed(atTimelineOffset: offset)))
        }
    }

    // MARK: - Hit testing

    /// How far a press may land from a point and still take it.
    ///
    /// A visible point is small, because a big one hides the curve it sits on.
    /// What it is grabbed by is not the same thing — a finger needs 40 points
    /// and a pointer needs about ten, and neither of those is a reason to draw
    /// a 40-point dot.
    static func hitRadius(forPointer: Bool) -> CGFloat { forPointer ? 11 : 22 }

    static let pointRadius: CGFloat = 5.5

    /// The point nearest a location, if any is within reach.
    func nearestPoint(to location: CGPoint, among points: [(id: UUID, position: CGPoint)],
                      pointer: Bool) -> UUID? {
        let radius = Self.hitRadius(forPointer: pointer)
        var best: (id: UUID, distance: CGFloat)?
        for point in points {
            let distance = hypot(point.position.x - location.x, point.position.y - location.y)
            guard distance <= radius else { continue }
            if best == nil || distance < best!.distance { best = (point.id, distance) }
        }
        return best?.id
    }
}
