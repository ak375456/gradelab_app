import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import GradeLab

/// End-to-end: a real file on disk, through the real decode, the real tiled
/// Metal render, and the real ImageIO encode.
///
/// Small on purpose. The grading maths is already covered on the GPU by
/// `Scripts/ValidateStillImage.swift`; what these check is the part that can
/// only go wrong once a file exists — that the exported picture is the source's
/// own resolution, is the right way up, and is tagged with the space it was
/// actually graded in.
final class ImageExportIntegrationTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gradelab-export-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes a JPEG whose four quadrants are different colours, so a rotation
    /// or a mirror is visible in the result rather than plausible.
    @discardableResult
    private func writeSource(
        width: Int, height: Int, orientation: Int, type: UTType = .jpeg
    ) throws -> URL {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let left = x < width / 2, top = y < height / 2
                // BGRA, premultiplied-first byte order.
                // Blue, green, red bytes. Four colours no two of which share a
                // dominant channel, so `dominant` cannot confuse them.
                let colour: (blue: UInt8, green: UInt8, red: UInt8) = switch (top, left) {
                case (true, true): (20, 20, 230)     // top-left: red
                case (true, false): (20, 230, 20)    // top-right: green
                case (false, true): (230, 20, 20)    // bottom-left: blue
                case (false, false): (20, 230, 230)  // bottom-right: yellow
                }
                pixels[index] = colour.blue
                pixels[index + 1] = colour.green
                pixels[index + 2] = colour.red
                pixels[index + 3] = 255
            }
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let url = directory.appendingPathComponent("source-\(orientation)")
            .appendingPathExtension(type.preferredFilenameExtension ?? "jpg")
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: 1.0
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func makeProject(url: URL, grade: GradeSettings = .neutral) throws -> ImageProject {
        let metadata = try ImageMetadataReader.read(url: url)
        return ImageProject(
            displayName: "Integration",
            asset: ImageAsset(id: UUID(), url: url, metadata: metadata),
            gradeSettings: grade)
    }

    /// The colour a decoded picture has at a fractional position, for corner
    /// checks that survive JPEG's ringing at the quadrant edges.
    private func sample(_ image: CGImage, atX fx: Double, y fy: Double) -> (r: Int, g: Int, b: Int) {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let x = min(width - 1, max(0, Int(Double(width) * fx)))
        let y = min(height - 1, max(0, Int(Double(height) * fy)))
        let index = (y * width + x) * 4
        return (Int(pixels[index + 2]), Int(pixels[index + 1]), Int(pixels[index]))
    }

    /// Names the quadrant a sample came from. Red and green are tested before
    /// the pair that contains them, so yellow is not reported as green.
    private func dominant(_ colour: (r: Int, g: Int, b: Int)) -> String {
        if colour.r > 128, colour.g > 128 { return "yellow" }
        if colour.r > 128 { return "red" }
        if colour.g > 128 { return "green" }
        if colour.b > 128 { return "blue" }
        return "unknown(\(colour))"
    }

    // MARK: - Resolution

    /// The export is the source's own dimensions. Not "about", and not reduced
    /// because the picture was large.
    func testExportPreservesTheSourcePixelDimensions() throws {
        // Larger than one tile in both axes, so the tiled path really runs, and
        // deliberately not a multiple of the tile side.
        let url = try writeSource(width: 2000, height: 1700, orientation: 1)
        let project = try makeProject(url: url)
        let output = try ImageExporter().export(
            project: project, configuration: ImageExportConfiguration(),
            destinationDirectory: directory)

        XCTAssertEqual(output.width, 2000)
        XCTAssertEqual(output.height, 1700)
        let source = CGImageSourceCreateWithURL(output.url as CFURL, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 2000)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 1700)
    }

    // MARK: - Orientation

    /// A portrait photograph — the everyday case, EXIF orientation 6 — comes out
    /// upright, at portrait dimensions, with its corners where they started.
    func testRotatedSourceExportsUprightAndUnmirrored() throws {
        let url = try writeSource(width: 1600, height: 1200, orientation: 6)
        let project = try makeProject(url: url)
        XCTAssertEqual(project.metadata.displayWidth, 1200)
        XCTAssertEqual(project.metadata.displayHeight, 1600)

        let output = try ImageExporter().export(
            project: project, configuration: ImageExportConfiguration(),
            destinationDirectory: directory)
        XCTAssertEqual(output.width, 1200, "a rotated source must export at its displayed size")
        XCTAssertEqual(output.height, 1600)

        let exported = CGImageSourceCreateWithURL(output.url as CFURL, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(exported, 0, nil) as! [CFString: Any]
        // The pixels are upright, so the file must not also ask a viewer to
        // rotate them — that would rotate the picture twice.
        XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int ?? 1, 1)

        // Orientation 6 rotates the stored picture 90° clockwise, so the stored
        // top-left quadrant (red) belongs in the displayed top-right.
        let image = CGImageSourceCreateImageAtIndex(exported, 0, nil)!
        XCTAssertEqual(dominant(sample(image, atX: 0.75, y: 0.25)), "red", "top-right")
        XCTAssertEqual(dominant(sample(image, atX: 0.75, y: 0.75)), "green", "bottom-right")
        XCTAssertEqual(dominant(sample(image, atX: 0.25, y: 0.25)), "blue", "top-left")
        XCTAssertEqual(dominant(sample(image, atX: 0.25, y: 0.75)), "yellow", "bottom-left")
    }

    // MARK: - Colour

    /// The exported file is tagged with the space it was graded in. An untagged
    /// file, or one tagged sRGB while carrying Rec.709 values, would be shown
    /// wrongly by anything that honours profiles.
    func testExportCarriesTheWorkingColorProfile() throws {
        let url = try writeSource(width: 900, height: 600, orientation: 1)
        let output = try ImageExporter().export(
            project: try makeProject(url: url), configuration: ImageExportConfiguration(),
            destinationDirectory: directory)
        let exported = CGImageSourceCreateWithURL(output.url as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(exported, 0, nil)!
        let space = try XCTUnwrap(image.colorSpace)
        XCTAssertNotNil(space.name, "the exported file must carry a named colour space")
        XCTAssertEqual(space.copyICCData() as Data?,
                       ImageDecoder.workingColorSpace.copyICCData() as Data?,
                       "the exported profile must be the space the picture was graded in")
    }

    /// Every offered format writes a real file at full resolution.
    func testEveryOfferedFormatWrites() throws {
        let url = try writeSource(width: 640, height: 480, orientation: 1)
        let project = try makeProject(url: url)
        for format in ImageExportFormat.available {
            var configuration = ImageExportConfiguration()
            configuration.format = format
            let output = try ImageExporter().export(
                project: project, configuration: configuration, destinationDirectory: directory)
            XCTAssertEqual(output.width, 640, "\(format.title)")
            XCTAssertEqual(output.height, 480, "\(format.title)")
            XCTAssertGreaterThan(output.byteCount, 0, "\(format.title) wrote an empty file")
            let source = CGImageSourceCreateWithURL(output.url as CFURL, nil)
            XCTAssertEqual(CGImageSourceGetType(source!) as String?, format.utType.identifier)
        }
    }

    // MARK: - HDR gain maps

    /// The regression that matters most: almost every photograph a recent iPhone
    /// takes is an SDR picture with an HDR gain map attached, and an earlier
    /// build refused all of them as "HDR". A gain map is auxiliary data — the
    /// primary image is a complete SDR picture, and it is what gets graded.
    func testPhotographWithAnHDRGainMapImportsAndGrades() throws {
        let url = try writeSourceWithGainMap(width: 900, height: 600)

        let metadata = try ImageMetadataReader.read(url: url)
        XCTAssertTrue(metadata.hasHDRGainMap, "the fixture must actually carry a gain map")
        XCTAssertFalse(metadata.isHDR, "a gain map is not an HDR-encoded primary image")

        let support = ImageColorSupport(metadata: metadata)
        XCTAssertTrue(support.allowsGrading, "a photograph with a gain map must be gradeable")
        XCTAssertFalse(support.isBlocking)
        XCTAssertEqual(support.notice?.contains("gain map"), true,
                       "the import must say plainly that the gain map is not carried through")

        // And it goes all the way through: decode, grade, export.
        var grade = GradeSettings.neutral
        grade.exposure = -0.5
        let output = try ImageExporter().export(
            project: try makeProject(url: url, grade: grade),
            configuration: ImageExportConfiguration(), destinationDirectory: directory)
        XCTAssertEqual(output.width, 900)
        XCTAssertEqual(output.height, 600)
    }

    /// An image whose *primary* data is HDR-encoded is still refused — there is
    /// no SDR picture inside it to fall back to.
    func testHDREncodedPrimaryImageIsStillRefused() {
        let metadata = ImageMetadata(
            fileName: "hdr.heic", pixelWidth: 4032, pixelHeight: 3024, orientation: 1,
            typeIdentifier: "public.heic", fileSize: nil, bitsPerComponent: 10,
            colorModel: "RGB", colorProfileName: "ITU-R BT.2100 PQ", hasEmbeddedProfile: true,
            isWideGamut: false, isHDR: true, hasAlpha: false, dpi: nil, creationDate: nil,
            isRAW: false, hdrGainMap: false)
        let support = ImageColorSupport(metadata: metadata)
        XCTAssertFalse(support.allowsGrading)
        XCTAssertEqual(support.notice?.contains("PQ or HLG"), true)
    }

    /// Writes a JPEG with a real auxiliary HDR gain map attached, the way an
    /// iPhone photograph carries one.
    private func writeSourceWithGainMap(width: Int, height: Int) throws -> URL {
        let base = try writeSource(width: width, height: height, orientation: 1)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(base as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))

        // A one-channel 8-bit map at half size, which is the shape a gain map has.
        let mapWidth = width / 2, mapHeight = height / 2
        let mapData = Data(repeating: 128, count: mapWidth * mapHeight)
        let description: [CFString: Any] = [
            kCGImagePropertyWidth: mapWidth,
            kCGImagePropertyHeight: mapHeight,
            kCGImagePropertyBytesPerRow: mapWidth,
            kCGImagePropertyPixelFormat: Int(kCVPixelFormatType_OneComponent8)
        ]
        let info: [CFString: Any] = [
            kCGImageAuxiliaryDataInfoData: mapData as CFData,
            kCGImageAuxiliaryDataInfoDataDescription: description as CFDictionary
        ]

        let url = directory.appendingPathComponent("gainmap.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 1.0
        ] as CFDictionary)
        CGImageDestinationAddAuxiliaryDataInfo(
            destination, kCGImageAuxiliaryDataTypeHDRGainMap, info as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("This platform would not write an auxiliary HDR gain map")
        }
        return url
    }

    // MARK: - The grade actually reaches the file

    /// A grade with something set in every part of the model changes the
    /// exported pixels, and a neutral one does not — which is what proves the
    /// export is running the grading pipeline rather than copying the source.
    func testTheGradeReachesTheExportedPixels() throws {
        let url = try writeSource(width: 1800, height: 1400, orientation: 1)

        let neutral = try ImageExporter().export(
            project: try makeProject(url: url), configuration: ImageExportConfiguration(),
            destinationDirectory: directory)

        var grade = GradeSettings.neutral
        grade.exposure = -0.8
        grade.contrast = 30
        grade.saturation = -40
        var advanced = AdvancedGrade.neutral
        advanced.vignette = -70
        advanced.hsl[0].hue = 25
        advanced.wheels[0].strength = 40
        advanced.effects = FilmEffects(fade: 15, sharpness: 30, bloom: 40,
                                       glow: 20, halation: 25, grain: 30)
        grade.advanced = advanced

        let graded = try ImageExporter().export(
            project: try makeProject(url: url, grade: grade),
            configuration: ImageExportConfiguration(), destinationDirectory: directory)

        let a = CGImageSourceCreateImageAtIndex(
            CGImageSourceCreateWithURL(neutral.url as CFURL, nil)!, 0, nil)!
        let b = CGImageSourceCreateImageAtIndex(
            CGImageSourceCreateWithURL(graded.url as CFURL, nil)!, 0, nil)!

        // The centre is far from the vignette, so this is the tone and colour
        // work; the corner is where the vignette is strongest.
        let centreNeutral = sample(a, atX: 0.5, y: 0.3)
        let centreGraded = sample(b, atX: 0.5, y: 0.3)
        XCTAssertNotEqual(centreNeutral.r, centreGraded.r)
        let cornerGraded = sample(b, atX: 0.02, y: 0.02)
        let cornerNeutral = sample(a, atX: 0.02, y: 0.02)
        XCTAssertLessThan(
            cornerGraded.r + cornerGraded.g + cornerGraded.b,
            cornerNeutral.r + cornerNeutral.g + cornerNeutral.b,
            "a negative vignette must darken the corner of the exported picture")
    }
}


