import Foundation
import AVFoundation

/// User-selected delivery settings, checked against the device before encoding.
struct ExportConfiguration: Equatable, Sendable {
    enum Resolution: String, Codable, Sendable, CaseIterable {
        case original = "Original"
        case hd = "720p"
        case fullHD = "1080p"
        case ultraHD = "4K"
        case custom = "Custom"
    }

    enum FrameRate: String, Codable, Sendable, CaseIterable {
        case original = "Original"
        case fps24 = "24", fps25 = "25", fps30 = "30", fps50 = "50", fps60 = "60"
        var value: Double? { Double(rawValue) }
    }

    enum Codec: String, Codable, Sendable, CaseIterable {
        case hevc = "HEVC"
        case h264 = "H.264"
        /// Mastering formats. Intra-frame and near-lossless, so a graded file
        /// can go into another edit or grade without a generation of loss —
        /// which is the reason to have shot ProRes in the first place.
        case proRes422HQ = "ProRes 422 HQ"
        case proRes422 = "ProRes 422"

        var avCodec: AVVideoCodecType {
            switch self {
            case .hevc: .hevc
            case .h264: .h264
            case .proRes422HQ: .proRes422HQ
            case .proRes422: .proRes422
            }
        }

        /// The same codec as VideoToolbox names it, for the pre-flight probe.
        ///
        /// Deliberately exhaustive and sitting next to `avCodec`: the probe used
        /// to pick its codec with `codec == .hevc ? HEVC : H.264`, so both ProRes
        /// cases asked the hardware about H.264 — a question every device says
        /// yes to — and a ProRes export was never actually pre-flighted.
        var cmCodecType: CMVideoCodecType {
            switch self {
            case .hevc: kCMVideoCodecType_HEVC
            case .h264: kCMVideoCodecType_H264
            case .proRes422HQ: kCMVideoCodecType_AppleProRes422HQ
            case .proRes422: kCMVideoCodecType_AppleProRes422
            }
        }

        /// ProRes is constant-quality: it has no bitrate target to set, and
        /// offering one would be a control that does nothing.
        var usesBitRate: Bool {
            switch self {
            case .hevc, .h264: true
            case .proRes422HQ, .proRes422: false
            }
        }

        /// ProRes belongs in a QuickTime movie. MP4 has no standard mapping for
        /// it, and writing one produces a file most tools will not open.
        var requiresQuickTime: Bool { !usesBitRate }

        /// Roughly how many bits per second this ProRes flavour uses at 4K30,
        /// for the size estimate. ProRes rates are set by the format and the
        /// frame size, not chosen.
        var proResBitsPerPixelPerFrame: Double? {
            switch self {
            case .proRes422HQ: 0.85
            case .proRes422: 0.57
            case .hevc, .h264: nil
            }
        }

        var detail: String {
            switch self {
            case .hevc: String(localized: "Smaller files. Plays almost everywhere.")
            case .h264: String(localized: "Largest compatibility, larger files.")
            case .proRes422HQ: String(localized: "Mastering quality for further editing. Very large files.")
            case .proRes422: String(localized: "Mastering quality, somewhat smaller than HQ.")
            }
        }
    }

    enum QualityPreset: String, Codable, Sendable, CaseIterable {
        case maximum = "Maximum", high = "High", compact = "Smaller file"

        /// Display only. `rawValue` stays the persisted key so existing
        /// projects keep decoding.
        var title: String {
            switch self {
            case .maximum: String(localized: "Maximum")
            case .high: String(localized: "High")
            case .compact: String(localized: "Smaller file")
            }
        }
    }

    enum Container: String, CaseIterable, Sendable {
        case mov = "MOV", mp4 = "MP4"
        var fileType: AVFileType { self == .mov ? .mov : .mp4 }
        var fileExtension: String { rawValue.lowercased() }
    }

    var resolution: Resolution
    var frameRate: FrameRate
    var codec: Codec
    var qualityPreset: QualityPreset
    var container: Container = .mov
    var customLongEdge: Int = 1920

    /// Nil selects a resolution/FPS/codec-aware average bitrate from the quality preset.
    var videoBitRate: Int?

    /// AAC is used so decoded source audio is never silently discarded. 256 kbps is a
    /// high-quality default for the common mono/stereo tracks handled by this milestone.
    var audioBitRate: Int
    var optimizeForNetworkUse: Bool

    init(
        resolution: Resolution = .original,
        frameRate: FrameRate = .original,
        codec: Codec = .hevc,
        qualityPreset: QualityPreset = .maximum,
        videoBitRate: Int? = nil,
        audioBitRate: Int = 256_000,
        optimizeForNetworkUse: Bool = false
    ) {
        self.resolution = resolution
        self.frameRate = frameRate
        self.codec = codec
        self.qualityPreset = qualityPreset
        self.videoBitRate = videoBitRate
        self.audioBitRate = audioBitRate
        self.optimizeForNetworkUse = optimizeForNetworkUse
    }

    static let maximumQuality = ExportConfiguration()

    func dimensions(width: Int, height: Int) -> (width: Int, height: Int) {
        guard resolution != .original else { return (width, height) }
        let edge: Int
        switch resolution {
        case .original: return (width, height)
        case .hd: edge = 1280
        case .fullHD: edge = 1920
        case .ultraHD: edge = 3840
        case .custom: edge = customLongEdge
        }
        let scale = Double(edge) / Double(max(1, max(width, height)))
        return (max(2, Int((Double(width)*scale/2).rounded())*2),
                max(2, Int((Double(height)*scale/2).rounded())*2))
    }

    /// The container the file is actually written in, which the codec can
    /// override: ProRes is only meaningful in a QuickTime movie.
    var resolvedContainer: Container {
        codec.requiresQuickTime ? .mov : container
    }

    func resolvedBitRate(width: Int, height: Int, fps: Double?) -> Int {
        // ProRes rates come from the format itself. This is only used for the
        // size estimate; nothing is asked of the encoder.
        if let perPixel = codec.proResBitsPerPixelPerFrame {
            return Int(min(4_000_000_000, Double(width) * Double(height) * (fps ?? 30) * perPixel))
        }
        if let videoBitRate { return videoBitRate }
        let factor: Double = qualityPreset == .maximum ? 0.24 : qualityPreset == .high ? 0.14 : 0.07
        let codecFactor: Double = codec == .h264 ? 1.4 : 1
        return Int(min(240_000_000, max(2_000_000, Double(width)*Double(height)*(fps ?? 30)*factor*codecFactor)))
    }
}
