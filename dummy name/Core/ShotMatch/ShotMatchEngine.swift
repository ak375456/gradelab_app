@preconcurrency import Metal
import CoreMedia
import Foundation

// ---------------------------------------------------------------------------
// Shot Match: the engine
//
// Sequences decode → analyse → solve, off the main thread, with the reference's
// measurement cached so matching ten clips against one reference analyses that
// reference once.
//
// It owns no UI state and no document state. The editor asks it for a
// measurement or for a solution and gets a value back; what to do with that —
// where to put it, how to undo it, what to draw — belongs to the editor, and
// keeping the line there is what will let a batch match, a reference library and
// a masked match reuse every line of this.
// ---------------------------------------------------------------------------

/// What the panel is waiting for, so it can say so rather than just spinning.
enum ShotMatchProgress: Equatable, Sendable {
    case analyzingReference
    case analyzingShot
    case matching

    var message: String {
        switch self {
        case .analyzingReference: String(localized: "Analyzing reference…")
        case .analyzingShot: String(localized: "Analyzing current shot…")
        case .matching: String(localized: "Matching…")
        }
    }
}

enum ShotMatchError: LocalizedError {
    case noFrames
    case analysisUnavailable
    case notEnoughDetail

    var errorDescription: String? {
        switch self {
        case .noFrames:
            String(localized: "No frame could be read to analyze.")
        case .analysisUnavailable:
            String(localized: "Shot Match could not start on this device.")
        case .notEnoughDetail:
            // A frame of one flat colour genuinely cannot be matched: there is
            // no tonal distribution to compare and no neutral to find. Saying so
            // is better than returning values derived from nothing.
            String(localized: "There is not enough detail in this picture to match.")
        }
    }
}

/// What to measure.
///
/// A value rather than a set of arguments so the cache has something to key on:
/// two requests that describe the same picture with the same grade are the same
/// measurement, and the engine can say so without re-decoding anything.
struct ShotMatchRequest: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// A clip, sampled at one moment.
        case clipFrame(url: URL, seconds: Double)
        /// A clip, sampled across its length and averaged.
        case clipAverage(url: URL, range: TimelineRange)
        /// An imported still.
        case image(url: URL)
    }

    var source: Source
    /// The grade the picture is carrying. Part of the key: the same frame with a
    /// different grade is a different picture.
    var grade: GradeSettings
    var masks: [MaskedGradeLayer]
    var colorMode: ProjectColorMode
    var fallbackMatrix: String?

    var isClipAverage: Bool {
        if case .clipAverage = source { return true }
        return false
    }
}

/// Analysis and solving, off the main thread.
///
/// An actor rather than a lock: every entry point is async already, the cache is
/// the only shared state, and an actor makes "two panels asking for the same
/// reference at once" resolve into one analysis without any locking written by
/// hand.
actor ShotMatchEngine {
    /// How many measurements to keep.
    ///
    /// Eight covers the case this exists for: a reference, plus the run of
    /// shots being matched to it one after another. A profile is about a
    /// kilobyte, so keeping eight of them costs nothing.
    private static let cacheLimit = 8

    /// How many of those keep their pixels.
    ///
    /// The samples are the expensive part — around 150,000 colours, near two
    /// megabytes — and only the shot being corrected needs them, because only
    /// it is re-graded during the solve. A reference is consulted through its
    /// profile alone. So the two are aged out separately: profiles stay, and
    /// pixels are dropped as soon as the next couple of shots have been
    /// measured. Keeping all eight would cost fifteen megabytes to hold frames
    /// nothing will read again.
    private static let sampleCacheLimit = 2

    private struct Entry {
        var request: ShotMatchRequest
        var profile: ShotProfile
        /// Dropped once this measurement has aged out of `sampleCacheLimit`.
        /// A cache hit that finds no samples re-decodes, which is the right
        /// trade: it is rare, and the alternative is holding every frame of
        /// every clip in a sequence.
        var samples: ShotSamples?
    }

    private let renderer: ShotMatchAnalysisRenderer
    private let appleLogRenderingLUT: MTLTexture?
    private var cache: [Entry] = []

    init?(context: MetalContext, appleLogRenderingLUT: MTLTexture?) {
        guard let renderer = ShotMatchAnalysisRenderer(context: context) else { return nil }
        self.renderer = renderer
        self.appleLogRenderingLUT = appleLogRenderingLUT
    }

    /// Drops every cached measurement. Called when the panel closes, and when a
    /// clip's media changes underneath it.
    func invalidate() {
        cache.removeAll()
        renderer.release()
    }

    /// A measurement already taken, if it is still held.
    ///
    /// Only the profile, which is the part that never ages out. This is what
    /// makes matching a run of clips against one reference decode that
    /// reference once: the reference's pixels are dropped after a couple of
    /// shots, and nothing ever asks for them again.
    func cachedProfile(_ request: ShotMatchRequest) -> ShotProfile? {
        cache.first { $0.request == request }?.profile
    }

    /// Measures a picture, reusing the answer if it has already been measured.
    ///
    /// The samples come back too, because the solver needs them for the shot it
    /// is correcting. A reference only ever needs its profile, which is why that
    /// is the part the document keeps.
    func measure(
        _ request: ShotMatchRequest,
        progress: (@Sendable (ShotMatchProgress) -> Void)? = nil
    ) async throws -> (profile: ShotProfile, samples: ShotSamples) {
        if let hit = cache.first(where: { $0.request == request }), let samples = hit.samples {
            return (hit.profile, samples)
        }
        let frames = try await decode(request)
        try Task.checkCancellation()

        var profiles: [ShotProfile] = []
        var pooled: [SIMD3<Float>] = []
        for pixels in frames {
            try Task.checkCancellation()
            guard let measured = renderer.analyze(
                pixelBuffer: pixels.buffer,
                grade: request.grade,
                masks: request.masks,
                colorMode: request.colorMode,
                fallbackMatrix: request.fallbackMatrix,
                appleLogRenderingLUT: appleLogRenderingLUT
            ) else { continue }
            guard !measured.samples.isEmpty else { continue }
            profiles.append(ShotAnalyzer.profile(
                linearSamples: measured.samples, headroomFraction: measured.headroomFraction))
            pooled.append(contentsOf: measured.samples)
        }
        guard let profile = ShotAnalyzer.merged(profiles), profile.isUsable else {
            throw profiles.isEmpty ? ShotMatchError.noFrames : ShotMatchError.notEnoughDetail
        }
        let samples = ShotSamples(linear: pooled)
        store(Entry(request: request, profile: profile, samples: samples))
        return (profile, samples)
    }

    /// The whole operation: measure both pictures, then solve.
    ///
    /// `referenceProfile` is offered as an input so a match against a reference
    /// that has already been measured — a saved one, or the eighth clip in a
    /// sequence — never decodes it again. That is the same mechanism a batch
    /// match will use, which is why the reference arrives as a profile rather
    /// than as a request the engine would have to re-derive it from.
    func match(
        shot: ShotMatchRequest,
        reference: ShotMatchRequest?,
        referenceProfile: ShotProfile?,
        components: ShotMatchComponents,
        mode: ShotMatchMode,
        progress: (@Sendable (ShotMatchProgress) -> Void)? = nil
    ) async throws -> (solution: ShotMatchSolution, reference: ShotProfile) {
        let resolved: ShotProfile
        if let referenceProfile, referenceProfile.isUsable {
            resolved = referenceProfile
        } else if let reference, let cached = cachedProfile(reference), cached.isUsable {
            resolved = cached
        } else if let reference {
            progress?(.analyzingReference)
            resolved = try await measure(reference).profile
        } else {
            throw ShotMatchError.noFrames
        }
        try Task.checkCancellation()

        progress?(.analyzingShot)
        let measured = try await measure(shot)
        try Task.checkCancellation()

        progress?(.matching)
        let solution = MatchSolver.solve(
            targetSamples: measured.samples,
            target: measured.profile,
            reference: resolved,
            components: components,
            mode: mode)
        return (solution, resolved)
    }

    /// Re-solves without re-measuring anything.
    ///
    /// What the component toggles and the mode switch call. Both change the
    /// answer and neither changes the pictures, so paying for a decode would be
    /// paying for nothing — and would put a visible pause on a checkbox.
    func resolve(
        shot: ShotMatchRequest,
        referenceProfile: ShotProfile,
        components: ShotMatchComponents,
        mode: ShotMatchMode
    ) async throws -> ShotMatchSolution {
        let measured = try await measure(shot)
        return MatchSolver.solve(
            targetSamples: measured.samples,
            target: measured.profile,
            reference: referenceProfile,
            components: components,
            mode: mode)
    }

    // MARK: - Decoding

    private func decode(_ request: ShotMatchRequest) async throws -> [ShotMatchPixels] {
        switch request.source {
        case .clipFrame(let url, let seconds):
            return try await ShotMatchFrameSource.videoFrames(
                url: url,
                at: [CMTime(seconds: max(0, seconds), preferredTimescale: 600)],
                colorMode: request.colorMode)
        case .clipAverage(let url, let range):
            return try await ShotMatchFrameSource.videoFrames(
                url: url,
                at: ShotMatchFrameSource.sampleTimes(range: range),
                colorMode: request.colorMode)
        case .image(let url):
            return [try await ShotMatchFrameSource.stillFrame(url: url)]
        }
    }

    private func store(_ entry: Entry) {
        cache.removeAll { $0.request == entry.request }
        cache.insert(entry, at: 0)
        if cache.count > Self.cacheLimit { cache.removeLast(cache.count - Self.cacheLimit) }
        for index in cache.indices where index >= Self.sampleCacheLimit {
            cache[index].samples = nil
        }
    }
}
