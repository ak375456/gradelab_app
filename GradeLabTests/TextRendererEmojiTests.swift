import CoreGraphics
import CoreImage
import XCTest
@testable import GradeLab

final class TextRendererEmojiTests: XCTestCase {
    private let canvas = CGSize(width: 800, height: 450)

    private func clip(_ text: String) throws -> TextClip {
        var clip = TextClip(placement: .init(
            id: UUID(), trackID: UUID(), timelineStart: .zero,
            duration: try .seconds(3)
        ))
        clip.text = text
        clip.style.fontSize = 100
        return clip
    }

    func testEmojiOnlyAndMixedTextIncludeColorGlyphInkInSelectionBounds() throws {
        for text in ["🌈", "Hello 🌈", "👨‍👩‍👧‍👦 👋🏽 🇵🇰 1️⃣", "First 🌈\nSecond 👋🏽"] {
            let title = try clip(text)
            let layout = TextRenderer.layout(title, canvas: canvas, collectingElements: true)
            XCTAssertFalse(layout.colorGlyphs.isEmpty, text)
            XCTAssertFalse(layout.ink.isNull, text)
            for glyph in layout.colorGlyphs {
                XCTAssertTrue(layout.fittedBounds.contains(glyph.bounds), text)
                XCTAssertGreaterThan(glyph.bounds.width, 0, text)
                XCTAssertGreaterThan(glyph.bounds.height, 0, text)
            }
            XCTAssertGreaterThan(try coloredPixelCount(TextRenderer.image(title, canvas: canvas)), 100, text)
        }
    }

    func testEmojiKeepNativeColorsWithCustomFontAndTextGradient() throws {
        var title = try clip("Hello 🌈 👋🏽")
        title.style.fontName = "Helvetica-Bold"
        title.style.isBold = true
        title.color = .init(red: 0, green: 1, blue: 0)
        title.gradient = .init(start: .white, end: .white)
        title.strokeWidth = 3
        title.backgroundOpacity = 0.5
        title.shadowOpacity = 0.5
        title.glowOpacity = 0.2
        title.curve = 0.45
        // The letter fill is white, so any colourful pixels came from emoji.
        XCTAssertGreaterThan(try coloredPixelCount(TextRenderer.image(title, canvas: canvas)), 100)
    }

    func testComplexEmojiAreRevealedAsWholeGraphemeClusters() throws {
        let title = try clip("A👨‍👩‍👧‍👦👋🏽🇵🇰1️⃣B")
        let layout = TextRenderer.layout(title, canvas: canvas, collectingElements: true)
        XCTAssertEqual(Set(layout.colorGlyphs.map(\.cluster)), Set([1, 2, 3, 4]))

        var resolved = ResolvedTextClip(clip: title)
        resolved.effects.glyphStates = (0..<title.text.count).map { _ in TextGlyphState(opacity: 0) }
        XCTAssertEqual(try coloredPixelCount(TextRenderer.image(resolved, canvas: canvas)), 0)
        resolved.effects.glyphStates?[1] = .neutral
        let revealed = try coloredPixelCount(TextRenderer.image(resolved, canvas: canvas))
        XCTAssertGreaterThan(revealed, 100)
        XCTAssertLessThan(revealed, try coloredPixelCount(TextRenderer.image(title, canvas: canvas)))
    }

    func testAnimatedEmojiMoveAndExportAtTheAuthoredScale() throws {
        let title = try clip("🌈")
        var resolved = ResolvedTextClip(clip: title)
        resolved.effects.glyphStates = [.init(offsetX: 45, offsetY: 20, rotationDegrees: 15)]
        let still = try XCTUnwrap(TextRenderer.image(title, canvas: canvas))
        let animated = try XCTUnwrap(TextRenderer.image(resolved, canvas: canvas))
        let context = CIContext()
        let stillPixels = try pixels(still, context: context)
        let animatedPixels = try pixels(animated, context: context)
        XCTAssertNotEqual(stillPixels, animatedPixels)
        XCTAssertGreaterThan(try coloredPixelCount(animated), 100)

        let export = try XCTUnwrap(TextRenderer.image(resolved,
            canvas: CGSize(width: 1600, height: 900), authoredCanvas: canvas))
        XCTAssertEqual(export.extent.width, animated.extent.width * 2, accuracy: 0.001)
        XCTAssertEqual(export.extent.height, animated.extent.height * 2, accuracy: 0.001)
        XCTAssertEqual(export.extent.midX, animated.extent.midX * 2, accuracy: 0.001)
        XCTAssertEqual(export.extent.midY, animated.extent.midY * 2, accuracy: 0.001)
    }

    private func coloredPixelCount(_ image: CIImage?) throws -> Int {
        let rgba = try pixels(XCTUnwrap(image), context: CIContext())
        return stride(from: 0, to: rgba.count, by: 4).reduce(0) { count, offset in
            let rgb = [rgba[offset], rgba[offset + 1], rgba[offset + 2]]
            return count + (rgba[offset + 3] > 50 && Int(rgb.max()!) - Int(rgb.min()!) > 40 ? 1 : 0)
        }
    }

    private func pixels(_ image: CIImage, context: CIContext) throws -> [UInt8] {
        let rect = CGRect(origin: .zero, size: canvas)
        let cg = try XCTUnwrap(context.createCGImage(image, from: rect))
        var rgba = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let bitmap = try XCTUnwrap(CGContext(data: bytes.baseAddress,
                width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            bitmap.draw(cg, in: rect)
        }
        return rgba
    }
}
