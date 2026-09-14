@preconcurrency import AVFoundation
import XCTest
@testable import GradeLab

final class ExportModelTests: XCTestCase {
    func testCompositionAudioUsesOutputTimingAndRetainsSampleData() throws {
        var stream = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
        )
        var description: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &stream, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description
        ), noErr)
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 16,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: 16, flags: 0, blockBufferOut: &block
        ), noErr)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: try XCTUnwrap(block),
            formatDescription: try XCTUnwrap(description), sampleCount: 2,
            presentationTimeStamp: CMTime(value: 0, timescale: 48_000, flags: .valid, epoch: 1),
            packetDescriptions: nil, sampleBufferOut: &sample
        ), noErr)
        let source = try XCTUnwrap(sample)
        let projectTime = CMTime(value: 5, timescale: 1)
        XCTAssertEqual(CMSampleBufferSetOutputPresentationTimeStamp(source, newValue: projectTime), noErr)
        let prepared = try XCTUnwrap(AudioExportFormat.sampleForWriter(source))
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(prepared), projectTime)
        XCTAssertEqual(CMSampleBufferGetNumSamples(prepared), 2)
        XCTAssertEqual(CMSampleBufferGetDuration(prepared), CMSampleBufferGetDuration(source))
        XCTAssertTrue(CMSampleBufferGetDataBuffer(prepared) === CMSampleBufferGetDataBuffer(source))
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(source).epoch, 1)
    }

    func testDisabledAlternateAudioPresentationIsNotExported() async throws {
        let composition = AVMutableComposition()
        let enabled = try XCTUnwrap(composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ))
        let disabled = try XCTUnwrap(composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ))
        enabled.isEnabled = true
        disabled.isEnabled = false

        let selected = try await AudioTrackSelection.enabledTracks(from: [enabled, disabled])

        XCTAssertEqual(selected.map(\.trackID), [enabled.trackID])
    }

    func testNativeStereoPCMBypassesTheFailingReaderSideConversion() {
        let nativePCM = ExportMediaSettings.audioReaderSettings(
            sourceFormatID: kAudioFormatLinearPCM,
            sourceChannelCount: 2,
            encodedChannelCount: 2,
            requiresTimePitchProcessing: false
        )
        XCTAssertNil(nativePCM)

        let retimedPCM = ExportMediaSettings.audioReaderSettings(
            sourceFormatID: kAudioFormatLinearPCM,
            sourceChannelCount: 2,
            encodedChannelCount: 2,
            requiresTimePitchProcessing: true
        )
        XCTAssertNotNil(retimedPCM, "Retimed audio still needs decoded samples for pitch preservation")

        let compressed = ExportMediaSettings.audioReaderSettings(
            sourceFormatID: kAudioFormatMPEG4AAC,
            sourceChannelCount: 2,
            encodedChannelCount: 2,
            requiresTimePitchProcessing: false
        )
        XCTAssertEqual(compressed?[AVFormatIDKey] as? AudioFormatID, kAudioFormatLinearPCM)
    }

    func testContradictoryStereoLayoutIsRemovedFromWriterHint() throws {
        var stream = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
        )
        // Same mismatch as the failing camera movie: two PCM channels, but a
        // layout with six channel descriptions.
        let header: [UInt32] = [kAudioChannelLayoutTag_UseChannelDescriptions, 0, 6]
        var layout = header.withUnsafeBytes { Data($0) }
        var channel = AudioChannelDescription(
            mChannelLabel: kAudioChannelLabel_Left, mChannelFlags: [],
            mCoordinates: (0, 0, 0)
        )
        for _ in 0..<6 { withUnsafeBytes(of: &channel) { layout.append(contentsOf: $0) } }
        var source: CMAudioFormatDescription?
        let status = layout.withUnsafeBytes { bytes in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &stream,
                layoutSize: bytes.count,
                layout: bytes.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self),
                magicCookieSize: 0, magicCookie: nil, extensions: nil,
                formatDescriptionOut: &source
            )
        }
        XCTAssertEqual(status, noErr)
        let repaired = try AudioExportFormat.validatedPCMDescription(XCTUnwrap(source))
        var layoutSize = 0
        XCTAssertNil(CMAudioFormatDescriptionGetChannelLayout(repaired, sizeOut: &layoutSize))
        let actual = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(repaired)).pointee
        XCTAssertEqual(actual.mFormatFlags, stream.mFormatFlags)
        XCTAssertEqual(actual.mSampleRate, stream.mSampleRate)
        XCTAssertEqual(actual.mChannelsPerFrame, 2)
        XCTAssertEqual(actual.mBitsPerChannel, 32)
        XCTAssertEqual(actual.mBytesPerFrame, stream.mBytesPerFrame)
    }

    func testValidStereoLayoutIsRetained() throws {
        var stream = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
        )
        var layout = AudioChannelLayout(
            mChannelLayoutTag: kAudioChannelLayoutTag_Stereo,
            mChannelBitmap: [], mNumberChannelDescriptions: 0,
            mChannelDescriptions: AudioChannelDescription()
        )
        var source: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &stream,
            layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &source
        ), noErr)
        let original = try XCTUnwrap(source)
        let checked = try AudioExportFormat.validatedPCMDescription(original)
        XCTAssertTrue(CFEqual(original, checked))
    }

    func testResizingPreservesPortraitAndLandscapeShape() {
        var configuration = ExportConfiguration.maximumQuality
        configuration.resolution = .fullHD
        let landscape = configuration.dimensions(width: 3840, height: 2160)
        let portrait = configuration.dimensions(width: 2160, height: 3840)
        XCTAssertEqual(landscape.width, 1920)
        XCTAssertEqual(landscape.height, 1080)
        XCTAssertEqual(portrait.width, 1080)
        XCTAssertEqual(portrait.height, 1920)
        configuration.resolution = .custom
        configuration.customLongEdge = 1000
        let custom = configuration.dimensions(width: 1920, height: 1080)
        XCTAssertEqual(custom.width, 1000)
        XCTAssertEqual(custom.height % 2, 0)
    }

    func testQualityAndManualBitrate() {
        var configuration = ExportConfiguration.maximumQuality
        let high = configuration.resolvedBitRate(width: 1920, height: 1080, fps: 30)
        configuration.qualityPreset = .compact
        XCTAssertLessThan(configuration.resolvedBitRate(width: 1920, height: 1080, fps: 30), high)
        configuration.videoBitRate = 12_000_000
        XCTAssertEqual(configuration.resolvedBitRate(width: 3840, height: 2160, fps: 60), 12_000_000)
        XCTAssertNil(ExportConfiguration.FrameRate.original.value)
        XCTAssertEqual(ExportConfiguration.FrameRate.fps24.value, 24)
    }
    func testProgressIsClampedToAValidDisplayRange() {
        let belowZero = ExportProgress(
            fractionCompleted: -1,
            processedDuration: -4,
            totalDuration: -8,
            presentationTime: -2
        )
        let aboveOne = ExportProgress(
            fractionCompleted: 1.5,
            processedDuration: 12,
            totalDuration: 10,
            presentationTime: 12
        )

        XCTAssertEqual(belowZero.fractionCompleted, 0)
        XCTAssertEqual(belowZero.processedDuration, 0)
        XCTAssertEqual(belowZero.totalDuration, 0)
        XCTAssertEqual(belowZero.percentage, 0)
        XCTAssertEqual(aboveOne.fractionCompleted, 1)
        XCTAssertEqual(aboveOne.percentage, 100)
    }

    func testMaximumQualityConfigurationPreservesSourceGeometryAndTiming() {
        let configuration = ExportConfiguration.maximumQuality

        XCTAssertEqual(configuration.resolution, .original)
        XCTAssertEqual(configuration.frameRate, .original)
        XCTAssertEqual(configuration.codec, .hevc)
        XCTAssertEqual(configuration.qualityPreset, .maximum)
        XCTAssertNil(configuration.videoBitRate)
        XCTAssertEqual(configuration.audioBitRate, 256_000)
    }
}
