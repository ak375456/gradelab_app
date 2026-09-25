@preconcurrency import Metal
@preconcurrency import CoreVideo
import Foundation
import simd

// ---------------------------------------------------------------------------
// Shot Match: getting a picture into the analysis space
//
// The only part of the feature that touches Metal, and it is deliberately the
// only part: `ShotAnalyzer`, `MatchSolver` and the whole document model take
// arrays of colours and know nothing about textures, so they are testable on a
// host with no GPU and reusable for anything that can produce pixels.
//
// This runs the shipping grading path — `applyLookAndGrade`, the real look LUT,
// the real curve rows, the real masked local grades — and converts the result
// into the analysis space. Two consequences worth stating:
//
//   - What is measured is the picture the preview is showing, grade and all.
//     A reference shot is a graded shot; matching the ungraded source would
//     match the camera rather than the colorist.
//   - A grading stage cannot drift away from what Shot Match believes it does,
//     because there is no second implementation of any of it here.
// ---------------------------------------------------------------------------

/// Frames in the analysis space, ready for `ShotAnalyzer`.
struct ShotMatchFrame: Sendable {
    /// Linear analysis-space RGB.
    var samples: [SIMD3<Float>]
    /// Share of pixels that were above diffuse white before the analysis space
    /// clamped them. Zero for SDR.
    var headroomFraction: Float
}

/// Renders a decoded frame into the analysis space and reads it back.
///
/// Held by the editor for as long as a match panel is open and released with
/// it: the pipelines are cheap to keep and expensive to rebuild, but there is
/// no reason for a project that has never opened the panel to carry them.
final class ShotMatchAnalysisRenderer: @unchecked Sendable {

    /// Long edge of the analysis texture.
    ///
    /// 512 across is about 150,000 pixels — 0.9% of a 4K frame, and roughly
    /// seventy times more than the solve actually uses. Analysing the full
    /// frame would cost a hundred times as much to measure the same
    /// distribution: percentiles, a neutral estimate and three zone chromas are
    /// converged long before this many samples.
    ///
    /// The grade derived from these pixels is then applied by the ordinary
    /// pipeline at the source's own resolution, so nothing about the export is
    /// affected by the size of the analysis.
    static let analysisLongEdge = 512

    private let context: MetalContext
    private let lock = NSLock()
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private var cachedTexture: MTLTexture?
    private var cachedSize = (width: 0, height: 0)

    init?(context: MetalContext) {
        self.context = context
        for name in ["shotMatchSampleYUV", "shotMatchSampleBGRA", "shotMatchSampleHDR"] {
            guard let function = context.library.makeFunction(name: name),
                  let state = try? context.device.makeComputePipelineState(function: function) else {
                return nil
            }
            pipelines[name] = state
        }
        // Apple Log is specialised on the Log 2 function constant, exactly as
        // the preview and export pipelines are. A device with no Apple Log
        // source never needs these, so a failure to build them is not a reason
        // to have no Shot Match at all.
        for isLog2 in [false, true] {
            let key = AppleLogSpecialization.key("shotMatchSampleAppleLog", isLog2: isLog2)
            if let state = AppleLogSpecialization.computePipeline(
                "shotMatchSampleAppleLog", isLog2: isLog2,
                library: context.library, device: context.device) {
                pipelines[key] = state
            }
        }
    }

    /// The analysis size for a frame, preserving its aspect so nothing is
    /// stretched — a stretched frame would measure the same colours, but a
    /// portrait clip and a landscape one would no longer weight the picture the
    /// same way.
    static func analysisSize(width: Int, height: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (0, 0) }
        let longest = max(width, height)
        guard longest > analysisLongEdge else { return (width, height) }
        let scale = Double(analysisLongEdge) / Double(longest)
        func scaled(_ value: Int) -> Int { max(2, Int((Double(value) * scale).rounded())) }
        return (scaled(width), scaled(height))
    }

    /// One frame, graded and measured.
    ///
    /// Synchronous and blocking on the GPU, which is correct here and would not
    /// be in the preview: this is called from a detached task while the panel
    /// shows its progress, the pass is a fraction of a millisecond, and the
    /// alternative — a completion handler per frame — would serialise five
    /// frames of a clip into five round trips for no gain.
    func analyze(
        pixelBuffer: CVPixelBuffer,
        grade: GradeSettings,
        masks: [MaskedGradeLayer],
        colorMode: ProjectColorMode,
        fallbackMatrix: String?,
        appleLogRenderingLUT: MTLTexture?
    ) -> ShotMatchFrame? {
        guard let textures = PixelBufferTextures(pixelBuffer: pixelBuffer, context: context) else {
            return nil
        }
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let size = Self.analysisSize(width: sourceWidth, height: sourceHeight)
        guard size.width > 0, size.height > 0 else { return nil }

        let name: String
        switch textures.storage {
        case .biPlanar:
            name = colorMode.isAppleLog
                ? AppleLogSpecialization.key("shotMatchSampleAppleLog", isLog2: colorMode == .appleLog2)
                : "shotMatchSampleYUV"
        case .bgra: name = "shotMatchSampleBGRA"
        case .linearHalf: name = "shotMatchSampleHDR"
        }
        guard let pipeline = pipelines[name] else { return nil }
        // Apple Log has no alternative display transform, so an unprepared
        // rendering LUT is a refusal rather than something to substitute for.
        if name.hasPrefix("shotMatchSampleAppleLog"), appleLogRenderingLUT == nil { return nil }

        lock.lock()
        guard let destination = texture(width: size.width, height: size.height) else {
            lock.unlock(); return nil
        }
        lock.unlock()

        let program = GradeProgram(
            settings: grade, masks: masks, bypass: false,
            aspect: CGSize(width: sourceWidth, height: sourceHeight).maskAspect)
        var uniforms = program.uniforms
        var yuv = YUVUniforms.make(for: pixelBuffer, fallbackMatrix: fallbackMatrix)
        var hdr = HDRDisplayUniforms()

        guard let command = context.commandQueue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else { return nil }
        command.label = "GradeLab Shot Match analysis"
        encoder.setComputePipelineState(pipeline)
        switch textures.storage {
        case .biPlanar(_, let luma, _, let chroma):
            encoder.setTexture(luma, index: 0)
            encoder.setTexture(chroma, index: 1)
            encoder.setBytes(&yuv, length: MemoryLayout<YUVUniforms>.stride, index: 1)
        case .bgra(_, let texture):
            encoder.setTexture(texture, index: 0)
        case .linearHalf(_, let texture):
            encoder.setTexture(texture, index: 0)
            encoder.setBytes(&hdr, length: MemoryLayout<HDRDisplayUniforms>.stride, index: 2)
        }
        encoder.setTexture(destination, index: 2)
        encoder.setTexture(context.luts.texture(for: program.lookIdentifier), index: 3)
        encoder.setTexture(appleLogRenderingLUT, index: 4)
        encoder.setTexture(context.curves.texture(for: program.curveRows), index: 6)
        encoder.setTexture(context.warps.texture(for: program.warp), index: 12)
        encoder.setBytes(&uniforms, length: MemoryLayout<GradeUniforms>.stride, index: 0)
        program.locals.bind(encoder)
        let threadWidth = max(1, min(pipeline.threadExecutionWidth, size.width))
        encoder.dispatchThreads(
            MTLSize(width: size.width, height: size.height, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: threadWidth,
                height: max(1, min(pipeline.maxTotalThreadsPerThreadgroup / threadWidth, size.height)),
                depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        // Keeps the source's `CVMetalTexture` bindings alive until the GPU has
        // finished with them; releasing earlier would pull the IOSurface out
        // from under a pass that is still reading it.
        withExtendedLifetime(textures) {}
        guard command.status == .completed else { return nil }

        return read(destination, width: size.width, height: size.height)
    }

    /// Reads the analysis texture back into linear samples.
    private func read(_ texture: MTLTexture, width: Int, height: Int) -> ShotMatchFrame {
        let count = width * height
        var pixels = [Float](repeating: 0, count: count * 4)
        pixels.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!,
                             bytesPerRow: width * 4 * MemoryLayout<Float>.size,
                             from: MTLRegionMake2D(0, 0, width, height),
                             mipmapLevel: 0)
        }
        var samples = [SIMD3<Float>]()
        samples.reserveCapacity(count)
        var aboveWhite = 0
        var counted = 0
        for index in 0..<count {
            let base = index * 4
            // Alpha is the analysis flag, not opacity: -1 marks a pixel that is
            // not part of the picture at all and is dropped, 1 marks one that
            // was above diffuse white before the space clamped it.
            let flag = pixels[base + 3]
            if flag < -0.5 { continue }
            counted += 1
            if flag > 0.5 { aboveWhite += 1 }
            let encoded = SIMD3(pixels[base], pixels[base + 1], pixels[base + 2])
            guard encoded.x.isFinite, encoded.y.isFinite, encoded.z.isFinite else { continue }
            samples.append(ShotMatchColor.toLinear(simd_clamp(encoded, .zero, .one)))
        }
        return ShotMatchFrame(
            samples: samples,
            headroomFraction: counted > 0 ? Float(aboveWhite) / Float(counted) : 0)
    }

    private func texture(width: Int, height: Int) -> MTLTexture? {
        if let existing = cachedTexture, cachedSize == (width, height) { return existing }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderWrite, .shaderRead]
        // Shared so the CPU can read it without a blit. The texture is written
        // once and read once, never filtered, so there is nothing for a private
        // allocation to buy.
        descriptor.storageMode = .shared
        guard let made = context.device.makeTexture(descriptor: descriptor) else { return nil }
        cachedTexture = made
        cachedSize = (width, height)
        return made
    }

    /// Frees the analysis texture. Called when the panel closes.
    func release() {
        lock.lock()
        cachedTexture = nil
        cachedSize = (0, 0)
        lock.unlock()
    }
}
