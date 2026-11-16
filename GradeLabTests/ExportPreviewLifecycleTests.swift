import AVFoundation
import QuartzCore
import XCTest
@testable import GradeLab

@MainActor
final class ExportPreviewLifecycleTests: XCTestCase {
    func testReleasingPreviewKeepsPlayheadButDetachesMediaAndCancelsSeeking() async throws {
        let playback = VideoPlaybackController(url: URL(fileURLWithPath: "/tmp/unused-preview.mov"),
                                               duration: 12, frameDuration: 1.0 / 30)
        playback.beginSeeking()
        playback.seekInteractively(to: 5)
        XCTAssertNotNil(playback.player.currentItem)

        playback.releaseSequenceResources()
        // Allow queued observer/seek callbacks from the detached item to run.
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertNil(playback.player.currentItem)
        XCTAssertNil(playback.frameProvider.latestFrame)
        XCTAssertEqual(playback.currentTime, 5)
        XCTAssertEqual(playback.duration, 12)
        XCTAssertFalse(playback.isPlaying)
        XCTAssertFalse(playback.isSeeking)
        XCTAssertFalse(playback.isReady)

        playback.releaseSequenceResources()
        XCTAssertEqual(playback.currentTime, 5, "Repeated suspension must preserve the return position")
        playback.clearSequence()
        XCTAssertEqual(playback.currentTime, 0)
        XCTAssertEqual(playback.duration, 0)
    }

    func testHDRTransitionPlaysOnFirstTapAfterExport() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("The HLG preview and export require a hardware Main 10 codec")
        #else
        let url = Bundle(for: Self.self).url(forResource: "hlg_test", withExtension: "mov")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("hlg_test.mov")
        let asset = try await VideoMetadataReader().read(from: url)
        var project = VideoProject(sourceURL: url, displayName: "HDR transition", metadata: asset.metadata,
                                   sourceRange: asset.sourceRange, frameDuration: asset.frameDuration)
        project.canvas.width = 1440
        project.canvas.height = 810
        let clip = try XCTUnwrap(project.timeline.firstVideoClip)
        _ = try TimelineEditing.split(clip.id, at: .seconds(0.2), in: &project)
        let cut = try XCTUnwrap(TimelineTransitionEditing.editableCuts(in: project).first)
        _ = try TimelineTransitionEditing.apply(.slideRight, at: cut, in: &project)
        XCTAssertTrue(project.colorMode.isHDR)

        let model = try EditorViewModel(project: project)
        let playback = model.playback
        let savedQuality = playback.previewQuality
        playback.previewQuality = .medium
        defer {
            playback.releaseSequenceResources()
            playback.previewQuality = savedQuality
        }
        // On a cold Catalyst shader cache the HDR transition may take over a
        // minute to compile. The first post-export Play below uses that cache
        // and still has to work within its own short deadline.
        let preparationDeadline = Date().addingTimeInterval(180)
        while (model.isPreparingTimeline || !playback.isReady),
              playback.errorMessage == nil, Date() < preparationDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard !model.isPreparingTimeline else {
            XCTFail("HDR preview did not finish its initial preparation")
            return
        }
        XCTAssertTrue(playback.isReady, playback.errorMessage ?? "HDR preview did not prepare")
        XCTAssertNotNil(playback.player.currentItem)

        model.suspendPreviewForExport()
        XCTAssertNil(playback.player.currentItem)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: destination) }
        var configuration = ExportConfiguration(resolution: .custom)
        configuration.customLongEdge = 320
        let exporter = try VideoExporter(context: MetalContext())
        let result = try await exporter.export(asset: asset, settings: .neutral, configuration: configuration,
                                               project: project, outputURL: destination)
        let exported = try await VideoMetadataReader().read(from: result)
        XCTAssertEqual(exported.metadata.isHDR, true)

        model.resumePreviewAfterExport()
        let rebuildDeadline = Date().addingTimeInterval(10)
        while model.isPreparingTimeline, Date() < rebuildDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isPreparingTimeline)
        XCTAssertNotNil(playback.player.currentItem)
        playback.togglePlayback()
        XCTAssertTrue(playback.isPlaying)
        XCTAssertTrue(playback.isPlayingReduced)

        let playbackDeadline = Date().addingTimeInterval(10)
        var decodedThroughCut = false
        while Date() < playbackDeadline, playback.errorMessage == nil {
            if playback.frameProvider.pixelBuffer(forHostTime: CACurrentMediaTime()) != nil,
               playback.frameProvider.presentationTime.seconds >= cut.time.seconds {
                decodedThroughCut = true
            }
            if playback.currentTime > cut.time.seconds && decodedThroughCut { break }
            guard playback.isPlaying else { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(playback.errorMessage)
        XCTAssertTrue(decodedThroughCut, "The rebuilt preview must deliver frames through the transition on the first Play")
        XCTAssertGreaterThan(playback.currentTime, cut.time.seconds, "Playback must pass the transition cut")
        #endif
    }
}
