import Foundation

/// An app preference, independent of the project and its authored timing.
enum DurationDisplayFormat: String, CaseIterable, Identifiable, Sendable {
    case secondsAndMilliseconds
    case decimalSeconds
    case secondsAndFrames

    static let preferenceKey = "editor.durationDisplayFormat"
    static let defaultValue = Self.secondsAndMilliseconds
    var id: String { rawValue }

    var title: String {
        switch self {
        case .secondsAndMilliseconds: String(localized: "Seconds & milliseconds")
        case .decimalSeconds: String(localized: "Decimal seconds")
        case .secondsAndFrames: String(localized: "Seconds & frames")
        }
    }

    var explanation: String {
        switch self {
        case .secondsAndMilliseconds:
            String(localized: "Clear units for small durations. 1,000 milliseconds (ms) make 1 second (s).")
        case .decimalSeconds:
            String(localized: "0.60 s is 600 milliseconds. A full second is 1.00 s.")
        case .secondsAndFrames:
            String(localized: "f means frames. Values show the nearest frame at the project's frame rate.")
        }
    }
}

/// Pure presentation: changing format never rounds or rewrites stored time.
enum DurationText {
    static func string(from seconds: Double, format: DurationDisplayFormat = .defaultValue,
                       frameRate: Double? = nil) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < 1e12 else { return "—" }
        switch format {
        case .decimalSeconds:
            let value = ((seconds * 1_000).rounded() / 1_000)
                .formatted(.number.grouping(.never).precision(.fractionLength(2...3)))
            return String(localized: "\(value) s")
        case .secondsAndFrames:
            if let frameRate = validFrameRate(frameRate) {
                let nominalRate = max(1, Int(frameRate.rounded()))
                var wholeSeconds = Int64(seconds.rounded(.down))
                var frames = Int(((seconds - Double(wholeSeconds)) * frameRate).rounded())
                if frames >= nominalRate {
                    wholeSeconds += 1
                    frames = 0
                }
                let whole = wholeSeconds.formatted(.number.grouping(.never))
                let frame = frames.formatted(.number.grouping(.never).precision(.integerLength(2...)))
                return String(localized: "\(whole) s \(frame) f")
            }
            // An unknown project cadence is a real state, never a guessed FPS.
            return millisecondsString(from: seconds)
        case .secondsAndMilliseconds:
            return millisecondsString(from: seconds)
        }
    }

    static func validFrameRate(_ frameRate: Double?) -> Double? {
        guard let frameRate, frameRate.isFinite, frameRate > 0, frameRate <= 1_000 else { return nil }
        return frameRate
    }

    private static func millisecondsString(from seconds: Double) -> String {
        let totalMilliseconds = Int64((seconds * 1_000).rounded())
        let whole = (totalMilliseconds / 1_000).formatted(.number.grouping(.never))
        let milliseconds = (totalMilliseconds % 1_000).formatted(.number.grouping(.never))
        if totalMilliseconds == 0 || totalMilliseconds.isMultiple(of: 1_000) {
            return String(localized: "\(whole) s")
        }
        if totalMilliseconds < 1_000 {
            return String(localized: "\(milliseconds) ms")
        }
        return String(localized: "\(whole) s \(milliseconds) ms")
    }
}

/// Only slider drags snap. Exact entry and saved durations retain their precision.
enum SliderSnap {
    static func value(_ proposed: Double, in range: ClosedRange<Double>, points: [Double]) -> Double {
        let clamped = min(range.upperBound, max(range.lowerBound, proposed))
        let tolerance = min(0.075, (range.upperBound - range.lowerBound) * 0.02)
        guard let nearest = points.filter({ range.contains($0) })
            .min(by: { abs($0 - clamped) < abs($1 - clamped) }),
              abs(nearest - clamped) <= tolerance else { return clamped }
        return nearest
    }
}
