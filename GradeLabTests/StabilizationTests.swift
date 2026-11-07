import AVFoundation
import CoreImage
import simd
import Vision
import XCTest
@testable import GradeLab

final class StabilizationTests: XCTestCase {
    private let size = CGSize(width: 960, height: 540)

    private func solve(jitter: Double = 0, rotation: Double = 0) throws -> VideoStabilization {
        let poses = (0..<180).map { i in
            let t = Double(i)/30
            return StabilizationPose(seconds: t, x: 25*t+jitter*sin(t*2 * .pi*6),
                y: jitter*cos(t*2 * .pi*5), rotation: rotation*sin(t*2 * .pi*4), segment: 0)
        }
        return try StabilizationPath.solve(poses, size: size,
            range: .init(start: .zero, duration: try .seconds(6)), encodedSize: size)
    }

    func testSteadyPanIsPreservedIncludingEnds() throws {
        let solved = try solve().adjustingStrength(1)
        XCTAssertEqual(solved.cropZoom, 1, accuracy: 1e-9)
        for sample in solved.samples {
            XCTAssertEqual(sample.x, 0, accuracy: 1e-9)
            XCTAssertEqual(sample.y, 0, accuracy: 1e-9)
        }
    }

    func testHighFrequencyShakeIsReducedWithoutLaggingPan() throws {
        let solved = try solve(jitter: 9).adjustingStrength(1)
        var raw = 0.0, corrected = 0.0
        for sample in solved.samples.dropFirst(30).dropLast(30) {
            let jitter = 9*sin(sample.seconds*2 * .pi*6)
            raw += jitter*jitter
            let residual = jitter+sample.x*size.width
            corrected += residual*residual
        }
        XCTAssertLessThan(corrected/raw, 0.02)
        XCTAssertLessThan(solved.cropZoom, 1.1)
    }

    func testCropContainsEveryCornerThroughoutInterpolatedMotion() throws {
        for canvas in [size, CGSize(width: 540, height: 960), CGSize(width: 960, height: 960)] {
            let samples = [
                StabilizationSample(seconds: 0, x: 0.035, y: -0.04, rotation: 0.055, segment: 0),
                StabilizationSample(seconds: 1, x: -0.03, y: 0.02, rotation: -0.04, segment: 0)
            ]
            let base = VideoStabilization(encodedWidth: Int(canvas.width), encodedHeight: Int(canvas.height),
                analyzedRange: .init(start: .zero, duration: try .seconds(2)), samples: samples)
            for strength in stride(from: 0.0, through: 1, by: 0.1) {
                let solved = base.adjustingStrength(strength)
                for t in stride(from: 0.0, through: 1, by: 0.025) {
                    let inverse = solved.correction(at: t, size: canvas).inverted()
                    for point in [CGPoint.zero, CGPoint(x: canvas.width,y: 0),
                                  CGPoint(x: 0,y: canvas.height), CGPoint(x: canvas.width,y: canvas.height)] {
                        let source = point.applying(inverse)
                        XCTAssertGreaterThanOrEqual(source.x, -0.0001)
                        XCTAssertGreaterThanOrEqual(source.y, -0.0001)
                        XCTAssertLessThanOrEqual(source.x, canvas.width+0.0001)
                        XCTAssertLessThanOrEqual(source.y, canvas.height+0.0001)
                    }
                }
            }
        }
    }

    func testExcessiveShakeIsLimitedRatherThanOvercropped() throws {
        let solved = try solve(jitter: 160, rotation: 0.1).adjustingStrength(1)
        XCTAssertTrue(solved.limitedCorrection)
        XCTAssertLessThanOrEqual(solved.cropZoom, VideoStabilization.maximumZoom+0.00001)
    }

    func testSourceTimeSurvivesTrimSpeedAndTimelineMove() throws {
        let project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/stabilize.mov"),
            displayName: "Shake", metadata: makeVideoMetadata(durationSeconds: 6, hasAudio: false))
        var clip = try XCTUnwrap(project.timeline.firstVideoClip)
        clip.stabilization = try solve(jitter: 5)
        clip.sourceRange = .init(start: try .seconds(1), duration: try .seconds(2))
        clip.placement.timelineStart = try .seconds(12)
        clip.speed = 2
        clip.placement.duration = try .seconds(1)
        let expected = try XCTUnwrap(clip.stabilization).correction(at: 1.5, size: size)
        XCTAssertEqual(clip.stabilizationCorrection(at: CMTime(seconds: 12.25, preferredTimescale: 600), size: size), expected)
        clip.sourceRange = .init(start: .zero, duration: try .seconds(7))
        XCTAssertNil(clip.resolvedStabilization) // Extending outside analysis requires another pass.
    }

    func testProjectsBeforeStabilizationDecodeAndResultsRoundTrip() throws {
        var project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/stabilize.mov"),
            displayName: "Shake", metadata: makeVideoMetadata(durationSeconds: 6, hasAudio: false))
        let plain = try JSONEncoder().encode(project)
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("stabilization"))
        XCTAssertEqual(try JSONDecoder().decode(VideoProject.self, from: plain), project)
        var clip = try XCTUnwrap(project.timeline.firstVideoClip)
        clip.stabilization = try solve(jitter: 5)
        try TimelineEditing.replace(clip.id, with: [clip], in: &project)
        XCTAssertTrue(project.needsLayerCompositor)
        XCTAssertEqual(try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(project)), project)
    }

    func testSplitRetainsSourceAnalysisAndReplacementClearsIt() throws {
        var project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/stabilize.mov"),
            displayName: "Shake", metadata: makeVideoMetadata(durationSeconds: 6,hasAudio: false))
        var clip = try XCTUnwrap(project.timeline.firstVideoClip)
        clip.stabilization = try solve(jitter: 5)
        try TimelineEditing.replace(clip.id,with: [clip],in: &project)
        let rightID = try TimelineEditing.split(clip.id,at: .seconds(3),in: &project)
        let right = try XCTUnwrap(project.timeline.videoClip(id: rightID))
        XCTAssertEqual(right.stabilization,clip.stabilization)
        XCTAssertEqual(right.stabilizationCorrection(at: .init(seconds: 3.5,preferredTimescale: 600),size: size),
                       clip.stabilizationCorrection(at: .init(seconds: 3.5,preferredTimescale: 600),size: size))
        let asset = ProjectMediaAsset(id: UUID(),url: URL(fileURLWithPath: "/tmp/replacement.mov"),
            sourceRange: right.sourceRange,videoMetadata: makeVideoMetadata(durationSeconds: 6,hasAudio: false),
            frameDuration: project.canvas.frameDuration)
        let replacement = try ClipReplacement.prepare(clipID: rightID,asset: asset,timing: .keepDuration,in: project)
        XCTAssertNil(replacement.clip.stabilization)
    }

    func testIndependentShotsNeverSmoothAcrossACut() throws {
        let poses: [StabilizationPose] = (0..<90).map { i in
            let time = Double(i)/30
            let x = i < 45 ? Double(i) : 2000+Double(i)
            let segment = i < 45 ? 0 : 1
            return StabilizationPose(seconds: time,x: x,y: 0,rotation: 0,segment: segment)
        }
        let solved = try StabilizationPath.solve(poses,size: size,
            range: .init(start: .zero,duration: try .seconds(3)),encodedSize: size)
        XCTAssertEqual(solved.cropZoom,1,accuracy: 1e-9)
        XCTAssertTrue(solved.samples.allSatisfy { abs($0.x) < 1e-9 })
    }

    func testSampledSlowMotionHoldsCorrectionUntilTheSourceChanges() throws {
        let project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/stabilize.mov"),
            displayName: "Shake",metadata: makeVideoMetadata(durationSeconds: 1,hasAudio: false))
        var clip = project.timeline.firstVideoClip!
        clip.speed = 0.5; clip.placement.duration = try .seconds(2)
        clip.stabilization = VideoStabilization(strength: 1,encodedWidth: 960,encodedHeight: 540,
            analyzedRange: clip.sourceRange,samples: [
                .init(seconds: 0,x: 0.01,y: 0,rotation: 0,segment: 0),
                .init(seconds: 1/30.0,x: -0.01,y: 0,rotation: 0,segment: 0)
            ]).adjustingStrength(1)
        let first = clip.stabilizationCorrection(at: .zero,size: size)
        let between = CMTime(seconds: 1/30.0,preferredTimescale: 60_000)
        XCTAssertEqual(clip.stabilizationCorrection(at: between,size: size),first)
        clip.frameInterpolation = .blending
        XCTAssertNotEqual(clip.stabilizationCorrection(at: between,size: size),first)
        clip.speed = 1; clip.placement.duration = try .seconds(1)
        // An interpolation preference left over after restoring normal speed
        // must not animate the correction over AVFoundation's held frames.
        XCTAssertEqual(clip.stabilizationCorrection(at: .init(seconds: 1/60.0,preferredTimescale: 60_000),size: size),first)
        clip.speed = 0.5; clip.placement.duration = try .seconds(2)
        clip.frameInterpolation = .sampling
        clip.stabilization?.hasSubsampledMotion = true
        XCTAssertNotEqual(clip.stabilizationCorrection(at: between,size: size),first)
    }

    func testSDRAndMetalSamplingAgreeAfterPortraitOrientationAndPlacement() throws {
        let solved = try solve(jitter: 8, rotation: 0.015)
        let correction = solved.correction(at: 1.3, size: size)
        var placement = VisualTransform()
        placement.positionX = 0.4; placement.positionY = 0.6
        placement.scale = 0.8; placement.rotationDegrees = 12
        let canvas = CGSize(width: 1080, height: 1920)
        let preferred = CGAffineTransform(a: 0,b: 1,c: -1,d: 0,tx: size.height,ty: 0)
        let transform = LayerCompositor.transform(placement, encoded: size, preferred: preferred, canvas: canvas)
        let layer = HDRLayerUniforms(transform: transform, sourceSize: size, canvasSize: canvas,
                                     opacity: 1, sourceCorrection: correction)
        for x in stride(from: 200.0, through: 800, by: 200) {
            let point = SIMD3<Float>(Float(x), 900, 1)
            let fitted = SIMD3(simd_dot(SIMD3(layer.row0.x,layer.row0.y,layer.row0.z),point),
                               simd_dot(SIMD3(layer.row1.x,layer.row1.y,layer.row1.z),point), 1)
            let metalUV = CGPoint(x: Double(simd_dot(SIMD3(layer.stabilizationRow0.x,layer.stabilizationRow0.y,layer.stabilizationRow0.z),fitted)),
                                  y: Double(simd_dot(SIMD3(layer.stabilizationRow1.x,layer.stabilizationRow1.y,layer.stabilizationRow1.z),fitted)))
            let ciSource = CGPoint(x: x,y: canvas.height-900).applying(transform.inverted()).applying(correction.inverted())
            XCTAssertEqual(metalUV.x, ciSource.x/size.width, accuracy: 1e-6)
            XCTAssertEqual(metalUV.y, 1-ciSource.y/size.height, accuracy: 1e-6)
        }
    }

    /// A real Vision registration of a known image shift guards the target/
    /// reference direction and Y convention, which cannot be proven by mocks.
    func testVisionRegistrationCorrectsKnownShift() throws {
        let converter = TrackingLuminance()
        let previous = Self.patternFrame(dx: 0, dy: 0)
        let current = Self.patternFrame(dx: 6, dy: -4)
        converter.setReference(previous)
        let alignment = try XCTUnwrap(StabilizationAnalysis.register(current: current, previous: previous,
            currentBuffer: converter.pixelBuffer(current), previousBuffer: converter.pixelBuffer(previous), converter: converter))
        let centre = CGPoint(x: 192,y: 108), mapped = centre.applying(alignment)
        XCTAssertEqual(mapped.x-centre.x, -6, accuracy: 1)
        XCTAssertEqual(mapped.y-centre.y, 4, accuracy: 1)
    }

    func testRegistrationRejectsCutAndFlatFrame() throws {
        let frame = Self.patternFrame(dx: 0,dy: 0)
        let flat = TrackingFrame(luma: Data(repeating: 128, count: frame.luma.count), width: frame.width,
                                 height: frame.height, time: .zero)
        XCTAssertNil(StabilizationAnalysis.rigidAlignment(matrix_identity_float3x3, current: flat, previous: frame))
        var invalid = matrix_identity_float3x3; invalid[2][0] = 1_000
        XCTAssertNil(StabilizationAnalysis.rigidAlignment(invalid, current: frame, previous: frame))
    }

    func testVisionRegistrationCorrectsRollWithoutPerspectiveWarp() throws {
        let converter = TrackingLuminance()
        let previous = Self.patternFrame(dx: 0,dy: 0)
        let current = Self.patternFrame(dx: 5,dy: -3,rotation: 0.012)
        converter.setReference(previous)
        let alignment = try XCTUnwrap(StabilizationAnalysis.register(current: current,previous: previous,
            currentBuffer: converter.pixelBuffer(current),previousBuffer: converter.pixelBuffer(previous),converter: converter))
        XCTAssertEqual(atan2(alignment.b,alignment.a),-0.012,accuracy: 0.003)
        XCTAssertEqual(alignment.a*alignment.d-alignment.b*alignment.c,1,accuracy: 0.000001)
    }

    static func patternFrame(dx: Int, dy: Int, rotation: Double = 0) -> TrackingFrame {
        let width = 384, height = 216
        var data = Data(count: width*height)
        for y in 0..<height {
            for x in 0..<width {
                // Continuous textured scene, translated in bottom-left coords.
                let px = Double(x-dx)-Double(width)/2
                let py = Double(height-1-y-dy)-Double(height)/2
                let u = cos(rotation)*px+sin(rotation)*py+Double(width)/2
                let v = -sin(rotation)*px+cos(rotation)*py+Double(height)/2
                func noise(_ a: Int, _ b: Int) -> Double {
                    var hash = UInt64(bitPattern: Int64(a &* 374761393 &+ b &* 668265263))
                    hash = (hash ^ (hash >> 13)) &* 1274126177
                    return Double(hash % 101)-50
                }
                let gx = Int(floor(u/7)), gy = Int(floor(v/7))
                let fx = u/7-Double(gx), fy = v/7-Double(gy)
                let top = noise(gx,gy)*(1-fx)+noise(gx+1,gy)*fx
                let bottom = noise(gx,gy+1)*(1-fx)+noise(gx+1,gy+1)*fx
                let wave = 120+30*sin(u*0.13)+25*cos(v*0.17)+1.5*(top*(1-fy)+bottom*fy)
                data[y*width+x] = UInt8(min(255,max(0,wave)))
            }
        }
        return .init(luma: data, width: width, height: height, time: .zero)
    }
}
