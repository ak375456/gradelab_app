@preconcurrency import AVFoundation
import CoreMedia
import Foundation

struct VideoMetadataReader: Sendable {
    func read(from url: URL, originalFileName: String? = nil) async throws -> VideoAsset {
        let asset = AVURLAsset(url: url)

        do {
            async let playableValue = asset.load(.isPlayable)
            async let protectedValue = asset.load(.hasProtectedContent)
            let duration = try await asset.load(.duration)
            guard try await playableValue else { throw GradeLabError.unsupportedVideo }
            guard try await !protectedValue else { throw GradeLabError.protectedVideo }
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let videoTrack = videoTracks.first else {
                throw GradeLabError.missingVideoTrack
            }

            async let naturalSizeValue = videoTrack.load(.naturalSize)
            async let transformValue = videoTrack.load(.preferredTransform)
            async let nominalFPSValue = videoTrack.load(.nominalFrameRate)
            async let minFrameDurationValue = videoTrack.load(.minFrameDuration)
            async let bitrateValue = videoTrack.load(.estimatedDataRate)
            async let descriptionsValue = videoTrack.load(.formatDescriptions)
            async let timeRangeValue = videoTrack.load(.timeRange)

            let naturalSize = try await naturalSizeValue
            let transform = try await transformValue
            let nominalFPS = try await nominalFPSValue
            let minFrameDuration = try await minFrameDurationValue
            let bitrate = try await bitrateValue
            let formatDescriptions = try await descriptionsValue

            let transformedRect = CGRect(origin: .zero, size: naturalSize)
                .applying(transform)
                .standardized
            let displayWidth = Int(abs(transformedRect.width).rounded())
            let displayHeight = Int(abs(transformedRect.height).rounded())

            let primaryDescription = formatDescriptions.first
            let codecType = primaryDescription.map(CMFormatDescriptionGetMediaSubType)
            let fourCC = codecType.map(Self.fourCCString) ?? "Unknown"
            let extensions = primaryDescription
                .flatMap(CMFormatDescriptionGetExtensions)
                .map { $0 as NSDictionary }

            let rawPrimaries = Self.extensionString(extensions, key: kCMFormatDescriptionExtension_ColorPrimaries)
            let rawTransfer = Self.extensionString(extensions, key: kCMFormatDescriptionExtension_TransferFunction)
            let rawMatrix = Self.extensionString(extensions, key: kCMFormatDescriptionExtension_YCbCrMatrix)
            let rawLogTransfer = Self.extensionString(extensions, key: kCMFormatDescriptionExtension_LogTransferFunction)
            let bitDepth = Self.bitDepth(from: extensions, fourCC: fourCC)
            let creationDate = try? await asset.load(.creationDate)?.load(.dateValue)
            let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey])

            let metadata = VideoMetadata(
                fileName: originalFileName ?? url.lastPathComponent,
                durationSeconds: max(0, duration.seconds),
                encodedWidth: Int(abs(naturalSize.width).rounded()),
                encodedHeight: Int(abs(naturalSize.height).rounded()),
                displayWidth: max(1, displayWidth),
                displayHeight: max(1, displayHeight),
                preferredTransform: .init(transform),
                nominalFrameRate: nominalFPS > 0 ? Double(nominalFPS) : nil,
                minimumFrameDurationSeconds: minFrameDuration.isValid && minFrameDuration.seconds > 0
                    ? minFrameDuration.seconds
                    : nil,
                codec: Self.codecLabel(for: fourCC),
                codecFourCC: fourCC,
                estimatedBitrate: bitrate > 0 ? Double(bitrate) : nil,
                fileSize: resourceValues?.fileSize.map(Int64.init),
                hasAudio: !audioTracks.isEmpty,
                videoTrackCount: videoTracks.count,
                audioTrackCount: audioTracks.count,
                colorPrimaries: Self.colorPrimariesLabel(rawPrimaries),
                transferFunction: Self.transferLabel(rawTransfer),
                yCbCrMatrix: Self.matrixLabel(rawMatrix),
                logTransferFunction: Self.logTransferLabel(rawLogTransfer),
                logProfileIdentifier: rawLogTransfer,
                isHDR: Self.hdrState(transfer: rawTransfer),
                bitDepth: bitDepth,
                creationDate: creationDate
            )
            let timeRange = try await timeRangeValue
            return VideoAsset(url: url, metadata: metadata,
                sourceRange: try TimelineRange(start: TimelineTime(timeRange.start), duration: TimelineTime(timeRange.duration)),
                frameDuration: minFrameDuration.isNumeric && minFrameDuration > .zero ? try TimelineTime(minFrameDuration) : nil)
        } catch let error as GradeLabError {
            throw error
        } catch {
            #if DEBUG
            print("Metadata read failed: \(error)")
            #endif
            throw GradeLabError.unableToReadMetadata
        }
    }

    private static func extensionString(_ extensions: NSDictionary?, key: CFString) -> String? {
        guard let value = extensions?[key] else { return nil }
        return String(describing: value)
    }

    private static func bitDepth(from extensions: NSDictionary?, fourCC: String) -> Int? {
        if let number = extensions?[kCMFormatDescriptionExtension_BitsPerComponent] as? NSNumber {
            return number.intValue
        }
        let codec = fourCC.lowercased()
        let atoms = extensions?[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? NSDictionary

        // HEVCDecoderConfigurationRecord carries exact luma/chroma bit depth.
        if ["hvc1", "hev1"].contains(codec),
           let configuration = atoms?["hvcC"] as? Data,
           configuration.count > 18 {
            let luma = 8 + Int(configuration[17] & 0x07)
            let chroma = 8 + Int(configuration[18] & 0x07)
            return max(luma, chroma)
        }

        // AVC Baseline/Main/Extended/High are defined as 8-bit profiles. High 10
        // and High 4:2:2 are conservatively classified as 10-bit so V1 never asks
        // AVFoundation for an unnoticed 8-bit conversion of higher-precision input.
        if ["avc1", "avc3"].contains(codec),
           let configuration = atoms?["avcC"] as? Data,
           configuration.count > 1 {
            switch configuration[1] {
            case 66, 77, 88, 100:
                return 8
            case 110, 122:
                return 10
            default:
                return nil
            }
        }
        return nil
    }

    private static func fourCCString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff)
        ]
        return String(bytes: bytes, encoding: .macOSRoman) ?? String(format: "0x%08X", code)
    }

    private static func codecLabel(for fourCC: String) -> String {
        switch fourCC.lowercased() {
        case "avc1", "avc3": "H.264"
        case "hvc1", "hev1": "HEVC"
        case "muxa": "HEVC with Alpha"
        case "apco": "ProRes 422 Proxy"
        case "apcs": "ProRes 422 LT"
        case "apcn": "ProRes 422"
        case "apch": "ProRes 422 HQ"
        case "ap4h": "ProRes 4444"
        case "ap4x": "ProRes 4444 XQ"
        case "jpeg": "Motion JPEG"
        default: fourCC == "Unknown" ? "Unknown" : fourCC
        }
    }

    private static func colorPrimariesLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        if raw.contains("ITU_R_2020") { return "BT.2020" }
        if raw.contains("ITU_R_709") { return "BT.709" }
        if raw.contains("P3_D65") { return "Display P3" }
        if raw.contains("SMPTE_C") { return "SMPTE-C" }
        return raw
    }

    private static func transferLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        if raw.contains("ITU_R_2100_HLG") { return "HLG" }
        if raw.contains("SMPTE_ST_2084") { return "PQ" }
        if raw.contains("ITU_R_709") { return "BT.709" }
        if raw.contains("sRGB") { return "sRGB" }
        if raw.contains("Linear") { return "Linear" }
        return raw
    }

    private static func matrixLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        if raw.contains("ITU_R_2020") { return "BT.2020" }
        if raw.contains("ITU_R_709") { return "BT.709" }
        if raw.contains("ITU_R_601_4") { return "BT.601" }
        return raw
    }

    /// Names the Log format from its official identifier.
    ///
    /// Compared against Apple's own constants by way of `SourceColorProfile`
    /// rather than by searching the string for "AppleLog": the identifiers are
    /// reverse-DNS values Apple publishes, and Apple Log 2's
    /// (`com.apple.apple-wide-gamut.apple-log`) contains Apple Log's name as a
    /// substring — so a substring test would report the wrong profile for it.
    private static func logTransferLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return SourceColorProfile.fromLogIdentifier(raw).displayName
    }

    private static func hdrState(transfer raw: String?) -> Bool? {
        guard let raw else { return nil }
        if raw.contains("ITU_R_2100_HLG") || raw.contains("SMPTE_ST_2084") { return true }
        if raw.contains("ITU_R_709") || raw.contains("sRGB") { return false }
        return nil
    }
}
