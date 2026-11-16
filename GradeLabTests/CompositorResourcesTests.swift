@preconcurrency import Metal
import XCTest
@testable import GradeLab

final class CompositorResourcesTests: XCTestCase {
    func testPlainSDRVideoOnlyPreparesOneGradingKernelForLayers() {
        let plan = CompositorResources.PipelinePlan(
            mode: .sdr, hasVideo: true, hasStills: false, hasTransitions: false)
        XCTAssertEqual(plan.names, ["gradeExportBGRA"])
        XCTAssertFalse(plan.isLog2)

        let effects = CompositorResources.PipelinePlan(
            mode: .sdrWide, hasVideo: true, hasStills: true, hasTransitions: true)
        XCTAssertEqual(effects.names, ["gradeExportBGRA", "gradeStillBGRA", "transitionBGRA"])
    }

    func testHDRAndAppleLogOnlyPrepareTheirOwnColorPath() {
        let hdr = CompositorResources.PipelinePlan(
            mode: .hdrHLG, hasVideo: true, hasStills: false, hasTransitions: true)
        XCTAssertEqual(hdr.names, ["compositeVideoHDR", "resolveHDRCanvas", "compositeTransitionHDR"])
        XCTAssertFalse(hdr.isLog2)
        let hdrTitle = CompositorResources.PipelinePlan(
            mode: .hdrHLG, hasVideo: true, hasStills: false, hasTransitions: false, hasDrawnLayers: true)
        XCTAssertTrue(hdrTitle.names.contains("compositeImageHDR"))

        let log = CompositorResources.PipelinePlan(
            mode: .appleLog, hasVideo: true, hasStills: true, hasTransitions: false)
        let log2 = CompositorResources.PipelinePlan(
            mode: .appleLog2, hasVideo: true, hasStills: true, hasTransitions: false)
        XCTAssertTrue(log.names.contains("compositeVideoAppleLog"))
        XCTAssertEqual(log.names, log2.names)
        XCTAssertFalse(log.isLog2)
        XCTAssertTrue(log2.isLog2)
    }

    func testAppPreviewAndExportShareTheSameCompiledPipeline() async throws {
        let preview = try CompositorResources.shared()
        let export = try CompositorResources.shared(supplied: MetalContext())
        XCTAssertTrue(preview.context === export.context)
        XCTAssertTrue(preview.ci === export.ci)

        // Start both requests together, as when a preview rebuild overlaps export.
        async let previewPipeline = Task.detached {
            preview.pipeline("transitionBGRA").map(ObjectIdentifier.init)
        }.value
        async let exportPipeline = Task.detached {
            export.pipeline("transitionBGRA").map(ObjectIdentifier.init)
        }.value
        let (first, second) = await (previewPipeline, exportPipeline)
        XCTAssertNotNil(first, "The transition shader must still compile on demand")
        XCTAssertEqual(first, second)
    }

    func testCustomShaderContextIsKeptSeparateForHostValidation() throws {
        let app = try CompositorResources.shared()
        let custom = try MetalContext(library: app.context.library)
        let isolated = try CompositorResources.shared(supplied: custom)
        XCTAssertTrue(isolated.context === custom)
        XCTAssertFalse(isolated.ci === app.ci)
    }

    func testLookPreparationReachesSharedCompositorContext() async throws {
        let identifier = try XCTUnwrap(LUTAsset.bundledCreativeLooks.first?.id)
        let prepared = await CompositorResources.prepareLooks([identifier])
        XCTAssertTrue(prepared)
        XCTAssertTrue(try CompositorResources.shared().context.luts.isReady(identifier))
    }
}
