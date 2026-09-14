import Foundation
import CoreImage
import CoreText
import ImageIO

@main struct ValidateText {
    static func main() throws {
        let canvas = CGSize(width: 1080, height: 1920)
        var clip = TextClip(placement: .init(id: UUID(), trackID: UUID(), timelineStart: .zero, duration: try .seconds(3)))
        clip.text = "Visible Text\nSecond line"; clip.style.fontSize = 100
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let baseline = try render(clip, canvas, context)
        let bounds = inkBounds(baseline)
        precondition(bounds.width > 100 && bounds.height > 100, "Text is missing")
        precondition(abs(bounds.midX-canvas.width/2) < 30 && abs(bounds.midY-canvas.height/2) < 30, "Default text is not centered")
        var moved = clip; moved.transform.positionX = 0.25; moved.transform.positionY = 0.25
        let movedBounds = inkBounds(try render(moved, canvas, context))
        precondition(abs(movedBounds.midX-canvas.width*0.25) < 35 && abs(movedBounds.midY-canvas.height*0.25) < 35)
        moved = clip; moved.transform.rotationDegrees = 90
        let rotated = inkBounds(try render(moved, canvas, context))
        precondition(abs(rotated.width-bounds.height) < 10, "Rotation not applied")
        var styled = clip; styled.style.isBold = true; styled.style.isItalic = true; styled.style.isUnderlined = true
        let traitsImage = try render(styled, canvas, context)
        precondition(tryPixels(traitsImage) != tryPixels(baseline), "Font traits did not change pixels")
        styled = clip; styled.strokeWidth = 8; styled.backgroundOpacity = 0.6; styled.cornerRadius = 18
        styled.shadowOpacity = 0.7; styled.glowOpacity = 0.5; styled.decoration = .init(padding: 20, shadowColor: .black, glowColor: .init(red: 1, green: 0, blue: 0), glowRadius: 25)
        let decorative = try render(styled, canvas, context)
        precondition(tryPixels(decorative) != tryPixels(baseline))
        let url = URL(fileURLWithPath: "/tmp/gradelab-text-verified.png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        let backdrop = CIImage(color: CIColor(red: 0.12, green: 0.12, blue: 0.12)).cropped(to: CGRect(origin: .zero, size: canvas))
        let displayImage = context.createCGImage(TextRenderer.image(styled, canvas: canvas)!.composited(over: backdrop), from: backdrop.extent)!
        CGImageDestinationAddImage(destination, displayImage, nil); precondition(CGImageDestinationFinalize(destination))
        clip.text = "Arc follows glyphs"; clip.curve = 0.65
        let up = try render(clip, canvas, context)
        clip.curve = -0.65
        let down = try render(clip, canvas, context)
        precondition(tryPixels(up) != tryPixels(down))
        precondition(inkBounds(up).width > 100 && inkBounds(down).width > 100)
        clip.opacity = 0
        let transparentImage = try render(clip, canvas, context)
        precondition(inkBounds(transparentImage).isNull, "Zero opacity is not transparent")

        // Background hugs the glyphs instead of spanning the whole wrapping width.
        var boxed = TextClip(placement: .init(id: UUID(), trackID: UUID(), timelineStart: .zero, duration: try .seconds(3)))
        boxed.text = "Hi"; boxed.style.fontSize = 90; boxed.style.layoutWidth = 0.9
        boxed.decoration = .init(padding: 20)
        var unboxed = boxed
        boxed.backgroundOpacity = 1; boxed.backgroundColor = .init(red: 0, green: 0.4, blue: 1)
        let boxedBounds = inkBounds(try render(boxed, canvas, context))
        let glyphBounds = inkBounds(try render(unboxed, canvas, context))
        let wrapWidth = canvas.width*0.9
        precondition(boxedBounds.width < wrapWidth*0.6, "Background still spans the wrapping width: \(boxedBounds.width) of \(wrapWidth)")
        precondition(boxedBounds.width >= glyphBounds.width, "Background is narrower than the glyphs")
        precondition(boxedBounds.width-glyphBounds.width < 140, "Background is far wider than the requested padding")

        // Gradient fill follows the requested axis and replaces the flat colour.
        unboxed.text = "Gradient"; unboxed.style.fontSize = 150
        let flat = try render(unboxed, canvas, context)
        var vertical = unboxed
        vertical.gradient = .init(start: .init(red: 1, green: 0, blue: 0), end: .init(red: 0, green: 0, blue: 1), angleDegrees: 90)
        let verticalImage = try render(vertical, canvas, context)
        precondition(tryPixels(verticalImage) != tryPixels(flat), "Gradient did not change pixels")
        let ink = inkBounds(verticalImage)
        let band = ink.height/3
        let upper = averageColor(verticalImage, CGRect(x: ink.minX, y: ink.minY, width: ink.width, height: band))
        let lower = averageColor(verticalImage, CGRect(x: ink.minX, y: ink.maxY-band, width: ink.width, height: band))
        precondition(upper.blue > upper.red+40, "Gradient end colour is missing at the top: \(upper)")
        precondition(lower.red > lower.blue+40, "Gradient start colour is missing at the bottom: \(lower)")
        var horizontal = vertical; horizontal.gradient?.angleDegrees = 0
        let horizontalImage = try render(horizontal, canvas, context)
        let span = inkBounds(horizontalImage)
        let left = averageColor(horizontalImage, CGRect(x: span.minX, y: span.minY, width: span.width/3, height: span.height))
        let right = averageColor(horizontalImage, CGRect(x: span.maxX-span.width/3, y: span.minY, width: span.width/3, height: span.height))
        precondition(left.red > left.blue+40 && right.blue > right.red+40, "Gradient angle is ignored: \(left) \(right)")

        // Alignment ranges lines inside the block; it must not slide the block off its anchor.
        var aligned = unboxed; aligned.text = "Text"; aligned.style.fontSize = 90; aligned.gradient = nil
        var centres: [CGFloat] = []
        var rasters: [[UInt8]] = []
        for alignment in [TextStyle.Alignment.left, .center, .right] {
            aligned.style.alignment = alignment
            let image = try render(aligned, canvas, context)
            centres.append(inkBounds(image).midX); rasters.append(tryPixels(image))
        }
        precondition(centres.allSatisfy { abs($0-canvas.width/2) < 12 }, "Alignment moves the block off its anchor: \(centres)")
        var ragged = aligned; ragged.text = "A much longer first line\nshort"
        ragged.style.alignment = .left
        let leftRagged = tryPixels(try render(ragged, canvas, context))
        ragged.style.alignment = .right
        let rightRagged = tryPixels(try render(ragged, canvas, context))
        precondition(leftRagged != rightRagged, "Alignment no longer ranges multiline text")

        // The background box is centred on the line box and does not jump between words
        // that have ascenders/descenders and words that do not.
        func box(_ text: String) throws -> CGRect {
            var clip = aligned; clip.style.alignment = .center; clip.text = text
            clip.backgroundOpacity = 1; clip.backgroundColor = .init(red: 1, green: 0.9, blue: 0)
            clip.decoration = .init(padding: 12)
            return inkBounds(try render(clip, canvas, context))
        }
        func glyphs(_ text: String) throws -> CGRect {
            var clip = aligned; clip.style.alignment = .center; clip.text = text
            return inkBounds(try render(clip, canvas, context))
        }
        let plainBox = try box("Text"), capsBox = try box("TEXT"), descenderBox = try box("Typography")
        precondition(abs(plainBox.minY-capsBox.minY) < 3 && abs(plainBox.maxY-capsBox.maxY) < 3
            && abs(plainBox.minY-descenderBox.minY) < 3 && abs(plainBox.maxY-descenderBox.maxY) < 3,
            "Background height depends on which letters were typed")
        let plainGlyphs = try glyphs("Text")
        let above = plainGlyphs.minY-plainBox.minY, below = plainBox.maxY-plainGlyphs.maxY
        precondition(abs(above-below) < 15, "Text is not vertically centred in its background: \(above) above, \(below) below")

        print("PASS: canvas-centered multiline text, normalized placement, rotation, actual font traits, underline, stroke/background/shadow/glow, opposite arcs, opacity, glyph-hugging background width, anchored alignment, vertically centred stable background box and directional gradient fill. Image: \(url.path)")
    }
    static func render(_ clip: TextClip, _ canvas: CGSize, _ context: CIContext) throws -> CGImage {
        guard let image = TextRenderer.image(clip, canvas: canvas), let cg = context.createCGImage(image, from: CGRect(origin: .zero, size: canvas)) else { throw TimelineError.invalid("No raster produced") }; return cg
    }
    static func tryPixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width*image.height*4)
        data.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }
    /// Mean colour of the opaque pixels inside a region, in top-down raster rows.
    static func averageColor(_ image: CGImage, _ rect: CGRect) -> (red: Int, green: Int, blue: Int) {
        let data = tryPixels(image)
        var totals = (0, 0, 0), count = 0
        for y in max(0, Int(rect.minY))..<min(image.height, Int(rect.maxY)) {
            for x in max(0, Int(rect.minX))..<min(image.width, Int(rect.maxX)) {
                let offset = (y*image.width+x)*4
                guard data[offset+3] > 200 else { continue }
                totals.0 += Int(data[offset]); totals.1 += Int(data[offset+1]); totals.2 += Int(data[offset+2]); count += 1
            }
        }
        guard count > 0 else { return (0, 0, 0) }
        return (totals.0/count, totals.1/count, totals.2/count)
    }
    static func inkBounds(_ image: CGImage) -> CGRect {
        let data = tryPixels(image); var minX = image.width, minY = image.height, maxX = -1, maxY = -1
        for y in 0..<image.height { for x in 0..<image.width where data[(y*image.width+x)*4+3] > 10 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        return maxX < 0 ? .null : CGRect(x: minX, y: minY, width: maxX-minX+1, height: maxY-minY+1)
    }
}
