import AVFoundation
import CoreMedia
import VideoToolbox
import XCTest
@testable import GradeLab

/// The export pre-flight asks VideoToolbox whether this machine can encode what
/// is about to be written. It used to ask about the wrong codec: the probe chose
/// its `CMVideoCodecType` with `codec == .hevc ? HEVC : H.264`, so both ProRes
/// cases were tested as H.264 — a question every supported device answers yes to
/// — and a ProRes export went unchecked until it failed at write time.
///
/// These tests pin the three rules that fix it: every codec maps to its own
/// VideoToolbox type, the codec that gets probed is the codec that gets written,
/// and a constant-quality format is never asked for a bitrate or a profile.
final class ExportCodecProbeTests: XCTestCase {

    // MARK: - Every codec maps to its own encoder

    func testEachCodecMapsToItsOwnVideoToolboxType() {
        let mapped = ExportConfiguration.Codec.allCases.map(\.cmCodecType)
        XCTAssertEqual(
            Set(mapped).count,
            ExportConfiguration.Codec.allCases.count,
            "Two codecs share a CMVideoCodecType, so one of them is being probed as the other."
        )
    }

    func testProResIsNotProbedAsH264() {
        for codec in [ExportConfiguration.Codec.proRes422HQ, .proRes422] {
            XCTAssertNotEqual(codec.cmCodecType, kCMVideoCodecType_H264, "\(codec.rawValue)")
            XCTAssertNotEqual(codec.cmCodecType, kCMVideoCodecType_HEVC, "\(codec.rawValue)")
        }
        XCTAssertEqual(ExportConfiguration.Codec.proRes422HQ.cmCodecType, kCMVideoCodecType_AppleProRes422HQ)
        XCTAssertEqual(ExportConfiguration.Codec.proRes422.cmCodecType, kCMVideoCodecType_AppleProRes422)
    }

    func testTheVideoToolboxTypeAgreesWithTheWriterType() {
        // Two mappings of the same enum sitting in one file. If a new case is
        // given one and not the other, the writer and the probe disagree about
        // what is being encoded — which is the shape of the original bug.
        let pairs: [(ExportConfiguration.Codec, AVVideoCodecType, CMVideoCodecType)] = [
            (.hevc, .hevc, kCMVideoCodecType_HEVC),
            (.h264, .h264, kCMVideoCodecType_H264),
            (.proRes422HQ, .proRes422HQ, kCMVideoCodecType_AppleProRes422HQ),
            (.proRes422, .proRes422, kCMVideoCodecType_AppleProRes422)
        ]
        XCTAssertEqual(pairs.count, ExportConfiguration.Codec.allCases.count,
                       "A codec was added without being covered here.")
        for (codec, avCodec, cmType) in pairs {
            XCTAssertEqual(codec.avCodec, avCodec, codec.rawValue)
            XCTAssertEqual(codec.cmCodecType, cmType, codec.rawValue)
        }
    }

    // MARK: - The probed codec is the written codec

    private func configuration(codec: ExportConfiguration.Codec) -> ExportConfiguration {
        var configuration = ExportConfiguration.maximumQuality
        configuration.codec = codec
        return configuration
    }

    func testAWidePrecisionSourceForcesHEVCForTheBitrateCodecs() {
        // H.264 cannot carry 10 bits, so a 10-bit source is written as HEVC
        // whichever of the two was picked.
        for mode in [ProjectColorMode.sdrWide, .hdrHLG, .appleLog, .appleLog2] {
            for codec in [ExportConfiguration.Codec.hevc, .h264] {
                XCTAssertEqual(
                    ExportMediaSettings.effectiveCodec(colorMode: mode, configuration: configuration(codec: codec)),
                    .hevc,
                    "\(mode) / \(codec.rawValue)"
                )
                XCTAssertTrue(
                    ExportMediaSettings.requiresMain10(colorMode: mode, configuration: configuration(codec: codec)),
                    "\(mode) / \(codec.rawValue)"
                )
            }
        }
    }

    func testAWidePrecisionSourceDoesNotOverrideADeliberateProResChoice() {
        // This is the half the checker's copy of the rule was missing. ProRes
        // carries 10 bits natively, so it is honoured — and it must not then be
        // probed for an HEVC Main 10 encoder it never asks for.
        for mode in [ProjectColorMode.sdrWide, .hdrHLG, .appleLog, .appleLog2] {
            for codec in [ExportConfiguration.Codec.proRes422HQ, .proRes422] {
                XCTAssertEqual(
                    ExportMediaSettings.effectiveCodec(colorMode: mode, configuration: configuration(codec: codec)),
                    codec,
                    "\(mode) / \(codec.rawValue) was overridden"
                )
                XCTAssertFalse(
                    ExportMediaSettings.requiresMain10(colorMode: mode, configuration: configuration(codec: codec)),
                    "\(mode) / \(codec.rawValue) was probed for HEVC Main 10"
                )
            }
        }
    }

    func testAnSDRSourceIsWrittenAsWhateverWasPicked() {
        for codec in ExportConfiguration.Codec.allCases {
            XCTAssertEqual(
                ExportMediaSettings.effectiveCodec(colorMode: .sdr, configuration: configuration(codec: codec)),
                codec,
                codec.rawValue
            )
            XCTAssertFalse(
                ExportMediaSettings.requiresMain10(colorMode: .sdr, configuration: configuration(codec: codec)),
                codec.rawValue
            )
        }
    }

    // MARK: - Constant-quality formats get no bitrate and no profile

    func testOnlyTheBitrateCodecsCarryARate() {
        XCTAssertTrue(ExportConfiguration.Codec.hevc.usesBitRate)
        XCTAssertTrue(ExportConfiguration.Codec.h264.usesBitRate)
        XCTAssertFalse(ExportConfiguration.Codec.proRes422HQ.usesBitRate)
        XCTAssertFalse(ExportConfiguration.Codec.proRes422.usesBitRate)
    }

    func testTheWriterWithholdsBitrateAndProfileFromProRes() throws {
        // The probe's rule has to match the writer's, so assert the writer's
        // behaviour here too: whatever the probe sets, these are the settings
        // the file is actually written with.
        let source = try Self.makeSourceInfo()
        for codec in [ExportConfiguration.Codec.proRes422HQ, .proRes422] {
            let settings = ExportMediaSettings.videoWriterSettings(
                source: source,
                configuration: configuration(codec: codec)
            )
            let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]
            XCTAssertNil(compression[AVVideoAverageBitRateKey], codec.rawValue)
            XCTAssertNil(compression[AVVideoProfileLevelKey], codec.rawValue)
            XCTAssertEqual(settings[AVVideoCodecKey] as? AVVideoCodecType, codec.avCodec, codec.rawValue)
        }
    }

    // MARK: - The probe actually runs for ProRes

    func testTheProbeAcceptsProResAtASizeThisMachineCanEncode() {
        // The previous implementation could not answer this question at all: it
        // would have created an H.264 session and set a ~211 Mbps average
        // bitrate on it. This asks VideoToolbox about ProRes itself.
        for codec in [ExportConfiguration.Codec.proRes422HQ, .proRes422] {
            XCTAssertTrue(
                ExportCapabilityProbe.encoderIsSupported(
                    width: 1920,
                    height: 1080,
                    expectedFrameRate: 30,
                    videoBitRate: nil,
                    codec: codec,
                    requiresMain10: false
                ),
                "\(codec.rawValue) was refused at 1080p30 on a machine that can encode it."
            )
        }
    }

    func testAFrameRateDoesNotSinkAProResProbe() {
        // `ExpectedFrameRate` is not a property a ProRes session has:
        // VideoToolbox answers -12900, kVTPropertyNotSupportedErr. Treating that
        // as a capability failure — which the first cut of this fix did —
        // refuses every ProRes export on a machine that encodes them fine.
        for rate in [23.976, 25, 29.97, 30, 59.94] as [Double] {
            for codec in [ExportConfiguration.Codec.proRes422HQ, .proRes422] {
                XCTAssertTrue(ExportCapabilityProbe.encoderIsSupported(
                    width: 1920, height: 1080, expectedFrameRate: rate,
                    videoBitRate: nil, codec: codec
                ), "\(codec.rawValue) at \(rate) fps")
            }
        }
    }

    func testAStrayBitrateIsIgnoredForProRes() {
        // The callers withhold it, but the probe must not fail if one arrives:
        // a ~211 Mbps ProRes size estimate set as an average bitrate is exactly
        // what the old code did.
        for codec in [ExportConfiguration.Codec.proRes422HQ, .proRes422] {
            XCTAssertTrue(ExportCapabilityProbe.encoderIsSupported(
                width: 1920, height: 1080, expectedFrameRate: 30,
                videoBitRate: 211_507_200, codec: codec
            ), codec.rawValue)
        }
    }

    func testTheProbeStillAcceptsTheBitrateCodecs() {
        XCTAssertTrue(ExportCapabilityProbe.encoderIsSupported(
            width: 1920, height: 1080, expectedFrameRate: 30,
            videoBitRate: 12_000_000, codec: .h264
        ))
        XCTAssertTrue(ExportCapabilityProbe.encoderIsSupported(
            width: 1920, height: 1080, expectedFrameRate: 30,
            videoBitRate: 10_000_000, codec: .hevc
        ))
    }

    func testTheProbeRejectsAnEmptyFrame() {
        for codec in ExportConfiguration.Codec.allCases {
            XCTAssertFalse(ExportCapabilityProbe.encoderIsSupported(
                width: 0, height: 0, expectedFrameRate: 30,
                videoBitRate: nil, codec: codec
            ), codec.rawValue)
        }
    }

    // MARK: - Helpers

    /// A one-frame SDR movie on disk, which is the cheapest way to get the real
    /// `AVAssetTrack` that `ExportSourceInfo` requires.
    private static func makeSourceInfo() throws -> ExportSourceInfo {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GradeLab-ProbeTest-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        try writeSingleFrameMovie(to: url)
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw XCTSkip("Could not build a sample movie for the writer-settings check.")
        }
        return ExportSourceInfo(
            asset: asset,
            videoTrack: track,
            encodedWidth: 1920,
            encodedHeight: 1080,
            duration: CMTime(value: 1, timescale: 30),
            videoTimeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 30)),
            sessionStartTime: .zero,
            preferredTransform: .identity,
            nominalFrameRate: 30,
            naturalTimeScale: 600,
            audioTracks: []
        )
    }

    private static func writeSingleFrameMovie(to url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1920,
            AVVideoHeightKey: 1080
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 1920, 1080, kCVPixelFormatType_32BGRA, nil, &buffer)
        if let buffer {
            adaptor.append(buffer, withPresentationTime: .zero)
        }
        input.markAsFinished()

        let finished = XCTestExpectation(description: "writer finished")
        writer.finishWriting { finished.fulfill() }
        _ = XCTWaiter().wait(for: [finished], timeout: 10)
    }
}
