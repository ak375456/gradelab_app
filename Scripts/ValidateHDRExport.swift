@preconcurrency import AVFoundation
import Foundation
import Metal
import simd

/// End-to-end HDR export check on real hardware, using the app's own writer
/// settings and the real `gradeExportHDR` kernel.
///
/// It encodes a tagged HLG source through the actual export path, then reopens
/// the result and measures it — codec, profile, bit depth, colour tags — and
/// decodes both files to compare pixels. A file with correct metadata and wrong
/// pixels is the failure this is designed to catch; correct metadata alone
/// establishes nothing.
@main
struct ValidateHDRExport {
    static func main() async throws {
        let sourceURL = URL(fileURLWithPath: "GradeLabTests/hlg_test.mov")
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gradelab-hdr-export-check.mov")
        try? FileManager.default.removeItem(at: outputURL)

        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("A Metal device is required")
        }
        let shaderSource = try String(contentsOfFile: "dummy name/Metal/Shaders.metal", encoding: .utf8)
        let library = try await device.makeLibrary(source: shaderSource, options: nil)
        let pipeline = try await device.makeComputePipelineState(function: library.makeFunction(name: "gradeExportHDR")!)
        var textureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        let cache = textureCache!

        // --- read the source with the app's HDR reader settings ---------------
        let asset = AVURLAsset(url: sourceURL)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let size = try await track.load(.naturalSize)
        let width = Int(size.width), height = Int(size.height)
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: track, outputSettings: ExportMediaSettings.videoReaderSettings(colorMode: .hdrHLG)
        )
        guard reader.canAdd(readerOutput) else { fatalError("reader rejected the HDR settings") }
        reader.add(readerOutput)
        reader.startReading()

        // --- writer configured exactly as the app configures it ---------------
        var sourceInfo = try await ExportSourceInspector.inspect(
            VideoAsset(url: sourceURL, metadata: try await VideoMetadataReader().read(from: sourceURL).metadata)
        )
        let writerSettings = ExportMediaSettings.videoWriterSettings(
            source: sourceInfo, configuration: .maximumQuality
        )
        let profile = (writerSettings[AVVideoCompressionPropertiesKey] as? [String: Any])?[AVVideoProfileLevelKey]
        print("Writer profile requested: \(profile.map { String(describing: $0) } ?? "none")")
        precondition(String(describing: profile).contains("Main10") || String(describing: profile).contains("Main_10"),
                     "HDR export must request HEVC Main 10, got \(String(describing: profile))")
        precondition(sourceInfo.colorMode.isHDR, "the HLG source must resolve to an HDR project")

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: writerSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: ExportMediaSettings.writerPixelBufferAttributes(
                source: sourceInfo, configuration: .maximumQuality
            )
        )
        guard writer.canAdd(input) else { fatalError("writer rejected the Main 10 settings") }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var grade = GradeUniforms(settings: .neutral, bypass: false)
        var hdr = HDRDisplayUniforms()
        let identityLUT = try LUTTextureFactory.makeIdentity(device: device, size: 33)

        func texture(_ buffer: CVPixelBuffer, _ format: MTLPixelFormat, _ plane: Int, write: Bool) -> MTLTexture? {
            var ref: CVMetalTexture?
            let attrs: CFDictionary? = write
                ? [kCVMetalTextureUsage: MTLTextureUsage([.shaderWrite, .shaderRead]).rawValue] as CFDictionary
                : nil
            let w = plane == 0 ? CVPixelBufferGetWidthOfPlane(buffer, 0) : CVPixelBufferGetWidthOfPlane(buffer, 1)
            let h = plane == 0 ? CVPixelBufferGetHeightOfPlane(buffer, 0) : CVPixelBufferGetHeightOfPlane(buffer, 1)
            guard CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, cache, buffer, attrs, format, w, h, plane, &ref) == kCVReturnSuccess,
                  let ref else { return nil }
            return CVMetalTextureGetTexture(ref)
        }
        func packed(_ buffer: CVPixelBuffer, _ format: MTLPixelFormat) -> MTLTexture? {
            var ref: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, cache, buffer, nil, format,
                CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &ref) == kCVReturnSuccess,
                  let ref else { return nil }
            return CVMetalTextureGetTexture(ref)
        }

        var frames = 0
        var time = CMTime.zero
        let frameDuration = CMTime(value: 1, timescale: 30)
        while let sample = readerOutput.copyNextSampleBuffer(), frames < 6 {
            guard let sourceBuffer = CMSampleBufferGetImageBuffer(sample) else { break }
            precondition(CVPixelBufferGetPixelFormatType(sourceBuffer) == kCVPixelFormatType_64RGBAHalf,
                         "reader did not deliver extended-range half float")
            while !input.isReadyForMoreMediaData { usleep(2000) }
            var destination: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination) == kCVReturnSuccess,
                  let destination else { fatalError("no pixel buffer from the adaptor pool") }
            precondition(CVPixelBufferGetPixelFormatType(destination) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                         "the adaptor pool is not 10-bit 4:2:0 - an 8-bit intermediate would defeat the whole path")

            guard let src = packed(sourceBuffer, .rgba16Float),
                  let luma = texture(destination, .r16Unorm, 0, write: true),
                  let chroma = texture(destination, .rg16Unorm, 1, write: true) else {
                fatalError("could not map textures")
            }
            let command = queue.makeCommandBuffer()!
            let encoder = command.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(src, index: 0)
            encoder.setTexture(luma, index: 1)
            encoder.setTexture(chroma, index: 2)
            encoder.setTexture(identityLUT, index: 3)
            encoder.setBytes(&grade, length: MemoryLayout<GradeUniforms>.stride, index: 0)
            LocalGradeStack.empty.bind(encoder)
            encoder.setBytes(&hdr, length: MemoryLayout<HDRDisplayUniforms>.stride, index: 1)
            encoder.dispatchThreads(MTLSize(width: chroma.width, height: chroma.height, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
            encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
            precondition(command.status == .completed, "kernel failed: \(String(describing: command.error))")

            precondition(adaptor.append(destination, withPresentationTime: time), "append failed")
            time = CMTimeAdd(time, frameDuration)
            frames += 1
        }
        input.markAsFinished()
        await writer.finishWriting()
        precondition(writer.status == .completed, "writer failed: \(String(describing: writer.error))")
        print("PASS encoded \(frames) frames at \(width)x\(height)")

        // --- measure the file we actually produced ----------------------------
        let report = try await ExportOutputInspector.verify(outputURL, expecting: .hdrHLG)
        print("PASS output measured: \(report.summary)")
        precondition(report.codec == "hvc1", "expected hvc1, got \(report.codec)")
        precondition(report.bitDepth == 10, "expected 10-bit, got \(String(describing: report.bitDepth))")
        precondition(report.isHLGBT2020, "colour tags are wrong")
        precondition(report.width == width && report.height == height, "dimensions changed")

        // --- pixels, not just metadata ---------------------------------------
        // Decode source and output the same way and compare. Correct tags on
        // wrong pixels is exactly what a metadata-only check would miss.
        func decodeBands(_ url: URL) async throws -> [SIMD3<Float>] {
            let asset = AVURLAsset(url: url)
            let track = try await asset.loadTracks(withMediaType: .video)[0]
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track, outputSettings: ExportMediaSettings.videoReaderSettings(colorMode: .hdrHLG))
            reader.add(output); reader.startReading()
            guard let sample = output.copyNextSampleBuffer(),
                  let buffer = CMSampleBufferGetImageBuffer(sample) else { return [] }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let h = CVPixelBufferGetHeight(buffer), w = CVPixelBufferGetWidth(buffer)
            let row = CVPixelBufferGetBytesPerRow(buffer)
            let base = CVPixelBufferGetBaseAddress(buffer)!
            let band = h / 5
            return (0..<5).map { index in
                let y = min(h - 1, index * band + band / 2)
                let p = base.advanced(by: y * row + (w / 2) * 8).assumingMemoryBound(to: Float16.self)
                return SIMD3(Float(p[0]), Float(p[1]), Float(p[2]))
            }
        }
        let before = try await decodeBands(sourceURL)
        let after = try await decodeBands(outputURL)
        precondition(before.count == 5 && after.count == 5, "could not read comparison bands")
        var worst: Float = 0
        print("  HLG band   source linear -> exported linear")
        for (index, pair) in zip(before, after).enumerated() {
            let relative = abs(pair.1.x - pair.0.x) / max(pair.0.x, 0.05)
            worst = max(worst, relative)
            print(String(format: "    %.2f       %8.4f  ->  %8.4f   (%.2f%%)",
                         Double(index) * 0.25, pair.0.x, pair.1.x, relative * 100))
        }
        // Lossy HEVC at these levels; a few percent is encoding, a transform
        // error would be tens of percent or a sign flip.
        precondition(worst < 0.06, "pixel round trip drifted \(worst * 100)% - the transform is wrong, not the encoder")
        print(String(format: "PASS pixels preserved through encode/decode: worst %.2f%%", worst * 100))
        print("PASS: Main 10 profile, 10-bit output, HLG BT.2020 tags, dimensions, pixel fidelity")
    }
}
