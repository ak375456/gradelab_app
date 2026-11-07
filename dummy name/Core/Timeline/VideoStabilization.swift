import CoreGraphics
import CoreMedia
import Foundation

/// Source-time corrections, independent of placement, speed, orientation and grade.
/// Kept in the document so reopening/exporting never depends on an analysis cache.
struct StabilizationSample: Codable, Equatable, Sendable {
    var seconds: Double
    var x: Double // translation as a fraction of encoded width, Y-up
    var y: Double // translation as a fraction of encoded height
    var rotation: Double // radians, about the encoded picture's centre
    var segment: Int
}

struct VideoStabilization: Codable, Equatable, Sendable {
    var isEnabled = true
    var strength: Double = 0.8
    var cropZoom: Double = 1
    var encodedWidth: Int
    var encodedHeight: Int
    var analyzedRange: TimelineRange
    var samples: [StabilizationSample]
    var limitedCorrection = false
    var unreliableFrames = 0
    /// High-rate sources can have frames between the bounded motion samples.
    var hasSubsampledMotion: Bool? = nil

    static let maximumZoom = 1.35

    func covers(_ range: TimelineRange) -> Bool {
        guard let end = try? range.end, let analyzedEnd = try? analyzedRange.end else { return false }
        return range.start >= analyzedRange.start && end <= analyzedEnd
    }

    func adjustingStrength(_ requested: Double) -> Self {
        var copy = self
        copy.strength = requested.isFinite ? min(1, max(0, requested)) : 0.8
        copy.cropZoom = samples.reduce(1) {
            max($0, Self.requiredZoom($1, strength: copy.strength,
                                     size: CGSize(width: encodedWidth, height: encodedHeight)))
        }
        return copy
    }

    /// A fixed crop for the whole analysed take: no per-frame zoom pumping.
    static func requiredZoom(_ sample: StabilizationSample, strength: Double, size: CGSize) -> Double {
        let w = max(1, size.width), h = max(1, size.height)
        let angle = sample.rotation * strength
        let c = abs(cos(angle)), s = abs(sin(angle))
        let dx = sample.x * w * strength, dy = sample.y * h * strength
        let rotatedX = abs(cos(angle) * dx + sin(angle) * dy)
        let rotatedY = abs(-sin(angle) * dx + cos(angle) * dy)
        let availableW = w - 2 * rotatedX, availableH = h - 2 * rotatedY
        guard availableW > 0, availableH > 0 else { return .infinity }
        return max(1, (c*w + s*h) / availableW, (s*w + c*h) / availableH)
    }

    func correction(at seconds: Double, size: CGSize, interpolates: Bool = true) -> CGAffineTransform {
        guard isEnabled, strength.isFinite, strength > 0, cropZoom.isFinite, cropZoom >= 1,
              encodedWidth > 0, encodedHeight > 0, samples.count > 1,
              seconds.isFinite, size.width > 0, size.height > 0 else { return .identity }
        // Binary search matters when a long take has tens of thousands of frames.
        var lo = 0, hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].seconds <= seconds + 0.00001 { lo = mid + 1 } else { hi = mid }
        }
        let a = samples[max(0, lo - 1)], b = samples[min(samples.count - 1, lo)]
        let mix = interpolates && a.segment == b.segment && b.seconds > a.seconds
            ? min(1, max(0, (seconds - a.seconds) / (b.seconds - a.seconds))) : 0
        let x = (a.x + (b.x-a.x)*mix) * strength * size.width
        let y = (a.y + (b.y-a.y)*mix) * strength * size.height
        let rotation = (a.rotation + (b.rotation-a.rotation)*mix) * strength
        guard x.isFinite, y.isFinite, rotation.isFinite else { return .identity }
        return CGAffineTransform(translationX: -size.width/2, y: -size.height/2)
            .concatenating(.init(rotationAngle: rotation))
            .concatenating(.init(translationX: x, y: y))
            .concatenating(.init(scaleX: cropZoom, y: cropZoom))
            .concatenating(.init(translationX: size.width/2, y: size.height/2))
    }
}

extension VideoClip {
    var resolvedStabilization: VideoStabilization? {
        guard let stabilization, stabilization.isEnabled, stabilization.covers(sourceRange) else { return nil }
        return stabilization
    }

    func stabilizationCorrection(at composition: CMTime, size: CGSize) -> CGAffineTransform {
        guard let settings = resolvedStabilization, let time = try? TimelineTime(composition),
              let source = try? sourceTime(at: time) else { return .identity }
        // A held source frame must keep its correction too. Interpolating a
        // camera correction under sampled slow motion would move a still frame
        // between source updates and reintroduce judder. Blended/flow frames and
        // high-rate sources analysed below native FPS need interpolation.
        let interpolates = smoothsMotion || settings.hasSubsampledMotion == true
        return settings.correction(at: source.seconds, size: size, interpolates: interpolates)
    }
}

/// Rigid global camera poses, in analysis pixels. We deliberately discard the
/// homography's perspective/shear: bending buildings to follow a moving subject
/// produces the rubbery look that a camera stabilizer must avoid.
struct StabilizationPose: Sendable {
    var seconds: Double
    var x: Double
    var y: Double
    var rotation: Double
    var segment: Int
}

enum StabilizationPath {
    /// Symmetric Gaussian local-linear regression removes shake without lag.
    /// Unlike a causal filter it sees both sides of the frame; unlike an edge-
    /// truncated average it preserves the velocity of a steady pan at the ends.
    static func solve(_ poses: [StabilizationPose], size: CGSize,
                      range: TimelineRange, encodedSize: CGSize,
                      unreliableFrames: Int = 0) throws -> VideoStabilization {
        guard poses.count > 1, size.width > 0, size.height > 0 else {
            throw StabilizationError.message(String(localized: "This clip is too short to stabilize."))
        }
        var corrections: [StabilizationSample] = []
        corrections.reserveCapacity(poses.count)
        var segmentStart = 0
        while segmentStart < poses.count {
            try Task.checkCancellation()
            var segmentEnd = segmentStart + 1
            while segmentEnd < poses.count, poses[segmentEnd].segment == poses[segmentStart].segment { segmentEnd += 1 }
            var left = segmentStart, right = segmentStart
            for index in segmentStart..<segmentEnd {
                if index % 128 == 0 { try Task.checkCancellation() }
                let pose = poses[index]
                let radius = 1.5, sigma = 0.5
                while left < index, poses[left].seconds < pose.seconds-radius { left += 1 }
                while right < segmentEnd, poses[right].seconds <= pose.seconds+radius { right += 1 }
                var sw = 0.0, st = 0.0, stt = 0.0
                var sx = SIMD3<Double>.zero, stx = SIMD3<Double>.zero
                for neighbour in left..<right {
                    let other = poses[neighbour], t = other.seconds-pose.seconds
                    let w = exp(-0.5 * t*t/(sigma*sigma))
                    let value = SIMD3(other.x, other.y, other.rotation)
                    sw += w; st += w*t; stt += w*t*t
                    sx += value*w; stx += value*(w*t)
                }
                let determinant = sw*stt-st*st
                let smooth = determinant > 1e-10 ? (sx*stt-stx*st)/determinant : sx/max(sw, 1e-10)
                let current = CGAffineTransform(rotationAngle: pose.rotation)
                    .concatenating(.init(translationX: pose.x, y: pose.y))
                let desired = CGAffineTransform(rotationAngle: smooth.z)
                    .concatenating(.init(translationX: smooth.x, y: smooth.y))
                let correction = current.inverted().concatenating(desired)
                let centre = CGPoint(x: size.width/2, y: size.height/2)
                let moved = centre.applying(correction)
                // Fade corrections at registration breaks/cuts, without joining
                // unrelated shots or pulling the camera through a failed frame.
                let head = segmentStart == 0 ? 1 : min(1, (pose.seconds-poses[segmentStart].seconds)/0.15)
                let tail = segmentEnd == poses.count ? 1 : min(1, (poses[segmentEnd-1].seconds-pose.seconds)/0.15)
                let fade = max(0, min(head, tail))
                corrections.append(.init(seconds: pose.seconds,
                    x: (moved.x-centre.x)/size.width*fade,
                    y: (moved.y-centre.y)/size.height*fade,
                    rotation: (smooth.z-pose.rotation)*fade, segment: pose.segment))
            }
            segmentStart = segmentEnd
        }
        // Prefer a little residual movement to an extreme crop. Attenuate the
        // whole path once, so hitting the crop budget cannot cause a local jump.
        func maximumCrop(_ amount: Double) -> Double {
            corrections.reduce(1) { max($0, VideoStabilization.requiredZoom($1, strength: amount, size: size)) }
        }
        let limited = maximumCrop(1) > VideoStabilization.maximumZoom
        if limited {
            var low = 0.0, high = 1.0
            for _ in 0..<24 {
                let mid = (low+high)/2
                if maximumCrop(mid) <= VideoStabilization.maximumZoom { low = mid } else { high = mid }
            }
            corrections = corrections.map {
                var sample = $0; sample.x *= low; sample.y *= low; sample.rotation *= low; return sample
            }
        }
        return VideoStabilization(encodedWidth: Int(encodedSize.width), encodedHeight: Int(encodedSize.height),
            analyzedRange: range, samples: corrections, limitedCorrection: limited,
            unreliableFrames: unreliableFrames).adjustingStrength(0.8)
    }
}

enum StabilizationError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
