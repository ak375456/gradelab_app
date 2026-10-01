import Foundation

// ---------------------------------------------------------------------------
// Temporal depth stability
//
// Monocular depth estimated one frame at a time flickers: the estimator is
// asked a slightly different question by every frame and answers each one
// independently, so a lit cheek would pulse with the grain. Lighting attached
// to that would be unwatchable. So depth is never taken one frame at a time.
//
// The estimator runs on KEYFRAMES — a few per second. Every frame, keyframe or
// not, carries the previous frame's depth forward along measured motion (the
// same pyramidal, forward/backward-checked search noise reduction uses), so a
// surface keeps its depth while it moves. At a keyframe the new estimate is
// first brought onto the same scale as the carried depth — monocular depth is
// only defined up to a scale and an offset, and comparing two raw estimates
// directly is itself a source of flicker — and then only part of the
// difference is taken, spread over the following frames rather than landed
// in one. Where the motion search failed — something came into view, a hand
// crossed the frame — the carried value is worthless and the estimate is
// taken outright.
//
// What is stored is normalised against a slowly moving range, so the depth
// scale a light sees does not jump from frame to frame either.
//
// This file is plain arithmetic on arrays: no Metal, no Vision, no media. It
// is what the unit tests drive directly.
// ---------------------------------------------------------------------------

/// A motion field, as the flow search writes it: per texel of a coarse grid,
/// the displacement (in that grid's pixels) from the current frame to a
/// neighbour, and the match cost.
struct RelightFlowField: Sendable {
    let width: Int
    let height: Int
    /// x, y displacement in grid pixels; z the patch match cost (mean absolute
    /// luma difference, 0…1); w unused.
    let vectors: [SIMD4<Float>]

    var isValid: Bool { width > 0 && height > 0 && vectors.count == width * height }

    /// Bilinear sample at a grid position, clamped to the grid.
    func sample(x: Float, y: Float) -> SIMD4<Float> {
        let cx = min(max(x, 0), Float(width - 1))
        let cy = min(max(y, 0), Float(height - 1))
        let x0 = Int(cx), y0 = Int(cy)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = cx - Float(x0), fy = cy - Float(y0)
        let a = vectors[y0 * width + x0], b = vectors[y0 * width + x1]
        let c = vectors[y1 * width + x0], d = vectors[y1 * width + x1]
        let top = a + (b - a) * fx
        let bottom = c + (d - c) * fx
        return top + (bottom - top) * fy
    }
}

/// The running depth for one analysis pass.
struct RelightTemporalState: Sendable {
    let width: Int
    let height: Int
    /// Nearness, on the scale of the first estimate of this shot.
    var depth: [Float]
    var confidence: [Float]
    /// Correction from the last keyframe still waiting to be applied.
    var pending: [Float]
    /// The slowly moving range the stored depth is normalised against.
    var low: Float
    var high: Float

    var count: Int { width * height }
}

enum RelightTemporalFusion {
    struct Parameters: Sendable {
        /// How much of a reliable pixel's difference from a new estimate is
        /// taken at a keyframe. Lower is steadier and slower to correct.
        var blend: Float
        /// The share of a pending correction applied each frame.
        var spreadRate: Float
        /// How fast the normalisation range follows the content.
        var rangeRate: Float

        static let fast = Parameters(blend: 0.45, spreadRate: 0.4, rangeRate: 0.12)
        static let high = Parameters(blend: 0.32, spreadRate: 0.3, rangeRate: 0.08)
    }

    /// A state that starts from one estimate: the first frame, or the first
    /// frame after a cut.
    static func fresh(estimate: [Float], confidence: [Float], width: Int, height: Int) -> RelightTemporalState {
        let range = percentileRange(estimate)
        return RelightTemporalState(width: width, height: height, depth: estimate,
                                    confidence: confidence,
                                    pending: [Float](repeating: 0, count: width * height),
                                    low: range.low, high: range.high)
    }

    /// A state resumed from a stored frame, so a second analysis pass joins
    /// the first without a seam.
    static func resumed(from plane: RelightDepthPlane) -> RelightTemporalState {
        let depth = plane.depth.map { Float($0) / 65535 }
        let confidence = plane.confidence.map { Float($0) / 255 }
        return RelightTemporalState(width: plane.width, height: plane.height, depth: depth,
                                    confidence: confidence,
                                    pending: [Float](repeating: 0, count: plane.width * plane.height),
                                    low: 0, high: 1)
    }

    /// Carries the previous frame's state onto the current frame.
    ///
    /// - Parameters:
    ///   - forward: motion from the CURRENT frame to the previous one, so each
    ///     current pixel knows where it came from.
    ///   - backward: motion from the previous frame to the current one, used
    ///     only to check the first. Where the two disagree the pixel was
    ///     hidden in one of the frames, and its carried value is not trusted.
    /// - Returns: the carried state and a per-pixel reliability, 0…1.
    static func propagate(
        _ state: RelightTemporalState,
        forward: RelightFlowField,
        backward: RelightFlowField?
    ) -> (state: RelightTemporalState, reliability: [Float]) {
        let width = state.width, height = state.height
        guard forward.isValid, width > 1, height > 1 else {
            return (state, [Float](repeating: 0, count: state.count))
        }
        let scaleX = Float(forward.width) / Float(width)
        let scaleY = Float(forward.height) / Float(height)
        var depth = [Float](repeating: 0, count: state.count)
        var confidence = [Float](repeating: 0, count: state.count)
        var pending = [Float](repeating: 0, count: state.count)
        var reliability = [Float](repeating: 0, count: state.count)

        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                let gx = (Float(x) + 0.5) * scaleX - 0.5
                let gy = (Float(y) + 0.5) * scaleY - 0.5
                let motion = forward.sample(x: gx, y: gy)
                let previousX = Float(x) + motion.x / scaleX
                let previousY = Float(y) + motion.y / scaleY
                let inside = previousX >= -0.5 && previousX <= Float(width) - 0.5
                    && previousY >= -0.5 && previousY <= Float(height) - 0.5
                depth[index] = bilinear(state.depth, width, height, previousX, previousY)
                confidence[index] = bilinear(state.confidence, width, height, previousX, previousY)
                pending[index] = bilinear(state.pending, width, height, previousX, previousY)

                var consistency: Float = 1
                if let backward, backward.isValid {
                    let back = backward.sample(x: (previousX + 0.5) * scaleX - 0.5,
                                               y: (previousY + 0.5) * scaleY - 0.5)
                    let dx = motion.x + back.x, dy = motion.y + back.y
                    let error = (dx * dx + dy * dy).squareRoot()
                    // The first half texel is the coarse grid, not the scene.
                    consistency = min(max(1 - max(error - 0.5, 0) / 1.5, 0), 1)
                }
                let costTerm = min(max(1 - (motion.z - 0.02) / 0.12, 0), 1)
                reliability[index] = inside ? consistency * costTerm : 0
            }
        }
        // Per-pixel agreement is noisy; a 3x3 average keeps a single bad match
        // from punching a hole in an otherwise steady surface.
        reliability = boxBlur3(reliability, width, height)
        var carried = state
        carried.depth = depth
        carried.confidence = confidence
        carried.pending = pending
        return (carried, reliability)
    }

    /// The scale and offset that best put `estimate` on `predicted`'s scale,
    /// weighted toward pixels both can vouch for.
    ///
    /// Monocular depth is affine-invariant: the same scene can come back from
    /// two frames with a different spread and a different zero. Aligning
    /// before blending is what lets a keyframe correct the SHAPE without
    /// jolting the overall depth every time one arrives.
    static func align(estimate: [Float], to predicted: [Float], weights: [Float]) -> (scale: Float, offset: Float) {
        var sw: Double = 0, sx: Double = 0, sy: Double = 0, sxx: Double = 0, sxy: Double = 0
        for index in estimate.indices where index < predicted.count && index < weights.count {
            let w = Double(max(weights[index], 0))
            guard w > 0.01 else { continue }
            let x = Double(estimate[index]), y = Double(predicted[index])
            sw += w; sx += w * x; sy += w * y; sxx += w * x * x; sxy += w * x * y
        }
        // Too little agreement to fit a line through: match the means instead,
        // which still removes the offset jump.
        guard sw > Double(estimate.count) * 0.08 else {
            let meanE = estimate.reduce(0, +) / Float(max(estimate.count, 1))
            let meanP = predicted.reduce(0, +) / Float(max(predicted.count, 1))
            return (1, meanP - meanE)
        }
        let denominator = sw * sxx - sx * sx
        guard abs(denominator) > 1e-9 else { return (1, Float((sy - sx) / sw)) }
        let scale = min(max((sw * sxy - sx * sy) / denominator, 0.4), 2.5)
        let offset = (sy - scale * sx) / sw
        return (Float(scale), Float(offset))
    }

    /// Folds a keyframe's estimate into the carried state.
    static func fuse(
        _ state: inout RelightTemporalState,
        estimate: [Float],
        estimateConfidence: [Float],
        reliability: [Float],
        parameters: Parameters
    ) {
        guard estimate.count == state.count, estimateConfidence.count == state.count,
              reliability.count == state.count else { return }
        var weights = [Float](repeating: 0, count: state.count)
        for index in weights.indices { weights[index] = reliability[index] * estimateConfidence[index] }
        let fit = align(estimate: estimate, to: state.depth, weights: weights)
        for index in 0..<state.count {
            let target = fit.scale * estimate[index] + fit.offset
            let r = reliability[index]
            if r < 0.25 {
                // New content: the carried value describes something else.
                state.depth[index] = target
                state.pending[index] = 0
                state.confidence[index] = estimateConfidence[index] * 0.85
            } else {
                let take = parameters.blend + (1 - parameters.blend) * (1 - r) * 0.6
                // Replaces rather than adds to what was pending: the new
                // target supersedes the old one.
                state.pending[index] = take * (target - state.depth[index])
                state.confidence[index] += (estimateConfidence[index] - state.confidence[index]) * take
            }
        }
    }

    /// One frame's worth of a pending correction, and the confidence decay a
    /// frame without a fresh estimate earns.
    static func settle(_ state: inout RelightTemporalState, reliability: [Float]?, parameters: Parameters) {
        for index in 0..<state.count {
            let step = state.pending[index] * parameters.spreadRate
            state.depth[index] += step
            state.pending[index] -= step
            if let reliability, index < reliability.count {
                state.confidence[index] *= 0.75 + 0.25 * reliability[index]
            }
        }
    }

    /// The state as stored: normalised against a range that moves slowly, so
    /// the depth a light sees keeps its scale from frame to frame.
    static func normalized(_ state: inout RelightTemporalState, reset: Bool,
                           parameters: Parameters) -> (depth: [UInt16], confidence: [UInt8]) {
        let range = percentileRange(state.depth)
        if reset {
            state.low = range.low; state.high = range.high
        } else {
            state.low += (range.low - state.low) * parameters.rangeRate
            state.high += (range.high - state.high) * parameters.rangeRate
        }
        var low = state.low, high = state.high
        if high - low < 0.05 {
            let middle = (low + high) / 2
            low = middle - 0.025; high = middle + 0.025
        }
        let span = high - low
        var depth = [UInt16](repeating: 0, count: state.count)
        var confidence = [UInt8](repeating: 0, count: state.count)
        for index in 0..<state.count {
            let value = min(max((state.depth[index] - low) / span, 0), 1)
            depth[index] = UInt16((value * 65535).rounded())
            let trust = min(max(state.confidence[index], 0), 1)
            confidence[index] = UInt8((trust * 255).rounded())
        }
        return (depth, confidence)
    }

    // MARK: - Helpers

    /// The 2nd and 98th percentiles, from every fourth value. Percentiles
    /// rather than the extremes so one stray pixel cannot stretch the range.
    static func percentileRange(_ values: [Float]) -> (low: Float, high: Float) {
        guard !values.isEmpty else { return (0, 1) }
        var sample: [Float] = []
        sample.reserveCapacity(values.count / 4 + 1)
        var index = 0
        while index < values.count {
            if values[index].isFinite { sample.append(values[index]) }
            index += 4
        }
        guard !sample.isEmpty else { return (0, 1) }
        sample.sort()
        let low = sample[min(sample.count - 1, Int(Float(sample.count - 1) * 0.02))]
        let high = sample[min(sample.count - 1, Int(Float(sample.count - 1) * 0.98))]
        return (low, max(high, low + 1e-4))
    }

    static func bilinear(_ values: [Float], _ width: Int, _ height: Int, _ x: Float, _ y: Float) -> Float {
        let cx = min(max(x, 0), Float(width - 1))
        let cy = min(max(y, 0), Float(height - 1))
        let x0 = Int(cx), y0 = Int(cy)
        let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
        let fx = cx - Float(x0), fy = cy - Float(y0)
        let a = values[y0 * width + x0], b = values[y0 * width + x1]
        let c = values[y1 * width + x0], d = values[y1 * width + x1]
        let top = a + (b - a) * fx
        return top + ((c + (d - c) * fx) - top) * fy
    }

    static func boxBlur3(_ values: [Float], _ width: Int, _ height: Int) -> [Float] {
        guard width > 2, height > 2 else { return values }
        var result = values
        for y in 0..<height {
            for x in 0..<width {
                var total: Float = 0, count: Float = 0
                for dy in -1...1 {
                    let yy = y + dy
                    guard yy >= 0, yy < height else { continue }
                    for dx in -1...1 {
                        let xx = x + dx
                        guard xx >= 0, xx < width else { continue }
                        total += values[yy * width + xx]
                        count += 1
                    }
                }
                result[y * width + x] = total / count
            }
        }
        return result
    }
}
