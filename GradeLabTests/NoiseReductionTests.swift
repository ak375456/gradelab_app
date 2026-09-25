import AVFoundation
import CoreVideo
import XCTest
@testable import GradeLab

/// The document side of noise reduction: what a project stores, what it decodes
/// to, what export asks to be paid for, and what a device is allowed to run.
///
/// The engine itself is measured in `Scripts/validate-noise-reduction.sh`,
/// which drives the shipping shaders on the GPU with synthetic footage whose
/// noise and motion are known exactly. That belongs there rather than here: a
/// denoiser is judged by how much noise came out and how much detail stayed,
/// and neither question can be asked without a noise-free copy of the picture
/// to compare against.
final class NoiseReductionModelTests: XCTestCase {

    // MARK: - Persistence

    func testAProjectThatNeverOpensThePanelStoresNothing() {
        let project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/a.mov"),
                                   displayName: "a", metadata: makeVideoMetadata(durationSeconds: 5))
        XCTAssertNil(project.timeline.firstVideoClip?.gradeSettings.advanced?.noiseReduction)
        XCTAssertNil(AdvancedGrade.neutral.resolvedNoiseReduction)
    }

    func testProjectsSavedBeforeNoiseReductionDecodeWithItOff() throws {
        let json = #"{"curves":[],"hsl":[],"wheels":[],"vignette":0,"vignetteMidpoint":50,"vignetteFeather":70}"#
        let grade = try JSONDecoder().decode(AdvancedGrade.self, from: Data(json.utf8))
        XCTAssertNil(grade.noiseReduction)
        XCTAssertNil(grade.resolvedNoiseReduction)
    }

    func testEverySettingSurvivesSaveAndReload() throws {
        var grade = AdvancedGrade.neutral
        var noise = NoiseReduction.neutral
        noise.isTemporalEnabled = true
        noise.frames = .five
        noise.temporalLuma = 45; noise.temporalChroma = 70
        noise.motionThreshold = 38; noise.detailProtection = 62
        noise.isMotionCompensated = false
        noise.isSpatialEnabled = true
        noise.spatialLuma = 25; noise.spatialChroma = 55
        noise.radius = 48; noise.detailRecovery = 33
        noise.protectsEdges = false
        noise.quality = .high
        grade.noiseReduction = noise

        let reloaded = try JSONDecoder().decode(
            AdvancedGrade.self, from: try JSONEncoder().encode(grade))
        XCTAssertEqual(reloaded.noiseReduction, noise)
    }

    func testHandEditedValuesAreClampedForTheRenderer() {
        var grade = AdvancedGrade.neutral
        var noise = NoiseReduction.neutral
        noise.isSpatialEnabled = true
        noise.spatialLuma = 5_000
        noise.spatialChroma = -20
        noise.radius = .nan
        grade.noiseReduction = noise
        let resolved = grade.resolvedNoiseReduction
        XCTAssertEqual(resolved?.spatialLuma, 100)
        XCTAssertEqual(resolved?.spatialChroma, 0)
        XCTAssertEqual(resolved?.radius, 0)
    }

    /// A module switched on with every strength at zero must resolve to nil.
    /// Every render path skips the engine on exactly this test, and the Pro
    /// gate charges on it, so it has to mean "cannot change a pixel".
    func testSwitchedOnButTurnedDownIsNotActive() {
        var grade = AdvancedGrade.neutral
        var noise = NoiseReduction.neutral
        noise.isTemporalEnabled = true
        noise.isSpatialEnabled = true
        grade.noiseReduction = noise
        XCTAssertNil(grade.resolvedNoiseReduction)
        XCTAssertFalse(noise.isActive)
    }

    func testStrengthsWithoutTheirSwitchDoNothing() {
        var noise = NoiseReduction.neutral
        noise.temporalLuma = 80
        noise.spatialLuma = 80
        XCTAssertFalse(noise.isActive, "A strength with its section switched off must not render")
    }

    // MARK: - The temporal window

    func testTheWindowReachesAsFarAsTheFrameCountSays() {
        var noise = NoiseReduction.neutral
        noise.isTemporalEnabled = true
        noise.temporalLuma = 50

        noise.frames = .two
        XCTAssertEqual(noise.temporalReach.backward, 1)
        XCTAssertEqual(noise.temporalReach.forward, 0,
                       "Two frames is the current frame and the past one, so it never waits on a frame that has not been decoded")
        noise.frames = .three
        XCTAssertEqual(noise.temporalReach.backward, 1)
        XCTAssertEqual(noise.temporalReach.forward, 1)
        noise.frames = .five
        XCTAssertEqual(noise.temporalReach.backward, 2)
        XCTAssertEqual(noise.temporalReach.forward, 2)
    }

    func testATemporalSettingWithNoStrengthFetchesNoFrames() {
        var noise = NoiseReduction.neutral
        noise.isTemporalEnabled = true
        noise.frames = .five
        XCTAssertEqual(noise.temporalReach.backward, 0)
        XCTAssertEqual(noise.temporalReach.forward, 0,
                       "Nothing should keep a decoder alive for a stage that cannot change a pixel")
    }

    // MARK: - Pro gating

    func testActiveNoiseReductionIsGatedAtExport() {
        var settings = GradeSettings.neutral
        var advanced = AdvancedGrade.neutral
        advanced.noiseReduction = NoiseReduction.Preset.medium.applied(to: .neutral)
        settings.advanced = advanced
        XCTAssertTrue(ProAccessPolicy.gradeRequirements(settings).contains(.noiseReduction))
    }

    func testAPanelThatWasOpenedButLeftNeutralIsNotGated() {
        var settings = GradeSettings.neutral
        var advanced = AdvancedGrade.neutral
        var noise = NoiseReduction.neutral
        noise.isTemporalEnabled = true
        advanced.noiseReduction = noise
        settings.advanced = advanced
        XCTAssertFalse(ProAccessPolicy.gradeRequirements(settings).contains(.noiseReduction),
                       "Nothing that cannot change the exported file may ask to be paid for")
    }

    // MARK: - Device capability

    func testAMachineWithRoomRunsTheWidestWindow() {
        let capability = NoiseReductionCapability.resolve(
            width: 1920, height: 1080, physicalMemory: 16 * 1024 * 1024 * 1024)
        XCTAssertTrue(capability.supportsTemporal)
        XCTAssertEqual(capability.maximumFrames, .five)
        XCTAssertEqual(capability.availableFrames.count, 3)
    }

    func testA4KProjectOnASmallDeviceIsNarrowedRatherThanRefused() {
        let capability = NoiseReductionCapability.resolve(
            width: 3840, height: 2160, physicalMemory: 4 * 1024 * 1024 * 1024)
        var authored = NoiseReduction.neutral
        authored.isTemporalEnabled = true
        authored.frames = .five
        authored.temporalLuma = 60
        let rendered = capability.constrained(authored)
        XCTAssertLessThanOrEqual(rendered.frames.rawValue, capability.maximumFrames.rawValue)
        if capability.reduces(authored) {
            XCTAssertNotEqual(rendered.frames, .five)
        }
        // Whatever it can run, the document is untouched: a project authored on
        // a Mac keeps its five-frame window and gets it back on a Mac.
        XCTAssertEqual(authored.frames, .five)
    }

    func testTheCostOfAWindowGrowsWithItsWidth() {
        let none = NoiseReductionStage.approximateBytes(width: 1920, height: 1080, neighbours: 0)
        let two = NoiseReductionStage.approximateBytes(width: 1920, height: 1080, neighbours: 2)
        let four = NoiseReductionStage.approximateBytes(width: 1920, height: 1080, neighbours: 4)
        XCTAssertLessThan(none, two)
        XCTAssertLessThan(two, four)
        let uhd = NoiseReductionStage.approximateBytes(width: 3840, height: 2160, neighbours: 4)
        XCTAssertGreaterThan(uhd, four * 3, "Four times the pixels should cost roughly four times as much")
    }

    // MARK: - Auto

    func testAutoSuggestsMoreForNoisierFootage() {
        let capability = NoiseReductionCapability.resolve(
            width: 1920, height: 1080, physicalMemory: 16 * 1024 * 1024 * 1024)
        let clean = NoiseProfile(luma: 0.0015, chroma: 0.002, shadowLuma: 0.002, shadowCoverage: 0.2)
        let noisy = NoiseProfile(luma: 0.02, chroma: 0.035, shadowLuma: 0.04, shadowCoverage: 0.4)
        let gentle = clean.suggestion(for: .neutral, capability: capability)
        let strong = noisy.suggestion(for: .neutral, capability: capability)
        XCTAssertLessThan(gentle.temporalLuma, strong.temporalLuma)
        XCTAssertLessThan(gentle.spatialChroma, strong.spatialChroma)
        XCTAssertTrue(strong.isActive)
    }

    func testAutoLeavesTheJudgementControlsAlone() {
        let capability = NoiseReductionCapability.resolve(
            width: 1920, height: 1080, physicalMemory: 16 * 1024 * 1024 * 1024)
        var current = NoiseReduction.neutral
        current.motionThreshold = 12
        current.detailProtection = 88
        let suggested = NoiseProfile(luma: 0.01, chroma: 0.01, shadowLuma: 0.01, shadowCoverage: 0.3)
            .suggestion(for: current, capability: capability)
        XCTAssertEqual(suggested.motionThreshold, 12,
                       "How cautious to be is a judgement, not a measurement")
        XCTAssertEqual(suggested.detailProtection, 88)
    }

    func testAutoNeverSuggestsSomethingTheDeviceCannotRun() {
        let capability = NoiseReductionCapability.resolve(
            width: 3840, height: 2160, physicalMemory: 3 * 1024 * 1024 * 1024)
        let suggestion = NoiseProfile(luma: 0.05, chroma: 0.06, shadowLuma: 0.07, shadowCoverage: 0.5)
            .suggestion(for: .neutral, capability: capability)
        XCTAssertLessThanOrEqual(suggestion.frames.rawValue, capability.maximumFrames.rawValue)
        if !capability.supportsTemporal {
            XCTAssertFalse(suggestion.isTemporalEnabled)
            XCTAssertTrue(suggestion.spatialIsActive,
                          "With no temporal window available the spatial stage has to carry it")
        }
    }
}

/// Scene-cut detection and the sliding window that feeds the export.
final class TemporalFrameSupplyTests: XCTestCase {

    private func frame(luma: UInt8, rightHalf: UInt8? = nil) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 48,
                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer)
        guard let buffer else { fatalError("Could not allocate a test frame") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0..<48 {
            for x in 0..<64 {
                base[y * stride + x] = (x >= 32 ? rightHalf : nil) ?? luma
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    func testTwoFramesOfTheSameShotAreNotACut() {
        let a = SceneSignature.read(frame(luma: 120))
        let b = SceneSignature.read(frame(luma: 124))
        XCTAssertNotNil(a)
        XCTAssertFalse(SceneSignature.isCut(a, b))
    }

    func testADifferentShotIsACut() {
        let a = SceneSignature.read(frame(luma: 40))
        let b = SceneSignature.read(frame(luma: 210))
        XCTAssertTrue(SceneSignature.isCut(a, b))
    }

    func testMovementWithinAShotIsNotACut() {
        // Half the frame changing brightness is a large local change and a
        // small global one. Treating it as a cut would throw away the temporal
        // window every time something moved.
        let a = SceneSignature.read(frame(luma: 110, rightHalf: 120))
        let b = SceneSignature.read(frame(luma: 110, rightHalf: 150))
        XCTAssertFalse(SceneSignature.isCut(a, b))
    }

    func testAFrameFormatItCannotReadIsNotReportedAsACut() {
        XCTAssertFalse(SceneSignature.isCut(nil, SceneSignature.read(frame(luma: 100))),
                       "An unknown layout must fall back to the per-pixel rejection, not refuse every neighbour")
    }

    // MARK: - The export window

    /// One decoded frame, as the window sees it.
    private func sample(_ index: Int, luma: UInt8) -> (sample: CMSampleBuffer, time: CMTime) {
        let buffer = frame(luma: luma)
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: CMTimeValue(index), timescale: 30),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format!,
            sampleTiming: &timing, sampleBufferOut: &sample)
        return (sample!, timing.presentationTimeStamp)
    }

    func testTheWindowHoldsFramesBackAndThenReleasesThem() throws {
        let window = TemporalExportWindow(backward: 2, forward: 2)
        var index = 0
        let total = 8
        func read() throws -> (sample: CMSampleBuffer, time: CMTime)? {
            guard index < total else { return nil }
            defer { index += 1 }
            return sample(index, luma: 120)
        }

        var emitted: [(time: CMTime, neighbours: [NoiseFrame])] = []
        while let step = try window.next(read: read) {
            emitted.append((step.frame.time, step.neighbours))
        }
        XCTAssertEqual(emitted.count, total, "Every frame has to be written, window or no window")

        // The first frame has no past and the last has no future, and both are
        // handled by offering fewer neighbours rather than by failing.
        XCTAssertEqual(emitted[0].neighbours.filter { $0.offset < 0 }.count, 0)
        XCTAssertEqual(emitted[0].neighbours.filter { $0.offset > 0 }.count, 2)
        XCTAssertEqual(emitted[total - 1].neighbours.filter { $0.offset > 0 }.count, 0)
        XCTAssertEqual(emitted[total - 1].neighbours.filter { $0.offset < 0 }.count, 2)
        // And a frame in the middle gets the whole window.
        XCTAssertEqual(Set(emitted[4].neighbours.map(\.offset)), [-2, -1, 1, 2])
    }

    func testTheWindowStopsAtACut() throws {
        let window = TemporalExportWindow(backward: 2, forward: 2)
        var index = 0
        // A cut between frames 3 and 4.
        func read() throws -> (sample: CMSampleBuffer, time: CMTime)? {
            guard index < 8 else { return nil }
            defer { index += 1 }
            return sample(index, luma: index < 4 ? 40 : 210)
        }
        var emitted: [(time: CMTime, neighbours: [NoiseFrame])] = []
        while let step = try window.next(read: read) {
            emitted.append((step.frame.time, step.neighbours))
        }
        // The last frame of the outgoing shot may look back but not forward.
        XCTAssertEqual(emitted[3].neighbours.filter { $0.offset > 0 }.count, 0,
                       "Nothing from the next shot may reach this frame")
        // The first frame of the incoming shot may look forward but not back.
        XCTAssertEqual(emitted[4].neighbours.filter { $0.offset < 0 }.count, 0)
        XCTAssertEqual(emitted[4].neighbours.filter { $0.offset > 0 }.count, 2)
    }

    func testAWindowWithNoReachStillWritesEveryFrame() throws {
        let window = TemporalExportWindow(backward: 0, forward: 0)
        var index = 0
        func read() throws -> (sample: CMSampleBuffer, time: CMTime)? {
            guard index < 4 else { return nil }
            defer { index += 1 }
            return sample(index, luma: 100)
        }
        var count = 0
        while let step = try window.next(read: read) {
            XCTAssertTrue(step.neighbours.isEmpty)
            count += 1
        }
        XCTAssertEqual(count, 4)
    }
}

// MARK: - The preview cache

/// `TemporalFrameCache` against a real decoded file, because every failure it
/// has is a timing failure and none of them shows in a picture.
///
/// `prefetch` is called on **every draw**. Anything that leaves its window
/// permanently unsatisfiable therefore does not merely fail — it tears down and
/// rebuilds an AVAssetReader sixty times a second, each rebuild decoding from
/// the preceding sync sample, against a player already decoding the same file.
/// That is what these tests count.
final class TemporalFrameCacheTests: XCTestCase {

    private static let frameCount = 90
    private static let size = (width: 160, height: 120)
    private var url: URL!

    override func setUp() async throws {
        try await super.setUp()
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gradelab-temporal-\(UUID().uuidString).mov")
        try await Self.writeMovie(to: url)
    }

    override func tearDown() async throws {
        if let url { try? FileManager.default.removeItem(at: url) }
        try await super.tearDown()
    }

    /// A short H.264 file with moving content, so the encoder produces real
    /// inter-frame dependencies and a seek genuinely costs a decode back to the
    /// preceding sync sample.
    private static func writeMovie(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size.width,
                kCVPixelBufferHeightKey as String: size.height
            ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for index in 0..<frameCount {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, size.width, size.height,
                                kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw XCTSkip("Could not allocate a frame") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            // A bar that moves, so consecutive frames are not identical.
            let bar = (index * 3) % size.width
            for y in 0..<size.height {
                for x in 0..<size.width {
                    let value: UInt8 = abs(x - bar) < 12 ? 230 : 60
                    let offset = y * stride + x * 4
                    base[offset] = value; base[offset + 1] = value
                    base[offset + 2] = value; base[offset + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(writer.error?.localizedDescription ?? "")")
    }

    private func makeCache() async throws -> TemporalFrameCache {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw XCTSkip("The written file has no video track")
        }
        return TemporalFrameCache(
            asset: asset, track: track,
            frameDuration: CMTime(value: 1, timescale: 30),
            frameSize: Self.size,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ])
    }

    /// Drives `prefetch` the way a draw loop does and waits for the ring to
    /// settle, rather than sleeping a fixed time.
    private func settle(_ cache: TemporalFrameCache, at time: CMTime,
                        backward: Int, forward: Int) async {
        for _ in 0..<40 {
            let before = cache.readerStarts
            cache.prefetch(at: time, backward: backward, forward: forward)
            try? await Task.sleep(nanoseconds: 25_000_000)
            if !cache.neighbours(at: time, backward: backward, forward: forward, limit: nil).isEmpty,
               cache.readerStarts == before {
                return
            }
        }
    }

    func testTheStartOfAClipDoesNotRebuildTheReaderForever() async throws {
        let cache = try await makeCache()
        // Zero is where the playhead sits when a project opens, and a window
        // asking for frames before it can never be covered. That is what turned
        // every draw into a new reader.
        await settle(cache, at: .zero, backward: 2, forward: 2)
        let settled = cache.readerStarts
        for _ in 0..<20 { cache.prefetch(at: .zero, backward: 2, forward: 2) }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(cache.readerStarts, settled,
                       "A covered window at the start of a clip must not start another reader")
        XCTAssertFalse(cache.neighbours(at: .zero, backward: 2, forward: 2, limit: nil).isEmpty,
                       "The first frame of a clip still has frames ahead of it")
    }

    func testPlaybackCostsOneReaderRatherThanOnePerFrame() async throws {
        let cache = try await makeCache()
        await settle(cache, at: CMTime(value: 10, timescale: 30), backward: 2, forward: 2)
        let afterFirst = cache.readerStarts

        // Thirty advancing frames, as playback delivers them.
        for index in 10..<40 {
            let time = CMTime(value: CMTimeValue(index), timescale: 30)
            cache.prefetch(at: time, backward: 2, forward: 2)
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // Reading forward is one decode per frame; restarting is a seek and a
        // decode from the preceding sync sample. Playing thirty frames must not
        // need thirty readers — the bar is deliberately loose, since a dropped
        // draw may legitimately cost one.
        XCTAssertLessThanOrEqual(cache.readerStarts - afterFirst, 3,
                                 "Playback must read forward rather than rebuild its reader")
    }

    func testTheEndOfAClipStopsAskingOnceThereIsNothingLeft() async throws {
        let cache = try await makeCache()
        // Past the last frame, so the window can never be filled forwards.
        let time = CMTime(value: CMTimeValue(Self.frameCount - 1), timescale: 30)
        for _ in 0..<12 {
            cache.prefetch(at: time, backward: 2, forward: 2)
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        let settled = cache.readerStarts
        for _ in 0..<20 { cache.prefetch(at: time, backward: 2, forward: 2) }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(cache.readerStarts, settled,
                       "A window reaching past the last frame must stop being asked for")
    }

    func testSuspendingReleasesTheFramesAndTheyComeBack() async throws {
        let cache = try await makeCache()
        let time = CMTime(value: 20, timescale: 30)
        await settle(cache, at: time, backward: 2, forward: 2)
        XCTAssertFalse(cache.neighbours(at: time, backward: 2, forward: 2, limit: nil).isEmpty)

        // What the renderer does for every draw the temporal stage cannot use.
        cache.suspend()
        XCTAssertTrue(cache.neighbours(at: time, backward: 2, forward: 2, limit: nil).isEmpty,
                      "Suspending has to actually let go of the frames")

        await settle(cache, at: time, backward: 2, forward: 2)
        XCTAssertFalse(cache.neighbours(at: time, backward: 2, forward: 2, limit: nil).isEmpty,
                       "And the window has to come back when the transport stops")
    }
}
