@preconcurrency import AVFoundation
@preconcurrency import Vision
import Foundation
import simd

enum StabilizationAnalysis {
    /// Bounded streaming decode: two analysis images, no full-resolution frame
    /// history. Analyze in source order even for a reversed or ramped clip.
    static func analyze(url: URL, range: TimelineRange,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> VideoStabilization {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw StabilizationError.message(String(localized: "This source has no video track to stabilize."))
        }
        let encodedSize = try await track.load(.naturalSize)
        let converter = TrackingLuminance()
        var previous: TrackingFrame?
        var previousBuffer: CVPixelBuffer?
        var trajectory = CGAffineTransform.identity
        var angle = 0.0
        var segment = 0, unreliable = 0, reliable = 0
        var poses: [StabilizationPose] = []
        var analysisSize = CGSize.zero
        var subsampled = false
        var lastProgress = ProcessInfo.processInfo.systemUptime
        let end = try range.end
        progress(0)
        try TrackingFrameSource.read(asset: asset, track: track, from: range.start.cmTime, to: end.cmTime) { sample, time in
            try Task.checkCancellation()
            // 60 motion measurements/sec captures handheld shake while bounding
            // the work for 120/240 fps sources. Actual PTS drives interpolation.
            if let previous, time.seconds-previous.time.seconds < 1/60.0-0.001 { subsampled = true; return true }
            let frame = try converter.frame(sample, time: time)
            if previous == nil { converter.setReference(frame) }
            let buffer = try converter.pixelBuffer(frame)
            analysisSize = CGSize(width: frame.width, height: frame.height)
            if let previous, let previousBuffer {
                // A registration failure breaks the path, not the recording or
                // analysis task. Decode/resource failures still propagate.
                var alignment: CGAffineTransform?
                do {
                    alignment = try register(current: frame, previous: previous, currentBuffer: buffer,
                                             previousBuffer: previousBuffer, converter: converter)
                } catch {
                    try Task.checkCancellation()
                }
                if let alignment, time.seconds-previous.time.seconds <= 0.25 {
                    trajectory = trajectory.concatenating(alignment.inverted())
                    // Unwrap rotation so crossing ±π cannot create a full spin.
                    let measured = atan2(trajectory.b, trajectory.a)
                    var delta = measured-angle
                    while delta > .pi { delta -= 2 * .pi }
                    while delta < -.pi { delta += 2 * .pi }
                    angle += delta
                    reliable += 1
                } else {
                    segment += 1; trajectory = .identity; angle = 0; unreliable += 1
                }
            }
            poses.append(.init(seconds: time.seconds, x: trajectory.tx, y: trajectory.ty,
                               rotation: angle, segment: segment))
            previous = frame; previousBuffer = buffer
            let now = ProcessInfo.processInfo.systemUptime
            if now-lastProgress >= 0.1 {
                progress(min(0.95, 0.95*(time.seconds-range.start.seconds)/max(0.001, range.duration.seconds)))
                lastProgress = now
            }
            guard poses.count < 120_000 else {
                throw StabilizationError.message(String(localized: "This clip is too long for one stabilization pass. Split it into shorter clips and analyze each one."))
            }
            return true
        }
        try Task.checkCancellation()
        guard reliable >= 2, reliable > unreliable else {
            throw StabilizationError.message(String(localized: "There is not enough consistent picture detail to stabilize this clip. Try a shorter section with less blur or subject movement."))
        }
        var solved = try StabilizationPath.solve(poses, size: analysisSize, range: range,
            encodedSize: encodedSize, unreliableFrames: unreliable)
        solved.hasSubsampledMotion = subsampled
        progress(1)
        return solved
    }

    /// Coarse phase registration first, then subpixel roll refinement. Vision's
    /// homography alone has a small convergence basin (including on clean
    /// translated fixtures); prealignment is essential for real handheld shake.
    static func register(current: TrackingFrame, previous: TrackingFrame,
                         currentBuffer: CVPixelBuffer, previousBuffer: CVPixelBuffer,
                         converter: TrackingLuminance) throws -> CGAffineTransform? {
        let translation = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: currentBuffer, options: [:])
        try VNImageRequestHandler(cvPixelBuffer: previousBuffer, orientation: .up).perform([translation])
        guard let coarse = translation.results?.first?.alignmentTransform,
              coarse.tx.isFinite, coarse.ty.isFinite,
              abs(coarse.tx) < Double(current.width)*0.18,
              abs(coarse.ty) < Double(current.height)*0.18 else { return nil }
        let dx = Int(coarse.tx.rounded()), dy = Int(coarse.ty.rounded())
        var seed = matrix_identity_float3x3
        seed[2][0] = Float(dx); seed[2][1] = Float(dy)
        let aligned = shifted(current, x: dx, y: dy)
        let refinement = VNHomographicImageRegistrationRequest(
            targetedCVPixelBuffer: try converter.pixelBuffer(aligned), options: [:])
        do {
            try VNImageRequestHandler(cvPixelBuffer: previousBuffer, orientation: .up).perform([refinement])
            if let observation = refinement.results?.first, observation.confidence >= 0.3,
               let rigid = rigidAlignment(observation.warpTransform*seed, current: current, previous: previous) {
                return rigid
            }
        } catch { try Task.checkCancellation() }
        // Non-planar scenes may refuse a homography but still have a good
        // global translation. It must pass the same luminance agreement test.
        seed[2][0] = Float(coarse.tx); seed[2][1] = Float(coarse.ty)
        return rigidAlignment(seed, current: current, previous: previous)
    }

    private static func shifted(_ frame: TrackingFrame, x: Int, y: Int) -> TrackingFrame {
        var data = Data(repeating: 0, count: frame.luma.count)
        let startX = max(0,x), endX = min(frame.width, frame.width+x)
        frame.luma.withUnsafeBytes { source in
            data.withUnsafeMutableBytes { destination in
                for row in 0..<frame.height {
                    let sourceRow = row+y
                    guard sourceRow >= 0, sourceRow < frame.height, endX > startX else { continue }
                    destination.baseAddress!.advanced(by: row*frame.width+startX)
                        .copyMemory(from: source.baseAddress!.advanced(by: sourceRow*frame.width+startX-x), byteCount: endX-startX)
                }
            }
        }
        return .init(luma: data, width: frame.width, height: frame.height, time: frame.time)
    }

    /// Fit a rigid transform to the registration's central field, retaining
    /// translation and roll but leaving intentional zoom alone. Reject extreme
    /// projective distortion and verify agreement with the actual luminance.
    static func rigidAlignment(_ h: simd_float3x3, current: TrackingFrame,
                               previous: TrackingFrame) -> CGAffineTransform? {
        guard current.width == previous.width, current.height == previous.height,
              (0..<3).allSatisfy({ column in (0..<3).allSatisfy { h[column][$0].isFinite } }) else { return nil }
        let size = CGSize(width: current.width, height: current.height)
        func project(_ point: CGPoint) -> CGPoint? {
            let p = h * SIMD3(Float(point.x), Float(point.y), 1)
            guard abs(p.z) > 0.0001 else { return nil }
            return CGPoint(x: Double(p.x/p.z), y: Double(p.y/p.z))
        }
        var points: [(CGPoint, CGPoint)] = []
        for iy in 1...3 {
            for ix in 1...3 {
                let p = CGPoint(x: size.width*Double(ix)/4, y: size.height*Double(iy)/4)
                guard let q = project(p), q.x.isFinite, q.y.isFinite else { return nil }
                points.append((p,q))
            }
        }
        let count = Double(points.count)
        let centre = CGPoint(x: size.width/2, y: size.height/2)
        let target = CGPoint(x: points.reduce(0) { $0+$1.1.x }/count,
                             y: points.reduce(0) { $0+$1.1.y }/count)
        var dot = 0.0, cross = 0.0, energy = 0.0
        for (p,q) in points {
            let x = p.x-centre.x, y = p.y-centre.y
            let u = q.x-target.x, v = q.y-target.y
            dot += x*u+y*v; cross += x*v-y*u; energy += x*x+y*y
        }
        let rotation = atan2(cross, dot), scale = hypot(dot,cross)/max(1,energy)
        guard abs(rotation) < 0.15, (0.85...1.18).contains(scale),
              abs(target.x-centre.x) < size.width*0.18,
              abs(target.y-centre.y) < size.height*0.18 else { return nil }
        let rigid = CGAffineTransform(translationX: -centre.x, y: -centre.y)
            .concatenating(.init(rotationAngle: rotation))
            .concatenating(.init(translationX: target.x, y: target.y))
        let fitError = points.reduce(0.0) { total, pair in
            let mapped = pair.0.applying(rigid)
            return total + hypot(mapped.x-pair.1.x, mapped.y-pair.1.y)
        }/count
        guard fitError < max(size.width, size.height)*0.035 else { return nil }
        // Image registration uses bottom-left pixel coordinates. The luma
        // arrays are top-first, so invert Y only at the sampling boundary.
        var n = 0.0, sumA = 0.0, sumB = 0.0, aa = 0.0, bb = 0.0, ab = 0.0
        for iy in 1..<16 {
            for ix in 1..<20 {
                let p = CGPoint(x: size.width*Double(ix)/20, y: size.height*Double(iy)/16)
                guard let q = project(p), q.x >= 1, q.x < size.width-1,
                      q.y >= 1, q.y < size.height-1 else { continue }
                let a = Double(current.luma[(current.height-1-Int(p.y))*current.width+Int(p.x)])
                let b = Double(previous.luma[(previous.height-1-Int(q.y))*previous.width+Int(q.x)])
                n += 1; sumA += a; sumB += b; aa += a*a; bb += b*b; ab += a*b
            }
        }
        let varianceA = aa-sumA*sumA/max(n,1), varianceB = bb-sumB*sumB/max(n,1)
        guard n >= 80, varianceA > n*4, varianceB > n*4 else { return nil }
        let correlation = (ab-sumA*sumB/n)/sqrt(varianceA*varianceB)
        guard correlation > 0.35 else { return nil }
        return rigid
    }
}
