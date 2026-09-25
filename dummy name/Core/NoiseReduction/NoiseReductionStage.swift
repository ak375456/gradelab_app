@preconcurrency import Metal
@preconcurrency import CoreVideo
import CoreMedia
import Foundation
import simd

// ---------------------------------------------------------------------------
// The engine
//
// One instance serves every path that needs it — the preview, the exporter and
// the layer compositor — for the same reason `FilmEffectsStage` does: a
// denoiser that ran different arithmetic in the preview than in the export
// would be a preview of a picture nobody is going to get. Quality settings
// change the resolution motion is estimated at and nothing else.
//
// It never runs unless something asks for it. A `NoiseReduction` that is not
// `isActive` leaves every path on exactly the route it took before this
// existed, and `releaseResources` gives back every surface the moment nothing
// is using them — which matters, because these are the largest allocations in
// the app.
// ---------------------------------------------------------------------------

/// One frame handed to the engine.
struct NoiseFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    /// Signed distance from the frame being rendered, in frames. Zero for the
    /// frame itself.
    let offset: Int
    /// When this frame is, so a caller that knows where the clip boundaries
    /// are can drop a neighbour that belongs to the next shot. Invalid when
    /// the supplier had no meaningful timeline to report.
    let time: CMTime

    init(pixelBuffer: CVPixelBuffer, offset: Int, time: CMTime = .invalid) {
        self.pixelBuffer = pixelBuffer
        self.offset = offset
        self.time = time
    }
}

/// What the stage produced, and what it had to settle for.
///
/// The second half is not decoration. Temporal reduction can only run on frames
/// that have actually been decoded, and at a cut, at the ends of a clip, or
/// while someone is dragging the playhead there may not be any. Reporting that
/// is what lets the editor say "spatial only, for now" instead of quietly
/// showing a different picture than the export will produce.
struct NoiseReductionResult {
    let texture: MTLTexture
    /// How many neighbours were actually combined. Zero means the temporal
    /// stage did not run.
    let temporalNeighbours: Int
    /// True when the settings asked for temporal reduction and it ran.
    let temporalRan: Bool
}

final class NoiseReductionStage: @unchecked Sendable {
    /// The most neighbours one pass can combine, which is the five-frame window
    /// minus the current frame. Fixed because the temporal kernels bind every
    /// neighbour at once rather than accumulating into a buffer — one pass over
    /// the frame instead of four, and no accumulation surface at all.
    static let maximumNeighbours = 4
    /// Levels in the matching pyramid. Four takes a quarter-resolution grid
    /// down to a thirty-second of the frame, which is coarse enough that a fast
    /// pan is a displacement of a few pixels there.
    private static let flowLevels = 4

    private let context: MetalContext
    private let isLog2: Bool
    private let lock = NSLock()

    private let prepareYUV: MTLComputePipelineState
    private let prepareBGRA: MTLComputePipelineState
    private let prepareHDR: MTLComputePipelineState
    private let prepareAppleLog: MTLComputePipelineState?
    private let downsampleLuma: MTLComputePipelineState
    private let downsampleChroma: MTLComputePipelineState
    private let buildGuide: MTLComputePipelineState
    private let noiseField: MTLComputePipelineState
    private let noiseFloor: MTLComputePipelineState
    private let flowSearch: MTLComputePipelineState
    private let flowSmooth: MTLComputePipelineState
    private let temporalLuma: MTLComputePipelineState
    private let temporalChroma: MTLComputePipelineState
    private let guidedSeed: MTLComputePipelineState
    private let boxBlur: MTLComputePipelineState
    private let guidedCoefficients: MTLComputePipelineState
    private let guidedApply: MTLComputePipelineState
    private let chromaFilter: MTLComputePipelineState
    private let detailRecovery: MTLComputePipelineState
    private let reconstruct: MTLComputePipelineState

    private var surfaces: Surfaces?

    init?(context: MetalContext, isLog2: Bool = false) {
        self.context = context
        self.isLog2 = isLog2
        func pipeline(_ name: String) -> MTLComputePipelineState? {
            guard let function = context.library.makeFunction(name: name) else { return nil }
            return try? context.device.makeComputePipelineState(function: function)
        }
        guard let prepareYUV = pipeline("nrPrepareYUV"),
              let prepareBGRA = pipeline("nrPrepareBGRA"),
              let prepareHDR = pipeline("nrPrepareHDR"),
              let downsampleLuma = pipeline("nrDownsampleLuma"),
              let downsampleChroma = pipeline("nrDownsampleChroma"),
              let buildGuide = pipeline("nrBuildGuide"),
              let noiseField = pipeline("nrNoiseField"),
              let noiseFloor = pipeline("nrNoiseFloor"),
              let flowSearch = pipeline("nrFlowSearch"),
              let flowSmooth = pipeline("nrFlowSmooth"),
              let temporalLuma = pipeline("nrTemporalLuma"),
              let temporalChroma = pipeline("nrTemporalChroma"),
              let guidedSeed = pipeline("nrGuidedSeed"),
              let boxBlur = pipeline("nrBoxBlur"),
              let guidedCoefficients = pipeline("nrGuidedCoefficients"),
              let guidedApply = pipeline("nrGuidedApply"),
              let chromaFilter = pipeline("nrChromaFilter"),
              let detailRecovery = pipeline("nrDetailRecovery"),
              let reconstruct = pipeline("nrReconstruct") else { return nil }
        self.prepareYUV = prepareYUV
        self.prepareBGRA = prepareBGRA
        self.prepareHDR = prepareHDR
        // Apple Log reaches the function constant that selects between the two
        // input transforms, so it is built through the specialisation helper
        // and is nil on a device that could not build the variant — never
        // silently the wrong transform.
        self.prepareAppleLog = AppleLogSpecialization.computePipeline(
            "nrPrepareAppleLog", isLog2: isLog2, library: context.library, device: context.device)
        self.downsampleLuma = downsampleLuma
        self.downsampleChroma = downsampleChroma
        self.buildGuide = buildGuide
        self.noiseField = noiseField
        self.noiseFloor = noiseFloor
        self.flowSearch = flowSearch
        self.flowSmooth = flowSmooth
        self.temporalLuma = temporalLuma
        self.temporalChroma = temporalChroma
        self.guidedSeed = guidedSeed
        self.boxBlur = boxBlur
        self.guidedCoefficients = guidedCoefficients
        self.guidedApply = guidedApply
        self.chromaFilter = chromaFilter
        self.detailRecovery = detailRecovery
        self.reconstruct = reconstruct
    }

    func releaseResources() {
        lock.lock(); surfaces = nil; lock.unlock()
    }

    /// Roughly what the surfaces for one frame size cost, in bytes.
    ///
    /// Used by the capability tier to decide what a device may be offered, and
    /// worth having as arithmetic rather than a guess: at 4K these are by a
    /// wide margin the largest allocations the app makes.
    static func approximateBytes(width: Int, height: Int, neighbours: Int) -> Int {
        let full = width * height
        let half = max(1, width / 2) * max(1, height / 2)
        let quarter = max(1, width / 4) * max(1, height / 4)
        // current frame: luma, full chroma, half chroma, guide
        var total = full * 2 + full * 4 + half * 4 + half * 8
        // each neighbour: luma, half chroma, and a single-channel guide
        total += neighbours * (full * 2 + half * 4 + half * 2)
        // the shared full-resolution chroma scratch the neighbours prepare into
        total += neighbours > 0 ? full * 4 : 0
        // temporal results, spatial working set, the recovered luma, the output
        total += full * 2 + half * 4
        total += quarter * 8 * 2 + full * 2 + half * 4 * 2
        total += full * 2 + full * 8
        if neighbours > 0 {
            // The motion fields and the matching pyramids. Two fields per
            // neighbour plus the scratch each level needs, and one halving
            // chain per frame in the window.
            total += neighbours * 2 * (quarter * 8) + quarter * 8 * 3
            total += (neighbours + 1) * full
            // And the decoded frames themselves. They are not the engine's
            // allocation, but they are held for its sake and a device that
            // cannot hold them cannot run this window.
            //
            // Counted as the ring the preview actually keeps rather than as the
            // window, which is four frames wider: `TemporalFrameCache` holds a
            // little slack either side so ordinary playback does not fall out of
            // it, and at 4K each of those frames is about a dozen megabytes that
            // a tier deciding what a phone can hold must not overlook.
            total += (neighbours + 5) * full * 3 / 2
        }
        return total
    }
}

// MARK: - Surfaces

private extension NoiseReductionStage {
    /// Every texture the engine works in, allocated as a set.
    ///
    /// Held as one object keyed by the frame size and the window width so that
    /// a resolution change, a quality change or a change of frame count
    /// replaces the whole set at once rather than leaving a mismatched half of
    /// it behind.
    final class Surfaces {
        let width: Int, height: Int
        let neighbours: Int
        let flowDivisor: Int

        let luma: MTLTexture
        let chromaFull: MTLTexture
        let chromaHalf: MTLTexture
        let guide: MTLTexture
        let fieldTiles: MTLTexture
        let field: MTLTexture

        let neighbourLuma: [MTLTexture]
        let neighbourChroma: [MTLTexture]
        let neighbourGuide: [MTLTexture]
        let neighbourChromaScratch: MTLTexture?

        let temporalLuma: MTLTexture
        let temporalChroma: MTLTexture

        let guidedA: MTLTexture
        let guidedB: MTLTexture
        let spatialLuma: MTLTexture
        let chromaScratchA: MTLTexture
        let chromaScratchB: MTLTexture

        let recovered: MTLTexture
        let output: MTLTexture

        /// Halvings of the luma plane, finest first. The matching pyramid is a
        /// window into this, which is why the chain is built once per frame and
        /// shared by every neighbour pair.
        let currentPyramid: [MTLTexture]
        let neighbourPyramids: [[MTLTexture]]
        /// Two scratch fields per pyramid level: one for the search, one for the
        /// median that follows it.
        let flowScratchA: [MTLTexture]
        let flowScratchB: [MTLTexture]
        /// The finished fields, one per neighbour per direction, at the finest
        /// pyramid level.
        let flowForward: [MTLTexture]
        let flowBackward: [MTLTexture]

        var chromaSize: (width: Int, height: Int) {
            (max(1, width / 2), max(1, height / 2))
        }

        /// The index into the halving chain that is the finest pyramid level.
        var flowBase: Int { Surfaces.baseLevel(for: flowDivisor) }

        /// Which halving of the frame the motion grid is.
        ///
        /// Counted rather than taken from `log2`: the divisor is always a power
        /// of two, and a floating-point logarithm that lands on 1.9999 would
        /// put the whole pyramid one level out.
        static func baseLevel(for divisor: Int) -> Int {
            var level = 0, value = max(divisor, 2)
            while value > 2 { value /= 2; level += 1 }
            return level
        }

        var flowSize: (width: Int, height: Int) {
            (currentPyramid[flowBase].width, currentPyramid[flowBase].height)
        }

        init?(device: MTLDevice, width: Int, height: Int, neighbours: Int, flowDivisor: Int) {
            self.width = width; self.height = height
            self.neighbours = neighbours; self.flowDivisor = flowDivisor

            func make(_ format: MTLPixelFormat, _ w: Int, _ h: Int) -> MTLTexture? {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: format, width: max(1, w), height: max(1, h), mipmapped: false)
                descriptor.usage = [.shaderRead, .shaderWrite]
                descriptor.storageMode = .private
                return device.makeTexture(descriptor: descriptor)
            }
            let halfWidth = max(1, width / 2), halfHeight = max(1, height / 2)
            let quarterWidth = max(1, width / 4), quarterHeight = max(1, height / 4)
            // The noise field is one texel per 8x8 block of the guide, which is
            // one per 16x16 block of the picture.
            let fieldWidth = max(1, (halfWidth + 7) / 8), fieldHeight = max(1, (halfHeight + 7) / 8)

            guard let luma = make(.r16Float, width, height),
                  let chromaFull = make(.rg16Float, width, height),
                  let chromaHalf = make(.rg16Float, halfWidth, halfHeight),
                  let guide = make(.rgba16Float, halfWidth, halfHeight),
                  let fieldTiles = make(.rgba16Float, fieldWidth, fieldHeight),
                  let field = make(.rgba16Float, fieldWidth, fieldHeight),
                  let temporalLuma = make(.r16Float, width, height),
                  let temporalChroma = make(.rg16Float, halfWidth, halfHeight),
                  let guidedA = make(.rgba16Float, quarterWidth, quarterHeight),
                  let guidedB = make(.rgba16Float, quarterWidth, quarterHeight),
                  let spatialLuma = make(.r16Float, width, height),
                  let chromaScratchA = make(.rg16Float, halfWidth, halfHeight),
                  let chromaScratchB = make(.rg16Float, halfWidth, halfHeight),
                  let recovered = make(.r16Float, width, height),
                  let output = make(.rgba16Float, width, height) else { return nil }
            self.luma = luma; self.chromaFull = chromaFull; self.chromaHalf = chromaHalf
            self.guide = guide; self.fieldTiles = fieldTiles; self.field = field
            self.temporalLuma = temporalLuma; self.temporalChroma = temporalChroma
            self.guidedA = guidedA; self.guidedB = guidedB; self.spatialLuma = spatialLuma
            self.chromaScratchA = chromaScratchA; self.chromaScratchB = chromaScratchB
            self.recovered = recovered; self.output = output

            // A neighbour's guide carries only its low-passed luminance: the
            // high-frequency channels describe the frame being rendered, and
            // nothing reads a neighbour's. One channel instead of four is a
            // saving of about fifty megabytes on a 4K five-frame window.
            var lumas: [MTLTexture] = [], chromas: [MTLTexture] = [], guides: [MTLTexture] = []
            for _ in 0..<neighbours {
                guard let l = make(.r16Float, width, height),
                      let c = make(.rg16Float, halfWidth, halfHeight),
                      let g = make(.r16Float, halfWidth, halfHeight) else { return nil }
                lumas.append(l); chromas.append(c); guides.append(g)
            }
            neighbourLuma = lumas; neighbourChroma = chromas; neighbourGuide = guides
            if neighbours > 0 {
                guard let scratch = make(.rg16Float, width, height) else { return nil }
                neighbourChromaScratch = scratch
            } else {
                neighbourChromaScratch = nil
            }

            // The halving chain, deep enough that the coarsest pyramid level
            // still exists at this frame size.
            let base = Surfaces.baseLevel(for: flowDivisor)
            let depth = base + NoiseReductionStage.flowLevels
            func chain() -> [MTLTexture]? {
                var levels: [MTLTexture] = []
                var w = width, h = height
                for _ in 0..<depth {
                    w = max(1, w / 2); h = max(1, h / 2)
                    guard let texture = make(.r16Float, w, h) else { return nil }
                    levels.append(texture)
                }
                return levels
            }
            guard let current = chain() else { return nil }
            currentPyramid = current
            var pyramids: [[MTLTexture]] = []
            for _ in 0..<neighbours {
                guard let level = chain() else { return nil }
                pyramids.append(level)
            }
            neighbourPyramids = pyramids

            var scratchA: [MTLTexture] = [], scratchB: [MTLTexture] = []
            for level in base..<depth {
                let size = (current[level].width, current[level].height)
                guard let a = make(.rgba16Float, size.0, size.1),
                      let b = make(.rgba16Float, size.0, size.1) else { return nil }
                scratchA.append(a); scratchB.append(b)
            }
            flowScratchA = scratchA; flowScratchB = scratchB

            var forward: [MTLTexture] = [], backward: [MTLTexture] = []
            let finest = (current[base].width, current[base].height)
            for _ in 0..<neighbours {
                guard let f = make(.rgba16Float, finest.0, finest.1),
                      let b = make(.rgba16Float, finest.0, finest.1) else { return nil }
                forward.append(f); backward.append(b)
            }
            flowForward = forward; flowBackward = backward
        }
    }

    func resolvedSurfaces(width: Int, height: Int, neighbours: Int, flowDivisor: Int) -> Surfaces? {
        lock.lock(); defer { lock.unlock() }
        if let existing = surfaces, existing.width == width, existing.height == height,
           existing.neighbours == neighbours, existing.flowDivisor == flowDivisor {
            return existing
        }
        // Dropped before the new set is asked for, so a resolution change does
        // not briefly hold two full working sets at once.
        surfaces = nil
        surfaces = Surfaces(device: context.device, width: width, height: height,
                            neighbours: neighbours, flowDivisor: flowDivisor)
        return surfaces
    }
}

// MARK: - Encoding

extension NoiseReductionStage {

    /// Encodes the whole engine into `command` and returns the denoised frame,
    /// in the same representation the grading stage expects as input.
    ///
    /// Nothing is committed and nothing is waited on: the caller owns the
    /// command buffer, so this can sit inside a pass that is already being
    /// built — which is what lets the preview denoise, grade and present in one
    /// submission.
    func encode(
        current: CVPixelBuffer,
        neighbours: [NoiseFrame],
        settings: NoiseReduction,
        colorMode: ProjectColorMode,
        hdr: HDRDisplayUniforms,
        fallbackMatrix: String?,
        into command: MTLCommandBuffer
    ) -> NoiseReductionResult? {
        let resolved = settings.clamped
        guard resolved.isActive else { return nil }
        guard let currentTextures = PixelBufferTextures(pixelBuffer: current, context: context) else { return nil }
        let width = CVPixelBufferGetWidth(current), height = CVPixelBufferGetHeight(current)
        guard width > 1, height > 1 else { return nil }

        // Neighbours that do not match the frame being rendered are dropped
        // rather than resized. A denoiser that silently scaled its evidence
        // would be aligning one picture to a different one.
        // Held to the window the settings actually ask for. A supplier may
        // hand over more than that — the export window is sized once for the
        // widest setting in the timeline — and using them would make the Frames
        // control do nothing whenever it was set below that maximum.
        let reach = resolved.temporalReach
        let usable = resolved.temporalIsActive
            ? neighbours
                .filter { CVPixelBufferGetWidth($0.pixelBuffer) == width
                       && CVPixelBufferGetHeight($0.pixelBuffer) == height
                       && $0.offset != 0
                       && $0.offset >= -reach.backward && $0.offset <= reach.forward }
                .sorted { abs($0.offset) < abs($1.offset) }
                .prefix(Self.maximumNeighbours)
            : []
        let neighbourList = Array(usable)
        // A temporal-only setting with no neighbours to combine would prepare
        // the frame, convert it and convert it straight back. Returning nil
        // instead puts the caller on its ordinary route, which is both cheaper
        // and exactly the same picture.
        guard resolved.spatialIsActive || !neighbourList.isEmpty else { return nil }

        let flowDivisor = resolved.quality.flowDivisor(longEdge: max(width, height))
        guard let s = resolvedSurfaces(width: width, height: height,
                                       neighbours: neighbourList.count,
                                       flowDivisor: flowDivisor) else { return nil }

        var plane = NoisePlaneUniforms(colorMode: colorMode)
        var uniforms = NoiseReductionUniforms(
            settings: resolved,
            lumaWeights: SIMD3(plane.luma.x, plane.luma.y, plane.luma.z),
            extendedRange: plane.luma.w > 0.5,
            size: (width, height),
            chromaSize: s.chromaSize)
        uniforms.flow = SIMD4(1 / Float(s.flowSize.width), 1 / Float(s.flowSize.height),
                              Float(s.flowSize.width), Float(s.flowSize.height))

        // 1. The frame itself, into the working planes.
        guard prepare(pixelBuffer: current, textures: currentTextures,
                      luma: s.luma, chroma: s.chromaFull,
                      colorMode: colorMode, hdr: hdr, plane: &plane,
                      fallbackMatrix: fallbackMatrix, into: command) else { return nil }
        downsample(downsampleChroma, source: s.chromaFull, destination: s.chromaHalf, into: command)
        encodeGuide(luma: s.luma, chroma: s.chromaHalf, guide: s.guide,
                    uniforms: &uniforms, into: command)
        encodeNoiseField(guide: s.guide, tiles: s.fieldTiles, field: s.field, into: command)

        // 2. Every neighbour, through exactly the same preparation.
        var prepared: [Int] = []
        for (index, frame) in neighbourList.enumerated() {
            guard let textures = PixelBufferTextures(pixelBuffer: frame.pixelBuffer, context: context),
                  let scratch = s.neighbourChromaScratch else { continue }
            guard prepare(pixelBuffer: frame.pixelBuffer, textures: textures,
                          luma: s.neighbourLuma[index], chroma: scratch,
                          colorMode: colorMode, hdr: hdr, plane: &plane,
                          fallbackMatrix: fallbackMatrix, into: command) else { continue }
            downsample(downsampleChroma, source: scratch,
                       destination: s.neighbourChroma[index], into: command)
            encodeGuide(luma: s.neighbourLuma[index], chroma: s.neighbourChroma[index],
                        guide: s.neighbourGuide[index], uniforms: &uniforms, into: command)
            // The textures are mapped from the neighbour's pixel buffer, so the
            // buffer has to outlive the GPU work rather than this loop.
            command.addCompletedHandler { _ in withExtendedLifetime(textures) {} }
            prepared.append(index)
        }

        // 3. Motion, in both directions, for every neighbour that survived.
        let usesFlow = resolved.isMotionCompensated && !prepared.isEmpty
        if usesFlow {
            buildPyramid(source: s.luma, levels: s.currentPyramid, into: command)
            for index in prepared {
                buildPyramid(source: s.neighbourLuma[index],
                             levels: s.neighbourPyramids[index], into: command)
            }
            for index in prepared {
                encodeFlow(from: s.currentPyramid, to: s.neighbourPyramids[index],
                           destination: s.flowForward[index], surfaces: s, into: command)
                encodeFlow(from: s.neighbourPyramids[index], to: s.currentPyramid,
                           destination: s.flowBackward[index], surfaces: s, into: command)
            }
        }

        // 4. Temporal.
        var temporalLumaSource = s.luma
        var temporalChromaSource = s.chromaHalf
        if !prepared.isEmpty {
            var samples = [TemporalSampleUniforms](repeating: TemporalSampleUniforms(), count: Self.maximumNeighbours)
            for (slot, index) in prepared.enumerated() {
                samples[slot] = TemporalSampleUniforms(
                    offset: neighbourList[index].offset,
                    falloff: uniforms.window.y,
                    usesFlow: usesFlow)
            }
            var count = UInt32(prepared.count)
            // Luma and chroma are separate passes over separate planes, so a
            // chroma-only setting costs one pass rather than two and never
            // touches the luminance at all.
            if uniforms.temporal.x > 0 {
                encodeTemporal(
                    pipeline: self.temporalLuma, chroma: false, surfaces: s, prepared: prepared,
                    usesFlow: usesFlow, samples: &samples, count: &count,
                    uniforms: &uniforms, into: command)
                temporalLumaSource = s.temporalLuma
            }
            if uniforms.temporal.y > 0 {
                encodeTemporal(
                    pipeline: self.temporalChroma, chroma: true, surfaces: s, prepared: prepared,
                    usesFlow: usesFlow, samples: &samples, count: &count,
                    uniforms: &uniforms, into: command)
                temporalChromaSource = s.temporalChroma
            }
        }

        // 5. Spatial.
        var spatialLumaSource = temporalLumaSource
        var spatialChromaSource = temporalChromaSource
        if resolved.spatialIsActive {
            if uniforms.spatial.x > 0 {
                encodeGuidedFilter(source: temporalLumaSource, destination: s.spatialLuma,
                                   surfaces: s, uniforms: &uniforms, into: command)
                spatialLumaSource = s.spatialLuma
            }
            if uniforms.spatial.y > 0 {
                encodeChromaFilter(source: temporalChromaSource, surfaces: s,
                                   guide: s.guide, uniforms: &uniforms, into: command)
                spatialChromaSource = s.chromaScratchB
            }
        }

        // 6. Detail recovery, against the frame as it arrived.
        var finalLuma = spatialLumaSource
        if uniforms.detail.x > 0, spatialLumaSource !== s.luma {
            guard let encoder = command.makeComputeCommandEncoder() else { return nil }
            encoder.setComputePipelineState(detailRecovery)
            encoder.setTexture(s.luma, index: 0)
            encoder.setTexture(spatialLumaSource, index: 1)
            encoder.setTexture(s.field, index: 2)
            encoder.setTexture(s.recovered, index: 3)
            encoder.setBytes(&uniforms, length: MemoryLayout<NoiseReductionUniforms>.stride, index: 0)
            Self.dispatch(encoder, pipeline: detailRecovery, width: width, height: height)
            encoder.endEncoding()
            finalLuma = s.recovered
        }

        // 7. Back to the representation the grade reads.
        guard let encoder = command.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(reconstruct)
        encoder.setTexture(finalLuma, index: 0)
        encoder.setTexture(s.chromaFull, index: 1)
        encoder.setTexture(s.chromaHalf, index: 2)
        // Chroma is applied as a difference from where it started, so a run
        // that changed nothing about colour binds nothing here and the full
        // resolution chroma passes through untouched.
        encoder.setTexture(spatialChromaSource !== s.chromaHalf ? spatialChromaSource : nil, index: 3)
        encoder.setTexture(s.output, index: 4)
        // How much of the chroma the half-resolution path could not see should
        // survive. Nothing is removed when no colour cleaning was asked for.
        plane.geometry.x = max(uniforms.temporal.y, uniforms.spatial.y)
        encoder.setBytes(&plane, length: MemoryLayout<NoisePlaneUniforms>.stride, index: 0)
        Self.dispatch(encoder, pipeline: reconstruct, width: width, height: height)
        encoder.endEncoding()

        command.addCompletedHandler { _ in withExtendedLifetime(currentTextures) {} }
        return NoiseReductionResult(
            texture: s.output,
            temporalNeighbours: prepared.count,
            temporalRan: resolved.temporalIsActive && !prepared.isEmpty)
    }
}

// MARK: - Stages

private extension NoiseReductionStage {

    func prepare(
        pixelBuffer: CVPixelBuffer,
        textures: PixelBufferTextures,
        luma: MTLTexture,
        chroma: MTLTexture,
        colorMode: ProjectColorMode,
        hdr: HDRDisplayUniforms,
        plane: inout NoisePlaneUniforms,
        fallbackMatrix: String?,
        into command: MTLCommandBuffer
    ) -> Bool {
        var hdrUniforms = hdr
        var yuv = YUVUniforms.make(for: pixelBuffer, fallbackMatrix: fallbackMatrix)
        let pipeline: MTLComputePipelineState
        switch textures.storage {
        case .biPlanar:
            if colorMode.isAppleLog {
                guard let appleLog = prepareAppleLog else { return false }
                pipeline = appleLog
            } else {
                pipeline = prepareYUV
            }
        case .bgra: pipeline = prepareBGRA
        case .linearHalf: pipeline = prepareHDR
        }
        guard let encoder = command.makeComputeCommandEncoder() else { return false }
        encoder.setComputePipelineState(pipeline)
        switch textures.storage {
        case .biPlanar(_, let lumaPlane, _, let chromaPlane):
            encoder.setTexture(lumaPlane, index: 0)
            encoder.setTexture(chromaPlane, index: 1)
            if !colorMode.isAppleLog {
                encoder.setBytes(&yuv, length: MemoryLayout<YUVUniforms>.stride, index: 1)
            }
        case .bgra(_, let texture):
            encoder.setTexture(texture, index: 0)
        case .linearHalf(_, let texture):
            encoder.setTexture(texture, index: 0)
            encoder.setBytes(&hdrUniforms, length: MemoryLayout<HDRDisplayUniforms>.stride, index: 2)
        }
        encoder.setTexture(luma, index: 2)
        encoder.setTexture(chroma, index: 3)
        encoder.setBytes(&plane, length: MemoryLayout<NoisePlaneUniforms>.stride, index: 0)
        Self.dispatch(encoder, pipeline: pipeline, width: luma.width, height: luma.height)
        encoder.endEncoding()
        return true
    }

    func downsample(
        _ pipeline: MTLComputePipelineState,
        source: MTLTexture, destination: MTLTexture,
        into command: MTLCommandBuffer
    ) {
        guard let encoder = command.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        Self.dispatch(encoder, pipeline: pipeline, width: destination.width, height: destination.height)
        encoder.endEncoding()
    }

    /// The per-tile estimate, then the erosion that turns it into a floor.
    func encodeNoiseField(
        guide: MTLTexture, tiles: MTLTexture, field: MTLTexture,
        into command: MTLCommandBuffer
    ) {
        guard let tileEncoder = command.makeComputeCommandEncoder() else { return }
        tileEncoder.setComputePipelineState(noiseField)
        tileEncoder.setTexture(guide, index: 0)
        tileEncoder.setTexture(tiles, index: 1)
        Self.dispatch(tileEncoder, pipeline: noiseField, width: tiles.width, height: tiles.height)
        tileEncoder.endEncoding()

        guard let floorEncoder = command.makeComputeCommandEncoder() else { return }
        floorEncoder.setComputePipelineState(noiseFloor)
        floorEncoder.setTexture(tiles, index: 0)
        floorEncoder.setTexture(field, index: 1)
        Self.dispatch(floorEncoder, pipeline: noiseFloor, width: field.width, height: field.height)
        floorEncoder.endEncoding()
    }

    func encodeGuide(
        luma: MTLTexture, chroma: MTLTexture, guide: MTLTexture,
        uniforms: inout NoiseReductionUniforms,
        into command: MTLCommandBuffer
    ) {
        guard let encoder = command.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(buildGuide)
        encoder.setTexture(luma, index: 0)
        encoder.setTexture(chroma, index: 1)
        encoder.setTexture(guide, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<NoiseReductionUniforms>.stride, index: 0)
        Self.dispatch(encoder, pipeline: buildGuide, width: guide.width, height: guide.height)
        encoder.endEncoding()
    }

    func buildPyramid(source: MTLTexture, levels: [MTLTexture], into command: MTLCommandBuffer) {
        var input = source
        for level in levels {
            downsample(downsampleLuma, source: input, destination: level, into: command)
            input = level
        }
    }

    /// Coarse to fine: an exhaustive search at the top, then one-pixel
    /// refinements seeded from the level above, with a vector median between
    /// each pair so an outlier cannot be carried down and refined into a
    /// confident mistake.
    func encodeFlow(
        from source: [MTLTexture], to target: [MTLTexture],
        destination: MTLTexture, surfaces s: Surfaces,
        into command: MTLCommandBuffer
    ) {
        let base = s.flowBase
        var seed: MTLTexture?
        for step in stride(from: Self.flowLevels - 1, through: 0, by: -1) {
            let level = base + step
            let scratchIndex = step
            let isCoarsest = step == Self.flowLevels - 1
            let isFinest = step == 0
            var params = SIMD4<Float>(
                isCoarsest ? 4 : 1,          // search radius, in this level's pixels
                isCoarsest ? 1 : 2,          // how far the seed has to be scaled up
                // Bias toward the seed, per pixel of travel. It decides what
                // happens where the picture gives the search nothing to hold
                // on to — a clear sky, a wall, a shadow — and there the right
                // answer is "it did not move", not whichever displacement the
                // grain happened to favour.
                0.0025,
                0)
            guard let searchEncoder = command.makeComputeCommandEncoder() else { return }
            searchEncoder.setComputePipelineState(flowSearch)
            searchEncoder.setTexture(source[level], index: 0)
            searchEncoder.setTexture(target[level], index: 1)
            searchEncoder.setTexture(seed, index: 2)
            searchEncoder.setTexture(s.flowScratchA[scratchIndex], index: 3)
            searchEncoder.setBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            Self.dispatch(searchEncoder, pipeline: flowSearch,
                          width: s.flowScratchA[scratchIndex].width,
                          height: s.flowScratchA[scratchIndex].height)
            searchEncoder.endEncoding()

            let smoothed = isFinest ? destination : s.flowScratchB[scratchIndex]
            guard let smoothEncoder = command.makeComputeCommandEncoder() else { return }
            smoothEncoder.setComputePipelineState(flowSmooth)
            smoothEncoder.setTexture(s.flowScratchA[scratchIndex], index: 0)
            smoothEncoder.setTexture(smoothed, index: 1)
            Self.dispatch(smoothEncoder, pipeline: flowSmooth,
                          width: smoothed.width, height: smoothed.height)
            smoothEncoder.endEncoding()
            seed = smoothed
        }
    }

    func encodeTemporal(
        pipeline: MTLComputePipelineState,
        chroma: Bool,
        surfaces s: Surfaces,
        prepared: [Int],
        usesFlow: Bool,
        samples: inout [TemporalSampleUniforms],
        count: inout UInt32,
        uniforms: inout NoiseReductionUniforms,
        into command: MTLCommandBuffer
    ) {
        guard let encoder = command.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(chroma ? s.chromaHalf : s.luma, index: 0)
        encoder.setTexture(s.guide, index: 1)
        encoder.setTexture(s.field, index: 2)
        for slot in 0..<Self.maximumNeighbours {
            let index = slot < prepared.count ? prepared[slot] : nil
            encoder.setTexture(index.map { chroma ? s.neighbourChroma[$0] : s.neighbourLuma[$0] },
                               index: 3 + slot)
            encoder.setTexture(index.map { s.neighbourGuide[$0] }, index: 7 + slot)
            encoder.setTexture(usesFlow ? index.map { s.flowForward[$0] } : nil, index: 11 + slot)
            encoder.setTexture(usesFlow ? index.map { s.flowBackward[$0] } : nil, index: 15 + slot)
        }
        let destination = chroma ? s.temporalChroma : s.temporalLuma
        encoder.setTexture(destination, index: 19)
        encoder.setBytes(&uniforms, length: MemoryLayout<NoiseReductionUniforms>.stride, index: 0)
        encoder.setBytes(&samples,
                         length: MemoryLayout<TemporalSampleUniforms>.stride * Self.maximumNeighbours,
                         index: 1)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 2)
        Self.dispatch(encoder, pipeline: pipeline,
                      width: destination.width, height: destination.height)
        encoder.endEncoding()
    }

    /// The fast guided filter: statistics at a quarter of each edge, applied at
    /// full resolution.
    func encodeGuidedFilter(
        source: MTLTexture, destination: MTLTexture,
        surfaces s: Surfaces,
        uniforms: inout NoiseReductionUniforms,
        into command: MTLCommandBuffer
    ) {
        let statsWidth = s.guidedA.width, statsHeight = s.guidedA.height
        // The radius follows the picture down to the grid the statistics are
        // gathered on, and never falls below one: a box of a single texel is
        // the identity, which would make low radii do nothing at all.
        let radius = max(1, Int((uniforms.spatial.z / 4).rounded()))

        guard let seedEncoder = command.makeComputeCommandEncoder() else { return }
        seedEncoder.setComputePipelineState(guidedSeed)
        seedEncoder.setTexture(source, index: 0)
        seedEncoder.setTexture(s.guidedA, index: 1)
        Self.dispatch(seedEncoder, pipeline: guidedSeed, width: statsWidth, height: statsHeight)
        seedEncoder.endEncoding()

        box(s.guidedA, into: s.guidedB, radius: radius, horizontal: true, command: command)
        box(s.guidedB, into: s.guidedA, radius: radius, horizontal: false, command: command)

        guard let coefficientEncoder = command.makeComputeCommandEncoder() else { return }
        coefficientEncoder.setComputePipelineState(guidedCoefficients)
        coefficientEncoder.setTexture(s.guidedA, index: 0)
        coefficientEncoder.setTexture(s.field, index: 1)
        coefficientEncoder.setTexture(s.guidedB, index: 2)
        coefficientEncoder.setBytes(&uniforms, length: MemoryLayout<NoiseReductionUniforms>.stride, index: 0)
        Self.dispatch(coefficientEncoder, pipeline: guidedCoefficients,
                      width: statsWidth, height: statsHeight)
        coefficientEncoder.endEncoding()

        box(s.guidedB, into: s.guidedA, radius: radius, horizontal: true, command: command)
        box(s.guidedA, into: s.guidedB, radius: radius, horizontal: false, command: command)

        guard let applyEncoder = command.makeComputeCommandEncoder() else { return }
        applyEncoder.setComputePipelineState(guidedApply)
        applyEncoder.setTexture(source, index: 0)
        applyEncoder.setTexture(s.guidedB, index: 1)
        applyEncoder.setTexture(s.guide, index: 2)
        applyEncoder.setTexture(s.field, index: 3)
        applyEncoder.setTexture(destination, index: 4)
        applyEncoder.setBytes(&uniforms, length: MemoryLayout<NoiseReductionUniforms>.stride, index: 0)
        Self.dispatch(applyEncoder, pipeline: guidedApply,
                      width: destination.width, height: destination.height)
        applyEncoder.endEncoding()
    }

    func box(
        _ source: MTLTexture, into destination: MTLTexture,
        radius: Int, horizontal: Bool, command: MTLCommandBuffer
    ) {
        var params = SIMD4<Float>(Float(radius), horizontal ? 1 : 0, horizontal ? 0 : 1, 0)
        guard let encoder = command.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(boxBlur)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        Self.dispatch(encoder, pipeline: boxBlur, width: destination.width, height: destination.height)
        encoder.endEncoding()
    }

    /// Two separable cross-bilateral passes over the chroma plane. The result
    /// lands in `chromaScratchB`; only the second pass blends toward it, so a
    /// half-filtered intermediate never reaches the picture.
    func encodeChromaFilter(
        source: MTLTexture, surfaces s: Surfaces, guide: MTLTexture,
        uniforms: inout NoiseReductionUniforms,
        into command: MTLCommandBuffer
    ) {
        let radius = max(1, min(Int(uniforms.detail.w.rounded()), 16))
        func pass(_ input: MTLTexture, _ output: MTLTexture, horizontal: Bool, blends: Bool) {
            var params = SIMD4<Float>(Float(radius), horizontal ? 1 : 0, horizontal ? 0 : 1,
                                      blends ? 1 : 0)
            guard let encoder = command.makeComputeCommandEncoder() else { return }
            encoder.setComputePipelineState(chromaFilter)
            encoder.setTexture(input, index: 0)
            encoder.setTexture(guide, index: 1)
            encoder.setTexture(s.field, index: 2)
            encoder.setTexture(output, index: 3)
            encoder.setTexture(blends ? source : nil, index: 4)
            encoder.setBytes(&uniforms, length: MemoryLayout<NoiseReductionUniforms>.stride, index: 0)
            encoder.setBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            Self.dispatch(encoder, pipeline: chromaFilter,
                          width: output.width, height: output.height)
            encoder.endEncoding()
        }
        pass(source, s.chromaScratchA, horizontal: true, blends: false)
        // The second pass blends the finished two-dimensional filter against
        // the plane this stage was handed, so the Chroma strength is applied
        // once to the whole filter rather than once per direction.
        pass(s.chromaScratchA, s.chromaScratchB, horizontal: false, blends: true)
    }

    static func dispatch(
        _ encoder: MTLComputeCommandEncoder,
        pipeline: MTLComputePipelineState,
        width: Int, height: Int
    ) {
        let threadWidth = max(1, min(pipeline.threadExecutionWidth, width))
        let threadHeight = max(1, min(pipeline.maxTotalThreadsPerThreadgroup / threadWidth, height))
        encoder.dispatchThreads(
            MTLSize(width: max(width, 1), height: max(height, 1), depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1))
    }
}

// MARK: - Measuring

extension NoiseReductionStage {

    /// Measures one frame's noise, for the Auto button.
    ///
    /// Synchronous and slow by the standards of this file — it commits its own
    /// command buffer and waits — so it belongs on a background queue and never
    /// on the render thread. It allocates its own surfaces rather than
    /// borrowing the render set, both because they need shared storage to be
    /// read back and because borrowing would mean measuring on textures a draw
    /// might be part way through.
    ///
    /// Measurement runs at the frame's NATIVE resolution. That is the whole
    /// point: noise lives at the pixel level, and the first thing any
    /// downscale does is average it away, so a measurement taken on a reduced
    /// copy would report a clean picture of a noisy one.
    func measure(
        pixelBuffer: CVPixelBuffer,
        colorMode: ProjectColorMode,
        hdr: HDRDisplayUniforms = HDRDisplayUniforms(),
        fallbackMatrix: String? = "BT.709"
    ) -> NoiseProfile? {
        guard let textures = PixelBufferTextures(pixelBuffer: pixelBuffer, context: context) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 16, height > 16 else { return nil }
        let halfWidth = max(1, width / 2), halfHeight = max(1, height / 2)
        let fieldWidth = max(1, (halfWidth + 7) / 8), fieldHeight = max(1, (halfHeight + 7) / 8)

        func make(_ format: MTLPixelFormat, _ w: Int, _ h: Int, shared: Bool = false) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: w, height: h, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = shared ? .shared : .private
            return context.device.makeTexture(descriptor: descriptor)
        }
        guard let luma = make(.r16Float, width, height),
              let chromaFull = make(.rg16Float, width, height),
              let chromaHalf = make(.rg16Float, halfWidth, halfHeight),
              let guide = make(.rgba16Float, halfWidth, halfHeight),
              // Float32 for the readback: half-float has about three decimal
              // digits, and a noise floor of 0.002 would be quantised into
              // uselessness by it.
              let tiles = make(.rgba32Float, fieldWidth, fieldHeight),
              let field = make(.rgba32Float, fieldWidth, fieldHeight, shared: true),
              let command = context.commandQueue.makeCommandBuffer() else { return nil }
        command.label = "GradeLab Noise Measurement"

        var plane = NoisePlaneUniforms(colorMode: colorMode)
        var uniforms = NoiseReductionUniforms(
            settings: .neutral, lumaWeights: SIMD3(plane.luma.x, plane.luma.y, plane.luma.z),
            extendedRange: plane.luma.w > 0.5,
            size: (width, height), chromaSize: (halfWidth, halfHeight))

        guard prepare(pixelBuffer: pixelBuffer, textures: textures, luma: luma, chroma: chromaFull,
                      colorMode: colorMode, hdr: hdr, plane: &plane,
                      fallbackMatrix: fallbackMatrix, into: command) else { return nil }
        downsample(downsampleChroma, source: chromaFull, destination: chromaHalf, into: command)
        encodeGuide(luma: luma, chroma: chromaHalf, guide: guide, uniforms: &uniforms, into: command)
        encodeNoiseField(guide: guide, tiles: tiles, field: field, into: command)
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { return nil }

        let count = fieldWidth * fieldHeight
        var readback = [SIMD4<Float>](repeating: .zero, count: count)
        readback.withUnsafeMutableBytes { raw in
            field.getBytes(raw.baseAddress!,
                           bytesPerRow: fieldWidth * MemoryLayout<SIMD4<Float>>.size,
                           from: MTLRegionMake2D(0, 0, fieldWidth, fieldHeight),
                           mipmapLevel: 0)
        }
        withExtendedLifetime(textures) {}
        return Self.profile(from: readback)
    }

    /// Turns a field of per-tile floors into one number per channel.
    ///
    /// A low percentile rather than a mean, for the same reason the tile
    /// estimate itself takes a minimum: most of a frame is texture, and the
    /// tiles that are nothing but noise are the only ones telling the truth
    /// about the sensor. The twentieth percentile is low enough to sit among
    /// those and high enough not to be decided by a single crushed-black tile.
    static func profile(from tiles: [SIMD4<Float>]) -> NoiseProfile? {
        guard !tiles.isEmpty else { return nil }
        func percentile(_ values: [Float], _ fraction: Float) -> Float {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            let index = min(sorted.count - 1, max(0, Int(Float(sorted.count - 1) * fraction)))
            return sorted[index]
        }
        let usable = tiles.filter { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
        guard !usable.isEmpty else { return nil }

        let luma = percentile(usable.map(\.x), 0.2)
        let chroma = percentile(usable.map(\.y), 0.2)
        // The darkest quarter of the frame, which is where a Log grade is about
        // to go looking and where the noise it finds will be worst.
        let brightnessThreshold = percentile(usable.map(\.z), 0.25)
        let shadows = usable.filter { $0.z <= brightnessThreshold }
        let shadowLuma = shadows.isEmpty ? luma : percentile(shadows.map(\.x), 0.3)
        return NoiseProfile(
            luma: luma, chroma: chroma, shadowLuma: shadowLuma,
            shadowCoverage: Float(shadows.count) / Float(usable.count))
    }
}
