#if !targetEnvironment(macCatalyst)
@preconcurrency import AVFoundation
@preconcurrency import Metal

/// GPU-completed storage is immutable once handed to the capture queue.
struct CameraMonitorFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
    let time: CMTime
}

/// Original samples go to the encoder first. Only the monitoring branch is
/// reduced and converted, with one GPU job in flight and a bounded buffer pool.
/// HDR arrives at the existing renderer as half-float HLG signal, exactly like
/// AVFoundation's HDR playback output. P3 preview uses the editor's Rec.709 view.
final class CameraPreviewConverter: @unchecked Sendable {
    private let context: MetalContext
    private let pipeline: MTLComputePipelineState
    private let gate = DispatchSemaphore(value: 1)
    private var pool: CVPixelBufferPool?
    private var size = CGSize.zero
    private var lastTime = -Double.infinity
    let profile: CameraProfile

    init(profile: CameraProfile) throws {
        self.profile = profile
        context = try MetalContext()
        guard let function = context.library.makeFunction(name: "cameraMonitorYUV") else {
            throw GradeLabError.rendererInitializationFailed
        }
        pipeline = try context.device.makeComputePipelineState(function: function)
    }

    func convert(_ sample: CMSampleBuffer, onFrame: @escaping @Sendable (CameraMonitorFrame) -> Void) {
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        guard time.seconds - lastTime >= 1.0 / 30 - 0.0001,
              gate.wait(timeout: .now()) == .success else { return }
        var submitted = false
        defer { if !submitted { gate.signal() } }
        guard let source = CMSampleBufferGetImageBuffer(sample),
              let textures = PixelBufferTextures(pixelBuffer: source, context: context),
              case .biPlanar(_, let luma, _, let chroma) = textures.storage else { return }
        let scale = min(1, 1280 / Double(max(CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source))))
        let width = max(2, Int(Double(CVPixelBufferGetWidth(source)) * scale) / 2 * 2)
        let height = max(2, Int(Double(CVPixelBufferGetHeight(source)) * scale) / 2 * 2)
        if size != CGSize(width: width, height: height) {
            size = CGSize(width: width, height: height)
            pool = nil
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferPixelFormatTypeKey as String: profile == .hdrHLG ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        guard let pool else { return }
        var output: CVPixelBuffer?
        let threshold = [kCVPixelBufferPoolAllocationThresholdKey as String: 3] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, threshold, &output) == kCVReturnSuccess,
              let output,
              let destination = context.packedTexture(from: output, pixelFormat: profile == .hdrHLG ? .rgba16Float : .bgra8Unorm, writable: true),
              let command = context.commandQueue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else { return }
        var yuv = YUVUniforms.make(for: source, fallbackMatrix: profile == .hdrHLG ? "BT.2020" : "BT.709")
        let transfer = CVBufferCopyAttachment(source, kCVImageBufferTransferFunctionKey, nil).map(String.init(describing:)) ?? ""
        var mode: UInt32 = profile == .hdrHLG ? 0 : transfer.contains("sRGB") ? 2 : 1
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(luma, index: 0); encoder.setTexture(chroma, index: 1)
        encoder.setTexture(destination.texture, index: 2)
        encoder.setBytes(&yuv, length: MemoryLayout<YUVUniforms>.stride, index: 0)
        encoder.setBytes(&mode, length: MemoryLayout<UInt32>.stride, index: 1)
        encoder.dispatchThreads(.init(width: width, height: height, depth: 1),
            threadsPerThreadgroup: .init(width: 16, height: 8, depth: 1))
        encoder.endEncoding()
        command.addCompletedHandler { [gate, textures, destination, source, output] command in
            _ = (textures, destination, source)
            defer { gate.signal() }
            if command.status == .completed { onFrame(CameraMonitorFrame(buffer: output, time: time)) }
        }
        lastTime = time.seconds
        submitted = true
        command.commit()
    }
}
#endif
