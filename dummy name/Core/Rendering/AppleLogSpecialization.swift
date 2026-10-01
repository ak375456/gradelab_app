@preconcurrency import Metal
import Foundation

// ---------------------------------------------------------------------------
// One shader, two input transforms
//
// Apple Log and Apple Log 2 share every shader in the app. They differ by one
// 3x3 matrix at the input transform, which `Shaders.metal` selects with the
// `kAppleLog2Requested` function constant.
//
// That makes the specialisation a build-time concern rather than a per-frame
// one, and it is centralised here so the renderer, the layer compositor and the
// exporter cannot drift into building it three slightly different ways — which
// would show up as a preview and an export disagreeing about a clip's colour.
// ---------------------------------------------------------------------------

enum AppleLogSpecialization {
    /// Must match `[[function_constant(0)]]` in Shaders.metal.
    private static let log2ConstantIndex = 0

    /// Constant values selecting the input transform.
    static func constants(isLog2: Bool) -> MTLFunctionConstantValues {
        let values = MTLFunctionConstantValues()
        var flag = isLog2
        values.setConstantValue(&flag, type: .bool, index: log2ConstantIndex)
        return values
    }

    /// The cache key a specialised pipeline is stored under.
    ///
    /// The *Metal function* is the same for both; only the key differs, so the
    /// existing name-keyed pipeline caches keep working unchanged and call sites
    /// keep selecting by name.
    static func key(_ function: String, isLog2: Bool) -> String {
        isLog2 ? function + "2" : function
    }

    /// Every shader whose source reaches `appleLogToWorking`, and therefore
    /// references the function constant.
    ///
    /// Deliberately short. Everything else in the Apple Log path — the display
    /// rendering, the canvas resolve, the layer blend, the transitions — runs on
    /// data that is already in the shared working space, where the two formats
    /// are the same signal and a second variant would be identical code.
    ///
    /// Metal treats a function that references a function constant as needing
    /// specialisation *always*: building a pipeline from one fetched by plain
    /// name fails at pipeline creation with "cannot be used to build a pipeline
    /// state", and that is true of the Apple Log variant as much as the Log 2
    /// one. So this list is what decides which path a function takes below, and
    /// every creation site goes through here rather than calling
    /// `makeFunction(name:)` directly.
    static let specializedFunctions: Set<String> = [
        "previewFragmentAppleLog",
        "gradeToTextureAppleLog",
        "compositeVideoAppleLog",
        "gradeExportAppleLogSDR10",
        "shotMatchSampleAppleLog",
        "nrPrepareAppleLog",
        "relightPrepareAppleLog",
        "relightAnalysisPrepareAppleLog"
    ]

    /// Builds a compute pipeline for `function`, specialised when `isLog2`.
    ///
    /// Function constants are resolved at `makeFunction` time, so a device that
    /// cannot build the variant returns nil here rather than silently falling
    /// back to the Apple Log transform — which would decode Log 2 through the
    /// wrong primaries and look almost right.
    static func computePipeline(
        _ function: String,
        isLog2: Bool,
        library: MTLLibrary,
        device: MTLDevice
    ) -> MTLComputePipelineState? {
        guard let fn = makeFunction(function, isLog2: isLog2, library: library) else { return nil }
        return try? device.makeComputePipelineState(function: fn)
    }

    /// Fetches `function`, specialised when it is one that needs it.
    ///
    /// A function outside `specializedFunctions` takes the plain path, so the
    /// shaders that never look at the constant are fetched exactly as they
    /// always were.
    static func makeFunction(
        _ function: String,
        isLog2: Bool,
        library: MTLLibrary
    ) -> MTLFunction? {
        guard specializedFunctions.contains(function) else {
            return library.makeFunction(name: function)
        }
        return try? library.makeFunction(name: function, constantValues: constants(isLog2: isLog2))
    }
}
