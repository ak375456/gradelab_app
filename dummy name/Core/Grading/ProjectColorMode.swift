import Foundation

/// The colour space a project works and outputs in.
///
/// This is a deliberate, persisted property of the project rather than something
/// inferred per frame, because preview, compositing and export must all obey the
/// same rule. Inferring it would let the preview and the exported file disagree.
///
/// The two modes are separate pipelines on purpose. `.sdr` is the pipeline that
/// shipped before HDR work began and is not modified by it, which is what makes
/// "existing projects look exactly as they did" a structural guarantee instead of
/// something to re-verify by eye.
enum ProjectColorMode: String, Codable, Equatable, Sendable, CaseIterable {
    /// 8-bit Rec.709 SDR. The original pipeline, unchanged.
    case sdr
    /// Rec.709 SDR carried at more than 8 bits — ProRes, 10-bit HEVC and the
    /// like. Identical colour science to `.sdr`; only the containers are wider,
    /// so nothing about the look changes, only what precision survives.
    case sdrWide
    /// BT.2100 HLG / BT.2020 source, worked on in extended-range linear.
    case hdrHLG
    /// Apple Log source. Decoded through Apple's published transfer function
    /// into the same extended-range linear working space `.hdrHLG` uses — the
    /// grading stage is shared — and delivered as Rec.709 SDR through Apple's
    /// own display rendering. Log is an input format here, never an output.
    case appleLog
    /// Apple Log 2 source — the Apple Log curve on Apple Wide Gamut primaries.
    ///
    /// A separate case rather than a flavour of `.appleLog`, for the same reason
    /// `.sdrWide` is separate from `.sdr`: the two share their working space,
    /// their grading stage and their delivery exactly, and differ only in the
    /// input transform. Keeping them distinct is what makes every switch in the
    /// app state which one it means, and what stops a Log 2 clip from being
    /// decoded through BT.2020 primaries because a check said `== .appleLog`.
    case appleLog2

    /// The label shown to a person choosing between them.
    var title: String {
        switch self {
        case .sdr, .sdrWide: "Convert to SDR"
        case .hdrHLG: "Keep HDR"
        case .appleLog: "Apple Log"
        case .appleLog2: "Apple Log 2"
        }
    }

    /// One line, no colour science. The detail lives in Source Information.
    var explanation: String {
        switch self {
        case .sdr, .sdrWide: "Creates a standard video for SDR viewing."
        case .hdrHLG: "Preserves HDR brightness and colour on compatible displays."
        case .appleLog: "Decodes Apple Log to scene light for grading, and delivers Rec.709."
        case .appleLog2: "Decodes Apple Log 2 to scene light for grading, and delivers Rec.709."
        }
    }

    /// Short badge for the editor and export summary.
    var badge: String {
        switch self {
        case .sdr: "SDR"
        case .sdrWide: "10-bit SDR"
        case .hdrHLG: "HDR"
        case .appleLog: "APPLE LOG"
        case .appleLog2: "APPLE LOG 2"
        }
    }

    var isHDR: Bool { self == .hdrHLG }

    /// True for both Log modes.
    ///
    /// Almost every question the pipeline asks about Log — which decoder format
    /// to request, whether Apple's rendering LUT is needed, whether this frame
    /// is camera code values rather than a picture — has the same answer for
    /// both, because after the input transform they are the same signal. Only
    /// the handful of places that choose the input transform itself need to
    /// tell them apart, and those switch on the case.
    var isAppleLog: Bool { self == .appleLog || self == .appleLog2 }
}

extension ProjectColorMode {
    /// The mode a newly imported source should default to.
    ///
    /// Only HLG is offered as HDR. PQ/HDR10 and Dolby Vision still have no
    /// validated path and must keep failing their existing checks rather than
    /// being quietly treated as HLG — they are different transfer functions and
    /// would render wrongly. Apple Log has its own mode and its own transform.
    static func `default`(for metadata: VideoMetadata) -> ProjectColorMode {
        switch SourceColorProfile.detect(metadata: metadata) {
        case .appleLog: return .appleLog
        case .appleLog2: return .appleLog2
        default: break
        }
        if canPreserveHDR(for: metadata) { return .hdrHLG }
        if usesWidePrecisionSDR(for: metadata) { return .sdrWide }
        return .sdr
    }

    /// Rec.709 colour carried at more than 8 bits. Depth alone is not enough:
    /// a 10-bit PQ or wide-gamut source is a colour problem, not a precision
    /// one, and must not be routed here just because it is deep.
    static func usesWidePrecisionSDR(for metadata: VideoMetadata) -> Bool {
        guard metadata.logTransferFunction == nil else { return false }
        guard let depth = metadata.bitDepth, depth > 8 else { return false }
        guard metadata.isHDR != true else { return false }
        let primariesOK = metadata.colorPrimaries == nil || metadata.colorPrimaries == "BT.709"
        let transferOK = metadata.transferFunction == nil || metadata.transferFunction == "BT.709"
        return primariesOK && transferOK
    }

    /// True when the pipeline must carry more than 8 bits. Colour handling is
    /// unchanged; only the decode, composition and encode containers widen.
    var isWidePrecision: Bool { self == .sdrWide || self == .hdrHLG || isAppleLog }

    /// Whether "Keep HDR" is a genuine option for this source.
    static func canPreserveHDR(for metadata: VideoMetadata) -> Bool {
        guard metadata.logTransferFunction == nil else { return false }
        guard metadata.transferFunction == "HLG" else { return false }
        guard let depth = metadata.bitDepth, depth >= 10 else { return false }
        return true
    }
}
