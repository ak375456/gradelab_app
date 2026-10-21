import AVFoundation
import CoreVideo
import Metal
import QuartzCore
import UIKit
import XCTest
@testable import GradeLab

@MainActor
final class PreviewComputeDispatchTests: XCTestCase {
    func testBundledSingleClipPreparesAndDecodesForPreview() async throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "onboarding-1-before", withExtension: "mp4"))
        let asset = try await VideoMetadataReader().read(from: url)
        let project = GradeProject(sourceURL: url, displayName: "Preview sample", metadata: asset.metadata)
        let sequence = try await SequenceComposition.build(project: project, forExport: false)
        let playback = VideoPlaybackController(url: url, duration: asset.metadata.durationSeconds)
        playback.replaceSequence(sequence, at: 0)
        let deadline = Date().addingTimeInterval(12)
        while !playback.isReady && playback.errorMessage == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(playback.isReady, playback.errorMessage ?? "preview did not become ready")
        XCTAssertNil(playback.errorMessage)
        #if targetEnvironment(simulator)
        XCTAssertNil(playback.player.currentItem?.videoComposition)
        #else
        XCTAssertNotNil(playback.player.currentItem?.videoComposition)
        #endif
        playback.play()
        defer { playback.pause() }
        var decoded: CVPixelBuffer?
        while decoded == nil && Date() < deadline {
            decoded = playback.frameProvider.pixelBuffer(forHostTime: CACurrentMediaTime())
            if decoded == nil { try await Task.sleep(for: .milliseconds(25)) }
        }
        XCTAssertNotNil(decoded, "a ready player must actually deliver frames to the Metal preview")
    }

    func testOddSizedLookThumbnailRendersThroughTheLastPixel() throws {
        let context = try MetalContext()
        let renderer = try LookPreviewRenderer(context: context)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: .init(width: 31, height: 17), format: format).image { canvas in
            UIColor(red: 0.75, green: 0.5, blue: 0.25, alpha: 1).setFill()
            canvas.fill(.init(x: 0, y: 0, width: 31, height: 17))
        }
        let source = try XCTUnwrap(renderer.makeSourceTexture(from: image))
        let output = try XCTUnwrap(renderer.render(settings: .neutral, source: source)?.cgImage)
        XCTAssertEqual(output.width, 31)
        XCTAssertEqual(output.height, 17)
        let bytes = try XCTUnwrap(output.dataProvider?.data) as Data
        let lastPixel = (output.height - 1) * output.bytesPerRow + (output.width - 1) * 4
        XCTAssertGreaterThan(bytes[lastPixel], 0)
        XCTAssertEqual(bytes[lastPixel + 3], 255, "padded dispatch must render the final partial group")
    }

    func testStillPreviewDownsampleRendersAnOddSizedSource() throws {
        let context = try MetalContext()
        var storage: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 37, 19, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &storage), kCVReturnSuccess)
        let buffer = try XCTUnwrap(storage)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<19 {
            for x in 0..<37 {
                let offset = y * stride + x * 4
                base[offset] = 64; base[offset + 1] = 128; base[offset + 2] = 192; base[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let renderer = try MetalVideoRenderer(context: context, frameProvider: StillFrameProvider(pixelBuffer: buffer),
            displaySize: .init(width: 37, height: 19), encodedSize: .init(width: 37, height: 19),
            preferredTransform: .identity, fallbackMatrix: nil)
        let output = try XCTUnwrap(renderer.lookPreviewSource(maximumEdge: 31))
        XCTAssertEqual(output.width, 31)
        XCTAssertEqual(output.height, 16)
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes {
            output.getBytes($0.baseAddress!, bytesPerRow: 4,
                            from: MTLRegionMake2D(output.width - 1, output.height - 1, 1, 1), mipmapLevel: 0)
        }
        XCTAssertEqual(Int(pixel[0]), 64, accuracy: 2)
        XCTAssertEqual(Int(pixel[1]), 128, accuracy: 2)
        XCTAssertEqual(Int(pixel[2]), 192, accuracy: 2)
        XCTAssertEqual(pixel[3], 255)
    }
}
