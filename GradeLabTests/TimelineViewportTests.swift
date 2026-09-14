import XCTest
@testable import GradeLab

final class TimelineViewportTests: XCTestCase {
    func testCenteredPlayheadAndCoordinateRoundTrip() {
        for zoom in [4.0, 48, 320] {
            let viewport = TimelineViewport(pixelsPerSecond: zoom, width: 390, offset: 75 * zoom)
            XCTAssertEqual(viewport.x(for: 75), 195)
            XCTAssertEqual(viewport.seconds(at: 195, duration: 3600), 75)
            XCTAssertEqual(viewport.seconds(at: viewport.x(for: 76.25), duration: 3600), 76.25, accuracy: 0.000001)
            XCTAssertGreaterThanOrEqual(viewport.rulerInterval * zoom, 70)
        }
    }

    func testViewportClampsBeforeStartAndAfterEnd() {
        let viewport = TimelineViewport(width: 390, offset: 0)
        XCTAssertEqual(viewport.seconds(at: 0, duration: 5), 0)
        XCTAssertEqual(viewport.seconds(at: 10000, duration: 5), 5)
    }

    func testSourceMappingPreservesRationalOffset() throws {
        let track = UUID()
        let clip = VideoClip(placement: .init(id: UUID(), trackID: track,
            timelineStart: try .seconds(2), duration: try .seconds(10)), assetID: UUID(),
            sourceRange: .init(start: try TimelineTime(value: 1001, timescale: 60000), duration: try .seconds(10)))
        XCTAssertEqual(try clip.sourceTime(at: .seconds(2)), clip.sourceRange.start)
        XCTAssertEqual(try clip.sourceTime(at: .seconds(3)), try clip.sourceRange.start.adding(.seconds(1)))
        XCTAssertEqual(try clip.sourceTime(at: .zero), clip.sourceRange.start)
        XCTAssertEqual(try clip.sourceTime(at: .seconds(100)), try clip.sourceRange.end)
    }
}
