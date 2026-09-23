import XCTest
@testable import GradeLab

/// A 1080p export of a 4K project used to composite every frame at 4K and then
/// hand the writer frames it scaled straight back down — four times the pixels
/// in every working buffer, every layer surface and every decoded still, for a
/// file that could never show them. Choosing a smaller export made no
/// difference to what it cost to produce.
final class ExportRenderSizeTests: XCTestCase {
    private let uhd = CGSize(width: 3840, height: 2160)

    func testA1080pExportOfA4KProjectCompositesAt1080p() {
        let requested = ExportConfiguration(resolution: .fullHD).dimensions(width: 3840, height: 2160)
        let size = SequenceComposition.exportRenderSize(
            requested: CGSize(width: requested.width, height: requested.height), canvas: uhd)
        XCTAssertEqual(size, CGSize(width: 1920, height: 1080))
        // The saving this is all for.
        let before = Int(uhd.width * uhd.height) * 4
        let after = Int(size.width * size.height) * 4
        XCTAssertEqual(before / after, 4, "every per-layer surface is a quarter the size")
    }

    func testSmallerPresetsGoSmallerStill() {
        for (resolution, expected) in [(ExportConfiguration.Resolution.hd, CGSize(width: 1280, height: 720))] {
            let requested = ExportConfiguration(resolution: resolution).dimensions(width: 3840, height: 2160)
            XCTAssertEqual(SequenceComposition.exportRenderSize(
                requested: CGSize(width: requested.width, height: requested.height), canvas: uhd), expected)
        }
    }

    /// Asking for more than the project has does not make the compositor
    /// invent pixels: it stays at the canvas, exactly as it did before.
    func testAskingForMoreThanTheCanvasChangesNothing() {
        XCTAssertEqual(SequenceComposition.exportRenderSize(
            requested: CGSize(width: 7680, height: 4320), canvas: uhd), uhd)
        XCTAssertEqual(SequenceComposition.exportRenderSize(requested: uhd, canvas: uhd), uhd)
        // "Original" means the canvas.
        let original = ExportConfiguration(resolution: .original).dimensions(width: 3840, height: 2160)
        XCTAssertEqual(SequenceComposition.exportRenderSize(
            requested: CGSize(width: original.width, height: original.height), canvas: uhd), uhd)
    }

    /// 4:2:0 chroma is subsampled by two in each direction, so an odd edge is
    /// not a size the encoder can take.
    func testDimensionsStayEvenAndDegenerateInputIsRefused() {
        let odd = SequenceComposition.exportRenderSize(
            requested: CGSize(width: 1919, height: 1079), canvas: uhd)
        XCTAssertEqual(Int(odd.width) % 2, 0)
        XCTAssertEqual(Int(odd.height) % 2, 0)
        XCTAssertEqual(SequenceComposition.exportRenderSize(requested: .zero, canvas: uhd), uhd)
        XCTAssertEqual(SequenceComposition.exportRenderSize(
            requested: CGSize(width: CGFloat.nan, height: CGFloat.nan), canvas: uhd), uhd)
    }
}
