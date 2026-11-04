import CoreText
import XCTest
@testable import GradeLab

final class DownloadedFontTests: XCTestCase {
    private let suppliedFaces: [String: [String]] = [
        "Magari": ["Magari-thin", "Magari-light", "Magari-Regular", "Magari-bold", "Magari-extrabold"],
        "Pirata One": ["PirataOne-Regular"],
        "Hopeless Romantic": ["HopelessRomantic-Regular"],
        "Syne": ["Syne-Regular", "Syne-Medium", "Syne-SemiBold", "Syne-Bold", "Syne-ExtraBold"]
    ]

    func testEverySuppliedFaceIsBundledSelectableAndFreeToExport() throws {
        let registry = FontRegistry.shared
        let entries = registry.entries()
        for (family, names) in suppliedFaces {
            let entry = try XCTUnwrap(entries.first { $0.family == family }, family)
            XCTAssertEqual(entries.filter { $0.family == family }.count, 1)
            XCTAssertEqual(registry.faces(entry.id).map(\.id), names, family)
            XCTAssertFalse(ProAccessPolicy.fontRequiresPro(family: family))
            for name in names {
                var clip = TextClip(placement: .init(
                    id: UUID(), trackID: UUID(), timelineStart: .zero,
                    duration: try .seconds(2)))
                registry.selectFace(name, for: &clip.style)
                registry.normalize(&clip.style)
                XCTAssertEqual(registry.selectedFace(clip.style), name)
                let renderedFont = try XCTUnwrap(registry.variant(
                    clip.style.fontName, bold: clip.style.isBold, italic: clip.style.isItalic))
                XCTAssertEqual(CTFontCopyPostScriptName(renderedFont) as String, name)
                XCTAssertEqual(registry.familyName(name), family, "Must not resolve to a system fallback")
                XCTAssertFalse(ProAccessPolicy.fontRequiresPro(postScriptName: name), name)
                XCTAssertTrue(ProAccessPolicy.textRequirements(clip).isEmpty, name)
                let restored = try JSONDecoder().decode(TextClip.self, from: JSONEncoder().encode(clip))
                XCTAssertEqual(registry.selectedFace(restored.style), name, "Style must survive reopening")
                XCTAssertNotNil(TextRenderer.image(restored, canvas: CGSize(width: 640, height: 360)), name)
            }
        }
    }

    func testRalewayRetainsAllEighteenFreeStyles() {
        let faces = FontRegistry.shared.faces("Raleway-Regular")
        XCTAssertEqual(faces.count, 18)
        for face in faces {
            XCTAssertFalse(ProAccessPolicy.fontRequiresPro(postScriptName: face.id), face.id)
        }
    }

    func testExistingVariableFaceSelectsTheEquivalentStyleWithoutChangingTheProject() {
        let style = TextStyle(fontName: "RalewayRoman-Medium")
        XCTAssertEqual(FontRegistry.shared.selectedFace(style), "Raleway-Medium")
        XCTAssertEqual(style.fontName, "RalewayRoman-Medium")
    }

    func testWeightSelectionChangesRenderedGlyphsAndKeepsExportGeometry() throws {
        let registry = FontRegistry.shared
        let authored = CGSize(width: 640, height: 360)
        let exported = CGSize(width: 1280, height: 720)
        for (light, heavy) in [("Magari-thin", "Magari-extrabold"), ("Syne-Regular", "Syne-ExtraBold")] {
            var clip = TextClip(placement: .init(
                id: UUID(), trackID: UUID(), timelineStart: .zero,
                duration: try .seconds(2)))
            clip.text = "GradeLab"
            registry.selectFace(light, for: &clip.style)
            let lightPath = TextRenderer.layout(clip, canvas: authored).path
            registry.selectFace(heavy, for: &clip.style)
            XCTAssertNotEqual(lightPath, TextRenderer.layout(clip, canvas: authored).path)
            let preview = try XCTUnwrap(TextRenderer.image(clip, canvas: authored))
            let export = try XCTUnwrap(TextRenderer.image(clip, canvas: exported, authoredCanvas: authored))
            XCTAssertEqual(preview.extent.width / authored.width, export.extent.width / exported.width, accuracy: 0.001)
            XCTAssertEqual(preview.extent.height / authored.height, export.extent.height / exported.height, accuracy: 0.001)
        }
    }
}
