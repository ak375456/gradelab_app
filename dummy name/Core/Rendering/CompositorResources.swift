@preconcurrency import Metal
import CoreImage
import Foundation
import os

/// AVFoundation can make a new compositor whenever a preview composition is
/// reassigned. Share its device resources, and compile each shader only when
/// a project needs it. An SDR edit should never wait for HDR or Apple Log.
enum CompositorResources {
    static let log = Logger(subsystem: "com.aftab.gradelab", category: "warmup")
    private static let defaultBundle = Result { Bundle(context: try MetalContext()) }

    /// Host validators can supply a different shader library. Keep those
    /// resources scoped to their sequence while sharing the shipping library
    /// across preview and export.
    static func shared(supplied: MetalContext? = nil) throws -> Bundle {
        if let supplied, supplied.usesCustomLibrary { return Bundle(context: supplied) }
        return try defaultBundle.get()
    }

    final class Bundle: @unchecked Sendable {
        let context: MetalContext
        let ci: CIContext
        private let condition = NSCondition()
        private var pipelines: [String: MTLComputePipelineState] = [:]
        private var building: Set<String> = []
        private var failed: Set<String> = []
        private let effectsLock = NSLock()
        private lazy var finishingEffects = FilmEffectsStage(context: context)

        init(context: MetalContext) {
            self.context = context
            ci = CIContext(mtlDevice: context.device, options: [
                .workingColorSpace: CGColorSpace(name: CGColorSpace.itur_709)!,
                .cacheIntermediates: false
            ])
        }

        var effects: FilmEffectsStage? {
            effectsLock.lock(); defer { effectsLock.unlock() }
            return finishingEffects
        }

        func pipeline(_ name: String, isLog2: Bool = false) -> MTLComputePipelineState? {
            let key = pipelineKey(name, isLog2: isLog2)
            condition.lock()
            while building.contains(key) { condition.wait() }
            if let state = pipelines[key] { condition.unlock(); return state }
            if failed.contains(key) { condition.unlock(); return nil }
            building.insert(key)
            condition.unlock()

            let began = Date()
            let state = AppleLogSpecialization.computePipeline(
                name, isLog2: isLog2, library: context.library, device: context.device)
            condition.lock()
            if let state { pipelines[key] = state }
            else { failed.insert(key) }
            building.remove(key)
            condition.broadcast()
            condition.unlock()
            let elapsed = Date().timeIntervalSince(began)
            if elapsed > 0.1 || state == nil {
                CompositorResources.log.notice("\(key, privacy: .public): \(elapsed, format: .fixed(precision: 2))s, success: \(state != nil)")
            }
            return state
        }

        /// Prepare the active color path off the main actor before handing the
        /// composition to AVFoundation. Effects that may be enabled later
        /// still resolve their own kernels through the same cache.
        func prepare(_ plan: PipelinePlan) async throws {
            for name in plan.names {
                try Task.checkCancellation()
                guard pipeline(name, isLog2: plan.isLog2) != nil else {
                    throw GradeLabError.rendererInitializationFailed
                }
            }
        }

        func appleLogPipelines(isLog2: Bool) throws -> [String: MTLComputePipelineState] {
            try Dictionary(uniqueKeysWithValues: AppleLogLayerRenderer.functionNames.map { name in
                guard let pipeline = pipeline(name, isLog2: isLog2) else {
                    throw GradeLabError.rendererInitializationFailed
                }
                return (pipelineKey(name, isLog2: isLog2), pipeline)
            })
        }

        private func pipelineKey(_ name: String, isLog2: Bool) -> String {
            AppleLogSpecialization.key(
                name, isLog2: isLog2 && AppleLogSpecialization.specializedFunctions.contains(name))
        }
    }

    struct PipelinePlan {
        let names: [String]
        let isLog2: Bool

        init(mode: ProjectColorMode, hasVideo: Bool, hasStills: Bool, hasTransitions: Bool,
             hasDrawnLayers: Bool = false) {
            isLog2 = mode == .appleLog2
            var needed: [String] = []
            switch mode {
            case .sdr, .sdrWide:
                if hasVideo { needed.append("gradeExportBGRA") }
                if hasStills { needed.append("gradeStillBGRA") }
                if hasTransitions { needed.append("transitionBGRA") }
            case .hdrHLG:
                needed = ["compositeVideoHDR", "resolveHDRCanvas"]
                if hasStills || hasDrawnLayers { needed.append("compositeImageHDR") }
                if hasTransitions { needed.append("compositeTransitionHDR") }
            case .appleLog, .appleLog2:
                needed = AppleLogLayerRenderer.functionNames
            }
            names = needed
        }
    }

    /// A creative look needs to be loaded into the context that grades layers.
    /// Parsing stays off both the main actor and AVFoundation's render queue.
    @discardableResult
    static func prepareLooks(_ identifiers: Set<String>, resources supplied: Bundle? = nil) async -> Bool {
        guard !identifiers.isEmpty else { return true }
        return await Task.detached(priority: .userInitiated) {
            guard let resources = supplied ?? (try? shared()) else { return false }
            var preparedEveryLook = true
            for identifier in identifiers {
                if !resources.context.luts.prepare(identifier) { preparedEveryLook = false }
            }
            return preparedEveryLook
        }.value
    }
}
