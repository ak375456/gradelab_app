import Foundation

/// What the app can honestly do with a given source.
///
/// The distinction that matters: **opening and previewing a source is a
/// different capability from grading and exporting it.** Before HDR work began
/// these were the same thing, so a source that could not be graded could not be
/// opened at all. HLG sources can now be decoded and previewed at full
/// precision, while grading and export remain gated until their pipelines are
/// validated — so the two capabilities are reported separately rather than one
/// standing in for the other.
enum ColorPipelineSupport: Equatable, Sendable {
    /// Fully tagged 8-bit Rec.709. Everything is available.
    case supported
    /// 8-bit, incomplete tags. Preview interprets as Rec.709; export stays blocked.
    case assumedRec709
    /// HLG 10-bit. Decoded, previewed and graded at full precision. Export is
    /// still gated separately until the Main10 encode path exists, so the
    /// reason says that rather than implying the file is broken.
    case hdrSupported(transfer: String)
    /// Rec.709 SDR carried at more than 8 bits — ProRes, 10-bit HEVC. Same
    /// colour handling as `.supported`; the pipeline just keeps the precision.
    case sdrWideSupported(bitDepth: Int)
    /// Apple Log, decoded through Apple's published transfer function into
    /// scene-linear BT.2020 and graded there.
    case appleLogSupported
    /// No validated path. Blocked, with an actionable reason.
    case unsupported(reason: String)
    /// The source is identified exactly — the app knows precisely what it is —
    /// but the transform it needs is not implemented yet.
    ///
    /// Distinct from `unsupported` on purpose. "We do not know what this is" and
    /// "we know exactly what this is and cannot process it yet" are different
    /// facts, and telling someone the first when the second is true is a lie
    /// about their footage.
    case recognizedUnsupported(profile: SourceColorProfile, reason: String)

    init(metadata: VideoMetadata) {
        // Log sources need a technical input transform, which is a different
        // piece of work from HDR display. HLG is not Apple Log.
        //
        // Identified from the file's own Log identifier, so each format is named
        // for what it is rather than lumped together. None of them is routed
        // through another's transform.
        let profile = SourceColorProfile.detect(metadata: metadata)
        switch profile {
        case .appleLog:
            self = .appleLogSupported
            return
        case .appleLog2:
            self = .recognizedUnsupported(
                profile: profile,
                reason: "This is Apple Log 2 footage, which is not supported yet. It is a different colour space from Apple Log — wider primaries as well as a different curve — so it is never processed through the Apple Log transform."
            )
            return
        case .otherLog:
            self = .unsupported(
                reason: "This video uses the \(profile.displayName) profile, which GradeLab does not support. Only formats with a validated input transform are graded."
            )
            return
        case .rec709, .rec709Wide, .hlgBT2020, .unknown:
            break
        }

        // HLG is the only HDR transfer with a validated decode path. PQ/HDR10 and
        // anything else stays blocked: they are different transfer functions and
        // treating them as HLG would render them wrongly.
        if metadata.transferFunction == "HLG" {
            if let depth = metadata.bitDepth, depth >= 10 {
                self = .hdrSupported(transfer: "HLG")
            } else {
                self = .unsupported(reason: "This HLG source does not report a 10-bit depth, so its precision cannot be verified.")
            }
            return
        }
        // Key off the transfer function itself, not the derived `isHDR` flag: a
        // file can carry a PQ transfer with the HDR flag missing, and falling
        // through to the generic bit-depth message would tell the user the wrong
        // thing about why it was refused.
        if metadata.transferFunction == "PQ" || metadata.isHDR == true {
            let transfer = metadata.transferFunction ?? "HDR"
            self = .unsupported(reason: "\(transfer) sources are not supported yet. Only HLG has a validated HDR path; GradeLab will not treat \(transfer) as HLG or silently convert it to SDR.")
            return
        }

        // More than 8 bits of Rec.709 is not a colour problem, only a precision
        // one: the colour science is the same path 8-bit SDR has always used, so
        // it needs wider containers rather than a new transform.
        if let depth = metadata.bitDepth, depth > 8 {
            if ProjectColorMode.usesWidePrecisionSDR(for: metadata) {
                self = .sdrWideSupported(bitDepth: depth)
            } else {
                self = .unsupported(reason: "\(depth)-bit \(metadata.colorPrimaries ?? metadata.transferFunction ?? "wide-colour") sources need a validated input transform.")
            }
            return
        }
        guard metadata.bitDepth != nil else {
            self = .unsupported(reason: "The source bit depth could not be verified as 8-bit. Grading is disabled to avoid an unreported precision conversion.")
            return
        }
        if let primaries = metadata.colorPrimaries,
           primaries != "BT.709" {
            self = .unsupported(reason: "\(primaries) sources need a validated wide-color input transform.")
            return
        }
        if let transfer = metadata.transferFunction,
           transfer != "BT.709" {
            self = .unsupported(reason: "The \(transfer) transfer function is not yet supported for grading.")
            return
        }
        if metadata.colorPrimaries == nil || metadata.transferFunction == nil {
            self = .assumedRec709
        } else {
            self = .supported
        }
    }

    /// Whether the grading tools may be used.
    var allowsGrading: Bool {
        switch self {
        case .supported, .assumedRec709, .hdrSupported, .sdrWideSupported, .appleLogSupported: true
        case .unsupported, .recognizedUnsupported: false
        }
    }

    /// Whether the editor may be opened and the source previewed. Wider than
    /// `allowsGrading`: an HLG source can be viewed before it can be graded.
    var allowsEditor: Bool {
        switch self {
        case .supported, .assumedRec709, .hdrSupported, .sdrWideSupported, .appleLogSupported: true
        case .unsupported, .recognizedUnsupported: false
        }
    }

    /// The colour mode a project for this source works in.
    var colorMode: ProjectColorMode {
        switch self {
        case .hdrSupported: .hdrHLG
        case .sdrWideSupported: .sdrWide
        case .appleLogSupported: .appleLog
        case .supported, .assumedRec709, .unsupported, .recognizedUnsupported: .sdr
        }
    }

    /// True when the state is informational rather than a refusal, so the UI can
    /// pick an appropriate icon and tone.
    var isBlocking: Bool {
        switch self {
        case .unsupported, .recognizedUnsupported: true
        default: false
        }
    }

    /// The source profile this classification was made from, for UI that names
    /// the footage rather than only its status.
    var recognizedProfile: SourceColorProfile? {
        if case .recognizedUnsupported(let profile, _) = self { return profile }
        return nil
    }

    var notice: String? {
        switch self {
        case .supported:
            nil
        case .assumedRec709:
            "This 8-bit source is missing complete color tags. Preview uses an explicitly labeled Rec.709 compatibility interpretation; export remains blocked unless the file declares its color properties."
        case .hdrSupported(let transfer):
            "\(transfer) HDR is decoded, previewed and graded at full 10-bit precision. HDR export is still being validated and stays disabled until then — this source is never converted to SDR without you choosing it."
        case .sdrWideSupported(let depth):
            "This \(depth)-bit Rec.709 source is decoded, graded and exported at full precision — the colour handling is the same as any SDR clip, and nothing is reduced to 8-bit along the way."
        case .appleLogSupported:
            "Apple Log is decoded with Apple's published transfer function into scene light, graded there, and delivered as Rec.709. The log encoding is never graded directly."
        case .unsupported(let reason):
            reason
        case .recognizedUnsupported(_, let reason):
            reason
        }
    }
}
