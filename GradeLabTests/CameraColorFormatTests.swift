#if !targetEnvironment(macCatalyst)
@preconcurrency import AVFoundation
import XCTest
@testable import GradeLab

@MainActor
final class CameraColorFormatTests: XCTestCase {
    func testQualityAndStorageUseTheSameBitRateAndProResVariants() {
        let format = CameraFormatOption(width: 3840, height: 2160, fps: 60, profile: .hdrHLG)
        XCTAssertEqual(CameraRecordingQuality.high.bitRate(format: format, codec: .hevc), 120_000_000)
        XCTAssertEqual(CameraRecordingQuality.maximum.bitRate(format: format, codec: .hevc), 180_000_000)
        let efficient = CameraRecordingEstimate(freeBytes: 10_000_000_000, format: format, codec: .hevc, hasAudio: false, quality: .efficient)
        let maximum = CameraRecordingEstimate(freeBytes: 10_000_000_000, format: format, codec: .hevc, hasAudio: false, quality: .maximum)
        XCTAssertEqual(efficient.seconds / maximum.seconds, 3, accuracy: 0.0001)
        let rates = [CameraCodec.proResHQ, .proRes, .proResLT, .proResProxy].map { CameraRecordingQuality.high.bitRate(format: format, codec: $0) }
        XCTAssertEqual(rates, rates.sorted(by: >))
        XCTAssertEqual(CameraRecordingQuality.efficient.bitRate(format: format, codec: .proRes), CameraRecordingQuality.maximum.bitRate(format: format, codec: .proRes))
        XCTAssertEqual(CameraFormatOption(width: 1280, height: 720, fps: 30, profile: .sdr).resolution, "720p")
        XCTAssertTrue(CameraFormatOption(width: 4032, height: 3024, fps: 30, profile: .sdr).usesSampleRecording)
        XCTAssertFalse(CameraProfile.appleLog.matches(.appleLog2))
        XCTAssertFalse(CameraProfile.sdr.matches(.displayP3))
        XCTAssertTrue(CameraProfile.hdrHLG.matches(.hlgBT2020))
    }

    func testHLGMonitoringPreservesTenBitCodeValues() async throws {
        let source = try buffer(tenBit: true, y: 721, cb: 512, cr: 512)
        let output = try await converted(source, profile: .hdrHLG)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), kCVPixelFormatType_64RGBAHalf)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        let pointer = try XCTUnwrap(CVPixelBufferGetBaseAddress(output)).assumingMemoryBound(to: UInt16.self)
        for channel in 0..<3 { XCTAssertEqual(Float(Float16(bitPattern: pointer[channel])), Float(721 - 64) / 876, accuracy: 0.002) }
    }

    func testP3MonitoringMatchesTheSameConversionUsedByTheEditor() async throws {
        // A non-neutral tagged P3 source catches a missing gamut transform;
        // grayscale would look right even if the primaries were ignored.
        let source = try buffer(tenBit: false, y: 125, cb: 105, cr: 165)
        let monitor = try await converted(source, profile: .displayP3)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CameraP3-\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: 64, AVVideoHeightKey: 64,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for index in 0..<12 {
            while !input.isReadyForMoreMediaData && writer.status == .writing { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(adaptor.append(source, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        input.markAsFinished(); await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
        let asset = try await VideoMetadataReader().read(from: url)
        XCTAssertEqual(SourceColorProfile.detect(metadata: asset.metadata), .displayP3)
        XCTAssertEqual(ProjectColorMode.default(for: asset.metadata), .sdrWide)
        _ = try await ExportSourceInspector.inspect(asset, requireExportColorTags: true)
        let media = AVURLAsset(url: url)
        let tracks = try await media.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: media)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: ExportMediaSettings.videoReaderSettings(colorMode: .sdrWide))
        reader.add(output); XCTAssertTrue(reader.startReading())
        let sample = try XCTUnwrap(output.copyNextSampleBuffer())
        let decoded = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        let rgb = try yuvPixel(decoded)
        CVPixelBufferLockBaseAddress(monitor, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(monitor, .readOnly) }
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(monitor)).assumingMemoryBound(to: UInt8.self)
        for (channel, index) in [(rgb.x, 2), (rgb.y, 1), (rgb.z, 0)] {
            XCTAssertEqual(Float(bytes[index]) / 255, min(max(channel, 0), 1), accuracy: 0.025, "Camera P3 view must match the actual AVFoundation edit/export conversion")
        }
        let playback = VideoPlaybackController.outputSettings(for: .sdrWide)[AVVideoColorPropertiesKey] as? [String: String]
        let export = ExportMediaSettings.videoReaderSettings(colorMode: .sdrWide)[AVVideoColorPropertiesKey] as? [String: String]
        XCTAssertEqual(playback, export)
    }

    private func buffer(tenBit: Bool, y: UInt16, cb: UInt16, cr: UInt16) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let type = tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, type, [kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let value = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(value, [])
        defer { CVPixelBufferUnlockBaseAddress(value, []) }
        for plane in 0..<2 {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(value, plane))
            let stride = CVPixelBufferGetBytesPerRowOfPlane(value, plane)
            for row in 0..<CVPixelBufferGetHeightOfPlane(value, plane) {
                for x in 0..<64 {
                    let code = plane == 0 ? y : x.isMultiple(of: 2) ? cb : cr
                    if tenBit { base.advanced(by: row * stride).assumingMemoryBound(to: UInt16.self)[x] = code << 6 }
                    else { base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)[x] = UInt8(code) }
                }
            }
        }
        CVBufferSetAttachment(value, kCVImageBufferYCbCrMatrixKey, tenBit ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(value, kCVImageBufferColorPrimariesKey, tenBit ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_P3_D65, .shouldPropagate)
        CVBufferSetAttachment(value, kCVImageBufferTransferFunctionKey, tenBit ? kCVImageBufferTransferFunction_ITU_R_2100_HLG : kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        return value
    }

    private func converted(_ buffer: CVPixelBuffer, profile: CameraProfile) async throws -> CVPixelBuffer {
        let converter = try CameraPreviewConverter(profile: profile)
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        let ready = expectation(description: "Bounded GPU camera conversion")
        let result = CameraFrameSource()
        converter.convert(try XCTUnwrap(sample)) { frame in result.update(frame.buffer, time: frame.time); ready.fulfill() }
        await fulfillment(of: [ready], timeout: 5)
        return try XCTUnwrap(result.latestFrame)
    }

    private func yuvPixel(_ buffer: CVPixelBuffer) throws -> SIMD3<Float> {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let y = Float(try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt16.self)[0]) / 65535
        let uv = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)).assumingMemoryBound(to: UInt16.self)
        let uniform = YUVUniforms.make(for: buffer, fallbackMatrix: "BT.709")
        let rgb = uniform.column0 * (y + uniform.offset.x)
            + uniform.column1 * (Float(uv[0]) / 65535 + uniform.offset.y)
            + uniform.column2 * (Float(uv[1]) / 65535 + uniform.offset.z)
        return .init(rgb.x, rgb.y, rgb.z)
    }
}
#endif
