import CoreGraphics
import Foundation

struct VideoMetadata: Codable, Equatable, Sendable {
    struct AffineTransform: Codable, Equatable, Sendable {
        let a: Double
        let b: Double
        let c: Double
        let d: Double
        let tx: Double
        let ty: Double

        init(_ transform: CGAffineTransform) {
            a = transform.a
            b = transform.b
            c = transform.c
            d = transform.d
            tx = transform.tx
            ty = transform.ty
        }

        var cgTransform: CGAffineTransform {
            CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
        }
    }

    let fileName: String
    let durationSeconds: Double
    let encodedWidth: Int
    let encodedHeight: Int
    let displayWidth: Int
    let displayHeight: Int
    let preferredTransform: AffineTransform
    let nominalFrameRate: Double?
    let minimumFrameDurationSeconds: Double?
    let codec: String
    let codecFourCC: String
    let estimatedBitrate: Double?
    let fileSize: Int64?
    let hasAudio: Bool
    let videoTrackCount: Int
    let audioTrackCount: Int
    let colorPrimaries: String?
    let transferFunction: String?
    let yCbCrMatrix: String?
    let logTransferFunction: String?
    /// The file's own Log identifier, a reverse-DNS string such as
    /// `com.apple.rec2020.apple-log`. Kept beside the display label because the
    /// label is for people and this is what classification compares against.
    /// Optional so projects saved before Log identification decode unchanged.
    let logProfileIdentifier: String?
    let isHDR: Bool?
    let bitDepth: Int?
    let creationDate: Date?

    var colorSummary: [String] {
        var values: [String] = []
        if let colorPrimaries { values.append(colorPrimaries) }
        if let transferFunction, !values.contains(transferFunction) { values.append(transferFunction) }
        if let logTransferFunction { values.append(logTransferFunction) }
        if isHDR == true { values.append("HDR") }
        return values
    }

    var displaySize: CGSize {
        CGSize(width: displayWidth, height: displayHeight)
    }

    var encodedSize: CGSize {
        CGSize(width: encodedWidth, height: encodedHeight)
    }

    var orientation: VideoOrientation {
        if displayWidth == displayHeight { return .square }
        return displayWidth > displayHeight ? .landscape : .portrait
    }

    var bestFrameRate: Double? {
        if let nominalFrameRate, nominalFrameRate > 0 { return nominalFrameRate }
        if let minimumFrameDurationSeconds, minimumFrameDurationSeconds > 0 {
            return 1 / minimumFrameDurationSeconds
        }
        return nil
    }

    // The three labels below are written as statics over plain numbers and
    // reached through instance properties. A project's canvas has dimensions and
    // a frame rate of its own — which, once a clip is trimmed, retimed or the
    // canvas resized, are not this source's — and it has to describe them with
    // exactly this wording. One definition, two callers.

    static func resolutionLabel(width: Int, height: Int) -> String {
        "\(width) × \(height)"
    }

    static func resolutionClass(width: Int, height: Int) -> String? {
        let long = max(width, height)
        let short = min(width, height)
        switch (long, short) {
        case (7680..., 4320...): return "8K"
        case (3840..., 2160...): return "4K"
        case (2560..., 1440...): return "1440p"
        case (1920..., 1080...): return "1080p"
        case (1280..., 720...): return "720p"
        default: return nil
        }
    }

    static func frameRateLabel(forFrameRate fps: Double?) -> String? {
        guard let fps, fps.isFinite, fps > 0 else { return nil }
        let rounded = fps.rounded()
        if abs(fps - rounded) < 0.01 {
            return String(format: "%.0f FPS", rounded)
        }
        return String(format: "%.2f FPS", fps)
    }

    var resolutionLabel: String {
        Self.resolutionLabel(width: displayWidth, height: displayHeight)
    }

    var resolutionClass: String? {
        Self.resolutionClass(width: displayWidth, height: displayHeight)
    }

    var frameRateLabel: String? {
        Self.frameRateLabel(forFrameRate: bestFrameRate)
    }

    var durationLabel: String {
        TimecodeFormatter.string(from: durationSeconds)
    }

    var bitrateLabel: String? {
        guard let estimatedBitrate, estimatedBitrate > 0 else { return nil }
        return String(format: "%.0f Mbps", estimatedBitrate / 1_000_000)
    }

    var fileSizeLabel: String? {
        guard let fileSize, fileSize > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

enum VideoOrientation: String, Codable, Sendable {
    case portrait
    case landscape
    case square
}

enum TimecodeFormatter {
    static func string(from seconds: Double, alwaysShowHours: Bool = false) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainingSeconds = total % 60
        if hours > 0 || alwaysShowHours {
            return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }
}
