@preconcurrency import Metal
import CoreImage
import Foundation
import os

/// GPU resources shared by every layer compositor, built exactly once per
/// process.
///
/// Two separate costs used to land on the user, and both are handled here.
///
/// **A new compositor per slider tick.** AVFoundation constructs a new
/// compositor object every time `AVPlayerItem.videoComposition` is assigned, and
/// the preview reassigns it on every transform change to force a fresh frame.
/// Each instance used to build its own Metal library, pipelines, `CIContext` and
/// `FilmEffectsStage`. None of that depends on the clip, the canvas or the
/// frame — only on the device — so it is shared. Anything genuinely per-render
/// (buffer pools, working canvases, still frames) stays on the compositor.
///
/// **Pipeline compilation is enormous.** Measured on an A16: 65 seconds for the
/// eighteen kernels, because each one inlines the whole grading chain — look,
/// LUT, curves, HSL, wheels, up to eight masked local grades. That is compiled
/// by the driver at `makeComputePipelineState` and cached on disk by the system,
/// which is why it is paid once per install and returns after a reinstall.
///
/// So it is built once, concurrently, and everybody waits on the same build
/// rather than starting a competing one. An earlier version had the launch
/// warm-up build throwaway states while this built its own, so the device
/// compiled everything twice at the same time on the same cores.
enum CompositorResources {
    struct Bundle {
        let context: MetalContext
        let pipelines: [String: MTLComputePipelineState]
        let ci: CIContext
        let effects: FilmEffectsStage?

        func pipeline(_ name: String) -> MTLComputePipelineState? { pipelines[name] }
    }

    /// Without these the compositor cannot draw at all, so a device that fails
    /// to build one gets an error rather than a silently degraded picture.
    /// Listed first because they are what an ordinary SDR clip needs, and the
    /// build reports itself ready for those before the rest finish.
    static let requiredNames = [
        "gradeExportBGRA", "gradeStillBGRA", "gradeBlendedBGRA",
        "applyLayerMaskBGRA", "transitionBGRA"
    ]

    /// Needed only by the HDR and Apple Log paths. A device without them refuses
    /// that colour mode with a reason, exactly as it did before.
    static let optionalNames = [
        "compositeVideoHDR", "compositeImageHDR", "resolveHDRCanvas", "compositeTransitionHDR",
        "compositeVideoAppleLog", "compositeImageAppleLog", "blendAppleLogLayer",
        "compositeTransitionAppleLog", "resolveAppleLogCanvas", "resolveAppleLogCanvas422"
    ]

    static var allNames: [String] { requiredNames + optionalNames }

    /// One build, one waiter list. `NSCondition` rather than a plain lock so a
    /// second caller arriving mid-build waits for the first build instead of
    /// starting its own — which is the duplicate-compilation bug in one line.
    private static let condition = NSCondition()
    private static var built: Bundle?
    private static var isBuilding = false

    static var isReady: Bool {
        condition.lock(); defer { condition.unlock() }
        return built != nil
    }

    /// Loads the creative looks a composited timeline will reference into the
    /// SAME Metal context its compositor uses.
    ///
    /// The ordinary preview renderer owns a different `MetalContext`. Preparing
    /// a look there is not enough once a second clip, transform or layer moves
    /// playback onto `LayerCompositor`: its cache would keep returning the
    /// identity texture and the selected LUT would appear to do nothing.
    /// Parsing stays off both the main actor and AVFoundation's render queue.
    @discardableResult
    static func prepareLooks(
        _ identifiers: Set<String>,
        context supplied: MetalContext? = nil
    ) async -> Bool {
        guard !identifiers.isEmpty else { return true }
        return await Task.detached(priority: .userInitiated) {
            let context: MetalContext
            if let supplied {
                context = supplied
            } else {
                guard let bundle = try? shared(
                    supplied: nil,
                    colorSpace: CompositorWarmup.workingColorSpace
                ) else { return false }
                context = bundle.context
            }
            var preparedEveryLook = true
            for identifier in identifiers {
                if !context.luts.prepare(identifier) { preparedEveryLook = false }
            }
            return preparedEveryLook
        }.value
    }

    /// - Parameter supplied: a context the caller already owns — export and the
    ///   validator pass theirs. A supplied context is built fresh and never
    ///   cached, so a test with its own shader library cannot poison the
    ///   process-wide bundle.
    static func shared(supplied: MetalContext?, colorSpace: CGColorSpace) throws -> Bundle {
        if let supplied { return try make(context: supplied, colorSpace: colorSpace) }
        condition.lock()
        while isBuilding { condition.wait() }
        if let built {
            condition.unlock()
            return built
        }
        isBuilding = true
        condition.unlock()

        let began = Date()
        do {
            let bundle = try make(context: MetalContext(), colorSpace: colorSpace)
            condition.lock()
            built = bundle
            isBuilding = false
            condition.broadcast()
            condition.unlock()
            CompositorWarmup.log.notice(
                "compositor resources built: \(Date().timeIntervalSince(began), format: .fixed(precision: 2))s")
            CompositorWarmup.shared.markReady()
            return bundle
        } catch {
            condition.lock()
            isBuilding = false
            condition.broadcast()
            condition.unlock()
            throw error
        }
    }

    private static func make(context: MetalContext, colorSpace: CGColorSpace) throws -> Bundle {
        let names = allNames
        var states: [String: MTLComputePipelineState] = [:]
        let resultLock = NSLock()
        // Compiled in parallel. These are independent compiles and the device is
        // documented as thread-safe for pipeline creation, so doing them one at a
        // time left most of the CPU idle through the longest wait in the app.
        DispatchQueue.concurrentPerform(iterations: names.count) { index in
            let name = names[index]
            guard let function = context.library.makeFunction(name: name),
                  let state = try? context.device.makeComputePipelineState(function: function) else { return }
            resultLock.lock()
            states[name] = state
            resultLock.unlock()
        }
        for name in requiredNames where states[name] == nil {
            throw GradeLabError.rendererInitializationFailed
        }
        return Bundle(
            context: context,
            pipelines: states,
            ci: CIContext(mtlDevice: context.device,
                          options: [.workingColorSpace: colorSpace, .cacheIntermediates: false]),
            effects: FilmEffectsStage(context: context))
    }
}
