import Metal
import XCTest
@testable import GradeLab

/// The warm-up only helps if it names the functions the compositor really
/// builds. A renamed or removed kernel would leave it silently warming nothing,
/// and the symptom — one long stall, on one device, on one install, never again
/// after a relaunch — is close to unreportable.
final class CompositorWarmupTests: XCTestCase {

    func testEveryWarmedFunctionExistsAndBuilds() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try XCTUnwrap(device.makeDefaultLibrary())
        for name in CompositorWarmup.pipelineNames {
            let function = try XCTUnwrap(library.makeFunction(name: name),
                                         "\(name) is warmed but no longer exists in the shader library.")
            XCTAssertNoThrow(try device.makeComputePipelineState(function: function),
                             "\(name) could not be built.")
        }
    }

    /// The list is the point, so an empty or accidentally-trimmed one should
    /// fail rather than pass by warming nothing. The three groups are
    /// `LayerCompositor.prepare`, `FilmEffectsStage` and `AppleLogLayerRenderer`.
    func testTheWarmedSetCoversAllThreeCompositingGroups() {
        let names = Set(CompositorWarmup.pipelineNames)
        for name in ["gradeExportBGRA", "applyLayerMaskBGRA", "transitionBGRA"] {
            XCTAssertTrue(names.contains(name), "LayerCompositor builds \(name) on its first frame.")
        }
        for name in ["compositeVideoHDR", "resolveHDRCanvas", "compositeTransitionHDR"] {
            XCTAssertTrue(names.contains(name), "The HDR layer path builds \(name) on its first frame.")
        }
        for name in ["compositeVideoAppleLog", "resolveAppleLogCanvas", "resolveAppleLogCanvas422"] {
            XCTAssertTrue(names.contains(name), "AppleLogLayerRenderer builds \(name) on its first frame.")
        }
        XCTAssertEqual(names.count, CompositorWarmup.pipelineNames.count, "The list has a duplicate.")
    }

    /// The finishing-effects stage is part of the shared bundle rather than of
    /// the name list, because it builds its own three pipelines. It still has to
    /// be built once with everything else, not per compositor.
    func testTheBundleCarriesTheFinishingEffectsStage() throws {
        let bundle = try CompositorResources.shared(supplied: nil, colorSpace: CompositorWarmup.workingColorSpace)
        XCTAssertNotNil(bundle.effects)
    }

    /// Calling it twice must not run it twice — it is started from app launch and
    /// is cheap to call from anywhere, which is only true if it is idempotent.
    @MainActor
    func testStartingTwiceIsHarmless() {
        CompositorWarmup.shared.start()
        CompositorWarmup.shared.start()
    }

    /// The whole point of the shared bundle: asking twice must hand back the
    /// same objects, not compile a second set. A new compositor is built on
    /// every transform tick, so a bundle that rebuilt per call would put minutes
    /// of shader compilation on a slider.
    func testTheBundleIsBuiltOnceAndShared() throws {
        let first = try CompositorResources.shared(supplied: nil, colorSpace: CompositorWarmup.workingColorSpace)
        let second = try CompositorResources.shared(supplied: nil, colorSpace: CompositorWarmup.workingColorSpace)
        XCTAssertTrue(first.context === second.context)
        XCTAssertTrue(first.ci === second.ci)
        for name in CompositorResources.requiredNames {
            XCTAssertTrue(first.pipeline(name) === second.pipeline(name), "\(name) was compiled twice.")
        }
        XCTAssertTrue(CompositorResources.isReady)
    }

    /// Multi-clip playback bypasses `MetalVideoRenderer` and grades inside the
    /// shared layer compositor. A look prepared only on the direct renderer's
    /// context silently becomes the identity LUT there.
    func testLookPreparationReachesSharedCompositorContext() async throws {
        let identifier = try XCTUnwrap(LUTAsset.bundledCreativeLooks.first?.id)
        let prepared = await CompositorResources.prepareLooks([identifier])
        XCTAssertTrue(prepared)
        let bundle = try CompositorResources.shared(
            supplied: nil,
            colorSpace: CompositorWarmup.workingColorSpace
        )
        XCTAssertTrue(bundle.context.luts.isReady(identifier))
    }

    /// Running the body directly must succeed on a device with Metal, and must
    /// not throw or trap when called repeatedly.
    func testTheWarmUpBodyCompletes() {
        CompositorWarmup.run()
        CompositorWarmup.run()
    }
}
