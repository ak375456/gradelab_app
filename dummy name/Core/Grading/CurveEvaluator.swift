import Foundation

// ---------------------------------------------------------------------------
// Curve evaluation
//
// Control points become a continuous function here, on the CPU, once per edit -
// never per pixel. The GPU only ever samples the 1D table this produces.
//
// The smooth mode is **monotone cubic Hermite interpolation** with
// Fritsch-Carlson tangent limiting (Fritsch & Carlson 1980). Ordinary
// Catmull-Rom or natural cubic splines overshoot: pull one point down and the
// curve dips below the neighbouring points on the way there, which on a tone
// curve means crushed blacks the user did not ask for, ringing on gradients,
// and negative values that later stages have to clamp away. Fritsch-Carlson
// rescales the tangents so the curve stays inside the box its own control
// points bound - so a monotone set of points gives a monotone curve, and no
// set of points can produce a value outside the range of the points around it.
// ---------------------------------------------------------------------------

struct CurveEvaluator {
    private let type: CurveType
    private let interpolation: CurveInterpolation
    /// Ascending x. For a cyclic curve this is the single period; evaluation
    /// wraps a query outside it back into range.
    private let xs: [Float]
    private let ys: [Float]
    /// Hermite tangents, one per knot. Empty for linear interpolation.
    private let tangents: [Float]

    init(_ curve: AdvancedCurve) {
        type = curve.type
        interpolation = curve.interpolation
        let sorted = curve.sortedPoints
        xs = sorted.map { min(max($0.x, 0), 1) }
        ys = sorted.map(\.y)
        tangents = interpolation == .monotoneCubic
            ? Self.monotoneTangents(xs: xs, ys: ys, cyclic: curve.type.isCyclic)
            : []
    }

    /// The curve's value at `x`. For cyclic curves any `x` is valid and wraps;
    /// for the rest `x` is clamped to 0...1.
    func value(at x: Float) -> Float {
        guard !xs.isEmpty else { return type.neutralY(at: min(max(x, 0), 1)) }
        guard xs.count > 1 else { return ys[0] }

        if type.isCyclic { return cyclicValue(at: x - x.rounded(.down)) }

        let clamped = min(max(x, 0), 1)
        // Outside the outermost points the curve holds its end value. Mapping
        // curves always carry endpoints at 0 and 1, so this only ever applies
        // to a hue-free adjustment curve whose ends were dragged inward.
        if clamped <= xs[0] { return ys[0] }
        if clamped >= xs[xs.count - 1] { return ys[ys.count - 1] }
        let i = segment(containing: clamped)
        return interpolate(i, i + 1, xs[i], xs[i + 1], clamped)
    }

    // MARK: - Cyclic

    /// Hue is a circle, so the last point joins back to the first across the
    /// 0/1 boundary. That wrap segment is a real segment: it has a width (the
    /// distance the short way round), tangents computed from the points on
    /// either side of the seam, and it is what makes a selection sitting on red
    /// behave the same as one sitting on green.
    private func cyclicValue(at x: Float) -> Float {
        let last = xs.count - 1
        if x >= xs[0] && x <= xs[last] {
            let i = segment(containing: x)
            return interpolate(i, i + 1, xs[i], xs[i + 1], x)
        }
        // In the wrap segment: from the last point forward, through 1/0, to the
        // first point. Shift the query into that segment's own coordinates.
        let start = xs[last]
        let end = xs[0] + 1
        let query = x < xs[0] ? x + 1 : x
        return interpolate(last, 0, start, end, query)
    }

    // MARK: - Segment maths

    private func segment(containing x: Float) -> Int {
        var low = 0
        var high = xs.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if xs[mid] <= x { low = mid } else { high = mid }
        }
        return low
    }

    private func interpolate(_ i: Int, _ j: Int, _ x0: Float, _ x1: Float, _ x: Float) -> Float {
        let h = x1 - x0
        guard h > 1e-9 else { return ys[j] }
        let t = (x - x0) / h
        guard interpolation == .monotoneCubic, !tangents.isEmpty else {
            return ys[i] + (ys[j] - ys[i]) * t
        }
        let t2 = t * t
        let t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        return h00 * ys[i] + h10 * h * tangents[i] + h01 * ys[j] + h11 * h * tangents[j]
    }

    // MARK: - Tangents

    /// Fritsch-Carlson: start from the average of the neighbouring secants,
    /// then shrink any tangent pair whose magnitudes would let the cubic leave
    /// the box its two control points bound.
    private static func monotoneTangents(xs: [Float], ys: [Float], cyclic: Bool) -> [Float] {
        let n = xs.count
        guard n > 1 else { return Array(repeating: 0, count: n) }

        // One secant per segment. A cyclic curve has an extra one closing the
        // circle, whose run is the distance the long way round to 1 and back.
        var widths = [Float](repeating: 0, count: cyclic ? n : n - 1)
        var secants = [Float](repeating: 0, count: cyclic ? n : n - 1)
        for i in 0..<(n - 1) {
            widths[i] = xs[i + 1] - xs[i]
            secants[i] = widths[i] > 1e-9 ? (ys[i + 1] - ys[i]) / widths[i] : 0
        }
        if cyclic {
            widths[n - 1] = (xs[0] + 1) - xs[n - 1]
            secants[n - 1] = widths[n - 1] > 1e-9 ? (ys[0] - ys[n - 1]) / widths[n - 1] : 0
        }

        var m = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let before = i == 0 ? (cyclic ? secants[secants.count - 1] : secants[0]) : secants[i - 1]
            let after = i == n - 1 ? (cyclic ? secants[n - 1] : secants[n - 2]) : secants[i]
            m[i] = (before + after) * 0.5
        }

        for s in 0..<secants.count {
            let i = s
            let j = (s + 1) % n
            if abs(secants[s]) < 1e-9 {
                // Flat segment: both ends must be flat or the cubic bulges.
                m[i] = 0
                m[j] = 0
                continue
            }
            // Tangents pointing against the segment would create an S inside it.
            if m[i] / secants[s] < 0 { m[i] = 0 }
            if m[j] / secants[s] < 0 { m[j] = 0 }
            let a = m[i] / secants[s]
            let b = m[j] / secants[s]
            let magnitude = a * a + b * b
            if magnitude > 9 {
                let scale = 3 / magnitude.squareRoot()
                m[i] = scale * a * secants[s]
                m[j] = scale * b * secants[s]
            }
        }
        return m
    }
}

// ---------------------------------------------------------------------------
// Sampling into the shape the GPU wants
// ---------------------------------------------------------------------------

enum CurveSampling {
    /// Samples per curve.
    ///
    /// 1025 rather than 1024 on purpose: with samples at `i / (count - 1)` the
    /// run is 1024, so the legacy tone-curve anchors at ¼, ½ and ¾ land exactly
    /// on texels 256, 512 and 768. A migrated linear curve is then reproduced
    /// bit-for-bit by the GPU's own linear filter instead of having its corners
    /// rounded off. 1025 samples of 16 bits per curve is 2 KB; all ten rows are
    /// 20 KB.
    static let count = 1025

    /// A curve as normalised 0...1 samples, ready to be quantised.
    ///
    /// Mapping curves are stored directly. Adjustment curves are biased into
    /// 0...1 as `(y + 1) / 2`, because the texture format is unsigned - the
    /// shader undoes it with one multiply-add.
    static func samples(_ curve: AdvancedCurve) -> [Float] {
        let evaluator = CurveEvaluator(curve)
        let mapping = curve.type.isMapping
        let last = Float(count - 1)
        return (0..<count).map { index in
            let y = evaluator.value(at: Float(index) / last)
            let encoded = mapping ? y : (y + 1) * 0.5
            return min(max(encoded, 0), 1)
        }
    }

    /// The same, quantised to the 16-bit unsigned normalised texture format.
    static func quantized(_ curve: AdvancedCurve) -> [UInt16] {
        samples(curve).map { value in
            UInt16(min(max(value, 0), 1) * Float(UInt16.max) + 0.5)
        }
    }
}
