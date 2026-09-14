import Foundation

/// UI-only geometry. None of these values are written to the project document.
struct TimelineViewport {
    static let zoomRange = 4.0...2400.0
    var pixelsPerSecond: Double = 48
    var width: Double
    var offset: Double

    func x(for seconds: Double) -> Double { width / 2 + seconds * pixelsPerSecond - offset }
    func seconds(at x: Double, duration: Double) -> Double {
        min(duration, max(0, (x - width / 2 + offset) / pixelsPerSecond))
    }
    var rulerInterval: Double {
        let target = 70 / pixelsPerSecond
        let magnitude = pow(10, floor(log10(target)))
        return ([1.0, 2, 5, 10].first { $0 * magnitude >= target } ?? 10) * magnitude
    }
}
