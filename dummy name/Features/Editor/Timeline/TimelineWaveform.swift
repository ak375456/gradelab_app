import Foundation

/// A zoom-aware envelope for one asset's audio.
///
/// `AudioWaveformStore` decodes a single fixed-density envelope per asset —
/// peak magnitude per bin. Drawing that array directly is what produced the
/// old picket fence: zoomed out it sampled every Nth bin and aliased, zoomed
/// in it repeated the same bin across many columns.
///
/// This builds a mip pyramid over it once per asset. Each level halves the bin
/// count and keeps the louder of each pair, so an overview still shows the
/// loud moments instead of whichever bin a column happened to land on. Zoomed
/// in, where a column covers less than one bin, neighbouring bins are
/// interpolated so the envelope reads as a continuous curve rather than a
/// staircase.
///
/// The decoded envelope is magnitude only, so there is no separate negative
/// half to plot. Mirroring it about the centre is the honest representation of
/// that data and is what every editor draws for a peak envelope.
struct TimelineWaveform {
    /// Level 0 is the decoded envelope; each subsequent level is half as long
    /// and keeps the louder of each pair.
    private let peakLevels: [[Float]]
    /// The same pyramid built by averaging instead of by maximum.
    ///
    /// It has to be built alongside rather than derived: once a level has been
    /// max-pooled, the quiet between two transients is gone, and averaging
    /// what is left just returns the transients again.
    private let meanLevels: [[Float]]
    /// Bin count of the decoded envelope, used to size a column in source bins.
    let sourceCount: Int

    init(peaks: [Float]) {
        guard peaks.count > 1 else {
            peakLevels = peaks.isEmpty ? [] : [peaks]
            meanLevels = peakLevels
            sourceCount = peaks.count
            return
        }
        var maxima: [[Float]] = [peaks]
        var means: [[Float]] = [peaks]
        while let finestMax = maxima.last, let finestMean = means.last, finestMax.count > 4 {
            var coarserMax = [Float](), coarserMean = [Float]()
            coarserMax.reserveCapacity((finestMax.count + 1) / 2)
            coarserMean.reserveCapacity((finestMean.count + 1) / 2)
            var index = 0
            while index < finestMax.count {
                let next = index + 1
                if next < finestMax.count {
                    coarserMax.append(max(finestMax[index], finestMax[next]))
                    coarserMean.append((finestMean[index] + finestMean[next]) / 2)
                } else {
                    coarserMax.append(finestMax[index])
                    coarserMean.append(finestMean[index])
                }
                index += 2
            }
            maxima.append(coarserMax)
            means.append(coarserMean)
        }
        peakLevels = maxima
        meanLevels = means
        sourceCount = peaks.count
    }

    var isEmpty: Bool { peakLevels.isEmpty || sourceCount == 0 }

    /// Peak amplitudes in 0...1 for `columns` evenly spaced screen columns
    /// spanning `start...end` as fractions of the source.
    ///
    /// Reusing `into` across frames keeps a scrolling timeline from allocating
    /// a fresh buffer for every clip on every tick.
    func amplitudes(from start: Double, to end: Double, columns: Int, into buffer: inout [Float]) {
        var ignored: [Float] = []
        amplitudes(from: start, to: end, columns: columns, peaks: &buffer, bodies: &ignored)
    }

    /// Peak amplitudes and, alongside them, the average level each column
    /// covers.
    ///
    /// Peak alone is the right answer zoomed in, where a column is a bin or
    /// less. Zoomed out it is not enough: taking the loudest bin of every
    /// column turns bursty audio into a solid band. Drawing the average as a
    /// filled body inside the peak envelope is what every professional editor
    /// does, and it is what makes an overview readable — the body shows where
    /// the sound sits, the envelope shows how far the transients reach. The
    /// two converge as the timeline zooms in, so no switch is needed.
    func amplitudes(from start: Double, to end: Double, columns: Int,
                    peaks: inout [Float], bodies: inout [Float]) {
        guard columns > 0 else {
            peaks.removeAll(keepingCapacity: true)
            bodies.removeAll(keepingCapacity: true)
            return
        }
        Self.reset(&peaks, columns: columns)
        Self.reset(&bodies, columns: columns)
        guard !isEmpty else { return }

        let span = end - start
        guard span.isFinite, span > 0 else { return }

        // Pick the level where one column reads about one bin. Any coarser and
        // detail is thrown away that the zoom could show; any finer and the
        // column is sampling rather than summarising.
        let sourceBinsPerColumn = Double(sourceCount) * span / Double(columns)
        var level = 0
        while level + 1 < peakLevels.count,
              sourceBinsPerColumn / Double(1 << level) > 2 { level += 1 }

        let maxBins = peakLevels[level]
        let meanBins = meanLevels[level]
        let binCount = Double(maxBins.count)
        let binsPerColumn = binCount * span / Double(columns)

        for column in 0..<columns {
            let position = (start + span * (Double(column) + 0.5) / Double(columns)) * binCount
            if binsPerColumn > 1 {
                // Aggregate: the loudest bin this column covers, and the level
                // the column sits at on average.
                let lower = max(0, Int((position - binsPerColumn / 2).rounded(.down)))
                let upper = min(maxBins.count, max(Int((position + binsPerColumn / 2).rounded(.up)), lower + 1))
                var peak: Float = 0
                var total: Float = 0
                for index in lower..<upper {
                    peak = max(peak, maxBins[index])
                    total += meanBins[index]
                }
                peaks[column] = peak
                bodies[column] = total / Float(max(1, upper - lower))
            } else {
                // Interpolate: a smooth curve between decoded bins rather than
                // a run of identical columns. At level zero the two pyramids
                // are the same array, so this reads as one waveform.
                let exact = position - 0.5
                let lower = Int(exact.rounded(.down))
                let fraction = Float(exact - Double(lower))
                let first = min(maxBins.count - 1, max(0, lower))
                let second = min(maxBins.count - 1, max(0, lower + 1))
                peaks[column] = maxBins[first] + (maxBins[second] - maxBins[first]) * fraction
                bodies[column] = meanBins[first] + (meanBins[second] - meanBins[first]) * fraction
            }
        }
    }

    private static func reset(_ buffer: inout [Float], columns: Int) {
        if buffer.count != columns {
            buffer = [Float](repeating: 0, count: columns)
        } else {
            for index in buffer.indices { buffer[index] = 0 }
        }
    }
}

/// Keeps one built pyramid per asset.
///
/// SwiftUI hands the canvas the same `[UUID: [Float]]` on every update, so
/// without this the pyramid would be rebuilt for every clip on every scroll
/// tick. The envelope for an asset never changes once decoded, so identity is
/// its bin count plus its endpoints — enough to notice a genuinely different
/// array without walking thousands of floats.
final class TimelineWaveformCache {
    private struct Entry {
        let signature: Signature
        let waveform: TimelineWaveform
    }
    private struct Signature: Equatable {
        let count: Int
        let first: Float
        let last: Float

        init(_ peaks: [Float]) {
            count = peaks.count
            first = peaks.first ?? 0
            last = peaks.last ?? 0
        }
    }

    private var entries: [UUID: Entry] = [:]
    /// Scratch buffers reused by every sampling call on the main thread.
    private var peakScratch: [Float] = []
    private var bodyScratch: [Float] = []

    func waveform(for assetID: UUID, peaks: [Float]) -> TimelineWaveform {
        let signature = Signature(peaks)
        if let entry = entries[assetID], entry.signature == signature { return entry.waveform }
        let waveform = TimelineWaveform(peaks: peaks)
        entries[assetID] = Entry(signature: signature, waveform: waveform)
        return waveform
    }

    /// Samples into the cache's shared scratch buffers and hands the peak
    /// envelope and the body level to `work`. Both slices are only valid for
    /// the duration of the call.
    func withAmplitudes<Result>(
        of waveform: TimelineWaveform, from start: Double, to end: Double, columns: Int,
        _ work: (ArraySlice<Float>, ArraySlice<Float>) -> Result
    ) -> Result {
        waveform.amplitudes(from: start, to: end, columns: columns,
                            peaks: &peakScratch, bodies: &bodyScratch)
        let count = min(columns, min(peakScratch.count, bodyScratch.count))
        return work(peakScratch[0..<count], bodyScratch[0..<count])
    }

    /// Drops envelopes for assets no longer on the timeline.
    func retain(assetIDs: Set<UUID>) {
        guard entries.count > assetIDs.count else { return }
        entries = entries.filter { assetIDs.contains($0.key) }
    }
}
