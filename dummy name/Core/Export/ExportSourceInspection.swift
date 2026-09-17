@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

struct ExportAudioTrackInfo {
    let track: AVAssetTrack
    let formatID: AudioFormatID
    /// Native PCM format hint with contradictory mono/stereo layout metadata
    /// removed. The underlying audio samples are not converted.
    let sourceFormatDescription: CMFormatDescription?
    let sampleRate: Double
    let channelCount: Int
    let channelLayout: Data?
    let timeRange: CMTimeRange
    let naturalTimeScale: CMTimeScale
}

struct ExportSourceInfo {
    let asset: AVAsset
    let videoTrack: AVAssetTrack
    let encodedWidth: Int
    let encodedHeight: Int
    let duration: CMTime
    let videoTimeRange: CMTimeRange
    let sessionStartTime: CMTime
    let preferredTransform: CGAffineTransform
    let nominalFrameRate: Double?
    let naturalTimeScale: CMTimeScale
    let audioTracks: [ExportAudioTrackInfo]
    var videoComposition: AVVideoComposition? = nil
    /// Reduced-resolution copies of `videoComposition`, used only while the
    /// preview is playing. Empty for export, which always renders full size.
    var playbackVideoCompositions: [PreviewQuality: AVVideoComposition] = [:]
    var timelineClips: [VideoClip]? = nil
    var compositionVideoTracks: [AVAssetTrack]? = nil
    var gradesBaked = false
    var audioMix: AVAudioMix? = nil
    /// Decides the reader format, the encoder profile and the colour tags. It
    /// comes from the project, not from the source, so a deliberate SDR
    /// conversion of an HDR source is possible later without re-deriving it.
    var colorMode: ProjectColorMode = .sdr

    var videoDurationSeconds: TimeInterval {
        videoTimeRange.duration.seconds
    }
}

enum ExportSourceInspector {
    static func inspect(_ source: VideoAsset, requireExportColorTags: Bool = true) async throws -> ExportSourceInfo {
        let asset = AVURLAsset(url: source.url)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let embeddedAudioTracks = try await asset.loadTracks(withMediaType: .audio)
        // A camera movie may contain an enabled stereo fallback and a disabled
        // Spatial Audio presentation in the same alternate group. They are two
        // versions of one recording, so a custom export must use only the
        // enabled presentation. Treating both as independent tracks duplicates
        // the sound and the disabled multichannel decode can fail with -50.
        let audioTracks = try await AudioTrackSelection.enabledTracks(from: embeddedAudioTracks)

        guard videoTracks.count == 1, let videoTrack = videoTracks.first else {
            if videoTracks.isEmpty {
                throw GradeLabError.missingVideoTrack
            }
            throw GradeLabError.unsupportedExport(
                String(localized: "Videos containing multiple video tracks are not supported for export yet.")
            )
        }

        async let naturalSizeValue = videoTrack.load(.naturalSize)
        async let preferredTransformValue = videoTrack.load(.preferredTransform)
        async let formatDescriptionsValue = videoTrack.load(.formatDescriptions)
        async let nominalFrameRateValue = videoTrack.load(.nominalFrameRate)
        async let minimumFrameDurationValue = videoTrack.load(.minFrameDuration)
        async let videoTimeRangeValue = videoTrack.load(.timeRange)
        async let naturalTimeScaleValue = videoTrack.load(.naturalTimeScale)

        let naturalSize = try await naturalSizeValue
        let preferredTransform = try await preferredTransformValue
        let formatDescriptions = try await formatDescriptionsValue
        let nominalFrameRate = try await nominalFrameRateValue
        let minimumFrameDuration = try await minimumFrameDurationValue
        let videoTimeRange = try await videoTimeRangeValue
        let naturalTimeScale = try await naturalTimeScaleValue

        guard duration.isNumeric, duration.seconds > 0,
              videoTimeRange.start.isNumeric,
              videoTimeRange.duration.isNumeric,
              videoTimeRange.duration.seconds > 0 else {
            throw GradeLabError.unsupportedExport(
                String(localized: "The source video does not have a finite exportable duration.")
            )
        }

        let width = Int(abs(naturalSize.width).rounded())
        let height = Int(abs(naturalSize.height).rounded())
        guard width > 0, height > 0 else {
            throw GradeLabError.unsupportedExport(
                String(localized: "The source video does not report valid encoded dimensions.")
            )
        }

        if requireExportColorTags {
            try validateMetadata(source.metadata)
            try validateVideoFormatDescriptions(
                formatDescriptions,
                colorMode: ProjectColorMode.default(for: source.metadata),
                allowMissingRec709Tags: ColorPipelineSupport(metadata: source.metadata) == .assumedRec709
            )
        } else {
            // Preview/editor path. This asks whether the source can be opened
            // at all, which is `allowsEditor` - deliberately wider than
            // `allowsGrading`, because an HLG source can be decoded and viewed
            // before the extended-range grading path is validated. Using the
            // grading gate here would refuse to build a preview composition for
            // a file the editor is meant to show. Export remains strictly
            // checked by the `requireExportColorTags` branch above.
            guard ColorPipelineSupport(metadata: source.metadata).allowsEditor else {
                throw GradeLabError.unsupportedVideo
            }
        }

        var inspectedAudioTracks: [ExportAudioTrackInfo] = []
        inspectedAudioTracks.reserveCapacity(audioTracks.count)
        for track in audioTracks {
            inspectedAudioTracks.append(try await inspectAudioTrack(track))
        }

        var sessionStartTime = videoTimeRange.start
        for audio in inspectedAudioTracks where audio.timeRange.start.isNumeric {
            if CMTimeCompare(audio.timeRange.start, sessionStartTime) < 0 {
                sessionStartTime = audio.timeRange.start
            }
        }
        guard CMTimeCompare(sessionStartTime, .zero) >= 0 else {
            throw GradeLabError.unsupportedExport(
                String(localized: "Videos with negative source timestamps cannot yet be exported without retiming.")
            )
        }

        let resolvedFrameRate: Double?
        if nominalFrameRate > 0 {
            resolvedFrameRate = Double(nominalFrameRate)
        } else if minimumFrameDuration.isNumeric, minimumFrameDuration.seconds > 0 {
            resolvedFrameRate = 1 / minimumFrameDuration.seconds
        } else {
            resolvedFrameRate = nil
        }

        return ExportSourceInfo(
            asset: asset,
            videoTrack: videoTrack,
            encodedWidth: width,
            encodedHeight: height,
            duration: duration,
            videoTimeRange: videoTimeRange,
            sessionStartTime: sessionStartTime,
            preferredTransform: preferredTransform,
            nominalFrameRate: resolvedFrameRate,
            naturalTimeScale: naturalTimeScale,
            audioTracks: inspectedAudioTracks,
            colorMode: ProjectColorMode.default(for: source.metadata)
        )
    }

    private static func validateMetadata(_ metadata: VideoMetadata) throws {
        // Everything below this line is the 8-bit Rec.709 rule set, and it is
        // only correct for sources that take that path. A mode with its own
        // validated pipeline — HLG, wide-precision SDR, Apple Log — is checked
        // against the format descriptions under that mode instead, a few lines
        // later. Applying the 8-bit rules to them refuses the very sources the
        // pipeline was built to carry: an Apple Log clip was rejected as
        // "12-bit source video is not supported", which is a statement about a
        // path it never takes.
        guard ProjectColorMode.default(for: metadata) == .sdr else { return }
        if metadata.isHDR == true {
            let transfer = metadata.transferFunction ?? "HDR"
            throw GradeLabError.unsupportedExport(
                String(localized: "\(transfer) export is not supported. Only HLG has a validated 10-bit HDR path.")
            )
        }
        if let bitDepth = metadata.bitDepth, bitDepth > 8 {
            throw GradeLabError.unsupportedExport(
                String(localized: "\(bitDepth)-bit source video is not supported yet. This export path is 8-bit only.")
            )
        }
        if let primaries = metadata.colorPrimaries, primaries != "BT.709" {
            throw unsupportedColorProperty("color primaries", value: primaries)
        }
        if let transferFunction = metadata.transferFunction, transferFunction != "BT.709" {
            throw unsupportedColorProperty("transfer function", value: transferFunction)
        }
        if let matrix = metadata.yCbCrMatrix, matrix != "BT.709" {
            throw unsupportedColorProperty("YCbCr matrix", value: matrix)
        }
    }

    private static func validateVideoFormatDescriptions(
        _ descriptions: [CMFormatDescription],
        colorMode: ProjectColorMode,
        allowMissingRec709Tags: Bool = false
    ) throws {
        guard !descriptions.isEmpty else {
            throw GradeLabError.unsupportedExport(
                String(localized: "The source color format could not be verified safely.")
            )
        }

        var firstDimensions: CMVideoDimensions?
        for description in descriptions {
            guard CMFormatDescriptionGetMediaType(description) == kCMMediaType_Video else {
                throw GradeLabError.unsupportedExport(
                    String(localized: "The source contains an invalid video format description.")
                )
            }

            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            if let firstDimensions,
               (firstDimensions.width != dimensions.width || firstDimensions.height != dimensions.height) {
                throw GradeLabError.unsupportedExport(
                    String(localized: "Videos that change encoded dimensions mid-stream are not supported yet.")
                )
            }
            firstDimensions = firstDimensions ?? dimensions

            let depth = try verifiedBitDepth(description)
            switch colorMode {
            case .sdr:
                try validateRec709(description, allowMissing: allowMissingRec709Tags)
                guard depth <= 8 else {
                    throw GradeLabError.unsupportedExport(
                        String(localized: "\(depth)-bit source video is not supported yet. This export path is 8-bit only.")
                    )
                }
            case .sdrWide:
                // Same Rec.709 requirements as 8-bit SDR; only the precision
                // differs, and it is carried rather than reduced.
                try validateRec709(description)
                guard depth > 8 else {
                    throw GradeLabError.unsupportedExport(
                        String(localized: "This source reports \(depth)-bit precision, so it does not need the wide path.")
                    )
                }
            case .hdrHLG:
                try validateHLG(description)
                guard depth >= 10 else {
                    throw GradeLabError.unsupportedExport(
                        String(localized: "This HLG source reports \(depth)-bit precision, which cannot be encoded as Main 10.")
                    )
                }
            case .appleLog, .appleLog2:
                // Verified from the file's own Log identifier rather than from
                // the ordinary colour tags: Apple Log carries its identity in a
                // separate extension, and the standard transfer tag says
                // nothing useful about it.
                try validateAppleLog(description, expecting: colorMode == .appleLog2 ? .appleLog2 : .appleLog)
                guard depth >= 10 else {
                    throw GradeLabError.unsupportedExport(
                        String(localized: "This \(colorMode.title) source reports \(depth)-bit precision. Log needs at least 10 bits to survive the transform to scene light.")
                    )
                }
            }
        }
    }

    /// The HDR equivalent of `validateRec709`. Dolby Vision stays rejected: its
    /// dynamic metadata is not carried through grading, and re-tagging graded
    /// frames with stale metadata would be worse than refusing.
    /// Confirms the source really is Apple Log, from the one tag that proves
    /// it: Apple's own Log identifier. Nothing is inferred from the codec, the
    /// bit depth or the ordinary colour tags, which for a Log file describe the
    /// container rather than the encoding.
    private static func validateAppleLog(
        _ description: CMFormatDescription,
        expecting expected: SourceColorProfile = .appleLog
    ) throws {
        let extensions = CMFormatDescriptionGetExtensions(description)
            .map { $0 as NSDictionary } ?? NSDictionary()
        let identifier = extensions[kCMFormatDescriptionExtension_LogTransferFunction]
            .map { String(describing: $0) }
        // Apple Log mode is only ever reached by detection, so a source with no
        // Log identifier in this path means something has gone wrong upstream.
        // Refused rather than transformed on an assumption.
        guard let identifier else {
            throw GradeLabError.unsupportedExport(
                String(localized: "This project is set to \(expected.displayName), but the source declares no Log profile. GradeLab does not apply the Apple Log transform to footage that does not identify itself as Log.")
            )
        }
        let declared = SourceColorProfile.fromLogIdentifier(identifier)
        guard declared == expected else {
            throw GradeLabError.unsupportedExport(
                String(localized: "This source declares itself as \(declared.displayName), not \(expected.displayName), so it is not processed through the \(expected.displayName) transform.")
            )
        }
        // Both Apple Log formats carry Y'C'BC'R built with the BT.2020
        // non-constant-luminance coefficients, and the shader inverts exactly
        // those. Apple Wide Gamut has no registered matrix code point of its
        // own, so Apple Log 2 signals BT.2020 here too — but it is checked
        // rather than assumed, because getting it wrong would tint the chroma
        // of every frame in a way that still looks like a plausible picture.
        let matrix = extensions[kCMFormatDescriptionExtension_YCbCrMatrix]
            .map { String(describing: $0) }
        if let matrix, !matrix.contains("ITU_R_2020") {
            throw GradeLabError.unsupportedExport(
                String(localized: "This \(expected.displayName) source declares a \(matrix) YCbCr matrix. GradeLab decodes Log chroma with the BT.2020 coefficients Apple specifies and will not reinterpret it.")
            )
        }
    }

    private static func validateHLG(_ description: CMFormatDescription) throws {
        let extensions = CMFormatDescriptionGetExtensions(description)
            .map { $0 as NSDictionary } ?? NSDictionary()
        let extensionDescription = String(describing: extensions)
        let codec = fourCC(CMFormatDescriptionGetMediaSubType(description)).lowercased()

        guard codec == "hvc1" || codec == "hev1" else {
            throw GradeLabError.unsupportedExport(
                String(localized: "HDR export requires an HEVC source; this one is \(codec.uppercased()).")
            )
        }
        if codec == "dvh1" || codec == "dvhe"
            || extensionDescription.localizedCaseInsensitiveContains("DolbyVision") {
            throw GradeLabError.unsupportedExport(
                String(localized: "Dolby Vision is not supported. Its dynamic metadata cannot be carried through grading, and GradeLab will not attach stale metadata to graded frames.")
            )
        }

        func require(_ value: Any?, contains token: String, property: String) throws {
            guard let value, String(describing: value).contains(token) else {
                throw GradeLabError.unsupportedExport(
                    String(localized: "HDR export needs \(property) to be \(token); this source reports \(value.map { String(describing: $0) } ?? "nothing").")
                )
            }
        }
        try require(extensions[kCMFormatDescriptionExtension_TransferFunction],
                    contains: "ITU_R_2100_HLG", property: "the transfer function")
        try require(extensions[kCMFormatDescriptionExtension_ColorPrimaries],
                    contains: "ITU_R_2020", property: "colour primaries")
        try require(extensions[kCMFormatDescriptionExtension_YCbCrMatrix],
                    contains: "ITU_R_2020", property: "the YCbCr matrix")
    }

    private static func validateRec709(
        _ description: CMFormatDescription,
        allowMissing: Bool = false
    ) throws {
        let extensions = CMFormatDescriptionGetExtensions(description)
            .map { $0 as NSDictionary } ?? NSDictionary()
        let extensionDescription = String(describing: extensions)
        let codec = fourCC(CMFormatDescriptionGetMediaSubType(description)).lowercased()

        if codec == "dvh1" || codec == "dvhe"
            || extensionDescription.localizedCaseInsensitiveContains("MasteringDisplayColorVolume")
            || extensionDescription.localizedCaseInsensitiveContains("ContentLightLevelInfo")
            || extensionDescription.localizedCaseInsensitiveContains("DolbyVision") {
            throw GradeLabError.unsupportedExport(
                String(localized: "HDR or Dolby Vision source video is not supported yet.")
            )
        }

        try requireRec709(
            extensions[kCMFormatDescriptionExtension_ColorPrimaries],
            property: "color primaries",
            allowMissing: allowMissing
        )
        try requireRec709(
            extensions[kCMFormatDescriptionExtension_TransferFunction],
            property: "transfer function",
            allowMissing: allowMissing
        )
        try requireRec709(
            extensions[kCMFormatDescriptionExtension_YCbCrMatrix],
            property: "YCbCr matrix",
            allowMissing: allowMissing
        )
    }

    private static func requireRec709(
        _ value: Any?,
        property: String,
        allowMissing: Bool = false
    ) throws {
        guard let value else {
            // Many otherwise ordinary 8-bit SDR camera files, including DJI
            // H.264 clips, omit these optional declarations. The preview
            // already decodes that narrowly verified case through the Rec.709
            // path, and export writes explicit Rec.709 output tags. Accepting
            // the same assumption here keeps both paths identical while any
            // explicit conflicting value still fails below.
            if allowMissing { return }
            throw GradeLabError.unsupportedExport(
                String(localized: "The source does not declare its \(property). Export is blocked to avoid an incorrect color conversion.")
            )
        }
        let text = String(describing: value)
        guard text.localizedCaseInsensitiveContains("ITU_R_709")
                || text.localizedCaseInsensitiveContains("BT.709") else {
            throw unsupportedColorProperty(property, value: text)
        }
    }

    private static func unsupportedColorProperty(_ property: String, value: String) -> GradeLabError {
        GradeLabError.unsupportedExport(
            String(localized: "The source uses \(value) \(property). Only 8-bit Rec.709 SDR export is supported right now.")
        )
    }

    private static func verifiedBitDepth(_ description: CMFormatDescription) throws -> Int {
        let extensions = CMFormatDescriptionGetExtensions(description)
            .map { $0 as NSDictionary } ?? NSDictionary()
        let codec = fourCC(CMFormatDescriptionGetMediaSubType(description)).lowercased()

        if let number = extensions[kCMFormatDescriptionExtension_BitsPerComponent] as? NSNumber {
            return number.intValue
        }

        // ProRes always carries BitsPerComponent, so reaching here means the
        // description is incomplete and the precision cannot be verified.
        if codec.hasPrefix("ap") || codec == "prores" {
            throw unverifiableBitDepth(codec)
        }

        let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms]
            as? NSDictionary
        if codec == "hvc1" || codec == "hev1" {
            guard let data = atomData(named: "hvcC", in: atoms), data.count > 18 else {
                throw unverifiableBitDepth(codec)
            }
            return 8 + Int(data[data.startIndex + 17] & 0x07)
        }

        if codec == "avc1" || codec == "avc3" {
            guard let data = atomData(named: "avcC", in: atoms), data.count > 1 else {
                throw unverifiableBitDepth(codec)
            }
            let profile = data[data.startIndex + 1]
            switch profile {
            case 66, 77, 88, 100:
                return 8
            case 110, 122:
                return 10
            default:
                throw unverifiableBitDepth(codec)
            }
        }

        throw unverifiableBitDepth(codec)
    }

    private static func unverifiableBitDepth(_ codec: String) -> GradeLabError {
        GradeLabError.unsupportedExport(
            String(localized: "The \(codec.uppercased()) source bit depth could not be verified as 8-bit. Export is blocked to avoid flattening higher-bit-depth video.")
        )
    }

    private static func atomData(named name: String, in atoms: NSDictionary?) -> Data? {
        if let data = atoms?[name] as? Data {
            return data
        }
        return nil
    }

    static func inspectAudioTrack(_ track: AVAssetTrack) async throws -> ExportAudioTrackInfo {
        async let descriptionsValue = track.load(.formatDescriptions)
        async let timeRangeValue = track.load(.timeRange)
        async let naturalTimeScaleValue = track.load(.naturalTimeScale)

        let descriptions = try await descriptionsValue
        let timeRange = try await timeRangeValue
        let naturalTimeScale = try await naturalTimeScaleValue
        guard let firstDescription = descriptions.first,
              CMFormatDescriptionGetMediaType(firstDescription) == kCMMediaType_Audio,
              let basicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(firstDescription) else {
            throw GradeLabError.unsupportedExport(
                String(localized: "A source audio track has an unreadable format and cannot be preserved.")
            )
        }

        let sampleRate = basicDescription.pointee.mSampleRate
        let channelCount = Int(basicDescription.pointee.mChannelsPerFrame)
        guard sampleRate.isFinite, sampleRate > 0, channelCount > 0 else {
            throw GradeLabError.unsupportedExport(
                String(localized: "A source audio track has invalid channel or sample-rate information.")
            )
        }

        for description in descriptions.dropFirst() {
            guard let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                  stream.pointee.mSampleRate == sampleRate,
                  Int(stream.pointee.mChannelsPerFrame) == channelCount else {
                throw GradeLabError.unsupportedExport(
                    String(localized: "Audio tracks that change format mid-stream cannot be preserved yet.")
                )
            }
        }

        let writerDescription = try AudioExportFormat.validatedPCMDescription(firstDescription)
        var layoutSize = 0
        let channelLayout = CMAudioFormatDescriptionGetChannelLayout(
            writerDescription,
            sizeOut: &layoutSize
        ).flatMap { layoutSize > 0 ? Data(bytes: $0, count: layoutSize) : nil }

        if channelCount > 2, channelLayout == nil {
            throw GradeLabError.unsupportedExport(
                String(localized: "A multichannel source audio track has no channel layout and cannot be preserved safely.")
            )
        }

        return ExportAudioTrackInfo(
            track: track,
            formatID: basicDescription.pointee.mFormatID,
            sourceFormatDescription: writerDescription,
            sampleRate: sampleRate,
            channelCount: channelCount,
            channelLayout: channelLayout,
            timeRange: timeRange,
            naturalTimeScale: naturalTimeScale
        )
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .macOSRoman) ?? String(format: "%08X", value)
    }
}
