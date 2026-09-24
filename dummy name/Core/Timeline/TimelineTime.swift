import CoreMedia
import Foundation

enum TimelineError: LocalizedError {
    case invalid(String)
    /// A document written by a newer build of the app.
    ///
    /// Kept apart from `.invalid` because the two need opposite handling on the
    /// way out of a store: `.invalid` means the bytes are damaged and the file
    /// is moved aside so the library can start again, while this means the file
    /// is fine and *we* are behind. Quarantining it would strand the user's work
    /// the moment they reinstalled the version that wrote it.
    case unsupportedVersion(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return String(localized: "Invalid project: \(reason)")
        case .unsupportedVersion(let reason): return reason
        }
    }
}

/// Persistent rational time. No conversion to seconds occurs during edit arithmetic.
/// Epochs, infinities and indefinite times are not valid document coordinates.
struct TimelineTime: Codable, Equatable, Comparable, Sendable {
    let value: Int64
    let timescale: Int32
    static let projectTimescale: Int32 = 240_000
    static let zero = try! TimelineTime(value: 0, timescale: 1)

    init(value: Int64, timescale: Int32) throws {
        guard timescale > 0 else { throw TimelineError.invalid(String(localized: "Time scale must be positive.")) }
        self.value = value
        self.timescale = timescale
    }

    init(_ time: CMTime) throws {
        guard time.isNumeric, time.epoch == 0 else { throw TimelineError.invalid(String(localized: "Time must be finite.")) }
        try self.init(value: time.value, timescale: time.timescale)
    }

    /// Only for UI input and migration of old documents that stored seconds.
    static func seconds(_ seconds: Double) throws -> Self {
        guard seconds.isFinite else { throw TimelineError.invalid(String(localized: "Time must be finite.")) }
        return try Self(CMTime(seconds: seconds, preferredTimescale: projectTimescale))
    }

    var cmTime: CMTime { CMTime(value: value, timescale: timescale) }
    var seconds: Double { cmTime.seconds }
    static func == (lhs: Self, rhs: Self) -> Bool { CMTimeCompare(lhs.cmTime, rhs.cmTime) == 0 }
    static func < (lhs: Self, rhs: Self) -> Bool { CMTimeCompare(lhs.cmTime, rhs.cmTime) < 0 }
    func adding(_ other: Self) throws -> Self { try exact(CMTimeAdd(cmTime, other.cmTime)) }
    func subtracting(_ other: Self) throws -> Self { try exact(CMTimeSubtract(cmTime, other.cmTime)) }
    private func exact(_ time: CMTime) throws -> Self {
        guard !time.flags.contains(.hasBeenRounded) else {
            throw TimelineError.invalid(String(localized: "Time arithmetic exceeded exact representation."))
        }
        return try Self(time)
    }

    private enum CodingKeys: String, CodingKey { case value, timescale }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(value: container.decode(Int64.self, forKey: .value),
                      timescale: container.decode(Int32.self, forKey: .timescale))
    }
}

struct TimelineRange: Codable, Equatable, Sendable {
    var start: TimelineTime
    var duration: TimelineTime
    var end: TimelineTime { get throws { try start.adding(duration) } }
    var cmTimeRange: CMTimeRange { CMTimeRange(start: start.cmTime, duration: duration.cmTime) }
}

struct ProjectCanvas: Codable, Equatable, Sendable {
    var width: Int
    var height: Int
    // nil means unknown: never silently substitute 30 FPS for an unknown source.
    var frameDuration: TimelineTime?
    var background = RGBAColor.black
    /// Optional so documents saved before this control keep decoding. Those
    /// projects already exported at the canvas size and cadence by default.
    var exportFollowsCanvas: Bool? = nil

    var usesCanvasExportSettings: Bool {
        get { exportFollowsCanvas ?? true }
        set { exportFollowsCanvas = newValue }
    }

    /// The canvas frame rate, or nil when the document does not know one.
    ///
    /// Nil is a real answer and is never replaced by a guess, for the same
    /// reason `frameDuration` is optional: a card that prints "30 FPS" over a
    /// project whose rate was never established is stating a fact it does not
    /// have.
    var frameRate: Double? {
        guard let frameDuration else { return nil }
        let seconds = frameDuration.seconds
        guard seconds.isFinite, seconds > 0 else { return nil }
        return 1 / seconds
    }

    /// Formatted the same way a source's rate is, so the project card and the
    /// source-information screen never spell the same number two ways.
    var frameRateLabel: String? { VideoMetadata.frameRateLabel(forFrameRate: frameRate) }

    var resolutionLabel: String { VideoMetadata.resolutionLabel(width: width, height: height) }

    var resolutionClass: String? { VideoMetadata.resolutionClass(width: width, height: height) }

    static func inferredFrameDuration(from metadata: VideoMetadata) -> TimelineTime? {
        if let fps = metadata.nominalFrameRate, fps.isFinite, fps > 0 {
            for numerator: Int32 in [24_000, 30_000, 60_000, 120_000] {
                if abs(fps - Double(numerator) / 1001) < 0.005 {
                    return try? TimelineTime(value: 1001, timescale: numerator)
                }
            }
            if abs(fps - fps.rounded()) < 0.0001, fps <= 1000 {
                return try? TimelineTime(value: 1, timescale: Int32(fps.rounded()))
            }
        }
        if let seconds = metadata.minimumFrameDurationSeconds, seconds > 0 {
            return try? TimelineTime.seconds(seconds)
        }
        return nil
    }
}
