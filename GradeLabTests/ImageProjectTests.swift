import XCTest
@testable import GradeLab

/// The still-image document, and the couple of constants that are restated
/// outside the app and could therefore drift.
///
/// The rendering itself is checked where it can actually be checked — on the
/// GPU, by `Scripts/ValidateStillImage.swift`, which renders a picture whole and
/// then in tiles and demands the two agree. These are the model-level promises.
final class ImageProjectTests: XCTestCase {

    private func makeMetadata(
        width: Int = 4032, height: Int = 3024, orientation: Int = 1
    ) -> ImageMetadata {
        ImageMetadata(
            fileName: "IMG_0001.HEIC", pixelWidth: width, pixelHeight: height,
            orientation: orientation, typeIdentifier: "public.heic", fileSize: 2_400_000,
            bitsPerComponent: 8, colorModel: "RGB", colorProfileName: "Display P3",
            hasEmbeddedProfile: true, isWideGamut: true, isHDR: false, hasAlpha: false,
            dpi: 72, creationDate: Date(timeIntervalSince1970: 1_700_000_000), isRAW: false,
            hdrGainMap: false)
    }

    /// Fixed timestamps, on a whole second. The store encodes dates as ISO 8601,
    /// which has no sub-second field, so a project built from `.now` cannot
    /// compare equal to itself after a round trip — a property of the date
    /// format, not of the document.
    private func makeProject(metadata: ImageMetadata? = nil) -> ImageProject {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        return ImageProject(
            displayName: "Test Photo",
            asset: ImageAsset(
                id: UUID(),
                url: URL(fileURLWithPath: "/tmp/gradelab-test.heic"),
                metadata: metadata ?? makeMetadata()),
            createdAt: timestamp,
            updatedAt: timestamp)
    }

    // MARK: - The grade is the same grade video uses

    /// The point of the whole feature: a photograph stores a `GradeSettings`,
    /// not a still-specific variant of one. If this ever became a separate type
    /// the preset library and the grade clipboard would silently stop crossing
    /// between the two kinds of document.
    func testImageProjectStoresTheSharedGradeSettings() throws {
        var settings = GradeSettings.neutral
        settings.exposure = 0.4
        settings.temperature = -22
        var advanced = AdvancedGrade.neutral
        advanced.vignette = -40
        advanced.hsl[3].saturation = 30
        advanced.effects = FilmEffects(fade: 10, sharpness: 20, bloom: 30,
                                       glow: 0, halation: 15, grain: 45)
        settings.advanced = advanced

        var project = makeProject()
        project.gradeSettings = settings

        // A grade taken off a photograph is the same value a clip would carry.
        let clip = VideoClip(
            placement: .init(id: UUID(), trackID: UUID(),
                             timelineStart: .zero, duration: try .seconds(1)),
            assetID: UUID(),
            sourceRange: .init(start: .zero, duration: try .seconds(1)),
            gradeSettings: project.gradeSettings)
        XCTAssertEqual(clip.gradeSettings, settings)
    }

    func testRoundTripPreservesTheGradeAndTheMetadata() throws {
        var project = makeProject()
        project.gradeSettings.exposure = -0.75
        project.gradeSettings.advanced = {
            var advanced = AdvancedGrade.neutral
            advanced.lut = "Warm Cinema.cube"
            advanced.lutIntensity = 62
            return advanced
        }()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(ImageProject.self, from: encoder.encode(project))

        XCTAssertEqual(restored, project)
        XCTAssertEqual(restored.gradeSettings.advanced?.lut, "Warm Cinema.cube")
        XCTAssertEqual(restored.gradeSettings.advanced?.lutIntensity, 62)
        XCTAssertEqual(restored.metadata.pixelWidth, 4032)
    }

    /// A document written before a grading control existed decodes with that
    /// control neutral, rather than failing to open.
    func testDocumentWithoutAGradeDecodesAsNeutral() throws {
        let json = """
        {
          "documentVersion": 1,
          "id": "\(UUID().uuidString)",
          "displayName": "Older Photo",
          "asset": {
            "id": "\(UUID().uuidString)",
            "url": "file:///tmp/gradelab-test.heic",
            "metadata": {
              "fileName": "a.heic", "pixelWidth": 100, "pixelHeight": 80,
              "orientation": 1, "hasEmbeddedProfile": false, "isWideGamut": false,
              "isHDR": false, "hasAlpha": false, "isRAW": false
            }
          },
          "createdAt": "2026-01-01T00:00:00Z",
          "updatedAt": "2026-01-01T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(ImageProject.self, from: Data(json.utf8))
        XCTAssertEqual(project.gradeSettings, .neutral)
    }

    // MARK: - Orientation

    /// The displayed size is the stored size with the EXIF transform applied.
    /// Everything downstream — the preview geometry, the tile arithmetic, the
    /// exported dimensions — is derived from this.
    func testSidewaysOrientationsExchangeTheDisplayedAxes() {
        for orientation in 1...4 {
            let metadata = makeMetadata(orientation: orientation)
            XCTAssertEqual(metadata.displayWidth, 4032, "orientation \(orientation)")
            XCTAssertEqual(metadata.displayHeight, 3024, "orientation \(orientation)")
        }
        for orientation in 5...8 {
            let metadata = makeMetadata(orientation: orientation)
            XCTAssertEqual(metadata.displayWidth, 3024, "orientation \(orientation)")
            XCTAssertEqual(metadata.displayHeight, 4032, "orientation \(orientation)")
        }
    }

    // MARK: - Colour support

    func testRAWIsRefusedRatherThanRunThroughTheSRGBPath() {
        var metadata = makeMetadata()
        metadata = ImageMetadata(
            fileName: metadata.fileName, pixelWidth: metadata.pixelWidth,
            pixelHeight: metadata.pixelHeight, orientation: 1,
            typeIdentifier: "com.adobe.raw-image", fileSize: nil, bitsPerComponent: 14,
            colorModel: "RGB", colorProfileName: nil, hasEmbeddedProfile: false,
            isWideGamut: false, isHDR: false, hasAlpha: false, dpi: nil,
            creationDate: nil, isRAW: true, hdrGainMap: false)
        let support = ImageColorSupport(metadata: metadata)
        XCTAssertFalse(support.allowsGrading)
        XCTAssertTrue(support.isBlocking)
        XCTAssertNotNil(support.notice)
    }

    /// A wide-gamut photograph is graded — but the conversion is stated rather
    /// than performed silently.
    func testWideGamutIsAcceptedAndTheConversionIsDisclosed() {
        let support = ImageColorSupport(metadata: makeMetadata())
        XCTAssertTrue(support.allowsGrading)
        XCTAssertFalse(support.isBlocking)
        XCTAssertEqual(support.notice?.contains("Display P3"), true)
    }

    // MARK: - Export

    /// The output is the source's resolution. There is no size option, and this
    /// is what says so.
    func testExportPreservesSourceResolution() {
        let metadata = makeMetadata(orientation: 6)
        XCTAssertEqual(metadata.displaySize, CGSize(width: 3024, height: 4032))
        XCTAssertEqual(ImageExportConfiguration.default(for: metadata).format,
                       ImageExportFormat.heic.isAvailable ? .heic : .jpeg)
    }

    func testPNGIsLosslessAndOffersNoQualityControl() {
        XCTAssertFalse(ImageExportFormat.png.isLossy)
        XCTAssertTrue(ImageExportFormat.jpeg.isLossy)
        XCTAssertTrue(ImageExportFormat.heic.isLossy)
    }

    /// `Scripts/ValidateStillImage.swift` cannot link the exporter — it would
    /// pull in ImageIO, UIKit and the whole project model — so it restates the
    /// tile geometry. This is what stops the two from drifting apart and the
    /// harness from validating numbers the app no longer uses.
    func testValidationHarnessTileGeometryMatchesTheExporter() {
        XCTAssertEqual(ImageExporter.tileSide, 1536)
        XCTAssertEqual(ImageExporter.tilePadding, 16)
        // The harness renders a 3500 x 2100 picture, where the derived overlap
        // is the floor.
        XCTAssertEqual(ImageExporter.tilePadding(for: CGSize(width: 3500, height: 2100)), 16)
    }

    /// The finishing effects must reach no further than the tile overlap, or a
    /// tile boundary would show. The glows are excluded from this by design —
    /// they are composited from a halo blurred over the whole picture — so the
    /// only reach left is the unsharp mask's, which is one texel of the
    /// reference size.
    func testSharpenReachFitsInsideTheTileOverlap() {
        // Ordinary cameras through to a very large stitched panorama.
        for longEdge in [2048, 4032, 8064, 16_000, 60_000] {
            let imageSize = CGSize(width: longEdge, height: longEdge * 3 / 4)
            let padding = ImageExporter.tilePadding(for: imageSize)
            let padded = CGFloat(ImageExporter.tileSide + padding * 2)
            let step = StillEffectGeometry.sharpenStep(
                imageSize: imageSize, surfaceSize: CGSize(width: padded, height: padded))
            // In texels of the padded tile, plus a texel for the bilinear spread.
            let reach = Double(step.x) * Double(padded) + 1
            XCTAssertLessThanOrEqual(
                reach, Double(padding),
                "sharpen reaches \(reach) px at \(longEdge) px wide, past the \(padding) px overlap")
        }
    }

    /// The blur radius is a fixed fraction of the picture for stills, and still
    /// a quarter of each edge for video.
    func testStillBlurSizeIsResolutionIndependentAndVideoIsUnchanged() {
        var fractions: Set<Int> = []
        for width in [1024, 2048, 4096, 8192] {
            let size = FilmEffectsStage.blurSize(
                width: width, height: width * 3 / 4, longEdge: StillEffectGeometry.blurLongEdge)
            XCTAssertEqual(size.width, StillEffectGeometry.blurLongEdge)
            fractions.insert(size.width)
        }
        XCTAssertEqual(fractions.count, 1)

        let video = FilmEffectsStage.blurSize(width: 1024, height: 768, longEdge: nil)
        XCTAssertEqual(video.width, 256)
        XCTAssertEqual(video.height, 192)
    }
}
