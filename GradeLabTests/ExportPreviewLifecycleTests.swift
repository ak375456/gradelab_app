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
}
