@preconcurrency import Metal
import Foundation

/// GPU resources shared by preview, export and the standalone validator. All
/// intermediate surfaces carry linear BT.2020 light, including transitions.
final class AppleLogLayerRenderer {
    let context: MetalContext
    let renderingLUT: MTLTexture
    private let pipelines: [String: MTLComputePipelineState]
    private var surfaces: [MTLTexture] = []

    static let functionNames = ["compositeVideoAppleLog", "compositeImageAppleLog", "blendAppleLogLayer",
                                "compositeTransitionAppleLog", "resolveAppleLogCanvas", "resolveAppleLogCanvas422"]

    private static let cacheLock = NSLock()
    /// The rendering LUT, keyed by shader library so a test or the validator
    /// running against its own compiled source cannot hand its texture to the app.
    private static var cachedLUT: [ObjectIdentifier: MTLTexture] = [:]

    /// - Parameter prebuilt: pipelines already compiled by `CompositorResources`.
    ///   Passing them is what keeps a new compositor — one per transform tick —
    ///   from recompiling these six kernels, which is minutes of work on a cold
    ///   device. Nil compiles them, which is what the validator and tests do
    ///   against their own library.
    init(context: MetalContext, prebuilt: [String: MTLComputePipelineState]? = nil) throws {
        self.context = context
        Self.cacheLock.lock()
        defer { Self.cacheLock.unlock() }
        let key = ObjectIdentifier(context.library)
        if let cached = Self.cachedLUT[key] {
            renderingLUT = cached
        } else {
            context.luts.prepareRenderingLUT(named: AppleLogRendering.rec709LUTResourceName)
            guard let lut = context.luts.renderingTexture(named: AppleLogRendering.rec709LUTResourceName) else {
                throw GradeLabError.unsupportedExport(
                    "Apple's Apple Log to Rec.709 rendering LUT could not be loaded. Apple Log layers have no defined display transform without it.")
            }
            renderingLUT = lut
            Self.cachedLUT[key] = lut
        }
        if let prebuilt, Self.functionNames.allSatisfy({ prebuilt[$0] != nil }) {
            pipelines = prebuilt.filter { Self.functionNames.contains($0.key) }
            return
        }
        var built: [String: MTLComputePipelineState] = [:]
        for name in Self.functionNames {
            guard let function = context.library.makeFunction(name: name) else {
                throw GradeLabError.rendererInitializationFailed
            }
            built[name] = try context.device.makeComputePipelineState(function: function)
        }
        pipelines = built
    }

    func canvases(width: Int, height: Int) throws -> [MTLTexture] {
        if surfaces.first?.width == width, surfaces.first?.height == height { return surfaces }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private
        // Two accumulated canvases and three temporary layer/transition inputs.
        // Their number is independent of timeline length and layer count.
        surfaces = try (0..<5).map { _ in
            guard let texture = context.device.makeTexture(descriptor: descriptor) else {
                throw GradeLabError.rendererInitializationFailed
            }
            return texture
        }
        return surfaces
    }

    /// Tiled dispatch uses the full canvas coordinates for masks, sampling and
    /// transitions. The validator exercises this same entry point in tiles.
    func encode(_ name: String, into command: MTLCommandBuffer,
                width: Int, height: Int, tileSize: Int? = nil,
                configure: (MTLComputeCommandEncoder) -> Void) throws {
        guard let pipeline = pipelines[name], let encoder = command.makeComputeCommandEncoder() else {
            throw GradeLabError.rendererInitializationFailed
        }
        encoder.label = name
        encoder.setComputePipelineState(pipeline)
        configure(encoder)
        let step = max(1, tileSize ?? max(width, height))
        let threadWidth = pipeline.threadExecutionWidth
        let threads = MTLSize(width: threadWidth,
                              height: max(1, min(8, pipeline.maxTotalThreadsPerThreadgroup / threadWidth)), depth: 1)
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                var origin = SIMD2<UInt32>(UInt32(x), UInt32(y))
                encoder.setBytes(&origin, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 7)
                encoder.dispatchThreads(.init(width: min(step, width - x), height: min(step, height - y), depth: 1),
                                        threadsPerThreadgroup: threads)
            }
        }
        encoder.endEncoding()
    }

    static func blendIndex(_ mode: VisualBlendMode) -> UInt32 {
        switch mode {
        case .normal: 0
        case .multiply: 1
        case .screen: 2
        case .overlay: 3
        case .softLight: 4
        case .hardLight: 5
        case .darken: 6
        case .lighten: 7
        }
    }
}
