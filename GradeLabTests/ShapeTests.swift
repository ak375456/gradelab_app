import CoreGraphics
import CoreImage
import CoreMedia
import XCTest
@testable import GradeLab

/// Shapes are deliberately built on the machinery text already uses, so these
/// tests are mostly about proving that reuse is real: the same keyframe engine,
/// the same placement, the same split and trim rules, the same document.
final class ShapeTests: XCTestCase {

    // MARK: - Helpers

    private func seconds(_ value: Double) throws -> TimelineTime { try .seconds(value) }

    private func shapeProject(duration: Double = 10, start: Double = 2, length: Double = 4,
                              kind: ShapeKind = .rectangle) throws -> (VideoProject, UUID) {
        var project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/source.mov"),
                                   displayName: "Shapes", metadata: makeVideoMetadata(durationSeconds: duration))
        let trackID = UUID()
        let clip = ShapeClip(placement: .init(id: UUID(), trackID: trackID,
                                              timelineStart: try seconds(start), duration: try seconds(length)),
                             kind: kind)
        project.timeline.tracks.insert(.init(id: trackID, name: "Shape", kind: .shape, items: [.shape(clip)]), at: 0)
        return (project, clip.id)
    }

    private func shape(_ project: VideoProject, _ id: UUID) -> ShapeClip {
        guard case .shape(let clip) = project.timeline.item(id: id)! else { fatalError("not a shape clip") }
        return clip
    }

    // MARK: - Document

    func testAShapeProjectValidatesAndSurvivesACodableRoundTrip() throws {
        var (project, id) = try shapeProject(kind: .star)
        var clip = shape(project, id)
        clip.pointCount = 6
        clip.innerRadius = 0.4
        clip.gradient = .init(start: .white, end: .black, angleDegrees: 45)
        clip.animation = ClipAnimation(tracks: [
            AnimationTrack(property: .shapeWidth, keyframes: [
                .init(time: .zero, value: .number(200)),
                .init(time: try seconds(2), value: .number(600))
            ])
        ])
        try OverlayEditing.replace(id, with: clip, in: &project)
        try project.validate()

        let data = try JSONEncoder().encode(project)
        let restored = try JSONDecoder().decode(VideoProject.self, from: data)
        try restored.validate()
        let decoded = shape(restored, id)
        XCTAssertEqual(decoded.kind, .star)
        XCTAssertEqual(decoded.pointCount, 6)
        XCTAssertEqual(decoded.innerRadius, 0.4)
        XCTAssertEqual(decoded.gradient?.angleDegrees, 45)
        XCTAssertEqual(decoded.animation?.track(.shapeWidth)?.keyframes.count, 2)
    }

    func testValidationRejectsAShapeWithNoSizeOrAnImpossiblePointCount() throws {
        var (project, id) = try shapeProject()
        var zeroWidth = shape(project, id)
        zeroWidth.width = 0
        var candidate = project
        try OverlayEditing.replace(id, with: zeroWidth, in: &candidate)
        XCTAssertThrowsError(try candidate.validate())

        var tooFewCorners = shape(project, id)
        tooFewCorners.kind = .polygon
        tooFewCorners.pointCount = 2
        candidate = project
        try OverlayEditing.replace(id, with: tooFewCorners, in: &candidate)
        XCTAssertThrowsError(try candidate.validate())

        // And the untouched project is still good, so the two above failed for
        // the reason under test rather than because the fixture was invalid.
        try project.validate()
    }

    func testATrackTakesOnlyItsOwnKindOfLayer() throws {
        let (project, id) = try shapeProject()
        let clip = shape(project, id)
        let shapeTrack = project.timeline.tracks.first { $0.kind == .shape }!
        XCTAssertTrue(shapeTrack.accepts(.shape(clip)))
        let text = TextClip(placement: .init(id: UUID(), trackID: shapeTrack.id,
                                             timelineStart: .zero, duration: try seconds(1)))
        XCTAssertFalse(shapeTrack.accepts(.text(text)))
        // A shape row draws no media, so the timeline gives it the short row a
        // title gets rather than a filmstrip's.
        XCTAssertTrue(TimelineTrack.Kind.shape.isDrawnOverlay)
        XCTAssertTrue(TimelineTrack.Kind.text.isDrawnOverlay)
        XCTAssertFalse(TimelineTrack.Kind.mainVideo.isDrawnOverlay)
        XCTAssertFalse(TimelineTrack.Kind.audio.isDrawnOverlay)
    }

    /// Every animatable property a shape advertises has to be one it can
    /// actually store, or `VideoProject.validate()` would reject a document the
    /// inspector itself produced.
    func testEveryAdvertisedPropertyIsSupportedAndInRange() {
        for property in ShapeClip.animatableProperties {
            XCTAssertTrue(ShapeClip.supports(property), "\(property.rawValue) is advertised but unsupported")
        }
        for property in [AnimatableProperty.shapeWidth, .shapeHeight, .shapeInnerRadius] {
            let value = property.defaultValue.number!
            XCTAssertTrue(property.range.contains(value), "\(property.rawValue) default is outside its range")
        }
        XCTAssertEqual(AnimatableProperty.fillColor.kind, .color)
        XCTAssertEqual(AnimatableProperty.shapeWidth.kind, .number)
    }

    /// A freshly inserted shape and one whose property has just been reset must
    /// agree, or "Reset this property" silently changes a value to something the
    /// tool never produces.
    func testAFreshShapeAlreadyHoldsEveryDocumentedDefault() {
        let fresh = ShapeClip(placement: .init(id: UUID(), trackID: UUID(), timelineStart: .zero, duration: .zero))
        for property in ShapeClip.animatableProperties {
            guard let current = fresh.baseValue(of: property) else {
                return XCTFail("\(property.rawValue) has no storage")
            }
            XCTAssertEqual(current, property.defaultValue,
                           "\(property.rawValue): a new shape differs from what Reset restores")
        }
    }

    // MARK: - Animation

    func testSizeAnimatesThroughTheSameEngineTextUses() throws {
        var (project, id) = try shapeProject(start: 2, length: 4)
        var clip = shape(project, id)
        clip.width = 100
        clip.animation = ClipAnimation(tracks: [
            AnimationTrack(property: .shapeWidth, keyframes: [
                .init(time: .zero, value: .number(100)),
                .init(time: try seconds(4), value: .number(500))
            ])
        ])
        try OverlayEditing.replace(id, with: clip, in: &project)
        try project.validate()

        let animated = shape(project, id)
        // Composition time 4s is two seconds into a clip that starts at 2s.
        XCTAssertEqual(animated.evaluated(at: try seconds(4)).width, 300, accuracy: 1e-9)
        XCTAssertEqual(animated.evaluated(at: try seconds(2)).width, 100, accuracy: 1e-9)
        XCTAssertEqual(animated.evaluated(at: try seconds(6)).width, 500, accuracy: 1e-9)
        // Authored values are never touched by evaluation.
        XCTAssertEqual(shape(project, id).width, 100)
    }

    func testColorAnimatesComponentWise() throws {
        var (project, id) = try shapeProject(start: 0, length: 4)
        var clip = shape(project, id)
        clip.animation = ClipAnimation(tracks: [
            AnimationTrack(property: .fillColor, keyframes: [
                .init(time: .zero, value: .color(.init(red: 0, green: 0, blue: 0, alpha: 1))),
                .init(time: try seconds(4), value: .color(.init(red: 1, green: 0.5, blue: 0, alpha: 0)))
            ])
        ])
        try OverlayEditing.replace(id, with: clip, in: &project)
        try project.validate()
        let mid = shape(project, id).evaluated(at: try seconds(2)).fillColor
        XCTAssertEqual(mid.red, 0.5, accuracy: 1e-9)
        XCTAssertEqual(mid.green, 0.25, accuracy: 1e-9)
        XCTAssertEqual(mid.alpha, 0.5, accuracy: 1e-9)
    }

    func testSplittingKeepsTheWholeCurveOnBothHalves() throws {
        var (project, id) = try shapeProject(start: 2, length: 4)
        var clip = shape(project, id)
        clip.animation = ClipAnimation(tracks: [
            AnimationTrack(property: .rotation, keyframes: [
                .init(time: .zero, value: .number(0)),
                .init(time: try seconds(4), value: .number(360))
            ])
        ])
        try OverlayEditing.replace(id, with: clip, in: &project)

        let rightID = try OverlayEditing.split(id, at: try seconds(4), in: &project)
        try project.validate()
        let left = shape(project, id), right = shape(project, rightID)
        XCTAssertEqual(left.animation?.track(.rotation)?.keyframes.count, 2)
        XCTAssertEqual(right.animation?.track(.rotation)?.keyframes.count, 2)
        XCTAssertEqual(right.animation!.startOffset.seconds, 2, accuracy: 1e-9)
        // The two halves agree with the unsplit original at the cut: 180° at 4s.
        XCTAssertEqual(left.evaluated(at: try seconds(4)).transform.rotationDegrees, 180, accuracy: 1e-6)
        XCTAssertEqual(right.evaluated(at: try seconds(4)).transform.rotationDegrees, 180, accuracy: 1e-6)
    }

    func testTrimmingTheHeadSlidesTheAnimationWindowRatherThanTheAnimation() throws {
        var (project, id) = try shapeProject(start: 2, length: 4)
        var clip = shape(project, id)
        clip.animation = ClipAnimation(tracks: [
            AnimationTrack(property: .opacity, keyframes: [
                .init(time: .zero, value: .number(0)),
                .init(time: try seconds(4), value: .number(1))
            ])
        ])
        try OverlayEditing.replace(id, with: clip, in: &project)

        try OverlayEditing.edit(id, operation: .trimStart, to: try seconds(3), in: &project)
        try project.validate()
        let trimmed = shape(project, id)
        XCTAssertEqual(trimmed.animation!.startOffset.seconds, 1, accuracy: 1e-9)
        XCTAssertEqual(trimmed.animation?.track(.opacity)?.keyframes.count, 2)
        // The value stayed glued to the content: what was 0.25 at 3s still is.
        XCTAssertEqual(trimmed.evaluated(at: try seconds(3)).opacity, 0.25, accuracy: 1e-9)
    }

    func testPastingGivesTheCopyItsOwnTrackAndIdentity() throws {
        var (project, id) = try shapeProject()
        let copyID = try OverlayEditing.paste(shape(project, id), at: try seconds(6), in: &project)
        try project.validate()
        XCTAssertNotEqual(copyID, id)
        let copy = shape(project, copyID)
        XCTAssertEqual(copy.placement.timelineStart.seconds, 6, accuracy: 1e-9)
        XCTAssertNotEqual(copy.placement.trackID, shape(project, id).placement.trackID)
        XCTAssertEqual(project.timeline.tracks.filter { $0.kind == .shape }.count, 2)
    }

    func testDeletingTheLastShapeOnATrackRemovesTheTrack() throws {
        var (project, id) = try shapeProject()
        try OverlayEditing.delete(id, in: &project)
        XCTAssertNil(project.timeline.item(id: id))
        XCTAssertTrue(project.timeline.tracks.allSatisfy { $0.kind != .shape })
    }

    // MARK: - Geometry

    func testAStarAndAPolygonHaveTheVertexCountsTheyClaim() {
        func corners(_ kind: ShapeKind, points: Int) -> Int {
            var clip = ShapeClip(placement: .init(id: UUID(), trackID: UUID(), timelineStart: .zero, duration: .zero),
                                 kind: kind)
            clip.width = 200; clip.height = 200; clip.pointCount = points
            var count = 0
            ShapeRenderer.path(clip).applyWithBlock { element in
                if element.pointee.type == .addLineToPoint || element.pointee.type == .moveToPoint { count += 1 }
            }
            return count
        }
        XCTAssertEqual(corners(.polygon, points: 6), 6)
        XCTAssertEqual(corners(.star, points: 5), 10)
    }

    /// The corner-radius control used a fixed 0...1024 range while the figure
    /// stopped changing at half its shorter side, so at a normal size nine
    /// tenths of the slider did nothing. The limit is now the shape's own.
    func testCornerRadiusRoundsAllTheWayAndStopsWhereTheCornersMeet() {
        var clip = ShapeClip(placement: .init(id: UUID(), trackID: UUID(), timelineStart: .zero, duration: .zero))
        clip.width = 200; clip.height = 100
        XCTAssertEqual(clip.maximumCornerRadius, 50)

        // Past that maximum the outline cannot change, which is exactly why the
        // slider must not offer the travel.
        clip.cornerRadius = clip.maximumCornerRadius
        let atMaximum = ShapeRenderer.path(clip)
        clip.cornerRadius = 4_000
        XCTAssertEqual(ShapeRenderer.path(clip).boundingBoxOfPath, atMaximum.boundingBoxOfPath)
        XCTAssertFalse(ShapeRenderer.path(clip).contains(CGPoint(x: 2, y: 2)))

        // A square at its maximum really is a circle: the box corners fall
        // outside the outline while the edge midpoints stay inside.
        clip.width = 200; clip.height = 200
        clip.cornerRadius = clip.maximumCornerRadius
        XCTAssertEqual(clip.maximumCornerRadius, 100)
        let circle = ShapeRenderer.path(clip)
        for corner in [CGPoint(x: 4, y: 4), CGPoint(x: 196, y: 4), CGPoint(x: 4, y: 196), CGPoint(x: 196, y: 196)] {
            XCTAssertFalse(circle.contains(corner), "corner \(corner) should be rounded away")
        }
        for edge in [CGPoint(x: 100, y: 4), CGPoint(x: 4, y: 100), CGPoint(x: 100, y: 196), CGPoint(x: 196, y: 100)] {
            XCTAssertTrue(circle.contains(edge), "edge midpoint \(edge) should still be inside")
        }
    }

    /// Shrinking a shape must not destroy a radius authored at a larger size —
    /// the renderer clamps, the document keeps what was asked for.
    func testShrinkingAShapeKeepsTheAuthoredCornerRadius() throws {
        var (project, id) = try shapeProject()
        var clip = shape(project, id)
        clip.width = 400; clip.height = 400; clip.cornerRadius = 200
        try OverlayEditing.replace(id, with: clip, in: &project)
        clip = shape(project, id)
        clip.width = 100; clip.height = 100
        try OverlayEditing.replace(id, with: clip, in: &project)
        try project.validate()
        XCTAssertEqual(shape(project, id).cornerRadius, 200)
        XCTAssertEqual(shape(project, id).maximumCornerRadius, 50)
    }

    func testPointCountIsClampedRatherThanDrawingNonsense() {
        var clip = ShapeClip(placement: .init(id: UUID(), trackID: UUID(), timelineStart: .zero, duration: .zero),
                             kind: .polygon)
        clip.pointCount = 1
        XCTAssertEqual(clip.resolvedPointCount, ShapeKind.pointCountRange.lowerBound)
        clip.pointCount = 999
        XCTAssertEqual(clip.resolvedPointCount, ShapeKind.pointCountRange.upperBound)
    }

    /// The whole reason `VisualTransform.placement` exists: a shape and a title
    /// carrying the same transform land in the same place, so the canvas handles
    /// can be written once against both.
    func testAShapeAndATitleShareOnePlacementDefinition() {
        var transform = VisualTransform()
        transform.positionX = 0.25
        transform.positionY = 0.75
        transform.scale = 1.5
        transform.rotationDegrees = 30
        let canvas = CGSize(width: 1920, height: 1080)
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 200)

        var shape = ShapeClip(placement: .init(id: UUID(), trackID: UUID(), timelineStart: .zero, duration: .zero))
        shape.transform = transform
        var text = TextClip(placement: .init(id: UUID(), trackID: UUID(), timelineStart: .zero, duration: .zero))
        text.transform = transform

        XCTAssertEqual(ShapeRenderer.placement(shape, bounds: bounds, canvas: canvas),
                       TextRenderer.placement(text, bounds: bounds, canvas: canvas))
    }

    // MARK: - Rendering

    func testAShapeRendersAndScalesWithTheSurfaceItIsGoingOnto() throws {
        var clip = ShapeClip(placement: .init(id: UUID(), trackID: UUID(), timelineStart: .zero, duration: .zero))
        clip.width = 400; clip.height = 200
        let authored = CGSize(width: 1920, height: 1080)
        guard let base = ShapeRenderer.image(clip, canvas: authored) else { return XCTFail("no raster") }
        guard let scaled = ShapeRenderer.image(clip, canvas: CGSize(width: 3840, height: 2160),
                                               authoredCanvas: authored) else { return XCTFail("no scaled raster") }
        XCTAssertEqual(scaled.extent.width, base.extent.width*2, accuracy: 2)
        XCTAssertEqual(scaled.extent.height, base.extent.height*2, accuracy: 2)
    }

    /// Placement end to end: the pixels land where `positionX`/`positionY` say,
    /// measured from the TOP as the model documents, in the color asked for.
    /// A Y-flip or an anchor mistake is invisible in an extent check and obvious
    /// here.
    func testAShapeIsDrawnWhereItsPositionSaysInTheColorItWasGiven() throws {
        let canvas = CGSize(width: 320, height: 180)
        var clip = ShapeClip(placement: .init(id: UUID(), trackID: UUID(), timelineStart: .zero, duration: .zero))
        clip.width = 80; clip.height = 40
        clip.fillColor = .init(red: 1, green: 0, blue: 0, alpha: 1)
        clip.transform.positionX = 0.25
        clip.transform.positionY = 0.25
        guard let shape = ShapeRenderer.image(clip, canvas: canvas) else { return XCTFail("no raster") }

        let frame = CGRect(origin: .zero, size: canvas)
        let composed = shape.composited(over: CIImage(color: .black).cropped(to: frame))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext()
        func sample(x: Int, fromTop y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(composed, toBitmap: &pixel, rowBytes: 4,
                           bounds: CGRect(x: x, y: Int(canvas.height) - y - 1, width: 1, height: 1),
                           format: .RGBA8, colorSpace: space)
            return (pixel[0], pixel[1], pixel[2])
        }
        // Centre of the shape: a quarter across, a quarter DOWN.
        let centre = sample(x: 80, fromTop: 45)
        XCTAssertGreaterThan(centre.r, 200)
        XCTAssertLessThan(centre.g, 60)
        XCTAssertLessThan(centre.b, 60)
        // Just inside each edge of an 80x40 box centred there.
        XCTAssertGreaterThan(sample(x: 42, fromTop: 45).r, 200)
        XCTAssertGreaterThan(sample(x: 118, fromTop: 45).r, 200)
        XCTAssertGreaterThan(sample(x: 80, fromTop: 27).r, 200)
        XCTAssertGreaterThan(sample(x: 80, fromTop: 63).r, 200)
        // Outside it, on every side, the canvas is untouched.
        for point in [(80, 20), (80, 70), (30, 45), (130, 45), (10, 10)] {
            XCTAssertLessThan(sample(x: point.0, fromTop: point.1).r, 60,
                              "pixel \(point) should be outside the shape")
        }
    }

    func testAShapeWithNothingToDrawProducesNoLayer() {
        var clip = ShapeClip(placement: .init(id: UUID(), trackID: UUID(), timelineStart: .zero, duration: .zero))
        clip.fillColor = .init(red: 1, green: 1, blue: 1, alpha: 0)
        clip.strokeWidth = 0
        XCTAssertNil(ShapeRenderer.image(clip, canvas: CGSize(width: 1920, height: 1080)))
        // An outline-only shape is a real shape, and still draws.
        clip.strokeWidth = 4
        XCTAssertNotNil(ShapeRenderer.image(clip, canvas: CGSize(width: 1920, height: 1080)))
    }

    // MARK: - Pro access

    /// Shapes are free. If this starts failing, it is a monetization decision
    /// being made by accident.
    func testShapesNeverRequirePro() throws {
        let (project, _) = try shapeProject()
        XCTAssertNil(ProAccessPolicy.contentRequirement(project))
    }
}
