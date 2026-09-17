@preconcurrency import AVFoundation
import CoreVideo
import Foundation
import VideoToolbox

enum ExportMediaSettings {
    static func validate(_ configuration: ExportConfiguration) throws {
        guard configuration.resolution != .custom || (64...7680).contains(configuration.customLongEdge) else {
            throw GradeLabError.unsupportedExport(String(localized: "Enter a longest edge from 64 to 7680 pixels."))
        }
        if let videoBitRate = configuration.videoBitRate, videoBitRate <= 0 {
            throw GradeLabError.unsupportedExport(String(localized: "The requested video bit rate must be greater than zero."))
        }
        guard configuration.audioBitRate > 0 else {
            throw GradeLabError.unsupportedExport(String(localized: "The requested audio bit rate must be greater than zero."))
        }
    }

    static func videoWriterSettings(
        source: ExportSourceInfo,
        configuration: ExportConfiguration
    ) -> [String: Any] {
        let dimensions = configuration.dimensions(width: source.encodedWidth, height: source.encodedHeight)
        let fps = configuration.frameRate.value ?? source.nominalFrameRate
        // HDR requires HEVC Main 10; 8-bit Main and H.264 High cannot carry it.
        var compressionProperties: [String: Any] = [:]
        // ProRes is constant-quality and intra-frame: a bitrate target, a
        // profile level and frame reordering are all meaningless to it, and
        // passing them makes the writer reject the settings outright.
        if configuration.codec.usesBitRate {
            let profileLevel: CFString
            switch (source.colorMode, configuration.codec) {
            case (.hdrHLG, _), (.sdrWide, _), (.appleLog, _), (.appleLog2, _):
                profileLevel = kVTProfileLevel_HEVC_Main10_AutoLevel
            case (.sdr, .hevc): profileLevel = kVTProfileLevel_HEVC_Main_AutoLevel
            case (.sdr, _): profileLevel = kVTProfileLevel_H264_High_AutoLevel
            }
            compressionProperties = [
                AVVideoAverageBitRateKey: configuration.resolvedBitRate(width: dimensions.width, height: dimensions.height, fps: fps),
                AVVideoProfileLevelKey: profileLevel as String,
                AVVideoAllowFrameReorderingKey: true
            ]
            if let videoBitRate = configuration.videoBitRate {
                compressionProperties[AVVideoAverageBitRateKey] = videoBitRate
                compressionProperties.removeValue(forKey: AVVideoQualityKey)
            }
        }
        if let frameRate = fps, frameRate > 0 {
            compressionProperties[AVVideoExpectedSourceFrameRateKey] = frameRate
        }

        let colorProperties: [String: Any] = source.colorMode.isHDR
            ? [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            ]
            : [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]

        return [
            // A wide-precision source forced HEVC because H.264 cannot carry 10
            // bits. ProRes can, so a deliberate ProRes choice is honoured
            // rather than overridden.
            AVVideoCodecKey: (source.colorMode.isWidePrecision && configuration.codec.usesBitRate
                              ? ExportConfiguration.Codec.hevc : configuration.codec).avCodec,
            AVVideoWidthKey: dimensions.width,
            AVVideoHeightKey: dimensions.height,
            AVVideoColorPropertiesKey: colorProperties,
            AVVideoCompressionPropertiesKey: compressionProperties
        ]
    }

    /// Decoder output for export. HDR asks for the same extended-range linear
    /// half-float surface the preview uses, so preview and export see identical
    /// pixels and there is no 8-bit intermediate anywhere in the HDR path.
    static func videoReaderSettings(colorMode: ProjectColorMode = .sdr) -> [String: Any] {
        switch colorMode {
        case .sdr:
            return [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        case .sdrWide:
            // Native 10-bit 4:2:2. The existing YUV shader path handles it
            // unchanged - `YUVUniforms` already computes 10-bit code ranges, and
            // 4:2:2 only changes the chroma plane's size, which CVPixelBuffer
            // reports. Asking for 4:2:2 rather than 4:2:0 avoids resampling the
            // chroma of a ProRes source on the way in.
            return [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        case .appleLog, .appleLog2:
            // The camera's own encoding, untouched. AVFoundation has no Apple
            // Log conversion to offer — the format is identified by a separate
            // metadata key that the colour-conversion machinery does not read —
            // so asking it for anything but the native samples would mean
            // decoding through the wrong transfer function.
            return [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        case .hdrHLG:
            return [
                AVVideoColorPropertiesKey: [
                    // Ask for the HLG representation, not linear. AVFoundation
                    // then converts *any* source into a correctly referenced HLG
                    // signal — measured: an SDR Rec.709 white lands on signal
                    // 0.749, i.e. BT.2408 reference white. That is the
                    // mixed-timeline reference-white policy, implemented by
                    // Apple rather than by us.
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
                ],
                AVVideoAllowWideColorKey: true,
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        }
    }

    /// The pixel formats a reader configured by `videoReaderSettings` can hand
    /// back for a given mode.
    ///
    /// The export loop used to require 8-bit NV12 outright, which was correct
    /// when SDR was the only mode. A wide-precision or HDR project asks its
    /// reader for something else entirely, so the check has to follow the mode
    /// rather than assert the old one — otherwise the very configuration the
    /// pipeline requested is rejected as unsupported.
    static func acceptedReaderFormats(colorMode: ProjectColorMode) -> Set<OSType> {
        switch colorMode {
        case .sdr:
            return [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        case .sdrWide:
            return [kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
                    kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
                    kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                    kCVPixelFormatType_420YpCbCr10BiPlanarFullRange]
        case .hdrHLG:
            return [kCVPixelFormatType_64RGBAHalf]
        case .appleLog, .appleLog2:
            // Read as the camera wrote it: 10-bit 4:2:2 log. The transform to
            // scene light happens on the GPU, in the same shader the preview
            // uses, so the two cannot disagree.
            return [kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
                    kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange]
        }
    }

    /// What the mode expects, for an error a person can act on.
    static func readerFormatDescription(colorMode: ProjectColorMode) -> String {
        switch colorMode {
        case .sdr: "8-bit NV12"
        case .sdrWide: "10-bit 4:2:2"
        case .hdrHLG: "half-float HLG"
        case .appleLog: "10-bit 4:2:2 Apple Log"
        case .appleLog2: "10-bit 4:2:2 Apple Log 2"
        }
    }

    static func writerPixelBufferAttributes(source: ExportSourceInfo, configuration: ExportConfiguration) -> [String: Any] {
        let dimensions = configuration.dimensions(width: source.encodedWidth, height: source.encodedHeight)
        // HDR composes directly into the encoder's 10-bit 4:2:0 video-range
        // planes ('x420'), which is the format AVAssetWriterInput requires for
        // Main 10. Using an 8-bit BGRA intermediate here would throw away the
        // precision the whole path exists to preserve.
        return [
            kCVPixelBufferPixelFormatTypeKey as String: source.colorMode.isWidePrecision
                ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                : kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: dimensions.width,
            kCVPixelBufferHeightKey as String: dimensions.height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
    }

    static func audioReaderSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    /// Reader settings for a source track that will be encoded as AAC.
    ///
    /// Uncompressed LPCM is already a valid input to `AVAssetWriter`'s audio
    /// encoder. Returning `nil` preserves those native sample buffers and avoids
    /// asking `AVAssetReader` to perform an LPCM-to-LPCM conversion, which some
    /// iPhone Spatial Audio fallback tracks reject with `paramErr` (-50).
    static func audioReaderSettings(
        sourceFormatID: AudioFormatID,
        sourceChannelCount: Int,
        encodedChannelCount: Int,
        requiresTimePitchProcessing: Bool
    ) -> [String: Any]? {
        if sourceFormatID == kAudioFormatLinearPCM,
           sourceChannelCount == encodedChannelCount,
           !requiresTimePitchProcessing {
            return nil
        }
        var settings = audioReaderSettings()
        if encodedChannelCount != sourceChannelCount {
            settings[AVNumberOfChannelsKey] = encodedChannelCount
        }
        return settings
    }

    /// AAC settings for one source track.
    ///
    /// `writer` is used to check whether the source's channel layout can
    /// actually be encoded. Some layouts cannot: an iPhone records a second
    /// Apple Positional Audio (spatial) track alongside the stereo one, and its
    /// 4-channel layout is rejected by the AAC encoder. Passing that layout
    /// through made `canApply` fail and blocked the entire export — including
    /// its perfectly encodable stereo track — with a message about preserving
    /// every audio track.
    ///
    /// Dropping the layout and keeping the channels is only valid up to stereo.
    /// **`AVAssetWriterInput` requires `AVChannelLayoutKey` above two channels
    /// and raises an Objective-C exception without it — which Swift cannot
    /// catch, so it is a crash, not an error. `canApply` does not enforce that
    /// rule: it answers `true` for four channels with no layout and the
    /// initialiser then traps.** Above stereo the only encodable answer is a
    /// fold-down, which `foldsDownToStereo` reports rather than leaving silent.
    static func audioWriterSettings(
        source: ExportAudioTrackInfo,
        configuration: ExportConfiguration,
        acceptedBy writer: AVAssetWriter? = nil
    ) -> [String: Any] {
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: source.sampleRate,
            AVNumberOfChannelsKey: source.channelCount,
            AVEncoderBitRateKey: configuration.audioBitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue
        ]
        guard let channelLayout = source.channelLayout else {
            // Nothing to describe the arrangement with, so anything above stereo
            // cannot be written at all.
            if source.channelCount > 2 { settings[AVNumberOfChannelsKey] = 2 }
            return settings
        }
        var withLayout = settings
        withLayout[AVChannelLayoutKey] = channelLayout
        guard let writer else { return withLayout }
        if writer.canApply(outputSettings: withLayout, forMediaType: .audio) {
            return withLayout
        }
        if source.channelCount <= 2,
           writer.canApply(outputSettings: settings, forMediaType: .audio) {
            return settings
        }
        settings[AVNumberOfChannelsKey] = 2
        return settings
    }

    /// The channel count this track will actually be encoded with.
    static func encodedChannelCount(
        source: ExportAudioTrackInfo,
        configuration: ExportConfiguration,
        writer: AVAssetWriter
    ) -> Int {
        audioWriterSettings(source: source, configuration: configuration, acceptedBy: writer)[
            AVNumberOfChannelsKey] as? Int ?? source.channelCount
    }

    /// True when a track loses channels on the way out, so the export summary
    /// can say so instead of letting the difference go unmentioned.
    static func foldsDownToStereo(
        source: ExportAudioTrackInfo,
        configuration: ExportConfiguration,
        writer: AVAssetWriter
    ) -> Bool {
        encodedChannelCount(source: source, configuration: configuration, writer: writer) < source.channelCount
    }

}
