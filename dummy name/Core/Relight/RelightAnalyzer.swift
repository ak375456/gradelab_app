@preconcurrency import AVFoundation
@preconcurrency import CoreVideo
import CoreGraphics
import CoreMedia
import Foundation

// ---------------------------------------------------------------------------
// Scene analysis for Relight
//
// Runs on a detached task, never on the main thread and never during playback
// or export rendering. It reads the clip's source range in order, once, and
// for every frame:
//
//   • reduces it to the analysis grid on the GPU and measures motion against
//     the frame before (RelightAnalysisGPU);
//   • watches for a cut inside the clip, by the same coarse luminance
//     signature noise reduction uses, and never carries depth across one;
//   • carries the running depth forward along the motion and, on keyframes,
//     folds in a fresh estimate (RelightTemporalFusion);
//   • stores the result at a steady rate below the frame rate, where the
//     renderers blend between stored frames.
//
// PROGRESSIVE. Analysis begins at the playhead and runs to the end of the
// clip, then fills in from the clip's start. Relight is usable on whatever has
// been stored, so the frame being looked at is lit within a second or two
// instead of after the whole clip. Each pass starts from a fresh estimate and
// both are normalised the same way, so where they meet the depth keeps its
// scale; a pass that finds depth stored just before it — an earlier analysis
// that was cancelled — continues from it rather than starting over.
//
// COOL. A device that reports a serious thermal state is given breathing room
// between frames and fewer estimates; one that reports critical is paused
// until it recovers, and the panel says so.
// ---------------------------------------------------------------------------

struct RelightAnalysisRequest: Sendable {
    let asset: ProjectMediaAsset
    let source: RelightSourceInfo
    /// The clip's source range. Only these frames are analysed.
    let sourceRange: TimelineRange
    /// Where to begin, as a source time. Nil starts at the range's beginning.
    let startAt: TimelineTime?
    let quality: RelightQuality
    let colorMode: ProjectColorMode
}

struct RelightAnalysisProgress: Sendable, Equatable {
    var fraction: Double
    var frames: Int
    var totalFrames: Int
    var isPreparing: Bool
    var isThermallyPaused: Bool
    var estimator: RelightEstimatorKind?
}

struct RelightAnalysisSummary: Sendable {
    var frames: Int
    var estimator: RelightEstimatorKind
}

enum RelightAnalyzer {
    /// The long edge of the image the estimators are shown. Vision's person
    /// segmentation and a depth network both work at about this size, so
    /// handing them more is decode time spent on nothing.
    static let estimatorLongEdge = 640

    static func analyze(
        _ request: RelightAnalysisRequest,
        context: MetalContext,
        progress: @escaping @Sendable (RelightAnalysisProgress) -> Void
    ) async throws -> RelightAnalysisSummary {
        let asset = AVURLAsset(url: request.asset.url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RelightError.message(String(localized: "This clip has no video to analyse."))
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let coordinates = try MaskTrackingCoordinates(encodedSize: naturalSize, preferredTransform: transform)
        let encoded = (width: Int(naturalSize.width.rounded()), height: Int(naturalSize.height.rounded()))
        let analysisSize = RelightStage.fitted(encoded, longEdge: RelightCapability.analysisLongEdge(quality: request.quality))
        let estimatorSize = RelightStage.fitted(encoded, longEdge: estimatorLongEdge)
        guard let gpu = RelightAnalysisGPU(context: context, colorMode: request.colorMode,
                                           analysisSize: analysisSize, estimatorSize: estimatorSize) else {
            throw RelightError.message(String(localized: "This device could not prepare scene analysis."))
        }
        let grid = RelightAnalysisGrid(width: analysisSize.width, height: analysisSize.height,
                                       coordinates: coordinates)
        let cueDetector = RelightSceneCueDetector()
        let structural = RelightStructuralEstimator()
        var model = RelightCoreMLEstimator.loadInstalled()
        var modelFailures = 0
        let parameters: RelightTemporalFusion.Parameters = request.quality == .high ? .high : .fast
        let interval = RelightCapability.keyframeInterval(quality: request.quality)
        let frameSeconds = request.source.frameDurationSeconds
        // Stored at no more than about fifteen frames a second: the depth is
        // fused and smooth, and blending between stored frames costs nothing
        // the eye can find, while storing every frame of 60p would quadruple
        // the cache for nothing.
        let storageStride = max(1, Int((1 / frameSeconds / 15).rounded()))
        let key = RelightDepthStore.Key(identifier: request.source.cacheIdentifier, quality: request.quality)

        let rangeStart = request.sourceRange.start
        let rangeEnd = try request.sourceRange.end
        let start = min(max(request.startAt ?? rangeStart, rangeStart), rangeEnd)
        var passes: [(from: TimelineTime, to: TimelineTime)] = [(start, rangeEnd)]
        if start > rangeStart { passes.append((rangeStart, start)) }
        let totalFrames = max(1, Int(((rangeEnd.seconds - rangeStart.seconds) / frameSeconds).rounded()))
        progress(.init(fraction: 0, frames: 0, totalFrames: totalFrames, isPreparing: true,
                       isThermallyPaused: false, estimator: model == nil ? .structural : .coreML))

        var processed = 0
        var estimatorUsed: RelightEstimatorKind = model == nil ? .structural : .coreML
        var currentRelief: Float = model == nil ? RelightStructuralEstimator.relief : RelightCoreMLEstimator.relief
        let outputSettings = VideoPlaybackController.outputSettings(for: request.colorMode)

        for pass in passes where pass.to > pass.from {
            try Task.checkCancellation()
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw RelightError.message(String(localized: "This clip cannot be decoded for scene analysis."))
            }
            reader.add(output)
            reader.timeRange = CMTimeRange(start: pass.from.cmTime, end: pass.to.cmTime)
            guard reader.startReading() else {
                throw reader.error ?? RelightError.message(String(localized: "Scene analysis could not start."))
            }
            defer { reader.cancelReading() }

            gpu.resetMotion()
            // Continue from depth stored just before this pass begins, when
            // an earlier analysis left some, so its scale carries on.
            var state: RelightTemporalState?
            var resumed = false
            let startIndex = request.source.frameIndex(sourceTime: pass.from)
            for back in 1...max(1, storageStride * 2) {
                if let plane = RelightDepthStore.shared.plane(key, frame: startIndex - Int64(back)),
                   plane.width == analysisSize.width, plane.height == analysisSize.height {
                    state = RelightTemporalFusion.resumed(from: plane)
                    resumed = true
                    break
                }
            }
            var previousSignature: SceneSignature?
            var framesSinceEstimate = Int.max
            var lowReliability = false

            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                let pressure = try await coolDown(progress: progress, processed: processed,
                                                  total: totalFrames, estimator: estimatorUsed)
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
                guard timestamp.isNumeric, CMTimeCompare(timestamp, pass.to.cmTime) < 0,
                      let sourceTime = try? TimelineTime(timestamp) else { continue }
                let index = request.source.frameIndex(sourceTime: sourceTime)

                let signature = SceneSignature.read(pixelBuffer)
                let isCut = SceneSignature.isCut(previousSignature, signature)
                previousSignature = signature
                if isCut { gpu.resetMotion() }

                let effectiveInterval = pressure ? interval * 2 : interval
                let needsEstimate = state == nil || isCut || framesSinceEstimate >= effectiveInterval
                    || (lowReliability && framesSinceEstimate >= 2)
                let frame = try gpu.process(pixelBuffer, wantsEstimatorImage: needsEstimate,
                                            wantsMotion: state != nil && !isCut)

                var reliability: [Float]?
                if var carried = state, !isCut {
                    if let forward = frame.forward {
                        let propagated = RelightTemporalFusion.propagate(carried, forward: forward,
                                                                         backward: frame.backward)
                        carried = propagated.state
                        reliability = propagated.reliability
                    } else if resumed {
                        // The first frame after a resume has no motion to the
                        // stored frame it continues from. It is one frame on,
                        // so it is trusted partially rather than not at all.
                        reliability = [Float](repeating: 0.6, count: carried.count)
                    }
                    state = carried
                }
                resumed = false

                var startsShot = false
                if needsEstimate, let image = frame.estimatorImage {
                    let cues = cueDetector.detect(image: image, grid: grid,
                                                  includeObjects: model == nil)
                    var estimate: RelightEstimate?
                    if let estimator = model {
                        do {
                            estimate = try estimator.estimate(image: image, cues: cues,
                                                              luma: frame.luma, grid: grid)
                        } catch {
                            modelFailures += 1
                            // A model that keeps failing on this device is set
                            // aside for the rest of the analysis rather than
                            // retried on every keyframe.
                            if modelFailures >= 3 { model = nil }
                        }
                    }
                    let result = estimate ?? structural.estimate(cues: cues, grid: grid)
                    estimatorUsed = result.estimator
                    if state == nil || isCut || reliability == nil {
                        state = RelightTemporalFusion.fresh(estimate: result.depth, confidence: result.confidence,
                                                            width: grid.width, height: grid.height)
                        startsShot = isCut
                    } else if var current = state, let reliability {
                        RelightTemporalFusion.fuse(&current, estimate: result.depth,
                                                   estimateConfidence: result.confidence,
                                                   reliability: reliability, parameters: parameters)
                        state = current
                    }
                    framesSinceEstimate = 0
                    currentRelief = result.relief
                } else {
                    framesSinceEstimate = framesSinceEstimate == Int.max ? Int.max : framesSinceEstimate + 1
                }

                guard var current = state else { continue }
                RelightTemporalFusion.settle(&current, reliability: needsEstimate ? nil : reliability,
                                             parameters: parameters)
                let resetRange = startsShot
                let normalised = RelightTemporalFusion.normalized(&current, reset: resetRange,
                                                                  parameters: parameters)
                state = current
                if let reliability {
                    lowReliability = reliability.reduce(0, +) / Float(max(reliability.count, 1)) < 0.55
                }

                if index % Int64(storageStride) == 0 || startsShot {
                    let plane = RelightDepthPlane(
                        width: grid.width, height: grid.height,
                        depth: normalised.depth, confidence: normalised.confidence,
                        startsShot: startsShot, estimator: estimatorUsed, relief: currentRelief)
                    try RelightDepthStore.shared.write(plane, key: key, frame: index)
                }
                processed += 1
                if processed % 3 == 0 {
                    progress(.init(fraction: min(1, Double(processed) / Double(totalFrames)),
                                   frames: processed, totalFrames: totalFrames, isPreparing: false,
                                   isThermallyPaused: false, estimator: estimatorUsed))
                }
            }
            if reader.status == .failed {
                throw reader.error ?? RelightError.message(String(localized: "Scene analysis stopped unexpectedly."))
            }
        }
        guard processed > 0 else {
            throw RelightError.message(String(localized: "No frames could be read from this clip."))
        }
        RelightDepthStore.shared.writeManifest(RelightAnalysisManifest(
            version: RelightSettings.analysisVersion, estimator: estimatorUsed, quality: request.quality,
            analysisWidth: grid.width, analysisHeight: grid.height, stride: storageStride,
            updatedAt: .now), key: key)
        progress(.init(fraction: 1, frames: processed, totalFrames: totalFrames, isPreparing: false,
                       isThermallyPaused: false, estimator: estimatorUsed))
        return RelightAnalysisSummary(frames: processed, estimator: estimatorUsed)
    }

    /// Waits out a critical thermal state, and reports whether the device is
    /// under enough pressure that the caller should do less.
    private static func coolDown(
        progress: @escaping @Sendable (RelightAnalysisProgress) -> Void,
        processed: Int, total: Int, estimator: RelightEstimatorKind
    ) async throws -> Bool {
        var state = ProcessInfo.processInfo.thermalState
        if state == .critical {
            progress(.init(fraction: min(1, Double(processed) / Double(max(total, 1))), frames: processed,
                           totalFrames: total, isPreparing: false, isThermallyPaused: true, estimator: estimator))
            while state == .critical {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                try Task.checkCancellation()
                state = ProcessInfo.processInfo.thermalState
            }
        }
        if state == .serious {
            try await Task.sleep(nanoseconds: 15_000_000)
            return true
        }
        return false
    }
}
