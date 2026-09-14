import CoreMedia
import CoreVideo
import Foundation

// ---------------------------------------------------------------------------
// What a source *is*
//
// Three different questions were previously answered by two types, and the
// third had nowhere to live:
//
//   - `ProjectColorMode`      — what the project works and delivers in.
//   - `ColorPipelineSupport`  — what the app is able to do with a source.
//   - `SourceColorProfile`    — what the source actually is. This file.
//
// The distinction matters most for Log. A Log file's identity is *source colour
// management*, not a creative choice and not a project setting: it decides which
// input transform the decoded pixels need before any grading tool touches them.
// Keeping it in its own type is what stops it from leaking into `GradeSettings`,
// where a copied grade or a saved preset would carry one clip's source profile
// onto another clip's footage.
// ---------------------------------------------------------------------------

/// The colour encoding a source arrives in.
enum SourceColorProfile: Equatable, Sendable {
    /// 8-bit Rec.709, the path the app has always had.
    case rec709
    /// Rec.709 carried at more than 8 bits — ProRes, 10-bit HEVC.
    case rec709Wide(bitDepth: Int)
    /// HLG / BT.2020, 10-bit.
    case hlgBT2020
    /// Apple Log, `com.apple.rec2020.apple-log`: BT.2020 primaries with Apple's
    /// Log transfer curve.
    case appleLog
    /// Apple Log 2, `com.apple.apple-wide-gamut.apple-log`. Deliberately a
    /// separate case: the identifier itself shows this is not the same colour
    /// space wearing a new curve — Apple Log is Rec.2020-primaried and Apple
    /// Log 2 is Apple Wide Gamut, so the primaries differ as well as the
    /// transfer function. Running one through the other's transform would be
    /// wrong twice over.
    case appleLog2
    /// A Log format from some other vendor, identified but not understood.
    /// The identifier is carried so the UI can name it.
    case otherLog(identifier: String)
    /// Nothing conclusive in the file.
    case unknown

    /// True when the source needs a technical input transform before any
    /// creative grading is meaningful.
    var isLog: Bool {
        switch self {
        case .appleLog, .appleLog2, .otherLog: true
        case .rec709, .rec709Wide, .hlgBT2020, .unknown: false
        }
    }

    /// The name shown in Source Information and the scope labels.
    var displayName: String {
        switch self {
        case .rec709: "Rec.709"
        case .rec709Wide(let depth): "Rec.709 · \(depth)-bit"
        case .hlgBT2020: "HLG · BT.2020"
        case .appleLog: "Apple Log"
        case .appleLog2: "Apple Log 2"
        case .otherLog(let identifier): Self.readableLogName(identifier)
        case .unknown: "Unknown"
        }
    }

    /// The primaries the profile is defined against, where the profile itself
    /// establishes them. Never guessed from appearance: `nil` means the file has
    /// to say, and the reader's own tag is used instead.
    var definedPrimaries: String? {
        switch self {
        case .appleLog: "BT.2020"
        // Apple Log 2's identifier names Apple Wide Gamut. Its primaries are
        // not restated here as a number, because the app has no validated
        // definition of them and inventing one is exactly what this type exists
        // to prevent.
        case .appleLog2: "Apple Wide Gamut"
        case .hlgBT2020: "BT.2020"
        case .rec709, .rec709Wide: "BT.709"
        case .otherLog, .unknown: nil
        }
    }

    /// How the dynamic range reads in Source Information.
    var dynamicRangeLabel: String {
        switch self {
        case .appleLog, .appleLog2, .otherLog: "Log (scene-referred)"
        case .hlgBT2020: "HDR"
        case .rec709, .rec709Wide: "SDR"
        case .unknown: "Unknown"
        }
    }

    // MARK: - Detection

    /// Classifies a source from its own metadata, never from its filename, its
    /// codec, its bit depth or how flat it looks.
    ///
    /// Log is decided first and only by the file's Log identifier, which is the
    /// one signal that actually proves it. Everything else keeps the exact
    /// classification the app already had.
    static func detect(metadata: VideoMetadata) -> SourceColorProfile {
        if let identifier = metadata.logProfileIdentifier {
            return fromLogIdentifier(identifier)
        }
        // A file written before this app read the identifier still carries the
        // label the reader derived at import.
        if let legacyLabel = metadata.logTransferFunction {
            if legacyLabel == appleLogDisplayName { return .appleLog }
            if legacyLabel == appleLog2DisplayName { return .appleLog2 }
            return .otherLog(identifier: legacyLabel)
        }
        if metadata.transferFunction == "HLG", let depth = metadata.bitDepth, depth >= 10 {
            return .hlgBT2020
        }
        if let depth = metadata.bitDepth, depth > 8,
           ProjectColorMode.usesWidePrecisionSDR(for: metadata) {
            return .rec709Wide(bitDepth: depth)
        }
        if metadata.bitDepth == 8,
           metadata.colorPrimaries ?? "BT.709" == "BT.709",
           metadata.transferFunction ?? "BT.709" == "BT.709" {
            return .rec709
        }
        return .unknown
    }

    /// Maps an official Log identifier onto a profile.
    ///
    /// Compared against Apple's own constants rather than by sniffing for
    /// "log" in a string, so a vendor whose identifier happens to contain the
    /// word cannot be mistaken for Apple's.
    static func fromLogIdentifier(_ identifier: String) -> SourceColorProfile {
        if identifier == (kCMFormatDescriptionLogTransferFunction_AppleLog as String) {
            return .appleLog
        }
        if #available(iOS 26.0, *),
           identifier == (kCVImageBufferLogTransferFunction_AppleLog2 as String) {
            return .appleLog2
        }
        // Apple Log 2's constant only exists from iOS 26. On an earlier system
        // the identifier still arrives in the file, and misreading it as Apple
        // Log would be the exact confusion this type exists to prevent — so the
        // published value is matched literally, and only as a fallback.
        if identifier == appleLog2Identifier { return .appleLog2 }
        return .otherLog(identifier: identifier)
    }

    /// `kCVImageBufferLogTransferFunction_AppleLog2`, needed literally only for
    /// systems older than the constant. Documented rather than hidden.
    private static let appleLog2Identifier = "com.apple.apple-wide-gamut.apple-log"

    static let appleLogDisplayName = "Apple Log"
    static let appleLog2DisplayName = "Apple Log 2"

    /// Turns a reverse-DNS identifier into something readable when the format
    /// is one the app does not know: `com.example.fancy-log` → "fancy log".
    private static func readableLogName(_ identifier: String) -> String {
        let tail = identifier.split(separator: ".").last.map(String.init) ?? identifier
        let spaced = tail.replacingOccurrences(of: "-", with: " ")
        guard let first = spaced.first else { return identifier }
        return first.uppercased() + spaced.dropFirst()
    }
}
