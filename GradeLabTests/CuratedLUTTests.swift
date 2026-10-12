import UIKit
import XCTest
@testable import GradeLab

final class CuratedLUTTests: XCTestCase {
    func testEveryCuratedResourceShipsAndLoads() throws {
        let looks = LUTAsset.bundledCuratedLooks
        XCTAssertEqual(looks.count, 8)
        XCTAssertEqual(Set(LUTAsset.bundledLooks.map(\.id)).count, LUTAsset.bundledLooks.count)
        XCTAssertEqual(Array(LUTAsset.bundledLooks.dropFirst(3).prefix(8)), looks)
        for look in looks {
            let resource = try XCTUnwrap(look.url(), look.name)
            XCTAssertEqual(resource.pathExtension, LUTBinary.fileExtension)
            let compiled = try LUTBinary.decode(contentsOf: resource)
            XCTAssertGreaterThan(compiled.size, 1)
            XCTAssertEqual(compiled.samples.count, compiled.size * compiled.size * compiled.size * 3)
            XCTAssertEqual(look.inputColorSpace, "Rec.709 / working SDR")
            XCTAssertEqual(look.kind, .creative)
            XCTAssertEqual(look.origin, .bundled, "New looks should load on demand")
        }
    }

    func testPackPrefixesAreHiddenWithoutChangingStoredIdentifiers() {
        for (filename, expected) in [
            ("FG_CineBright", "Cine Bright"),
            ("FGCineVibrant", "Cine Vibrant"),
            ("fg_CineCold", "Cine Cold"),
            ("FG_CineTeal&Orange1", "Cine Teal & Orange1"),
            ("ON1_Film_Print", "Film Print"),
            ("Night_Market", "Night Market"),
            ("Apple_LOG2_A", "Apple LOG2 A"),
            ("FGreen", "FGreen")
        ] {
            let look = LUTAsset.imported(resourceName: filename)
            XCTAssertEqual(look.name, expected)
            XCTAssertEqual(look.id, "\(filename).cube", "Display cleanup must preserve project compatibility")
        }
        for look in LUTAsset.bundledCuratedLooks {
            XCTAssertFalse(look.name.hasPrefix("FG"))
            XCTAssertFalse(look.name.hasPrefix("ON1"))
            XCTAssertFalse(look.name.contains("_"))
        }
    }

    /// Runs every new resource through the same Metal pipeline as the editor.
    /// The contact sheet also exposes missing thumbnails or duplicate looks.
    func testEveryCuratedLookRendersAnActualThumbnail() throws {
        let renderer = try LookPreviewRenderer(context: MetalContext())
        let reference = LookReferenceImage.make()
        let source = try XCTUnwrap(renderer.makeSourceTexture(from: reference))
        let original = try XCTUnwrap(renderer.render(look: nil, source: source))
        var tiles: [(String, UIImage)] = [("Original", original)]
        var rendered = Set<Data>()
        for look in LUTAsset.bundledCuratedLooks {
            let image = try XCTUnwrap(renderer.render(look: look, source: source), look.name)
            XCTAssertEqual(image.size, original.size)
            let data = try XCTUnwrap(image.pngData())
            XCTAssertNotEqual(data, original.pngData(), "\(look.name) must apply its LUT")
            XCTAssertTrue(rendered.insert(data).inserted, "\(look.name) duplicated another look")
            let tier = ProAccessPolicy.requiresPro(look) ? "Pro" : "Free"
            tiles.append(("\(look.name) · \(tier)", image))
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let sheet = UIGraphicsImageRenderer(size: CGSize(width: 660, height: 900), format: format).image { context in
            UIColor(white: 0.07, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 660, height: 900))
            for (index, tile) in tiles.enumerated() {
                let x = CGFloat(index % 3) * 220 + 20
                let y = CGFloat(index / 3) * 300 + 12
                tile.1.draw(in: CGRect(x: x, y: y, width: 180, height: 240))
                (tile.0 as NSString).draw(
                    in: CGRect(x: x - 5, y: y + 250, width: 190, height: 32),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 13, weight: .medium),
                                     .foregroundColor: UIColor.white])
            }
        }
        let attachment = XCTAttachment(image: sheet)
        attachment.name = "Curated looks — shipping Metal previews"
        attachment.lifetime = .keepAlways
        add(attachment)
        try sheet.pngData()?.write(to: URL(fileURLWithPath: "/tmp/gradelab-curated-looks.png"))
    }
}
