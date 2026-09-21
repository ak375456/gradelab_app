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
    /// Verified 8-bit SDR with incomplete tags. Preview and export consistently
    /// interpret it as Rec.709 without modifying the source file.
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
    /// Apple Log 2: the same transfer function decoded into scene light, then a
    /// gamut conversion from Apple Wide Gamut into the BT.2020 working space the
    /// Apple Log path already grades and delivers in.
    case appleLog2Supported
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
            self = .appleLog2Supported
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
        if let matrix = metadata.yCbCrMatrix,
           matrix != "BT.709" {
            self = .unsupported(reason: "The \(matrix) YCbCr matrix is not yet supported for grading.")
            return
        }
        if metadata.colorPrimaries == nil
            || metadata.transferFunction == nil
            || metadata.yCbCrMatrix == nil {
            self = .assumedRec709
        } else {
            self = .supported
        }
    }

    /// Whether the grading tools may be used.
    var allowsGrading: Bool {
        switch self {
        case .supported, .assumedRec709, .hdrSupported, .sdrWideSupported,
             .appleLogSupported, .appleLog2Supported: true
        case .unsupported, .recognizedUnsupported: false
        }
    }

    /// Whether the editor may be opened and the source previewed. Wider than
    /// `allowsGrading`: an HLG source can be viewed before it can be graded.
    var allowsEditor: Bool {
        switch self {
        case .supported, .assumedRec709, .hdrSupported, .sdrWideSupported,
             .appleLogSupported, .appleLog2Supported: true
        case .unsupported, .recognizedUnsupported: false
        }
    }

    /// The colour mode a project for this source works in.
    var colorMode: ProjectColorMode {
        switch self {
        case .hdrSupported: .hdrHLG
        case .sdrWideSupported: .sdrWide
        case .appleLogSupported: .appleLog
        case .appleLog2Supported: .appleLog2
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
            String(localized: "This 8-bit SDR source has incomplete color tags. GradeLab uses the standard Rec.709 interpretation consistently for preview and export; the original file remains unchanged.")
        case .hdrSupported(let transfer):
            String(localized: "\(transfer) HDR is decoded, previewed and graded at full 10-bit precision. HDR export is still being validated and stays disabled until then — this source is never converted to SDR without you choosing it.")
        case .sdrWideSupported(let depth):
            String(localized: "This \(depth)-bit Rec.709 source is decoded, graded and exported at full precision — the colour handling is the same as any SDR clip, and nothing is reduced to 8-bit along the way.")
        case .appleLogSupported:
            String(localized: "Apple Log is decoded with Apple's published transfer function into scene light, graded there, and delivered as Rec.709. The log encoding is never graded directly.")
        case .appleLog2Supported:
            String(localized: "Apple Log 2 uses the same transfer function as Apple Log on wider primaries, so it is decoded to scene light, converted from Apple Wide Gamut to BT.2020, and graded and delivered exactly as Apple Log is. Colour beyond BT.2020 is carried through the grade and only clips at the final Rec.709 encode.")
        case .unsupported(let reason):
            reason
        case .recognizedUnsupported(_, let reason):
            reason
        }
    }
}
