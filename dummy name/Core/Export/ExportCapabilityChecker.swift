@preconcurrency import AVFoundation
import Foundation
import VideoToolbox

struct ExportCapabilities: Equatable, Sendable {
    let sourceIsSupported: Bool
    let encoderIsSupported: Bool
    let writerAcceptsVideoSettings: Bool
    let writerAcceptsAudioSettings: Bool
    let issues: [String]
    /// Things worth saying that do not block the export.
    var notes: [String] = []

    var canExport: Bool {
        sourceIsSupported
            && encoderIsSupported
            && writerAcceptsVideoSettings
            && writerAcceptsAudioSettings
            && issues.isEmpty
    }
}

struct ExportCapabilityChecker: Sendable {
    func check(
        asset: VideoAsset,
        configuration: ExportConfiguration = .maximumQuality,
        project: VideoProject? = nil
    ) async -> ExportCapabilities {
        do {
            try ExportMediaSettings.validate(configuration)
            let source = try await ExportSourceInspector.inspect(asset)
            let dimensions = configuration.dimensions(
                width: project?.canvas.width ?? source.encodedWidth,
                height: project?.canvas.height ?? source.encodedHeight)
            let fps = configuration.frameRate.value ?? project?.canvas.frameRate ?? source.nominalFrameRate
            let colorMode = project?.colorMode ?? source.colorMode
            let effectiveCodec = ExportMediaSettings.effectiveCodec(colorMode: colorMode, configuration: configuration)
            let requiresMain10 = ExportMediaSettings.requiresMain10(colorMode: colorMode, configuration: configuration)
            let encoderSupported = ExportCapabilityProbe.encoderIsSupported(
                width: dimensions.width,
                height: dimensions.height,
                expectedFrameRate: fps,
                // A ProRes rate comes from the format itself and exists only for
                // the size estimate; handing it to the encoder would set a 211
                // Mbps average bitrate on a session that has no such control.
                videoBitRate: effectiveCodec.usesBitRate
                    ? configuration.resolvedBitRate(width: dimensions.width, height: dimensions.height, fps: fps)
                    : nil,
                codec: effectiveCodec,
                requiresMain10: requiresMain10
            )

            let checkURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("GradeLab-Capability-\(UUID().uuidString)")
                .appendingPathExtension(configuration.resolvedContainer.fileExtension)
            defer { try? FileManager.default.removeItem(at: checkURL) }

            let writer = try AVAssetWriter(outputURL: checkURL, fileType: configuration.resolvedContainer.fileType)
            let acceptsVideo = writer.canApply(
                outputSettings: ExportMediaSettings.videoWriterSettings(
                    source: source,
                    configuration: configuration,
                    project: project
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
            let colorSupport = ColorPipelineSupport(metadata: asset.metadata)
            if colorSupport == .assumedRec709, let notice = colorSupport.notice {
                notes.append(notice)
            }
            if !encoderSupported {
                // Name the codec that was actually tested. Saying "HEVC Main 10"
                // whenever the source happened to be 10-bit told a ProRes
                // customer to change a setting they had not chosen. Codec
                // identifiers stay English, like every other one in the app.
                let codecName = requiresMain10 ? "HEVC Main 10" : effectiveCodec.rawValue
                let size = "\(dimensions.width)×\(dimensions.height)"
                if let fps, fps > 0 {
                    let rate = String(format: "%.2f", locale: .current, fps)
                    issues.append(String(localized: "This device cannot encode \(codecName) at \(size) at \(rate) fps. Try a smaller size, a lower frame rate, or another codec."))
                } else {
                    issues.append(String(localized: "This device cannot encode \(codecName) at \(size). Try a smaller size or another codec."))
                }
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
                encoderIsSupported: encoderSupported,
                writerAcceptsVideoSettings: acceptsVideo,
                writerAcceptsAudioSettings: acceptsAudio,
                issues: issues,
                notes: notes
            )
        } catch {
            return ExportCapabilities(
                sourceIsSupported: false,
                encoderIsSupported: false,
                writerAcceptsVideoSettings: false,
                writerAcceptsAudioSettings: false,
                issues: [error.localizedDescription]
            )
        }
    }
}

enum ExportCapabilityProbe {
    /// Asks VideoToolbox whether this machine can encode the codec the export is
    /// actually going to request, at its real dimensions, frame rate and bitrate.
    ///
    /// Pass the codec from `ExportMediaSettings.effectiveCodec(colorMode:configuration:)`,
    /// not the configured one — a wide-precision source is written as HEVC, and
    /// probing what was picked rather than what will be written is how this check
    /// came to pass ProRes exports without testing anything.
    static func encoderIsSupported(
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

        // Hardware is required only for the long-GOP codecs, where a software
        // fallback would take longer than anyone would sit through. ProRes is
        // intra-frame and encodes acceptably in software — which is how every
        // Mac without a ProRes engine writes it — so requiring hardware there
        // would refuse exports that work perfectly well. Measured on an M-series
        // Mac: asking for a hardware ProRes encoder fails the session outright
        // with -12908, `kVTCouldNotFindVideoEncoderErr`.
        let encoderSpecification: CFDictionary? = codec.usesBitRate
            ? [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true] as CFDictionary
            : nil
        var optionalSession: VTCompressionSession?
        let creationStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codec.cmCodecType,
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

        // None of the three properties below exists on a ProRes session. ProRes
        // is constant-quality and intra-frame, so it has no profile level, no
        // bitrate target and — measured, not assumed — no frame-rate hint
        // either: `ExpectedFrameRate` returns -12900, `kVTPropertyNotSupportedErr`.
        // Setting any of them fails, and failing the probe on a property the
        // format simply does not have would report ProRes as unsupported on
        // hardware that encodes it perfectly well.
        //
        // `videoWriterSettings` withholds the profile and the bitrate for the
        // same reason. It does still pass `AVVideoExpectedSourceFrameRateKey`
        // for every codec, which is fine — AVFoundation drops a compression
        // property the encoder does not take, where VideoToolbox reports it.
        if codec.usesBitRate {
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
        }

        return VTCompressionSessionPrepareToEncodeFrames(session) == noErr
    }
}
