import Foundation

/// What an export is going to cost: how large the file will be, and — once it
/// is running — how much longer it has to go.
///
/// The size is arithmetic, not a guess: the encoder is given an average target
/// bitrate, so the file lands near `bitrate × duration`. It is still an
/// estimate — a variable-bitrate encoder spends fewer bits on simple footage —
/// so everything here is labelled as approximate rather than presented as a
/// promise.
///
/// The time remaining is not predictable before the export starts: it depends
/// on the device, the codec, the resolution and how much grading work each
/// frame carries. So it is measured rather than forecast — from how long the
/// export has actually taken so far.
struct ExportEstimate: Equatable, Sendable {
    /// Expected output size in bytes.
    let byteCount: Int64
    /// Timeline length being written, in seconds.
    let durationSeconds: TimeInterval

    /// "≈ 2.4 GB". `ByteCountFormatter` picks the unit, so a short clip reads
    /// in MB rather than "0.02 GB".
    var sizeLabel: String {
        "≈ " + ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    /// Total bits per second the writer is being asked for, video plus audio.
    static func totalBitRate(
        configuration: ExportConfiguration,
        width: Int,
        height: Int,
        fps: Double?,
        audioTrackCount: Int
    ) -> Int {
        let video = configuration.resolvedBitRate(width: width, height: height, fps: fps)
        return video + configuration.audioBitRate * max(0, audioTrackCount)
    }

    /// The expected size of an export with these settings.
    static func make(
        configuration: ExportConfiguration,
        canvasWidth: Int,
        canvasHeight: Int,
        fps: Double?,
        durationSeconds: TimeInterval,
        audioTrackCount: Int
    ) -> ExportEstimate? {
        guard durationSeconds > 0, canvasWidth > 0, canvasHeight > 0 else { return nil }
        let dimensions = configuration.dimensions(width: canvasWidth, height: canvasHeight)
        let bitRate = totalBitRate(
            configuration: configuration,
            width: dimensions.width,
            height: dimensions.height,
            fps: fps,
            audioTrackCount: audioTrackCount
        )
        let bytes = Double(bitRate) / 8 * durationSeconds
        guard bytes.isFinite, bytes > 0 else { return nil }
        return ExportEstimate(byteCount: Int64(bytes), durationSeconds: durationSeconds)
    }
}

// ---------------------------------------------------------------------------
// Time remaining
// ---------------------------------------------------------------------------

/// Turns elapsed time and progress into a remaining-time estimate.
///
/// Two things keep it from being annoying: it says nothing at all until the
/// export is far enough along for the number to mean something, and it smooths
/// what it reports, because the raw figure swings wildly whenever the encoder
/// hits a stretch of harder frames.
struct ExportTimeRemaining: Sendable {
    /// Below this fraction, or before this many seconds have passed, the
    /// estimate is noise and nothing is shown.
    private static let minimumFraction = 0.03
    private static let minimumElapsed: TimeInterval = 1.5
    /// How much of the new reading to take each update. Low enough to settle
    /// the number, high enough to react when the encode genuinely slows down.
    private static let smoothing = 0.25

    private var smoothed: TimeInterval?

    /// Updates from the export's own progress, returning what to display, or
    /// nil while it is still too early to say.
    mutating func update(fractionCompleted: Double, elapsed: TimeInterval) -> TimeInterval? {
        guard fractionCompleted >= Self.minimumFraction,
              fractionCompleted < 1,
              elapsed >= Self.minimumElapsed else { return nil }
        let total = elapsed / fractionCompleted
        let raw = max(0, total - elapsed)
        guard raw.isFinite else { return nil }
        let value = smoothed.map { $0 + (raw - $0) * Self.smoothing } ?? raw
        smoothed = value
        return value
    }

    mutating func reset() { smoothed = nil }

    /// "About 2 min remaining". Deliberately coarse: a to-the-second countdown
    /// on a number this approximate would be a false precision.
    static func label(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        if seconds < 10 { return "Almost done" }
        if seconds < 60 { return "About \(Int((seconds / 5).rounded()) * 5) sec remaining" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "About \(minutes) min remaining" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0
            ? "About \(hours) hr remaining"
            : "About \(hours) hr \(rest) min remaining"
    }
}
