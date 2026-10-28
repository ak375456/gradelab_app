import Metal
import UIKit
import XCTest
@testable import GradeLab

@MainActor
final class SunsetLUTTests: XCTestCase {
    func testSixCreativeLooksShipWithCleanNamesAndNativeGrids() throws {
        let looks = LUTAsset.bundledSunsetLooks
        XCTAssertEqual(looks.map(\.name), ["Desert Sunset", "Evergreen Chrome", "Amber Grove", "Soft Bloom", "Azure Film", "Azure Film Deep"])
        XCTAssertEqual(Array(LUTAsset.bundledLooks.dropFirst(11).prefix(6)), looks)
        XCTAssertEqual(Set(LUTAsset.bundledLooks.map(\.id)).count, LUTAsset.bundledLooks.count)
        var contents = Set<Data>()
        for (look, size) in zip(looks, [32, 32, 33, 33, 32, 32]) {
            XCTAssertEqual(look.kind, .creative)
            XCTAssertEqual(look.origin, .bundled, "Load on demand, without increasing startup preload")
            XCTAssertEqual(look.inputColorSpace, "Rec.709 / working SDR")
            XCTAssertFalse(look.name.localizedCaseInsensitiveContains("IWLTBAP"))
            XCTAssertFalse(look.name.contains("_"))
            XCTAssertTrue(ProAccessPolicy.requiresPro(look), "New bundled creative looks follow the existing export policy")
            let url = try XCTUnwrap(look.url(), look.name)
            XCTAssertEqual(url.pathExtension, LUTBinary.fileExtension)
            let compiled = try LUTBinary.decode(contentsOf: url)
            XCTAssertEqual(compiled.size, size, "Preserve the downloaded grid without resampling")
            XCTAssertEqual(compiled.samples.count, size * size * size * 3)
            XCTAssertTrue(contents.insert(try Data(contentsOf: url)).inserted, "Duplicate look")
        }
        #if !targetEnvironment(macCatalyst)
        let camera = CameraViewModel()
        XCTAssertTrue(Set(looks.map(\.id)).isSubset(of: Set(camera.looks.map(\.id))))
        #endif
    }

    func testLookStrengthAndPreviewUseTheSharedGPUGrade() throws {
        let renderer = try LookPreviewRenderer(context: MetalContext())
        let source = try XCTUnwrap(renderer.makeSourceTexture(from: LookReferenceImage.make()))
        let original = try pixels(XCTUnwrap(renderer.render(look: nil, source: source)))
        var images = Set<Data>()
        for look in LUTAsset.bundledSunsetLooks {
            var grade = GradeSettings.neutral
            grade.advanced = AdvancedGrade()
            grade.advanced?.lut = look.id
            grade.advanced?.lutIntensity = 100
            let fullImage = try XCTUnwrap(renderer.render(settings: grade, source: source))
            let full = try pixels(fullImage)
            XCTAssertTrue(images.insert(try XCTUnwrap(fullImage.pngData())).inserted)
            XCTAssertNotEqual(full, original, "\(look.name) must visibly apply")
            grade.advanced?.lutIntensity = 0
            let zero = try pixels(XCTUnwrap(renderer.render(settings: grade, source: source)))
            grade.advanced?.lutIntensity = 50
            let half = try pixels(XCTUnwrap(renderer.render(settings: grade, source: source)))
            var zeroError = 0, blendError = 0
            for i in original.indices where i % 4 != 3 {
                zeroError = max(zeroError, abs(Int(zero[i]) - Int(original[i])))
                blendError = max(blendError, abs(Int(half[i]) * 2 - Int(full[i]) - Int(original[i])))
            }
            XCTAssertLessThanOrEqual(zeroError, 1, "\(look.name) at 0% must preserve the original")
            XCTAssertLessThanOrEqual(blendError, 4, "\(look.name) at 50% must blend consistently")
        }
    }

    func testNewLookDescriptionsShipInEveryLanguage() throws {
        let keys = [
            "Sunset warmth with amber highlights and turquoise blues.",
            "Deep cyan greens, rich blues and warm film-like skin tones.",
            "Golden foliage and warm earth tones with crisp, saturated blues.",
            "Gentle contrast, soft warmth and mellow teal shadows.",
            "Faded cool shadows, warm skin and a soft blue film palette.",
            "Deep blacks, vivid blue skies and warm, punchy midtones."
        ]
        for locale in ["en", "de", "es", "fi", "fr", "it", "ja", "sv"] {
            let path = try XCTUnwrap(Bundle.lutResources.path(forResource: locale, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in keys {
                XCTAssertNotEqual(bundle.localizedString(forKey: key, value: "__missing__", table: nil), "__missing__", "\(locale): \(key)")
            }
        }
    }

    func testEveryLookRendersThePortraitAndFoliageReference() throws {
        let renderer = try LookPreviewRenderer(context: MetalContext())
        let photo = try XCTUnwrap(UIImage(named: "PaywallBefore", in: Bundle.lutResources, compatibleWith: nil))
        let source = try XCTUnwrap(renderer.makeSourceTexture(from: photo))
        let original = try XCTUnwrap(renderer.render(look: nil, source: source))
        let rendered = try LUTAsset.bundledSunsetLooks.map { look in
            (look.name, try XCTUnwrap(renderer.render(look: look, source: source), look.name))
        }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let sheet = UIGraphicsImageRenderer(size: .init(width: 660, height: 760), format: format).image { context in
            UIColor(white: 0.055, alpha: 1).setFill(); context.fill(.init(x: 0, y: 0, width: 660, height: 760))
            original.draw(in: .init(x: 22, y: 16, width: 72, height: 90))
            ("SUNSET COLLECTION" as NSString).draw(at: .init(x: 116, y: 28), withAttributes: [.font: UIFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: UIColor.white])
            ("Original above · Six creative 3D looks below · 100% strength" as NSString).draw(in: .init(x: 116, y: 66, width: 520, height: 36), withAttributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.lightGray])
            for (index, tile) in rendered.enumerated() {
                let x = CGFloat(index % 3) * 220 + 20, y = CGFloat(index / 3) * 314 + 124
                tile.1.draw(in: .init(x: x, y: y, width: 180, height: 225))
                (tile.0 as NSString).draw(in: .init(x: x, y: y + 238, width: 190, height: 44), withAttributes: [.font: UIFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: UIColor.white])
            }
        }
        let attachment = XCTAttachment(image: sheet)
        attachment.name = "Sunset collection — six shipping GPU looks"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func pixels(_ image: UIImage) throws -> [UInt8] {
        let cg = try XCTUnwrap(image.cgImage)
        var result = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: &result, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: cg.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return result
    }
}
