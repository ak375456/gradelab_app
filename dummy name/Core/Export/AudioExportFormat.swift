import AudioToolbox
import CoreMedia
import Foundation

enum AudioExportFormat {
    /// Native composition buffers can carry source PTS in epoch 1 while their
    /// output PTS is the epoch-0 project time. AAC must receive the output timing;
    /// the source epoch produces a MOV audio track with zero presentation duration.
    static func sampleForWriter(_ sample: CMSampleBuffer) throws -> CMSampleBuffer? {
        let count = CMSampleBufferGetNumSamples(sample)
        // Reader drain/end markers contain no media. AVAssetWriter is finalized
        // explicitly; these markers need not be submitted to its AAC encoder.
        if count == 0, CMSampleBufferGetDuration(sample) == .zero { return nil }
        let outputTime = CMSampleBufferGetOutputPresentationTimeStamp(sample)
        guard count > 0, outputTime.isNumeric,
              CMTimeCompare(outputTime, CMSampleBufferGetPresentationTimeStamp(sample)) != 0 else {
            return sample
        }
        guard count <= Int32.max,
              let description = CMSampleBufferGetFormatDescription(sample),
              CMFormatDescriptionGetMediaSubType(description) == kAudioFormatLinearPCM,
              CMSampleBufferGetOutputDuration(sample).isNumeric else {
            throw GradeLabError.exportFailed("The source audio timing could not be prepared for export.")
        }
        var timing = CMSampleTimingInfo(
            duration: CMTimeMultiplyByRatio(CMSampleBufferGetOutputDuration(sample),
                                            multiplier: 1, divisor: Int32(count)),
            presentationTimeStamp: outputTime, decodeTimeStamp: .invalid
        )
        var result: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &result
        )
        guard status == noErr, let result else {
            throw GradeLabError.exportFailed("The source audio timing could not be prepared for export.")
        }
        return result
    }

    /// Camera stereo fallback tracks can carry spatial layout descriptions whose
    /// channel count disagrees with the actual PCM stream. AVAssetWriter accepts
    /// their native integer samples, but fails with -12651 when that contradictory
    /// track description is supplied as its sourceFormatHint.
    static func validatedPCMDescription(_ description: CMFormatDescription) throws -> CMFormatDescription {
        guard var stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              stream.mFormatID == kAudioFormatLinearPCM,
              (1...2).contains(stream.mChannelsPerFrame) else { return description }

        var layoutSize = 0
        guard let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &layoutSize) else {
            return description
        }
        var channels: UInt32 = 0
        var resultSize = UInt32(MemoryLayout<UInt32>.size)
        let layoutStatus = AudioFormatGetProperty(
            kAudioFormatProperty_NumberOfChannelsForLayout,
            UInt32(layoutSize), layout, &resultSize, &channels
        )
        guard layoutStatus != noErr || channels != stream.mChannelsPerFrame else { return description }

        // Mono/stereo are unambiguous without a layout. Retain every ASBD field
        // and leave the sample buffers untouched. Do not copy the verbatim sample
        // description extension: it contains the same conflicting layout atom.
        var repaired: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &stream,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &repaired
        )
        guard status == noErr, let repaired else {
            throw GradeLabError.unsupportedExport("The source audio format could not be prepared for export.")
        }
        return repaired
    }
}
