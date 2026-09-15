import XCTest
@testable import GradeLab

/// Regression coverage for camera files that are valid 8-bit SDR but omit one
/// or more optional color declarations. DJI H.264 footage commonly has this
/// shape. `retime_test.mov` is a real 8-bit H.264 file with incomplete tags, so
/// this exercises AVFoundation's format descriptions rather than only a mocked
/// `VideoMetadata` value.
final class UntaggedSDRIntegrationTests: XCTestCase {
    private func fixtureURL() throws -> URL {
        try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "retime_test", withExtension: "mov"),
            "The untagged H.264 regression fixture is missing from the test bundle."
        )
    }

    func testUntaggedEightBitSDRUsesOneRec709PolicyForPreviewAndExport() async throws {
        let asset = try await VideoMetadataReader().read(from: fixtureURL())

        XCTAssertEqual(asset.metadata.bitDepth, 8)
        XCTAssertTrue(
            asset.metadata.colorPrimaries == nil
                || asset.metadata.transferFunction == nil
                || asset.metadata.yCbCrMatrix == nil,
            "The regression fixture must keep at least one color declaration absent."
        )
        XCTAssertEqual(ColorPipelineSupport(metadata: asset.metadata), .assumedRec709)

        _ = try await ExportSourceInspector.inspect(asset, requireExportColorTags: false)
        let exportSource = try await ExportSourceInspector.inspect(asset, requireExportColorTags: true)
        XCTAssertEqual(exportSource.colorMode, .sdr)
    }

    func testAnExplicitWideGamutTagIsNeverOverriddenByTheCompatibilityPath() async throws {
        let asset = try await VideoMetadataReader().read(from: fixtureURL())
        let conflictingMetadata = makeVideoMetadata(
            codec: asset.metadata.codec,
            codecFourCC: asset.metadata.codecFourCC,
            colorPrimaries: "BT.2020",
            transferFunction: nil,
            yCbCrMatrix: nil,
            isHDR: nil,
            bitDepth: 8
        )
        let conflicting = VideoAsset(
            id: asset.id,
            url: asset.url,
            metadata: conflictingMetadata,
            sourceRange: asset.sourceRange,
            frameDuration: asset.frameDuration
        )

        do {
            _ = try await ExportSourceInspector.inspect(conflicting, requireExportColorTags: true)
            XCTFail("An explicit BT.2020 declaration must stay blocked.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("BT.2020"))
        }
    }
}
