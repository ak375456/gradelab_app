@preconcurrency import AVFoundation
import Foundation
import VideoToolbox

struct ExportCapabilities: Equatable, Sendable {
    let sourceIsSupported: Bool
    let hardwareHEVCIsSupported: Bool
    let writerAcceptsVideoSettings: Bool
    let writerAcceptsAudioSettings: Bool
    let issues: [String]
    /// Things worth saying that do not block the export.
    var notes: [String] = []

    var canExport: Bool {
        sourceIsSupported
            && hardwareHEVCIsSupported
            && writerAcceptsVideoSettings
            && writerAcceptsAudioSettings
            && issues.isEmpty
    }
}

struct ExportCapabilityChecker: Sendable {
    func check(
        asset: VideoAsset,
        configuration: ExportConfiguration = .maximumQuality
    ) async -> ExportCapabilities {
        do {
            try ExportMediaSettings.validate(configuration)
            let source = try await ExportSourceInspector.inspect(asset)
            let dimensions = configuration.dimensions(width: source.encodedWidth, height: source.encodedHeight)
            let fps = configuration.frameRate.value ?? source.nominalFrameRate
            let hardwareSupported = ExportCapabilityProbe.hardwareHEVCIsSupported(
                width: dimensions.width,
                height: dimensions.height,
                expectedFrameRate: fps,
                videoBitRate: configuration.resolvedBitRate(width: dimensions.width, height: dimensions.height, fps: fps),
                codec: source.colorMode.isWidePrecision ? .hevc : configuration.codec,
                requiresMain10: source.colorMode.isWidePrecision
            )

            let checkURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("GradeLab-Capability-\(UUID().uuidString)")
                .appendingPathExtension(configuration.resolvedContainer.fileExtension)
            defer { try? FileManager.default.removeItem(at: checkURL) }

            let writer = try AVAssetWriter(outputURL: checkURL, fileType: configuration.resolvedContainer.fileType)
            let acceptsVideo = writer.canApply(
                outputSettings: ExportMediaSettings.videoWriterSettings(
                    source: source,
                    configuration: configuration
                ),
                forMediaType: .video
            )
            let acceptsAudio = source.audioTracks.allSatisfy { audio in
                writer.canApply(
                    outputSettings: ExportMediaSettings.audioWriterSettings(
                        source: audio,
                        configuration: configuration,
                        acceptedBy: writer
                    ),
                    forMediaType: .audio
                )
            }
            let flattenedLayouts = source.audioTracks.filter {
                ExportMediaSettings.foldsDownToStereo(source: $0, configuration: configuration, writer: writer)
            }.count

            var issues: [String] = []
            var notes: [String] = []
            if !hardwareSupported {
                issues.append(source.colorMode.isWidePrecision
                    ? "This iPhone cannot encode HEVC Main 10 at \(dimensions.width)×\(dimensions.height)\(fps.map { String(format: " at %.2f fps", $0) } ?? ""). Try a smaller size or a lower frame rate."
                    : "This iPhone cannot encode the selected codec, dimensions, and frame rate. Try H.264, 1080p, or a lower frame rate.")
            }
            if !acceptsVideo {
                issues.append("The selected video settings are unavailable. Try a lower resolution or another codec.")
            }
            if !acceptsAudio {
                issues.append("AVAssetWriter cannot preserve every source audio track as AAC.")
            }
            if flattenedLayouts > 0 {
                // A note, not a blocker: the audio still exports, but its spatial
                // arrangement does not survive AAC and saying so is better than
                // letting the difference go unmentioned.
                notes.append(flattenedLayouts == 1
                    ? "One audio track uses a spatial channel layout that AAC cannot carry, so it is exported in stereo. Any other audio track is unaffected."
                    : "\(flattenedLayouts) audio tracks use spatial channel layouts that AAC cannot carry, so they are exported in stereo. Any other audio track is unaffected.")
            }
            return ExportCapabilities(
                sourceIsSupported: true,
                hardwareHEVCIsSupported: hardwareSupported,
                writerAcceptsVideoSettings: acceptsVideo,
                writerAcceptsAudioSettings: acceptsAudio,
                issues: issues,
                notes: notes
            )
        } catch {
            return ExportCapabilities(
                sourceIsSupported: false,
                hardwareHEVCIsSupported: false,
                writerAcceptsVideoSettings: false,
                writerAcceptsAudioSettings: false,
                issues: [error.localizedDescription]
            )
        }
    }
}

enum ExportCapabilityProbe {
    static func hardwareHEVCIsSupported(
        width: Int,
        height: Int,
        expectedFrameRate: Double?,
        videoBitRate: Int?,
        codec: ExportConfiguration.Codec = .hevc,
        requiresMain10: Bool = false
    ) -> Bool {
        guard width > 0, height > 0 else {
            return false
        }

        let encoderSpecification = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
        ] as CFDictionary
        var optionalSession: VTCompressionSession?
        let creationStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &optionalSession
        )
        guard creationStatus == noErr, let session = optionalSession else {
            return false
        }
        defer { VTCompressionSessionInvalidate(session) }

        // Probe the exact profile the export will request. Main 10 support is
        // not implied by Main support, so asking for the wrong one would report a
        // capability the encoder does not actually have.
        let profile: CFString
        if requiresMain10 {
            profile = kVTProfileLevel_HEVC_Main10_AutoLevel
        } else {
            profile = codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel
        }
        guard VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: profile
        ) == noErr else {
            return false
        }
        if let expectedFrameRate, expectedFrameRate > 0 {
            guard VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_ExpectedFrameRate,
                value: NSNumber(value: expectedFrameRate)
            ) == noErr else {
                return false
            }
        }
        if let videoBitRate {
            guard VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_AverageBitRate,
                value: NSNumber(value: videoBitRate)
            ) == noErr else {
                return false
            }
        } else {
            guard VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_Quality,
                value: NSNumber(value: 1.0)
            ) == noErr else {
                return false
            }
        }

        return VTCompressionSessionPrepareToEncodeFrames(session) == noErr
    }
}
