import Foundation
import simd

// ---------------------------------------------------------------------------
// Shot Match: what a picture is measured as
//
// A profile is a description of a picture's GRADE, not of its contents. That
// distinction is the whole product principle: a reference of a blue ocean under
// an orange sunset and a target of a person indoors have almost nothing in
// common at the pixel level, and matching their histograms would wreck the
// target. What they can share is how the tone is distributed, where neutral
// sits, how the shadows and highlights are tinted relative to neutral, and how
// vivid the colour is.
//
// So everything stored here is either a robust order statistic (percentiles,
// never means over the whole frame) or a quantity measured RELATIVE TO NEUTRAL
// (every chroma reading is normalised to unit luminance, so it says "the
// shadows lean teal by this much", never "the shadows are this colour"). The
// one content-shaped measurement, the hue histogram, is used only to decide how
// alike two scenes are and to characterise a palette in Look mode; it is never
// mapped from one picture onto the other.
// ---------------------------------------------------------------------------

/// The representative pixels a profile was measured from.
///
/// Kept beside the profile rather than inside it, and deliberately not
/// `Codable`: a few thousand pixels are what the solver needs to predict the
/// picture after each stage, and they are worthless the moment the frame
/// changes. What is worth persisting is the summary, which is small, stable and
/// meaningful a year later.
///
/// Linear analysis-space RGB, so the solver's arithmetic is the shader's.
struct ShotSamples: Sendable {
    var linear: [SIMD3<Float>]

    var isEmpty: Bool { linear.isEmpty }
}

/// Percentile levels every profile carries, as fractions.
///
/// Both tails are sampled twice. p1/p99 find the real black and white points,
/// which a single 5/95 pair cannot distinguish from ordinary shadow and
/// highlight detail, and p5/p95 are what the exposure and contrast stages
/// actually solve against because they survive a few dead pixels and a specular
/// glint.
enum ShotPercentile {
    static let levels: [Float] = [0.01, 0.05, 0.10, 0.25, 0.50, 0.75, 0.90, 0.95, 0.99]
    static let p1 = 0, p5 = 1, p10 = 2, p25 = 3, p50 = 4, p75 = 5, p90 = 6, p95 = 7, p99 = 8
}

/// The three tonal ranges the wheels address, measured with the shader's own
/// weights so what is measured is what a wheel will move.
enum ShotZone: Int, CaseIterable, Sendable {
    case shadows = 0, midtones = 1, highlights = 2

    /// The weight this zone gives a pixel at a given **linear** luminance.
    /// Transcribed from `applyGradeCore`, which reads the wheels' tonal
    /// position from linear luminance rather than from the encoded value.
    static func weights(linearLuminance: Float) -> SIMD3<Float> {
        let position = min(max(linearLuminance, 0), 1)
        let sw = 1 - ShotMatchColor.smoothstep(0.02, 0.35, position)
        let hw = ShotMatchColor.smoothstep(0.35, 0.95, position)
        return SIMD3(sw, max(0, 1 - sw - hw), hw)
    }
}

/// A colour stored for JSON without dragging SIMD's own representation into the
/// document format.
struct ShotRGB: Codable, Equatable, Sendable {
    var r: Float, g: Float, b: Float

    init(_ value: SIMD3<Float>) { r = value.x; g = value.y; b = value.z }
    var simd: SIMD3<Float> { SIMD3(r, g, b) }

    static let neutral = ShotRGB(SIMD3(repeating: 1))
}

/// Everything Shot Match knows about one picture.
///
/// `Codable` on purpose: a reference is analysed once and its profile is what
/// gets kept — in memory while the reference is active, and in the project
/// document so a match survives the reference image being moved or deleted. A
/// picture that has been measured never needs to be found again.
struct ShotProfile: Codable, Equatable, Sendable {
    /// Bumped when a measurement changes meaning. A stored profile from an
    /// older version is re-analysed rather than compared against numbers that
    /// no longer mean the same thing.
    static let currentVersion = 1
    var version: Int = ShotProfile.currentVersion
    var space: ShotMatchAnalysisSpace = .rec709Display

    /// Encoded-luma percentiles at `ShotPercentile.levels`.
    ///
    /// Encoded rather than linear because the OETF is monotonic, so a
    /// percentile survives it exactly: `toLinear(p)` is the linear percentile,
    /// and storing the encoded value keeps the numbers readable against the
    /// waveform the app already draws.
    var luminancePercentiles: [Float]

    /// A 65-entry cumulative distribution of encoded luma, used to derive the
    /// residual tone mapping. Coarse on purpose: a finer CDF only adds noise to
    /// a curve that is smoothed and slope-limited immediately afterwards.
    var luminanceCDF: [Float]

    /// Mean linear RGB of the pixels that are plausibly neutral, normalised to
    /// unit luminance. `(1,1,1)` means no cast.
    var neutralBias: ShotRGB
    /// Share of pixels that qualified as neutral. Below a few percent the
    /// estimate is a grey-world guess over the whole frame and the solver damps
    /// the white-balance stage accordingly.
    var neutralCoverage: Float

    /// Per-zone chroma, each normalised to unit luminance — the tint of the
    /// shadows, midtones and highlights relative to neutral, never their colour.
    var zoneChroma: [ShotRGB]
    /// Per-zone mean linear luminance.
    var zoneLuminance: [Float]

    /// HSL saturation at the 10th, 50th and 90th percentiles, over pixels with
    /// enough luminance for saturation to mean anything.
    var saturationPercentiles: [Float]

    /// Twelve hue bins, weighted by saturation, normalised to sum to one.
    /// Characterises a palette; never mapped onto the target.
    var hueDistribution: [Float]

    /// Share of pixels at the very bottom and very top of the encoded range.
    var shadowClipping: Float
    var highlightClipping: Float
    /// Share of pixels that were above diffuse white before analysis normalised
    /// them. Zero for SDR. This is what keeps the solver from reading an HDR
    /// clip's specular highlights as blown ones.
    var headroomFraction: Float

    var sampleCount: Int

    // MARK: Derived

    func percentile(_ index: Int) -> Float {
        luminancePercentiles.indices.contains(index) ? luminancePercentiles[index] : 0
    }

    /// A percentile in linear light.
    func linearPercentile(_ index: Int) -> Float {
        ShotMatchColor.toLinear(percentile(index))
    }

    /// Distance between the 5th and 95th percentiles in stops — how much of the
    /// range the picture actually uses.
    var dynamicRangeStops: Float {
        let low = max(linearPercentile(ShotPercentile.p5), 1e-4)
        let high = max(linearPercentile(ShotPercentile.p95), low * 1.0001)
        return log2(high / low)
    }

    var medianSaturation: Float {
        saturationPercentiles.indices.contains(1) ? saturationPercentiles[1] : 0
    }

    func zone(_ zone: ShotZone) -> SIMD3<Float> {
        zoneChroma.indices.contains(zone.rawValue) ? zoneChroma[zone.rawValue].simd : SIMD3(repeating: 1)
    }

    func zoneLuminance(_ zone: ShotZone) -> Float {
        zoneLuminance.indices.contains(zone.rawValue) ? zoneLuminance[zone.rawValue] : 0
    }

    var isUsable: Bool { sampleCount >= 256 && luminancePercentiles.count == ShotPercentile.levels.count }

    /// This profile's tone scale moved by `stops`, with its shape untouched.
    ///
    /// Used to build the goal a damped match aims at. When the solver decides
    /// it will only take part of a measured exposure difference — because the
    /// reference is a snowfield and the shot is a night interior — every other
    /// control has to be told the same thing. Handing contrast and the
    /// tonal-range sliders the reference's own percentiles while exposure holds
    /// back would have them spend their whole travel putting back the stop
    /// exposure deliberately declined, and the damping would achieve nothing
    /// except an uglier set of numbers.
    ///
    /// Only the level moves. Percentile ratios, and therefore contrast and
    /// everything derived from the SHAPE of the tone distribution, are
    /// unchanged — which is the point: the style carries across in full even
    /// when the brightness does not.
    func scalingExposure(by stops: Float) -> ShotProfile {
        guard stops != 0, stops.isFinite else { return self }
        let scale = exp2(stops)
        func moved(_ encoded: Float) -> Float {
            ShotMatchColor.toEncoded(ShotMatchColor.toLinear(encoded) * scale)
        }
        var result = self
        result.luminancePercentiles = luminancePercentiles.map(moved)
        // The CDF is sampled at fixed levels, so moving it means asking, at
        // each level, what share of the picture used to sit at the level that
        // has now arrived here.
        let last = luminanceCDF.count - 1
        guard last > 0 else { return result }
        result.luminanceCDF = (0...last).map { bin in
            let level = Float(bin) / Float(last)
            let source = ShotMatchColor.toEncoded(ShotMatchColor.toLinear(level) / scale)
            return ShotMatchForwardModel.sampleToneCurve(luminanceCDF, source)
        }
        return result
    }
}

// ---------------------------------------------------------------------------
// Analysis
// ---------------------------------------------------------------------------

/// Turns analysis-space pixels into a `ShotProfile`.
///
/// Pure, synchronous and free of any dependency on Metal, the timeline or the
/// editor: it takes an array of colours and returns a value. That is what lets
/// the same code measure a reference image, a target clip, a frame sampled from
/// the middle of a shot and, later, a batch of eight clips, without any of
/// those callers knowing about each other.
enum ShotAnalyzer {
    /// A pixel must be at least this saturated before its hue is counted, and
    /// at most this saturated to be considered neutral.
    static let neutralSaturationLimit: Float = 0.12
    /// Below this encoded luma a pixel's colour is noise, and above it a pixel
    /// is close enough to clipping that its hue is the sensor's, not the
    /// scene's.
    static let neutralLumaRange: ClosedRange<Float> = 0.10...0.90

    static func profile(
        linearSamples samples: [SIMD3<Float>],
        headroomFraction: Float = 0,
        space: ShotMatchAnalysisSpace = .rec709Display
    ) -> ShotProfile {
        guard !samples.isEmpty else { return empty(space: space) }

        var encodedLuma = [Float](); encodedLuma.reserveCapacity(samples.count)
        var neutralSum = SIMD3<Double>.zero
        var neutralCount = 0
        var greySum = SIMD3<Double>.zero
        var greyWeight = 0.0
        var zoneSum = [SIMD3<Double>](repeating: .zero, count: 3)
        var zoneLumaSum = [Double](repeating: 0, count: 3)
        var zoneWeight = [Double](repeating: 0, count: 3)
        /// Plain membership, unweighted by brightness. `zoneWeight` is biased
        /// toward brighter pixels so a zone's CHROMA is measured where there is
        /// colour to measure; a zone's own brightness has to be the honest mean
        /// over everything in it, so it gets its own denominator.
        var zoneMembership = [Double](repeating: 0, count: 3)
        var saturations = [Float]()
        var hues = [Float](repeating: 0, count: 12)
        var shadowClipped = 0, highlightClipped = 0

        for sample in samples {
            // Clamped exactly where the shader clamps: `applyGradeCore` ends
            // with `saturate(linearToRec709(color))`, so anything the grade has
            // pushed past white or below black is measured as the clipped value
            // it will actually be. Measuring the unclipped number instead would
            // let the solver keep chasing a highlight that the pipeline has
            // already flattened, and it would report a dynamic range the
            // picture does not have.
            let linear = simd_clamp(sample, .zero, .one)
            let encoded = ShotMatchColor.toEncoded(linear)
            let luma = ShotMatchColor.luminance(encoded)
            encodedLuma.append(luma)
            if luma <= 0.004 { shadowClipped += 1 }
            if luma >= 0.996 { highlightClipped += 1 }

            let saturation = ShotMatchColor.saturation(encoded: encoded)
            let linearLuma = max(ShotMatchColor.luminance(linear), 1e-6)

            // Neutral estimate. Only low-saturation pixels in the middle of the
            // range: a saturated object tells you what colour it is, not what
            // colour the light was, and near either end the channels are
            // compressed toward each other and every pixel looks neutral.
            if saturation <= neutralSaturationLimit, neutralLumaRange.contains(luma) {
                neutralSum += SIMD3<Double>(linear / linearLuma)
                neutralCount += 1
            }
            // Grey-world fallback, weighted down by saturation so a frame with
            // no neutral at all still yields something better than a flat mean.
            let greyW = Double(max(0, 1 - saturation) * min(linearLuma, 1))
            greySum += SIMD3<Double>(linear / linearLuma) * greyW
            greyWeight += greyW

            let weights = ShotZone.weights(linearLuminance: Float(linearLuma))
            for zone in 0..<3 {
                let membership = Double(weights[zone])
                guard membership > 0 else { continue }
                zoneMembership[zone] += membership
                zoneLumaSum[zone] += Double(linearLuma) * membership
                let w = membership * Double(min(linearLuma, 4))
                guard w > 0 else { continue }
                zoneSum[zone] += SIMD3<Double>(linear / linearLuma) * w
                zoneWeight[zone] += w
            }

            if neutralLumaRange.lowerBound...1 ~= luma {
                saturations.append(saturation)
            }
            if saturation > neutralSaturationLimit, let hue = ShotMatchColor.hue(encoded: encoded) {
                let bin = min(11, Int(hue * 12))
                hues[bin] += saturation * min(Float(linearLuma), 1)
            }
        }

        encodedLuma.sort()
        let percentiles = ShotPercentile.levels.map { percentile(encodedLuma, $0) }
        saturations.sort()
        let saturationPercentiles = [0.10, 0.50, 0.90].map { percentile(saturations, Float($0)) }

        let neutralCoverage = Float(neutralCount) / Float(samples.count)
        let bias: SIMD3<Float>
        if neutralCount >= max(24, samples.count / 200) {
            bias = normalizedToUnitLuminance(SIMD3<Float>(neutralSum / Double(neutralCount)))
        } else if greyWeight > 0 {
            bias = normalizedToUnitLuminance(SIMD3<Float>(greySum / greyWeight))
        } else {
            bias = SIMD3(repeating: 1)
        }

        let chroma = (0..<3).map { zone -> ShotRGB in
            guard zoneWeight[zone] > 0 else { return .neutral }
            return ShotRGB(normalizedToUnitLuminance(SIMD3<Float>(zoneSum[zone] / zoneWeight[zone])))
        }
        // Weighted by the zone's own membership, so "the shadows are this
        // bright" means the pixels the shadow wheel would actually move.
        let zoneLuma = (0..<3).map { zone -> Float in
            zoneMembership[zone] > 0 ? Float(zoneLumaSum[zone] / zoneMembership[zone]) : 0
        }

        let hueTotal = hues.reduce(0, +)
        let hueDistribution = hueTotal > 0 ? hues.map { $0 / hueTotal } : hues

        return ShotProfile(
            version: ShotProfile.currentVersion,
            space: space,
            luminancePercentiles: percentiles,
            luminanceCDF: cumulative(encodedLuma),
            neutralBias: ShotRGB(bias),
            neutralCoverage: neutralCoverage,
            zoneChroma: chroma,
            zoneLuminance: zoneLuma,
            saturationPercentiles: saturationPercentiles,
            hueDistribution: hueDistribution,
            shadowClipping: Float(shadowClipped) / Float(samples.count),
            highlightClipping: Float(highlightClipped) / Float(samples.count),
            headroomFraction: headroomFraction,
            sampleCount: samples.count)
    }

    /// The average of several frames' profiles.
    ///
    /// A clip is not one frame. Matching a whole shot from a single frame means
    /// a passing cloud or a camera flash decides the grade for the entire clip,
    /// which is exactly the failure this avoids: several frames are sampled
    /// across the shot and their measurements averaged. Percentiles, chroma and
    /// saturation average directly; clipping and coverage are shares and
    /// average the same way.
    static func merged(_ profiles: [ShotProfile]) -> ShotProfile? {
        let usable = profiles.filter(\.isUsable)
        guard let first = usable.first else { return profiles.first }
        guard usable.count > 1 else { return first }
        let n = Float(usable.count)

        func mean(_ pick: (ShotProfile) -> [Float]) -> [Float] {
            let lists = usable.map(pick)
            guard let width = lists.first?.count, lists.allSatisfy({ $0.count == width }) else {
                return pick(first)
            }
            return (0..<width).map { index in lists.reduce(0) { $0 + $1[index] } / n }
        }
        func meanRGB(_ pick: (ShotProfile) -> [ShotRGB]) -> [ShotRGB] {
            let lists = usable.map(pick)
            guard let width = lists.first?.count, lists.allSatisfy({ $0.count == width }) else {
                return pick(first)
            }
            return (0..<width).map { index in
                ShotRGB(normalizedToUnitLuminance(
                    lists.reduce(SIMD3<Float>.zero) { $0 + $1[index].simd } / n))
            }
        }
        func meanValue(_ pick: (ShotProfile) -> Float) -> Float {
            usable.reduce(0) { $0 + pick($1) } / n
        }

        var result = first
        result.luminancePercentiles = mean(\.luminancePercentiles)
        result.luminanceCDF = mean(\.luminanceCDF)
        result.neutralBias = ShotRGB(normalizedToUnitLuminance(
            usable.reduce(SIMD3<Float>.zero) { $0 + $1.neutralBias.simd } / n))
        result.neutralCoverage = meanValue(\.neutralCoverage)
        result.zoneChroma = meanRGB(\.zoneChroma)
        result.zoneLuminance = mean(\.zoneLuminance)
        result.saturationPercentiles = mean(\.saturationPercentiles)
        result.hueDistribution = mean(\.hueDistribution)
        result.shadowClipping = meanValue(\.shadowClipping)
        result.highlightClipping = meanValue(\.highlightClipping)
        result.headroomFraction = meanValue(\.headroomFraction)
        result.sampleCount = usable.reduce(0) { $0 + $1.sampleCount }
        return result
    }

    static func empty(space: ShotMatchAnalysisSpace = .rec709Display) -> ShotProfile {
        ShotProfile(
            version: ShotProfile.currentVersion,
            space: space,
            luminancePercentiles: Array(repeating: 0, count: ShotPercentile.levels.count),
            luminanceCDF: Array(repeating: 0, count: 65),
            neutralBias: .neutral,
            neutralCoverage: 0,
            zoneChroma: Array(repeating: .neutral, count: 3),
            zoneLuminance: [0, 0, 0],
            saturationPercentiles: [0, 0, 0],
            hueDistribution: Array(repeating: 0, count: 12),
            shadowClipping: 0,
            highlightClipping: 0,
            headroomFraction: 0,
            sampleCount: 0)
    }

    // MARK: - Helpers

    /// A colour scaled so its Rec.709 luminance is exactly 1.
    ///
    /// Every chroma reading in a profile goes through this. It is what separates
    /// "how this picture is tinted" from "how bright this picture is", so the
    /// white-balance and wheel stages cannot accidentally solve an exposure
    /// difference as a colour cast.
    static func normalizedToUnitLuminance(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let luma = ShotMatchColor.luminance(rgb)
        guard luma > 1e-6, luma.isFinite else { return SIMD3(repeating: 1) }
        let normalized = rgb / luma
        return normalized.x.isFinite && normalized.y.isFinite && normalized.z.isFinite
            ? normalized : SIMD3(repeating: 1)
    }

    /// Linear-interpolated percentile of a sorted array.
    static func percentile(_ sorted: [Float], _ fraction: Float) -> Float {
        guard !sorted.isEmpty else { return 0 }
        guard sorted.count > 1 else { return sorted[0] }
        let position = min(max(fraction, 0), 1) * Float(sorted.count - 1)
        let index = Int(position)
        guard index < sorted.count - 1 else { return sorted[sorted.count - 1] }
        return sorted[index] + (sorted[index + 1] - sorted[index]) * (position - Float(index))
    }

    /// The share of pixels at or below each of 65 evenly spaced encoded levels.
    static func cumulative(_ sortedLuma: [Float], bins: Int = 65) -> [Float] {
        guard !sortedLuma.isEmpty else { return Array(repeating: 0, count: bins) }
        var result = [Float](repeating: 0, count: bins)
        var index = 0
        for bin in 0..<bins {
            let level = Float(bin) / Float(bins - 1)
            while index < sortedLuma.count, sortedLuma[index] <= level { index += 1 }
            result[bin] = Float(index) / Float(sortedLuma.count)
        }
        return result
    }
}
