@preconcurrency import Metal
import Combine
import CoreImage
import Foundation
import SwiftUI
import os

/// Builds the compositing pipelines at launch, and reports when they are ready.
///
/// Compiling them takes real time — measured at 65 seconds on an A16 for the
/// eighteen kernels, because each inlines the whole grading chain. The system
/// caches the result on disk, so it is paid once per install and returns after
/// a reinstall. It cannot be made free; it can only be moved off the moment
/// someone is waiting for a frame, and made visible when it is not finished.
///
/// This starts the one shared build in `CompositorResources`. It deliberately
/// does **not** compile anything itself: an earlier version built throwaway
/// pipeline states while the compositor built its own, so a cold device compiled
/// everything twice, concurrently, on the same cores — which is why warming at
/// launch made no difference to the stall.
@MainActor
final class CompositorWarmup: ObservableObject {
    static let shared = CompositorWarmup()
    nonisolated static let log = Logger(subsystem: "com.aftab.gradelab", category: "warmup")

    /// The kernels the layer path needs. Kept here because
    /// `CompositorWarmupTests` checks them against the shader library: a kernel
    /// renamed without updating the list would go quietly uncompiled, and the
    /// symptom is a stall on one device on one install.
    nonisolated static var pipelineNames: [String] { CompositorResources.allNames }

    /// False until the shared bundle exists. The editor reads this to keep the
    /// layer tools out of reach rather than letting someone tap Transform and
    /// meet a frozen picture with nothing on screen explaining it.
    @Published private(set) var isReady = false

    private var didStart = false

    private init() {}

    func start() {
        guard !didStart else { return }
        didStart = true
        if CompositorResources.isReady { isReady = true; return }
        Task.detached(priority: .userInitiated) {
            let began = Date()
            _ = try? CompositorResources.shared(supplied: nil,
                                                colorSpace: CompositorWarmup.workingColorSpace)
            Self.log.notice(
                "warm-up finished: \(Date().timeIntervalSince(began), format: .fixed(precision: 2))s")
        }
    }

    /// Called by `CompositorResources` once the build lands, from whichever
    /// thread finished it.
    nonisolated func markReady() {
        Task { @MainActor in self.isReady = true }
    }

    /// The working space the compositor's `CIContext` uses. The same value
    /// `LayerCompositor` holds — building against a different one would make a
    /// second, unshared context.
    nonisolated static let workingColorSpace = CGColorSpace(name: CGColorSpace.itur_709)!

    /// Synchronous build, for tests.
    nonisolated static func run() {
        _ = try? CompositorResources.shared(supplied: nil, colorSpace: workingColorSpace)
    }
}
