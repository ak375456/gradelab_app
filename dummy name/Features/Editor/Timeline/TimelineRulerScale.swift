import Foundation

/// Which tick a ruler position carries. The renderer maps these to a height
/// and a colour; the scale itself only decides where they fall.
enum TimelineTickKind {
    /// A labelled tick.
    case major
    /// An unlabelled subdivision of a major interval.
    case minor
    /// One source frame. Only offered once frames are far enough apart to be
    /// worth reading individually.
    case frame
}

/// The ruler's tick ladder for a given zoom.
///
/// Pure value logic, deliberately separate from drawing: the interval choice
/// is the part that has to be right at every zoom from four pixels a second to
/// a frame twenty points wide, and it is far easier to prove in a test than on
/// screen.
struct TimelineRulerScale: Equatable {
    /// Seconds between labelled ticks.
    let major: Double
    /// Seconds between unlabelled ticks. Equal to `major` when the zoom is too
    /// low for subdivisions to read as anything but noise.
    let minor: Double
    /// Seconds between frame ticks, or nil when frames are too close together
    /// to draw.
    let frame: Double?

    /// Editor-conventional intervals rather than a bare decade ladder: a
    /// timeline that steps 15s → 30s → 1m → 5m reads like a timeline, while one
    /// that steps 10s → 20s → 50s reads like a chart axis.
    private static let ladder: [Double] = [
        0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30,
        60, 120, 300, 600, 900, 1800, 3600, 7200
    ]

    /// How many pieces each ladder entry divides into. Chosen so a subdivision
    /// is always a round number of seconds or frames of its parent.
    private static func subdivisions(of interval: Double) -> Int {
        switch interval {
        case 2, 120, 7200: 4
        case 15, 900: 3
        case 30, 1800: 6
        case 60: 4
        default: 5
        }
    }

    /// The narrowest a labelled interval may get before the next rung is used.
    /// Labels are about 40pt wide, so 78 leaves a comfortable gap between them.
    static let targetLabelSpacing: Double = 78
    /// Minor ticks closer together than this stop separating anything.
    static let minimumMinorSpacing: Double = 7
    /// Frame ticks appear only once a frame is at least this wide. Higher
    /// than the minor spacing on purpose: a frame ruler is information, and at
    /// seven points apart it becomes texture.
    static let minimumFrameSpacing: Double = 9

    init(pixelsPerSecond: Double, frameDuration: Double = 0) {
        let scale = max(0.0001, pixelsPerSecond)
        let wanted = Self.targetLabelSpacing / scale
        let major = Self.ladder.first { $0 >= wanted } ?? Self.ladder[Self.ladder.count - 1]
        self.major = major

        // Step down through the subdivision count until the ticks are far
        // enough apart to be legible, rather than drawing a grey smear.
        var minor = major
        let pieces = Self.subdivisions(of: major)
        for divisor in [pieces, pieces / 2, 2] where divisor > 1 {
            let candidate = major / Double(divisor)
            if candidate * scale >= Self.minimumMinorSpacing { minor = candidate; break }
        }
        self.minor = minor

        // A frame tick is only meaningful when it is finer than the minor
        // ladder and wide enough to aim at.
        if frameDuration > 0, frameDuration < minor * 0.9,
           frameDuration * scale >= Self.minimumFrameSpacing {
            frame = frameDuration
        } else {
            frame = nil
        }
    }

    /// Walks the visible ticks from coarsest to finest, skipping any position
    /// a coarser level already claimed. No array is built: this runs on every
    /// scroll tick, and a ruler should not allocate to scroll.
    func forEachTick(from start: Double, to end: Double,
                     _ body: (Double, TimelineTickKind) -> Void) {
        guard end >= start, major > 0 else { return }
        let levels: [(Double, TimelineTickKind)] = [
            (major, .major),
            (minor == major ? nil : minor, .minor),
            (frame, .frame)
        ].compactMap { interval, kind in interval.map { ($0, kind) } }

        for (index, level) in levels.enumerated() {
            let (interval, kind) = level
            guard interval > 0 else { continue }
            let count = Int(((end - start) / interval).rounded(.down)) + 1
            guard count > 0, count < 20_000 else { continue }
            var step = (start / interval).rounded(.up)
            for _ in 0...count {
                let time = step * interval
                step += 1
                guard time >= start - 1e-9, time <= end + 1e-9 else { continue }
                // A coarser level already drew this position; drawing it twice
                // makes a minor tick look like a major one.
                let claimed = levels.prefix(index).contains { coarser, _ in
                    let ratio = time / coarser
                    return abs(ratio - ratio.rounded()) < 1e-6
                }
                if !claimed { body(time, kind) }
            }
        }
    }

    /// The label for a major tick, at the precision this zoom actually
    /// resolves. Sub-second intervals gain decimals; nothing above a second
    /// pretends to more precision than it has.
    ///
    /// Assembled from integer fields rather than from a `%f` width, because a
    /// zero-padded float width pads with a space here and produced "00: 2.5".
    func label(for seconds: Double) -> String {
        let clamped = max(0, seconds)
        if major >= 1 {
            let whole = Int(clamped.rounded())
            let hours = whole / 3600
            return hours > 0
                ? String(format: "%d:%02d:%02d", hours, (whole % 3600) / 60, whole % 60)
                : String(format: "%02d:%02d", whole / 60, whole % 60)
        }
        let unit = major >= 0.1 ? 10 : 100
        let ticks = Int((clamped * Double(unit)).rounded())
        let whole = ticks / unit
        let hours = whole / 3600
        let body = unit == 10
            ? String(format: "%02d:%02d.%01d", (whole % 3600) / 60, whole % 60, ticks % unit)
            : String(format: "%02d:%02d.%02d", (whole % 3600) / 60, whole % 60, ticks % unit)
        return hours > 0 ? String(format: "%d:", hours) + body : body
    }
}
