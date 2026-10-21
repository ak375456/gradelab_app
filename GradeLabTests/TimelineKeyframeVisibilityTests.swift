import UIKit
import XCTest
@testable import GradeLab

final class TimelineKeyframeDataTests: XCTestCase {
    private func animation(_ times: [Double], offset: Double = 0) throws -> ClipAnimation {
        .init(tracks: [.init(property: .opacity,
            keyframes: try times.map { .init(time: try .seconds($0), value: .number(0.8)) })],
              startOffset: try .seconds(offset))
    }

    func testAdaptersKeepVideoTextAndShapeKeyframesInTheirOwnTimelineWindows() throws {
        let placement = ItemPlacement(id: UUID(), trackID: UUID(), timelineStart: try .seconds(5),
                                      duration: try .seconds(3))
        let authored = try animation([0, 1, 2, 3, 4], offset: 1)
        var video = VideoClip(placement: placement, assetID: UUID(),
                             sourceRange: .init(start: .zero, duration: try .seconds(3)))
        video.animation = authored
        var text = TextClip(placement: placement)
        text.animation = authored
        var shape = ShapeClip(placement: placement)
        shape.animation = authored
        for item in [TimelineItem.video(video), .text(text), .shape(shape)] {
            XCTAssertEqual(TimelineDisplayClip(item)?.keyframeTimes, [5, 6, 7])
        }
    }

    func testMaskOnlyAnimationAlsoProducesDiamondsAndDeduplicatesSharedTimes() throws {
        var video = VideoClip(placement: .init(id: UUID(), trackID: UUID(),
            timelineStart: try .seconds(5), duration: try .seconds(3)), assetID: UUID(),
            sourceRange: .init(start: .zero, duration: try .seconds(3)))
        video.animation = .init(startOffset: try .seconds(1))
        video.maskedGrades = [.init(name: "Window", geometry: .starting(.ellipse),
                                    animation: try animation([0, 1, 2, 4]))]
        XCTAssertEqual(TimelineDisplayClip(.video(video))?.keyframeTimes, [5, 6])
        video.animation?.tracks = try animation([2], offset: 1).tracks
        XCTAssertEqual(TimelineDisplayClip(.video(video))?.keyframeTimes, [5, 6])
    }
}

@MainActor
final class TimelineKeyframeVisibilityTests: XCTestCase {
    private func whitePixel(_ image: UIImage, at point: CGPoint) throws -> Bool {
        let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: point.x.rounded(.down),
            y: point.y.rounded(.down), width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return rgba.prefix(3).allSatisfy { $0 > 225 }
    }

    func testEveryAnimatedLayerDrawsDiamondsWithoutSelectionOnPhoneDuoIPadAndMacWidths() throws {
        var project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/keyframe-visibility.mov"),
            displayName: "Keyframe visibility", metadata: makeVideoMetadata(durationSeconds: 9))
        let original = try XCTUnwrap(project.timeline.firstVideoClip)
        var main = original
        main.animation = .init(tracks: [.init(property: .opacity,
            keyframes: [.init(time: try .seconds(3), value: .number(0.8))])])
        try TimelineEditing.replace(main.id, with: [main], in: &project)
        var overlay = original
        let overlayRow = UUID()
        overlay.placement = .init(id: UUID(), trackID: overlayRow, timelineStart: .zero,
                                  duration: original.placement.duration)
        overlay.animation = .init(tracks: [.init(property: .opacity,
            keyframes: [.init(time: try .seconds(2), value: .number(0.7))])])
        project.timeline.tracks.insert(.init(id: overlayRow, name: "Overlay", kind: .videoOverlay,
                                            items: [.video(overlay)]), at: 0)
        let selections: [Set<UUID>] = [[], [main.id], [overlay.id], [main.id, overlay.id]]
        for width in [390.0, 669, 951, 1024, 1374] {
            let canvas = TimelineCanvas(frame: CGRect(x: 0, y: 0, width: width, height: 240))
            canvas.clips = project.timeline.items.compactMap(TimelineDisplayClip.init)
            canvas.tracks = project.timeline.tracks
            canvas.assets = project.assets
            canvas.showsClipNames = false
            canvas.showsClipDurations = false
            canvas.layoutIfNeeded()
            canvas.update(time: 1)
            for selection in selections {
                canvas.selectedIDs = selection
                canvas.selectedID = selection.count == 1 ? selection.first : nil
                canvas.keyframeTimes = canvas.clips.first { $0.id == canvas.selectedID }?.keyframeTimes ?? []
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let image = UIGraphicsImageRenderer(size: canvas.bounds.size, format: format).image { _ in
                    canvas.draw(canvas.bounds)
                }
                let overlayPoint = CGPoint(x: width / 2 + 48, y: TimelineMetrics.rowsTop + 66 - 6)
                let mainPoint = CGPoint(x: width / 2 + 96,
                    y: TimelineMetrics.rowsTop + 66 + TimelineMetrics.rowGap + 66 - 6)
                XCTAssertTrue(try whitePixel(image, at: overlayPoint), "Overlay diamond missing: width \(width), selection \(selection)")
                XCTAssertTrue(try whitePixel(image, at: mainPoint), "Main diamond missing: width \(width), selection \(selection)")
                if selection.isEmpty && (width == 390 || width == 951) {
                    try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/GradeLab-keyframes-\(Int(width)).png"))
                }
            }
        }
    }
}
