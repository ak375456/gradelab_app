import XCTest
@testable import GradeLab

final class TimelineWaveformTests: XCTestCase {

    private func sample(_ waveform: TimelineWaveform, from: Double = 0, to: Double = 1,
                        columns: Int) -> [Float] {
        var buffer: [Float] = []
        waveform.amplitudes(from: from, to: to, columns: columns, into: &buffer)
        return buffer
    }

    func testAnEmptyEnvelopeDrawsNothingRatherThanCrashing() {
        let waveform = TimelineWaveform(peaks: [])
        XCTAssertTrue(waveform.isEmpty)
        XCTAssertEqual(sample(waveform, columns: 10), [Float](repeating: 0, count: 10))
        XCTAssertTrue(sample(waveform, columns: 0).isEmpty)
    }

    func testZoomingOutAggregatesRatherThanSamplingSoLoudMomentsSurvive() {
        // One loud transient in an otherwise quiet 4096-bin envelope. Sampling
        // every Nth bin — what the old picket-fence drawing did — loses it
        // almost every time; max-pooling cannot.
        var peaks = [Float](repeating: 0.05, count: 4096)
        peaks[1234] = 1
        let waveform = TimelineWaveform(peaks: peaks)
        for columns in [8, 17, 40, 123, 400] {
            let values = sample(waveform, columns: columns)
            XCTAssertEqual(values.count, columns)
            XCTAssertEqual(values.max() ?? 0, 1, accuracy: 0.0001,
                           "the transient vanished at \(columns) columns")
        }
    }

    func testTheAggregateLandsInTheColumnThatActuallyCoversTheTransient() {
        var peaks = [Float](repeating: 0, count: 1000)
        peaks[750] = 1
        let waveform = TimelineWaveform(peaks: peaks)
        let columns = 50
        let values = sample(waveform, columns: columns)
        let loudest = try? XCTUnwrap(values.firstIndex(of: values.max() ?? 0))
        // 750/1000 of the way along 50 columns is column 37 or 38.
        XCTAssertNotNil(loudest)
        XCTAssertEqual(Double(loudest ?? 0), 37.5, accuracy: 1.5)
    }

    func testZoomingInInterpolatesInsteadOfRepeatingBins() {
        // Four bins stretched over many columns: the result has to climb
        // smoothly, not sit on four plateaus.
        let waveform = TimelineWaveform(peaks: [0, 0.25, 0.5, 1])
        let values = sample(waveform, columns: 64)
        XCTAssertEqual(values.count, 64)
        let distinct = Set(values.map { ($0 * 1000).rounded() })
        XCTAssertGreaterThan(distinct.count, 8, "a staircase, not an interpolated envelope")
        // Monotone input stays monotone.
        for index in 1..<values.count {
            XCTAssertGreaterThanOrEqual(values[index] + 1e-6, values[index - 1])
        }
    }

    func testAmplitudesStayInRangeAndCoverOnlyTheRequestedWindow() {
        let peaks = (0..<512).map { Float(sin(Double($0) / 9) * 0.5 + 0.5) }
        let waveform = TimelineWaveform(peaks: peaks)
        let whole = sample(waveform, columns: 200)
        XCTAssertTrue(whole.allSatisfy { $0 >= 0 && $0 <= 1 })

        // A window over the quiet half must not pick up the loud half.
        var quiet = [Float](repeating: 0.02, count: 512)
        for index in 256..<512 { quiet[index] = 1 }
        let split = TimelineWaveform(peaks: quiet)
        XCTAssertEqual(sample(split, from: 0, to: 0.45, columns: 64).max() ?? 0, 0.02, accuracy: 0.001)
        XCTAssertEqual(sample(split, from: 0.55, to: 1, columns: 64).max() ?? 0, 1, accuracy: 0.001)
    }

    func testDegenerateWindowsAreHandledRatherThanDividedBy() {
        let waveform = TimelineWaveform(peaks: [0.2, 0.9, 0.4])
        XCTAssertEqual(sample(waveform, from: 0.5, to: 0.5, columns: 8), [Float](repeating: 0, count: 8))
        XCTAssertEqual(sample(waveform, from: 1, to: 0, columns: 8), [Float](repeating: 0, count: 8))
        // A single-bin envelope has no pyramid to build but still draws.
        let single = TimelineWaveform(peaks: [0.7])
        XCTAssertFalse(single.isEmpty)
        XCTAssertEqual(sample(single, columns: 4), [Float](repeating: 0.7, count: 4))
    }
}

extension TimelineWaveformTests {
    private func both(_ waveform: TimelineWaveform, from: Double = 0, to: Double = 1,
                      columns: Int) -> (peaks: [Float], bodies: [Float]) {
        var peaks: [Float] = [], bodies: [Float] = []
        waveform.amplitudes(from: from, to: to, columns: columns, peaks: &peaks, bodies: &bodies)
        return (peaks, bodies)
    }

    func testTheBodyLevelSitsInsideThePeakEnvelopeWhenAggregating() {
        // Bursty: loud transients over near silence. Zoomed out, every column
        // covers several bins, so the peak reaches the transients while the
        // body stays near the average — which is what makes the overview
        // readable instead of a solid block.
        var peaks = [Float](repeating: 0.02, count: 2000)
        for index in stride(from: 0, to: 2000, by: 25) { peaks[index] = 1 }
        let waveform = TimelineWaveform(peaks: peaks)
        let sampled = both(waveform, columns: 40)
        XCTAssertEqual(sampled.peaks.count, 40)
        for (peak, body) in zip(sampled.peaks, sampled.bodies) {
            XCTAssertLessThanOrEqual(body, peak + 1e-6, "the body must never exceed the envelope")
        }
        XCTAssertEqual(sampled.peaks.max() ?? 0, 1, accuracy: 0.001)
        XCTAssertLessThan(sampled.bodies.max() ?? 1, 0.5, "the body is an average, not another peak")
    }

    func testPeakAndBodyConvergeOnceEveryColumnIsABinOrLess() {
        let waveform = TimelineWaveform(peaks: (0..<64).map { Float(($0 % 8)) / 8 })
        let sampled = both(waveform, columns: 400)
        for (peak, body) in zip(sampled.peaks, sampled.bodies) {
            XCTAssertEqual(peak, body, accuracy: 1e-6,
                           "zoomed in there is nothing to average, so the two must be one waveform")
        }
    }
}

final class TimelineWaveformCacheTests: XCTestCase {

    func testTheSameEnvelopeIsNotRebuiltOnEveryDraw() {
        let cache = TimelineWaveformCache()
        let id = UUID()
        let peaks = (0..<256).map { Float($0) / 256 }
        let first = cache.waveform(for: id, peaks: peaks)
        let second = cache.waveform(for: id, peaks: peaks)
        XCTAssertEqual(first.sourceCount, second.sourceCount)

        // A genuinely different envelope for the same asset must replace it.
        let replaced = cache.waveform(for: id, peaks: Array(peaks.prefix(128)))
        XCTAssertEqual(replaced.sourceCount, 128)
    }

    func testEnvelopesForAssetsNoLongerOnTheTimelineAreReleased() {
        let cache = TimelineWaveformCache()
        let kept = UUID(), dropped = UUID()
        _ = cache.waveform(for: kept, peaks: [0.1, 0.2, 0.3, 0.4])
        _ = cache.waveform(for: dropped, peaks: [0.5, 0.6, 0.7, 0.8])
        cache.retain(assetIDs: [kept])
        // The dropped entry is rebuilt from scratch, which is observable as a
        // fresh pyramid rather than as an error; the kept one is untouched.
        XCTAssertEqual(cache.waveform(for: kept, peaks: [0.1, 0.2, 0.3, 0.4]).sourceCount, 4)
        XCTAssertEqual(cache.waveform(for: dropped, peaks: [0.9]).sourceCount, 1)
    }

    func testSharedScratchBuffersHandBackExactlyTheRequestedColumns() {
        let cache = TimelineWaveformCache()
        let waveform = cache.waveform(for: UUID(), peaks: (0..<64).map { Float($0) / 64 })
        for columns in [120, 40, 200] {
            let counts = cache.withAmplitudes(of: waveform, from: 0, to: 1, columns: columns) {
                ($0.count, $1.count)
            }
            XCTAssertEqual(counts.0, columns, "a reused buffer must not leak the previous frame's width")
            XCTAssertEqual(counts.1, columns)
        }
    }
}
