import CoreGraphics
import CoreMedia
import CoreVideo
import XCTest
import SwiftUI
import UIKit
@testable import GradeLab

final class MaskGeometryEditingTests: XCTestCase {
    private var square: MaskGeometry {
        var g = MaskGeometry.starting(.freehand)
        g.points = [.init(x: 0.2, y: 0.2), .init(x: 0.8, y: 0.2),
                    .init(x: 0.8, y: 0.8), .init(x: 0.2, y: 0.8)]
        return g
    }

    func testOldPointsDecodeWithoutHandlesAndKeepTheirOutline() throws {
        let data = Data(#"{"x":0.25,"y":0.75}"#.utf8)
        let point = try JSONDecoder().decode(MaskPoint.self, from: data)
        XCTAssertNil(point.incoming)
        XCTAssertNil(point.outgoing)
        XCTAssertEqual(square.renderPoints, square.points)
    }

    func testCurveHandlesSurviveProjectGeometryRoundTrip() throws {
        var g = square
        g.points[0].outgoing = .init(x: 0.2, y: -0.15)
        g.points[1].incoming = .init(x: -0.2, y: -0.15)
        let decoded = try JSONDecoder().decode(MaskGeometry.self, from: JSONEncoder().encode(g))
        XCTAssertEqual(decoded, g)
        XCTAssertLessThan(try XCTUnwrap(g.renderPoints.map(\.y).min()), 0.1)
        let uniforms = LocalGradeUniforms(layer: .init(name: "Sky", geometry: g), curveRow: 0, pointOffset: 0)
        XCTAssertEqual(Int(uniforms.maskC.z), g.renderPoints.count)
    }

    func testDenseCurvedMasksStayInsideThePoolWithoutDroppingOtherMasks() {
        var g = square
        g.points = (0..<64).map { i in
            let angle = Double(i) * .pi / 32
            var p = MaskPoint(x: 0.5 + cos(angle) * 0.3, y: 0.5 + sin(angle) * 0.3)
            p.incoming = .init(x: -0.01, y: 0.01)
            p.outgoing = .init(x: 0.01, y: -0.01)
            return p
        }
        XCTAssertLessThanOrEqual(g.renderPoints.count, MaskGeometry.maximumPoints)
        XCTAssertTrue(g.renderPoints.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        let masks = (0..<3).map { MaskedGradeLayer(name: "Mask \($0)", geometry: g) }
        XCTAssertEqual(LocalGradeStack.admitted(masks).count, 3)
        XCTAssertLessThanOrEqual(LocalGradeStack(layers: masks, aspect: 1).byteCount, 4096)
    }

    func testTrackingBoundsIncludeTheCurvedEdge() throws {
        var g = square
        g.points[0].outgoing = .init(x: 0.2, y: -0.2)
        g.points[1].incoming = .init(x: -0.2, y: -0.2)
        let coordinates = try MaskTrackingCoordinates(encodedSize: CGSize(width: 1920, height: 1080), preferredTransform: .identity)
        XCTAssertLessThan(try coordinates.region(for: g).minY, 0.1)
    }

    func testTrackingRejectsTeleportAndCollapseButAllowsVFRMotion() {
        let before = CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1)
        let moved = before.offsetBy(dx: 0.3, dy: 0)
        XCTAssertFalse(MaskTrackingCoordinates.isContinuous(moved, after: before, elapsed: 1 / 30))
        XCTAssertTrue(MaskTrackingCoordinates.isContinuous(moved, after: before, elapsed: 0.5))
        XCTAssertFalse(MaskTrackingCoordinates.isContinuous(CGRect(x: 0.1, y: 0.1, width: 0.01, height: 0.01),
                                                            after: before, elapsed: 1 / 30))
    }

    func testTrackingConversionPreservesPixelsAndDoesNotOverwriteLiveBuffers() throws {
        let converter = TrackingLuminance()
        let first = try converter.pixelBuffer(.init(luma: Data([0, 64, 128, 255]), width: 2, height: 2, time: .zero))
        let second = try converter.pixelBuffer(.init(luma: Data(repeating: 200, count: 4), width: 2, height: 2, time: .zero))
        XCTAssertFalse(first === second)
        CVPixelBufferLockBaseAddress(first, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(first, .readOnly) }
        let bytes = CVPixelBufferGetBaseAddress(first)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(first)
        for (offset, value) in [(0, UInt8(0)), (4, UInt8(64)), (stride, UInt8(128)), (stride + 4, UInt8(255))] {
            XCTAssertEqual(bytes[offset], value)
            XCTAssertEqual(bytes[offset + 1], value)
            XCTAssertEqual(bytes[offset + 2], value)
            XCTAssertEqual(bytes[offset + 3], 255)
        }
        // Changing source dimensions must rebuild the pool and planar scratch.
        let resized = try converter.pixelBuffer(.init(luma: Data(repeating: 42, count: 6), width: 3, height: 2, time: .zero))
        XCTAssertEqual(CVPixelBufferGetWidth(resized), 3)
    }

    func testFitSnapAndZoomLimits() {
        XCTAssertEqual(PreviewZoom.snapped(0.96), 1)
        XCTAssertEqual(PreviewZoom.snapped(1.04), 1)
        XCTAssertEqual(PreviewZoom.snapped(1.2), 1.2)
        XCTAssertEqual(PreviewZoom.clamped(0.1), 0.5)
        XCTAssertEqual(PreviewZoom.clamped(30), 8)
    }
}

@MainActor
final class FreehandMaskEditingTests: XCTestCase {
    private func makeModel() throws -> EditorViewModel {
        let project = GradeProject(sourceURL: URL(fileURLWithPath: "/tmp/clip.mov"),
                                   displayName: "Masks", metadata: makeMetadata(duration: 10))
        let model = try EditorViewModel(project: project)
        model.addMask(.freehand)
        let id = try XCTUnwrap(model.selectedMaskID)
        for point in [MaskPoint(x: 0.2, y: 0.2), .init(x: 0.8, y: 0.2),
                      .init(x: 0.8, y: 0.8), .init(x: 0.2, y: 0.8)] {
            model.appendMaskPoint(id, point)
        }
        model.finishDrawingMask(id)
        return model
    }

    func testSelectingAnAnchorDoesNotDeleteOrReshapeIt() throws {
        let model = try makeModel()
        let before = try XCTUnwrap(model.selectedMask).geometry
        model.selectedMaskPointIndex = 1
        XCTAssertEqual(model.selectedMask?.geometry, before)
        model.selectMask(nil)
        XCTAssertNil(model.selectedMaskPointIndex)
    }

    func testMovingAScaledRotatedAnchorKeepsHandlesAndOtherVerticesPlaced() throws {
        let model = try makeModel()
        let id = try XCTUnwrap(model.selectedMaskID)
        model.updateMask(id, immediate: true) {
            $0.geometry.width = 0.8; $0.geometry.height = 0.7; $0.geometry.rotationDegrees = 31
            $0.geometry.points[0].outgoing = .init(x: 0.12, y: -0.04)
        }
        let before = try XCTUnwrap(model.selectedMask).geometry
        model.moveMaskPoint(id, index: 0, to: .init(x: 0.25, y: 0.3), committing: true)
        let after = try XCTUnwrap(model.selectedMask).geometry
        XCTAssertEqual(before.points[0].outgoing, after.points[0].outgoing)
        for i in 1..<before.points.count {
            let a = MaskTrackingCoordinates.placedVertex(before.points[i], geometry: before, aspect: 1920 / 1080)
            let b = MaskTrackingCoordinates.placedVertex(after.points[i], geometry: after, aspect: 1920 / 1080)
            XCTAssertEqual(a.x, b.x, accuracy: 0.00001)
            XCTAssertEqual(a.y, b.y, accuracy: 0.00001)
        }
    }

    func testLivePreviewCanBeCancelledWithoutChangingTheDocumentOrHistory() throws {
        let model = try makeModel()
        let original = model.project
        var draft = try XCTUnwrap(model.selectedMask).geometry
        draft.points[0].outgoing = .init(x: 0.1, y: -0.1)
        model.setMaskGeometryPreview(draft)
        XCTAssertEqual(model.project, original)
        let clip = try XCTUnwrap(model.maskPreviewProject.timeline.videoClip(id: try XCTUnwrap(model.selectedClipID)))
        XCTAssertEqual(clip.resolvedMaskedGrades.first?.geometry, draft)
        model.setMaskGeometryPreview(nil)
        XCTAssertEqual(model.maskPreviewProject, original)
    }

    func testExplicitDeletionCanBeUndoneAndPreservesATriangle() throws {
        let model = try makeModel()
        let id = try XCTUnwrap(model.selectedMaskID)
        model.removeMaskPoint(id, index: 1)
        XCTAssertEqual(model.selectedMask?.geometry.points.count, 3)
        model.removeMaskPoint(id, index: 1)
        XCTAssertEqual(model.selectedMask?.geometry.points.count, 3)
        model.undo()
        XCTAssertEqual(model.selectedMask?.geometry.points.count, 4)
    }
}

@MainActor
final class MaskViewportTests: XCTestCase {
    func testMaskViewportKeepsTwoFingerNavigationAndCentersZoomedOutContent() async throws {
        let controller = UIHostingController(rootView: PreviewViewport(interaction: .pinchOnly) {
            Color.blue.overlay(Text("Picture"))
        })
        controller.view.frame = CGRect(x: 0, y: 0, width: 640, height: 400)
        let window = UIWindow(frame: controller.view.frame)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        controller.view.layoutIfNeeded()
        func scroll(in view: UIView) -> UIScrollView? {
            if let found = view as? UIScrollView { return found }
            return view.subviews.compactMap { scroll(in: $0) }.first
        }
        let viewport = try XCTUnwrap(scroll(in: controller.view))
        XCTAssertEqual(viewport.panGestureRecognizer.minimumNumberOfTouches, 2)
        XCTAssertTrue(try XCTUnwrap(viewport.pinchGestureRecognizer).isEnabled)
        XCTAssertEqual(viewport.contentSize.width, 640, accuracy: 1)
        XCTAssertEqual(viewport.bounds.height, 400 - PreviewToolbarMetrics.height, accuracy: 1,
                       "Preview controls must have their own space outside the picture")
        viewport.setZoomScale(2, animated: false)
        viewport.layoutIfNeeded()
        XCTAssertEqual(viewport.zoomScale, 2, accuracy: 0.001)
        XCTAssertEqual(viewport.contentSize.width, 1280, accuracy: 1)
        viewport.setZoomScale(0.5, animated: false)
        viewport.layoutIfNeeded()
        let picture = try XCTUnwrap(viewport.delegate?.viewForZooming?(in: viewport))
        XCTAssertEqual(picture.center.x, 320, accuracy: 1)
        XCTAssertEqual(picture.center.y, viewport.bounds.midY, accuracy: 1)
    }

    func testMaskControlsFitCompactAndWidePreviews() async throws {
        let project = GradeProject(sourceURL: URL(fileURLWithPath: "/tmp/clip.mov"),
                                   displayName: "Sky", metadata: makeMetadata(duration: 10))
        let model = try EditorViewModel(project: project)
        model.addMask(.freehand)
        let id = try XCTUnwrap(model.selectedMaskID)
        for point in [MaskPoint(x: 0.05, y: 0.05), .init(x: 0.95, y: 0.05),
                      .init(x: 0.95, y: 0.4), .init(x: 0.55, y: 0.3), .init(x: 0.05, y: 0.45)] {
            model.appendMaskPoint(id, point)
        }
        model.finishDrawingMask(id)
        model.setMaskPointSmooth(id, index: 3, smooth: true)
        model.selectedMaskPointIndex = 3
        for size in [CGSize(width: 390, height: 500), CGSize(width: 900, height: 500)] {
            let controller = UIHostingController(rootView: PreviewViewport(interaction: .pinchOnly) {
                ZStack {
                    LinearGradient(colors: [.cyan.opacity(0.7), .blue.opacity(0.3), .green.opacity(0.4)], startPoint: .top, endPoint: .bottom)
                    MaskOverlay(model: model, displayedRect: { CGRect(x: 0, y: 0, width: 1, height: 1) })
                }
            })
            controller.view.frame = CGRect(origin: .zero, size: size)
            controller.view.backgroundColor = .black
            let window = UIWindow(frame: controller.view.frame)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: size).image { context in
                controller.view.layer.render(in: context.cgContext)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Mask viewport \(Int(size.width))"
            attachment.lifetime = .keepAlways
            add(attachment)
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/gradelab-mask-\(Int(size.width)).png"))
            XCTAssertEqual(image.size, size)
        }
    }
}
