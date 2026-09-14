import Foundation
import CoreGraphics
import CoreImage
import CoreText

/// Shared, screen-independent CoreText renderer. All dimensions are canvas units.
/// Glyph paths preserve shaping, ligatures and real font traits, including on arcs.
enum TextRenderer {
    struct Layout {
        let path: CGPath
        /// Wrapping box: the line-breaking width, not the visible extent.
        let bounds: CGRect
        /// Glyph ink only.
        let ink: CGRect
        /// What the user sees: ink width, and the typographic line box vertically so the
        /// box does not jump between words with and without ascenders or descenders.
        /// Anchors, placement, backgrounds and the selection frame all use this.
        let fittedBounds: CGRect
    }
    private struct Cached { let clip: TextClip; let canvas: CGSize; let image: CIImage; let layout: Layout }
    private static let lock = NSLock()
    private static var cache: [UUID: Cached] = [:]
    static func layout(_ clip: TextClip, canvas: CGSize) -> Layout {
        FontRegistry.shared.prepare()
        let size = CGFloat(clip.style.fontSize)
        let font = FontRegistry.shared.variant(clip.style.fontName, size: size, bold: clip.style.isBold, italic: clip.style.isItalic)
            ?? FontRegistry.shared.baseFont(clip.style.fontName, size: size)
        var text = clip.text
        switch clip.style.caseMode {
        case .uppercase: text = text.uppercased()
        case .lowercase: text = text.lowercased()
        case .title: text = text.capitalized
        case .original: break
        }
        // Explicit per-line alignment avoids a huge artificial text rectangle.
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTKernAttributeName as String): clip.style.characterSpacing
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let width = max(16, canvas.width * clip.style.layoutWidth)
        let length = attributed.length
        let path = CGMutablePath()
        var index = 0, baseline: CGFloat = 0, lastBaseline: CGFloat = 0
        while index < length {
            lastBaseline = baseline
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, index, Double(width)))
            var line = CTTypesetterCreateLine(typesetter, CFRange(location: index, length: min(count, length-index)))
            let last = index+count >= length
            let lineString = (text as NSString).substring(with: NSRange(location: index, length: min(count, length-index)))
            if clip.style.alignment == .justified && !last && !lineString.contains("\n"),
               let justified = CTLineCreateJustifiedLine(line, 1, Double(width)) { line = justified }
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let left: CGFloat
            switch clip.style.alignment {
            case .left, .justified: left = 0
            case .center: left = (width-lineWidth)/2
            case .right: left = width-lineWidth
            }
            let curve = CGFloat(clip.curve)
            let curvature = abs(curve) > 0.001 ? curve * .pi / max(size, lineWidth) : 0
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
                let count = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                for i in 0..<count {
                    guard let glyph = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
                    let gx = positions[i].x
                    var transform: CGAffineTransform
                    if curvature != 0 {
                        let distance = gx-lineWidth/2
                        let angle = distance*curvature
                        transform = CGAffineTransform(rotationAngle: angle)
                            .concatenating(.init(translationX: left+lineWidth/2+sin(angle)/curvature,
                                y: baseline+positions[i].y+(1-cos(angle))/curvature))
                    } else { transform = .init(translationX: left+gx, y: baseline+positions[i].y) }
                    path.addPath(glyph, transform: transform)
                }
            }
            if clip.style.isUnderlined {
                let underline = CGMutablePath()
                let y = baseline + CTFontGetUnderlinePosition(font)
                let thickness = max(1, CTFontGetUnderlineThickness(font))
                if curvature == 0 { underline.addRect(CGRect(x: left, y: y, width: lineWidth, height: thickness)) }
                else {
                    for step in 0...100 {
                        let distance = lineWidth*(CGFloat(step)/100-0.5), a = distance*curvature
                        let point = CGPoint(x: left+lineWidth/2+sin(a)/curvature, y: y+(1-cos(a))/curvature)
                        if step == 0 { underline.move(to: point) } else { underline.addLine(to: point) }
                    }
                }
                path.addPath(curvature == 0 ? underline : underline.copy(strokingWithWidth: thickness, lineCap: .round, lineJoin: .round, miterLimit: 2))
            }
            baseline -= CTFontGetAscent(font)+CTFontGetDescent(font)+CTFontGetLeading(font)+CGFloat(clip.style.lineSpacing)
            index += count
        }
        let ink = path.boundingBoxOfPath
        // Preserve the wrapping box for consistent multiline alignment.
        let bounds = CGRect(x: 0, y: ink.isNull ? -size*0.2 : ink.minY, width: width,
            height: max(size, ink.isNull ? size : ink.height))
        // Typographic line box: top of the first line's ascent to the last line's descent.
        // Unioned with the ink so arcs and unusual glyphs are never cropped out of it.
        let top = CTFontGetAscent(font), bottom = lastBaseline-CTFontGetDescent(font)
        let fitted: CGRect
        if ink.isNull || ink.width <= 0 {
            fitted = CGRect(x: 0, y: bottom, width: width, height: max(size, top-bottom))
        } else {
            let minY = min(bottom, ink.minY), maxY = max(top, ink.maxY)
            fitted = CGRect(x: ink.minX, y: minY, width: ink.width, height: maxY-minY)
        }
        return .init(path: path, bounds: bounds, ink: ink, fittedBounds: fitted)
    }
    static func placement(_ clip: TextClip, bounds: CGRect, canvas: CGSize) -> CGAffineTransform {
        CGAffineTransform(translationX: -(bounds.minX+bounds.width*clip.transform.anchorX),
            y: -(bounds.maxY-bounds.height*clip.transform.anchorY))
            .concatenating(.init(scaleX: clip.transform.scale*clip.transform.widthScale, y: clip.transform.scale*clip.transform.heightScale))
            .concatenating(.init(rotationAngle: -clip.transform.rotationDegrees * .pi/180))
            .concatenating(.init(translationX: clip.transform.positionX*canvas.width, y: (1-clip.transform.positionY)*canvas.height))
    }
    static func image(_ clip: TextClip, canvas: CGSize) -> CIImage? {
        guard !clip.text.isEmpty else { return nil }
        // Cache raster content; dragging/resizing/rotating only changes the CI transform.
        var key = clip; key.transform = .init(); key.opacity = 1
        key.placement = .init(id: clip.id, trackID: clip.placement.trackID, timelineStart: .zero, duration: .zero)
        lock.lock()
        let existing = cache[clip.id]
        lock.unlock()
        let matches = existing?.clip == key && existing?.canvas == canvas
        let geometry = matches ? existing!.layout : layout(clip, canvas: canvas)
        let raster: CIImage
        if let existing, existing.clip == key, existing.canvas == canvas { raster = existing.image }
        else {
            let decoration = clip.decoration ?? .init()
            let pad = max(CGFloat(decoration.padding), CGFloat(clip.strokeWidth))
            // Hug the glyphs: the wrap box is far wider than the text on short lines.
            let bounds = geometry.fittedBounds.insetBy(dx: -pad, dy: -pad)
            let extra = max(2, max(clip.shadowRadius*3+abs(clip.shadowOffsetX)+abs(clip.shadowOffsetY), decoration.glowRadius*3))
            let pixels = bounds.union(geometry.path.boundingBoxOfPath).insetBy(dx: -extra, dy: -extra).integral
            let quality = min(1, min(8192/max(pixels.width, pixels.height), sqrt(16_000_000/max(1, pixels.width*pixels.height))))
            guard let context = CGContext(data: nil, width: max(1, Int(ceil(pixels.width*quality))),
                height: max(1, Int(ceil(pixels.height*quality))), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.scaleBy(x: quality, y: quality)
            context.translateBy(x: -pixels.minX, y: -pixels.minY)
            func fillGlyphs() {
                guard let gradient = clip.gradient, let ramp = ramp(gradient) else {
                    context.addPath(geometry.path); context.setFillColor(cgColor(clip.color)); context.fillPath(); return
                }
                // Clip to the glyph outlines so the ramp follows the letters, not a rectangle.
                let box = geometry.ink.isNull ? geometry.bounds : geometry.ink
                context.saveGState()
                context.addPath(geometry.path); context.clip()
                let angle = gradient.angleDegrees * .pi/180
                let radius = (abs(cos(angle))*box.width + abs(sin(angle))*box.height)/2
                let axis = CGPoint(x: cos(angle)*radius, y: sin(angle)*radius)
                context.drawLinearGradient(ramp,
                    start: CGPoint(x: box.midX-axis.x, y: box.midY-axis.y),
                    end: CGPoint(x: box.midX+axis.x, y: box.midY+axis.y),
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                context.restoreGState()
            }
            if clip.strokeWidth > 0 {
                context.addPath(geometry.path)
                context.setStrokeColor(cgColor(clip.strokeColor)); context.setLineWidth(clip.strokeWidth*2)
                context.setLineJoin(.round); context.strokePath()
            }
            fillGlyphs()
            guard let cg = context.makeImage() else { return nil }
            let glyphs = CIImage(cgImage: cg)
            context.clear(pixels)
            if clip.backgroundOpacity > 0 {
                context.setFillColor(cgColor(clip.backgroundColor, opacity: clip.backgroundOpacity))
                context.addPath(CGPath(roundedRect: bounds, cornerWidth: clip.cornerRadius, cornerHeight: clip.cornerRadius, transform: nil)); context.fillPath()
            }
            guard let background = context.makeImage() else { return nil }
            var composed = CIImage(cgImage: background)
            // Tint and blur the glyph alpha separately: never redraw the fill for
            // each decoration, which would incorrectly increase its opacity.
            func halo(_ color: RGBAColor, opacity: Double, radius: Double) -> CIImage {
                glyphs.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity*color.alpha),
                    "inputBiasVector": CIVector(x: color.red, y: color.green, z: color.blue, w: 0)
                ]).applyingFilter("CIGaussianBlur", parameters: ["inputRadius": radius*quality])
            }
            if clip.shadowOpacity > 0 {
                composed = halo(decoration.shadowColor, opacity: clip.shadowOpacity, radius: clip.shadowRadius)
                    .transformed(by: .init(translationX: clip.shadowOffsetX*quality, y: -clip.shadowOffsetY*quality)).composited(over: composed)
            }
            if clip.glowOpacity > 0 {
                composed = halo(decoration.glowColor, opacity: clip.glowOpacity, radius: decoration.glowRadius).composited(over: composed)
            }
            raster = glyphs.composited(over: composed).cropped(to: glyphs.extent).transformed(by: .init(scaleX: 1/quality, y: 1/quality))
                .transformed(by: .init(translationX: pixels.minX, y: pixels.minY))
            lock.lock()
            if cache.count >= 6 { cache.removeAll() }
            cache[clip.id] = .init(clip: key, canvas: canvas, image: raster, layout: geometry)
            lock.unlock()
        }
        return raster.transformed(by: placement(clip, bounds: geometry.fittedBounds, canvas: canvas))
            .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: clip.opacity)])
    }
    private static func ramp(_ gradient: TextGradient) -> CGGradient? {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [cgColor(gradient.start), cgColor(gradient.end)] as CFArray, locations: [0, 1])
    }
    private static func cgColor(_ color: RGBAColor, opacity: Double = 1) -> CGColor {
        CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha*opacity)
    }
}
