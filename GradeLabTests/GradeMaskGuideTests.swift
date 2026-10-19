import SwiftUI
import Metal
import XCTest
@testable import GradeLab

final class GradeMaskGuideTests: XCTestCase {
    func testReportedQuarterTurnRectangleMatchesTheGradedRegion() {
        let picture = CGRect(x: 20, y: 40, width: 860, height: 484)
        let mask = GradeMask(isEnabled: true, shape: .rectangle, rotation: -90, feather: 0)
        let outline = GradeMaskGuideGeometry(mask: mask, picture: picture).outline().boundingRect
        // Rotation swaps the normalized dimensions BEFORE stretching them to
        // the picture. The old screen-space rotation drew a 194 × 516 strip.
        XCTAssertEqual(outline.width, 344, accuracy: 0.01)
        XCTAssertEqual(outline.height, 290.4, accuracy: 0.01)
        XCTAssertEqual(outline.midX, picture.midX, accuracy: 0.01)
        XCTAssertEqual(outline.midY, picture.midY, accuracy: 0.01)
    }

    func testGuideAndDraggingFollowRotatedMirroredLayerPlacement() throws {
        let encoded = CGSize(width: 1920, height: 1080)
        let canvas = CGSize(width: 1080, height: 1920)
        let preferred = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: 1080, ty: 1920)
        let coordinates = try MaskTrackingCoordinates(encodedSize: encoded, preferredTransform: preferred)
        var placement = VisualTransform()
        placement.positionX = 0.37; placement.positionY = 0.62
        placement.scale = 0.7; placement.widthScale = 1.3
        placement.rotationDegrees = 24
        let picture = CGRect(x: 18, y: 30, width: 270, height: 480)
        let mask = GradeMask(isEnabled: true, shape: .rectangle, rotation: -90, feather: 0)
        let guide = GradeMaskGuideGeometry(mask: mask, picture: picture,
            sourceToPicture: coordinates.sourceToCanvasTransform(placement, canvas: canvas))
        let render = LayerCompositor.transform(placement, encoded: encoded, preferred: preferred, canvas: canvas)
        // These are the source-space corners of the reported rotated window.
        var expected = CGRect.null
        for point in [CGPoint(x: 0.3, y: 0.2), CGPoint(x: 0.7, y: 0.2),
                      CGPoint(x: 0.7, y: 0.8), CGPoint(x: 0.3, y: 0.8)] {
            let rendered = CGPoint(x: point.x * encoded.width, y: (1 - point.y) * encoded.height).applying(render)
            let view = CGPoint(x: picture.minX + rendered.x / canvas.width * picture.width,
                               y: picture.minY + (1 - rendered.y / canvas.height) * picture.height)
            expected = expected.union(CGRect(origin: view, size: .zero))
        }
        let actual = guide.outline().boundingRect
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.01)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.01)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.01)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.01)
        let drag = CGSize(width: 27, height: -13)
        let delta = guide.sourceTranslation(drag)
        let before = guide.sourcePoint(CGPoint(x: 0.4, y: 0.6))
        let after = guide.sourcePoint(CGPoint(x: 0.4 + delta.x, y: 0.6 + delta.y))
        XCTAssertEqual(after.x - before.x, drag.width, accuracy: 0.001)
        XCTAssertEqual(after.y - before.y, drag.height, accuracy: 0.001)
    }

    #if targetEnvironment(macCatalyst)
    func testGuideMatchesActualMetalCoverageWithinHalfAPreviewPoint() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("dummy name/Metal/Shaders.metal"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "inline float softShapeMaskWeight("))
        let end = try XCTUnwrap(source.range(of: "// The colour qualifier:", range: start.upperBound..<source.endIndex))
        let probe = """
        #include <metal_stdlib>
        using namespace metal;
        \(source[start.lowerBound..<end.lowerBound])
        kernel void probe(device float *out [[buffer(0)]],
                          device const float2 *points [[buffer(1)]],
                          constant float4 &geometry [[buffer(2)]],
                          constant float4 &options [[buffer(3)]],
                          uint i [[thread_position_in_grid]]) {
            out[i] = softShapeMaskWeight(points[i], geometry, options);
        }
        """
        let library = try device.makeLibrary(source: probe, options: nil)
        let pipeline = try device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "probe")))
        let points: [SIMD2<Float>] = (0..<36).flatMap { y in
            (0..<64).map { x in SIMD2((Float(x) + 0.5) / 64, (Float(y) + 0.5) / 36) }
        }
        let input = try XCTUnwrap(device.makeBuffer(bytes: points,
            length: points.count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared))
        let output = try XCTUnwrap(device.makeBuffer(length: points.count * MemoryLayout<Float>.stride,
                                                     options: .storageModeShared))
        for shape in [GradeMaskShape.rectangle, .ellipse] {
            for angle: Float in [-90, 0, 37] {
                let mask = GradeMask(isEnabled: true, shape: shape, rotation: angle, feather: 0)
                var settings = GradeSettings.neutral
                settings.advanced = .neutral
                settings.advanced?.mask = mask
                let uniforms = GradeUniforms(settings: settings, bypass: false)
                var geometry = uniforms.gradeMaskA, options = uniforms.gradeMaskB
                let command = try XCTUnwrap(queue.makeCommandBuffer())
                let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
                encoder.setComputePipelineState(pipeline)
                encoder.setBuffer(output, offset: 0, index: 0)
                encoder.setBuffer(input, offset: 0, index: 1)
                encoder.setBytes(&geometry, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
                encoder.setBytes(&options, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)
                encoder.dispatchThreads(.init(width: points.count, height: 1, depth: 1),
                                        threadsPerThreadgroup: .init(width: 64, height: 1, depth: 1))
                encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
                XCTAssertNil(command.error)
                let weights = output.contents().assumingMemoryBound(to: Float.self)
                let guide = GradeMaskGuideGeometry(mask: mask, picture: CGRect(x: 20, y: 40, width: 860, height: 484))
                let outline = guide.outline()
                let boundary = outline.cgPath.copy(strokingWithWidth: 1, lineCap: .round,
                                                  lineJoin: .round, miterLimit: 10)
                for (index, point) in points.enumerated() {
                    let viewPoint = guide.sourcePoint(CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)))
                    if outline.contains(viewPoint) != (weights[index] > 0.5) {
                        // A vector ellipse and a raster shader can disagree at
                        // subpixel edges. Every difference must sit on the
                        // visible outline, never elsewhere in the picture.
                        XCTAssertTrue(boundary.contains(viewPoint), "\(shape), \(angle)°, UV \(point)")
                    }
                }
            }
        }
    }
    #endif
}

@MainActor
final class PreviewToolbarLayoutTests: XCTestCase {
    func testControlsStayOutsideCompactAndWidePictures() async throws {
        let project = GradeProject(sourceURL: URL(fileURLWithPath: "/tmp/guide.mov"),
                                   displayName: "Local mask", metadata: makeMetadata(duration: 10))
        let model = try EditorViewModel(project: project)
        model.gradeMaskBinding(\.shape).wrappedValue = .rectangle
        model.gradeMaskBinding(\.rotation).wrappedValue = -90
        model.gradeMaskBinding(\.feather).wrappedValue = 0
        model.gradeMaskBinding(\.isEnabled).wrappedValue = true
        for size in [CGSize(width: 320, height: 300), CGSize(width: 390, height: 340), CGSize(width: 900, height: 500)] {
            let controller = UIHostingController(rootView: PreviewViewport(interaction: .pinchOnly) {
                ZStack {
                    LinearGradient(colors: [.gray, .black], startPoint: .top, endPoint: .bottom)
                    GradeMaskOverlay(model: model, displayedRect: { CGRect(x: 0, y: 0, width: 1, height: 1) })
                }
            } controls: {
                Button {} label: { PreviewToolbarLabel(title: "Scopes", symbol: "waveform") }
                PreviewCompareButton(isPinned: .constant(false), showsOriginal: false, onHoldChanged: { _ in })
            })
            controller.view.frame = CGRect(origin: .zero, size: size)
            controller.view.backgroundColor = .black
            let window = UIWindow(frame: controller.view.frame)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            controller.view.layoutIfNeeded()
            func scroll(in view: UIView) -> UIScrollView? {
                if let scroll = view as? UIScrollView { return scroll }
                return view.subviews.compactMap { scroll(in: $0) }.first
            }
            let viewport = try XCTUnwrap(scroll(in: controller.view))
            XCTAssertEqual(viewport.bounds.width, size.width, accuracy: 1)
            XCTAssertEqual(viewport.bounds.height, size.height - PreviewToolbarMetrics.height, accuracy: 1)
            let image = UIGraphicsImageRenderer(size: size).image { controller.view.layer.render(in: $0.cgContext) }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Preview controls \(Int(size.width))"
            attachment.lifetime = .keepAlways
            add(attachment)
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("gradelab-preview-controls-\(Int(size.width)).png")
            try image.pngData()?.write(to: url)
            print("PREVIEW_CONTROLS_SHOT \(url.path)")
        }
    }
}
