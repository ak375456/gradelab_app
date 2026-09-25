@preconcurrency import AVFoundation
@preconcurrency import CoreVideo
import CoreMedia
import Foundation

// ---------------------------------------------------------------------------
// Shot Match: where frames come from
//
// Decoding is kept separate from analysis so that every caller — a reference
// clip, the shot being graded, an imported still, and eventually a batch of
// eight clips — reaches the same measurement through the same door.
//
// Colour management is settled here and nowhere else. Video is read with
// `ExportMediaSettings.videoReaderSettings`, the same request the exporter
// makes, so an Apple Log clip arrives as the camera's own 10-bit samples rather
// than as something AVFoundation has already reinterpreted, and an HLG clip
// arrives as a correctly referenced HLG signal. Stills go through
// `ImageDecoder`, which converts from the file's embedded profile — sRGB,
// Display P3, whatever it carries — into the app's Rec.709 working space, so an
// imported reference is never assumed to be sRGB just because most of them are.
// ---------------------------------------------------------------------------

/// A decoded frame on its way across an isolation boundary.
///
/// `CVPixelBuffer` is deliberately not `Sendable`, and rightly so. Here exactly
/// one decode produces the buffer, hands it over and never touches it again —
/// the same promise `PixelBufferTextures` and `DecodedStill` make, for the same
/// reason.
struct ShotMatchPixels: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

enum ShotMatchFrameSourceError: LocalizedError {
    case noVideoTrack
    case decodeFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: String(localized: "This clip has no video to analyze.")
        case .decodeFailed: String(localized: "A frame could not be read from this clip.")
        case .cancelled: String(localized: "Analysis was cancelled.")
        }
    }
}

enum ShotMatchFrameSource {

    /// Where to sample a clip that is being analysed as a whole.
    ///
    /// Five frames spread across the shot, avoiding both ends. The ends are
    /// avoided deliberately: a cut very often lands on a frame that is still
    /// settling — an auto-exposure ramp, the tail of a dissolve, a pan that has
    /// not stopped — and either one would bias the whole clip's measurement.
    /// The middle 80% is what the shot actually looks like.
    static let clipSampleFractions: [Double] = [0.1, 0.3, 0.5, 0.7, 0.9]

    /// Frames from a video file at the given source times.
    ///
    /// One reader for the whole set rather than one per frame: a reader seeks
    /// forward cheaply and re-creating it per frame means re-parsing the file
    /// and decoding a fresh GOP each time, which on 4K footage is the
    /// difference between a moment and several seconds.
    static func videoFrames(
        url: URL,
        at times: [CMTime],
        colorMode: ProjectColorMode
    ) async throws -> [ShotMatchPixels] {
        guard !times.isEmpty else { return [] }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ShotMatchFrameSourceError.noVideoTrack
        }
        let sorted = times.sorted { $0.seconds < $1.seconds }
        let duration = try await asset.load(.duration)

        var frames: [ShotMatchPixels] = []
        frames.reserveCapacity(sorted.count)
        for time in sorted {
            try Task.checkCancellation()
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: ExportMediaSettings.videoReaderSettings(colorMode: colorMode))
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw ShotMatchFrameSourceError.decodeFailed }
            reader.add(output)
            // A short window rather than a point: a reader started exactly on a
            // presentation time can return the frame after it, and on a long
            // GOP the first sample decoded may sit a little earlier. Either is
            // the right picture for analysis — this is a shot's colour, not a
            // frame-accurate edit — so the window is what makes the read
            // reliable rather than occasionally empty.
            let start = CMTimeMaximum(.zero, time)
            let window = CMTimeMinimum(CMTime(seconds: 0.5, preferredTimescale: 600),
                                       CMTimeMaximum(CMTimeSubtract(duration, start),
                                                     CMTime(seconds: 0.05, preferredTimescale: 600)))
            reader.timeRange = CMTimeRange(start: start, duration: window)
            guard reader.startReading() else { throw ShotMatchFrameSourceError.decodeFailed }
            defer { reader.cancelReading() }
            guard let sample = output.copyNextSampleBuffer(),
                  let buffer = CMSampleBufferGetImageBuffer(sample) else {
                // One unreadable frame is not a failed analysis. A clip that
                // yields nothing at all is caught by the caller, which has the
                // context to say so usefully.
                continue
            }
            frames.append(ShotMatchPixels(buffer: buffer))
        }
        guard !frames.isEmpty else { throw ShotMatchFrameSourceError.decodeFailed }
        return frames
    }

    /// A still, colour-managed into the working space.
    ///
    /// The decode is capped well below the file's own size. A reference image is
    /// measured, not shown at full resolution, and a 48 MP photograph decoded in
    /// full to produce a 512-pixel analysis would be hundreds of milliseconds
    /// and hundreds of megabytes for numbers that do not change.
    static func stillFrame(url: URL, maximumLongEdge: Int = 1024) async throws -> ShotMatchPixels {
        let decoded = try await ImageDecoder.decodeDetached(url: url, maximumLongEdge: maximumLongEdge)
        return ShotMatchPixels(buffer: decoded.buffer)
    }

    /// Source times for sampling a clip across its length.
    static func sampleTimes(range: TimelineRange) -> [CMTime] {
        let start = range.start.seconds
        let duration = max(range.duration.seconds, 0)
        guard duration > 0 else { return [CMTime(seconds: start, preferredTimescale: 600)] }
        return clipSampleFractions.map {
            CMTime(seconds: start + duration * $0, preferredTimescale: 600)
        }
    }
}
