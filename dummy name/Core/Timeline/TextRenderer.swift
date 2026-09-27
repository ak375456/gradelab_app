import Foundation
import CoreGraphics
import CoreImage
import CoreText

/// Shared, screen-independent CoreText renderer. All dimensions are canvas units.
/// Glyph paths preserve shaping, ligatures and real font traits, including on arcs.
enum TextRenderer {
    /// One drawn piece of the title, already positioned in layout space.
    ///
    /// Kept so a per-glyph animation can move, scale and fade pieces of the
    /// title WITHOUT re-typesetting it: the shaping, the ligatures and the
    /// kerning are all decided once, here, and animation only transforms the
    /// outlines afterwards.
    struct Element {
        let path: CGPath
        /// Which grapheme cluster of the case-mapped string this belongs to,
        /// which is the order a typewriter reveals in. A ligature carries its
        /// cluster's first index, so "fi" appears whole; a ZWJ emoji family is
        /// one cluster, so it never half-appears.
        let cluster: Int
        /// Pivot for a per-glyph scale or rotation.
        let center: CGPoint
    }
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
        /// Empty unless something asked for per-glyph animation.
        var elements: [Element] = []
    }

    /// The string CoreText is actually handed, after the case mode. Shared so
    /// the animator counts clusters on exactly what gets laid out.
    static func displayText(_ clip: TextClip) -> String {
        switch clip.style.caseMode {
        case .uppercase: clip.text.uppercased()
        case .lowercase: clip.text.lowercased()
        case .title: clip.text.capitalized
        case .original: clip.text
        }
    }

    /// Maps each UTF-16 offset of the laid-out string to its grapheme cluster
    /// ordinal. CoreText reports glyph provenance as UTF-16 offsets, and only a
    /// cluster is a safe thing to reveal or hide on its own.
    private static func clusterOrdinals(_ text: String) -> [Int] {
        var ordinals = [Int](repeating: 0, count: text.utf16.count)
        var offset = 0, cluster = 0
        for character in text {
            for _ in 0..<character.utf16.count {
                if offset < ordinals.count { ordinals[offset] = cluster }
                offset += 1
            }
            cluster += 1
        }
        return ordinals
    }
    private struct Cached {
        let clip: TextClip; let canvas: CGSize; let image: CIImage; let layout: Layout
        /// What the raster actually occupies, so the cache is bounded by memory
        /// rather than by a count that says nothing about size.
        var bytes: Int { Int(max(0, image.extent.width) * max(0, image.extent.height)) * 4 }
    }
    private static let lock = NSLock()
    private static var cache: [UUID: Cached] = [:]
    /// Least-recently-used first.
    private static var order: [UUID] = []
    private static let cacheBudget = 48 * 1024 * 1024

    /// Files a raster and drops the oldest until the cache is inside its
    /// budget.
    ///
    /// A count was the wrong unit, and six was the wrong count. The limit used
    /// to be `if cache.count >= 6 { cache.removeAll() }`, so a timeline with
    /// eleven titles threw away every cached raster the moment a seventh was
    /// reached — and then re-rasterized glyphs, gradients, strokes and shadows
    /// from scratch on the next frame, over and over. Ordering by age and
    /// measuring the actual pixels keeps the working set and bounds the memory.
    private static func remember(_ entry: Cached, for id: UUID) {
        cache[id] = entry
        order.removeAll { $0 == id }
        order.append(id)
        var total = cache.values.reduce(0) { $0 + $1.bytes }
        while total > cacheBudget, order.count > 1, let oldest = order.first {
            total -= cache[oldest]?.bytes ?? 0
            cache.removeValue(forKey: oldest)
            order.removeFirst()
        }
    }

    /// Releases every cached raster. Called when the system reports memory
    /// pressure: a dropped raster costs one re-render, which is always better
    /// than being killed.
    static func purge() {
        lock.lock(); cache.removeAll(); order.removeAll(); lock.unlock()
    }

    /// `elements` costs a kept reference per glyph, so it is only collected when
    /// a per-glyph animation is actually going to use them.
    static func layout(_ clip: TextClip, canvas: CGSize, collectingElements: Bool = false) -> Layout {
        FontRegistry.shared.prepare()
        let size = CGFloat(clip.style.fontSize)
        let font = FontRegistry.shared.variant(clip.style.fontName, size: size, bold: clip.style.isBold, italic: clip.style.isItalic)
            ?? FontRegistry.shared.baseFont(clip.style.fontName, size: size)
        let text = displayText(clip)
        let ordinals = collectingElements ? clusterOrdinals(text) : []
        var elements: [Element] = []
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
            // The underline belongs to its whole line, so it joins the line's
            // last cluster: with a typewriter it completes as the line does,
            // rather than appearing under letters that are not there yet.
            var lineFirstCluster = -1, lineLastCluster = -1
            let curve = CGFloat(clip.curve)
            let curvature = abs(curve) > 0.001 ? curve * .pi / max(size, lineWidth) : 0
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
                let count = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                var stringIndices = [CFIndex](repeating: 0, count: count)
                if collectingElements {
                    CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &stringIndices)
                }
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
                    if collectingElements, let placed = glyph.copy(using: &transform) {
                        let offset = stringIndices[i]
                        let cluster = offset >= 0 && offset < ordinals.count ? ordinals[offset] : max(lineFirstCluster, 0)
                        let box = placed.boundingBoxOfPath
                        // A space has no outline to measure, so it falls back to
                        // its pen position rather than an empty rect at the origin.
                        let center = box.isNull || box.isEmpty
                            ? CGPoint(x: left+gx, y: baseline+positions[i].y)
                            : CGPoint(x: box.midX, y: box.midY)
                        elements.append(Element(path: placed, cluster: cluster, center: center))
                        lineLastCluster = max(lineLastCluster, cluster)
                        if lineFirstCluster < 0 { lineFirstCluster = cluster }
                    }
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
                let drawn = curvature == 0 ? underline : underline.copy(strokingWithWidth: thickness, lineCap: .round, lineJoin: .round, miterLimit: 2)
                path.addPath(drawn)
                if collectingElements {
                    let box = drawn.boundingBoxOfPath
                    elements.append(Element(path: drawn, cluster: max(lineLastCluster, 0),
                                            center: box.isNull ? .zero : CGPoint(x: box.midX, y: box.midY)))
                }
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
        return .init(path: path, bounds: bounds, ink: ink, fittedBounds: fitted, elements: elements)
    }
    static func placement(_ clip: TextClip, bounds: CGRect, canvas: CGSize) -> CGAffineTransform {
        clip.transform.placement(bounds: bounds, canvas: canvas)
    }
    /// Renders authored text into a composition surface.
    ///
    /// Text point sizes, strokes, shadows and decoration measurements are stored
    /// in the editor's base-preview pixels. Export compositions are often larger
    /// than that authoring canvas, while low-quality playback can be smaller.
    /// Render in the authored coordinate system first and scale the finished
    /// layer once so every output preserves what the editor showed.
    /// A title with no animation presets. Keeps the previewing and thumbnail
    /// call sites unchanged.
    static func image(
        _ clip: TextClip,
        canvas: CGSize,
        authoredCanvas: CGSize? = nil
    ) -> CIImage? {
        image(ResolvedTextClip(clip: clip), canvas: canvas, authoredCanvas: authoredCanvas)
    }

    static func image(
        _ resolved: ResolvedTextClip,
        canvas: CGSize,
        authoredCanvas: CGSize? = nil
    ) -> CIImage? {
        let clip = resolved.clip
        let effects = resolved.effects
        if let authoredCanvas,
           authoredCanvas.width > 0, authoredCanvas.height > 0,
           authoredCanvas != canvas {
            guard let authored = image(resolved, canvas: authoredCanvas) else { return nil }
            return authored.transformed(by: .init(
                scaleX: canvas.width / authoredCanvas.width,
                y: canvas.height / authoredCanvas.height
            ))
        }
        guard !clip.text.isEmpty else { return nil }
        // Per-glyph animation changes the picture on every frame, so it neither
        // reads nor writes the cache: a hit would be stale, and a write would
        // evict rasters that are still worth keeping. Everything else — every
        // whole-title move, scale, rotation and fade — stays fully cached,
        // because the key already ignores transform and opacity.
        let states = effects.glyphStates
        let cacheable = states == nil
        var key = clip; key.transform = .init(); key.opacity = 1
        key.placement = .init(id: clip.id, trackID: clip.placement.trackID, timelineStart: .zero, duration: .zero)
        lock.lock()
        let existing = cacheable ? cache[clip.id] : nil
        // A hit is a use: without this the order would record only when each
        // raster was first made, and eviction would drop the one being read
        // every frame in favour of one nothing has touched since.
        if existing != nil { order.removeAll { $0 == clip.id }; order.append(clip.id) }
        lock.unlock()
        let matches = existing?.clip == key && existing?.canvas == canvas
        let geometry = matches ? existing!.layout
            : layout(clip, canvas: canvas, collectingElements: states != nil)
        var raster: CIImage
        if let existing, existing.clip == key, existing.canvas == canvas { raster = existing.image }
        else {
            let decoration = clip.decoration ?? .init()
            let pad = max(CGFloat(decoration.padding), CGFloat(clip.strokeWidth))
            // Hug the glyphs: the wrap box is far wider than the text on short lines.
            let bounds = geometry.fittedBounds.insetBy(dx: -pad, dy: -pad)
            // Per-glyph animation lifts and scales letters out of the authored
            // box, so the raster needs room for wherever they travel.
            let travel = states.map { states -> CGFloat in
                states.reduce(0) { CGFloat(max(Double($0), abs($1.offsetX) + abs($1.offsetY)
                    + max(0, $1.scale-1)*clip.style.fontSize)) }
            } ?? 0
            let extra = max(2, max(clip.shadowRadius*3+abs(clip.shadowOffsetX)+abs(clip.shadowOffsetY), decoration.glowRadius*3)) + travel
            let pixels = bounds.union(geometry.path.boundingBoxOfPath).insetBy(dx: -extra, dy: -extra).integral
            let quality = min(1, min(8192/max(pixels.width, pixels.height), sqrt(16_000_000/max(1, pixels.width*pixels.height))))
            guard let context = CGContext(data: nil, width: max(1, Int(ceil(pixels.width*quality))),
                height: max(1, Int(ceil(pixels.height*quality))), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.scaleBy(x: quality, y: quality)
            context.translateBy(x: -pixels.minX, y: -pixels.minY)
            // The title is drawn as a list of units. Without per-glyph animation
            // there is exactly ONE unit — the whole combined path at full alpha —
            // so this is the same two draws it has always been.
            var units: [(path: CGPath, alpha: Double)] = [(geometry.path, 1)]
            if let states, !geometry.elements.isEmpty {
                units = geometry.elements.compactMap { element in
                    let state = states[min(max(element.cluster, 0), states.count-1)]
                    guard state.opacity > 0.001 else { return nil }
                    guard !state.isNeutral else { return (element.path, 1) }
                    // Scale and rotate about the glyph's own middle, then carry
                    // it to its offset. Pivoting anywhere else swings letters
                    // around the canvas instead of animating them in place.
                    var transform = CGAffineTransform(translationX: element.center.x+state.offsetX,
                                                      y: element.center.y+state.offsetY)
                        .rotated(by: state.rotationDegrees * .pi/180)
                        .scaledBy(x: state.scale, y: state.scale)
                        .translatedBy(x: -element.center.x, y: -element.center.y)
                    guard let moved = element.path.copy(using: &transform) else { return nil }
                    return (moved, state.opacity)
                }
            }
            func fillGlyphs(_ path: CGPath) {
                guard let gradient = clip.gradient, let ramp = ramp(gradient) else {
                    context.addPath(path); context.setFillColor(cgColor(clip.color)); context.fillPath(); return
                }
                // Clip to the glyph outlines so the ramp follows the letters, not a rectangle.
                // Measured on the WHOLE title even when one glyph is being drawn,
                // so the ramp stays continuous across the letters.
                let box = geometry.ink.isNull ? geometry.bounds : geometry.ink
                context.saveGState()
                context.addPath(path); context.clip()
                let angle = gradient.angleDegrees * .pi/180
                let radius = (abs(cos(angle))*box.width + abs(sin(angle))*box.height)/2
                let axis = CGPoint(x: cos(angle)*radius, y: sin(angle)*radius)
                context.drawLinearGradient(ramp,
                    start: CGPoint(x: box.midX-axis.x, y: box.midY-axis.y),
                    end: CGPoint(x: box.midX+axis.x, y: box.midY+axis.y),
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                context.restoreGState()
            }
            // Every stroke, then every fill — the order a single path already
            // produced, so one letter's outline cannot sit on top of another
            // letter's face.
            if clip.strokeWidth > 0 {
                for unit in units {
                    context.saveGState()
                    context.setAlpha(unit.alpha)
                    context.addPath(unit.path)
                    context.setStrokeColor(cgColor(clip.strokeColor)); context.setLineWidth(clip.strokeWidth*2)
                    context.setLineJoin(.round); context.strokePath()
                    context.restoreGState()
                }
            }
            for unit in units {
                context.saveGState()
                context.setAlpha(unit.alpha)
                fillGlyphs(unit.path)
                context.restoreGState()
            }
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
            if cacheable {
                lock.lock()
                remember(.init(clip: key, canvas: canvas, image: raster, layout: geometry), for: clip.id)
                lock.unlock()
            }
        }
        // Wipe and blur act on the FINISHED raster, in the title's own layout
        // space — so a rotated title still wipes along its reading direction —
        // and after the cache, so neither of them ever invalidates it.
        if effects.wipes {
            raster = wiped(raster, bounds: geometry.fittedBounds,
                           progress: effects.wipeProgress, direction: effects.wipeDirection)
        }
        if effects.blurs {
            let radius = effects.blurRadius
            raster = raster.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": radius])
                .cropped(to: raster.extent.insetBy(dx: -radius*3, dy: -radius*3))
        }
        return raster.transformed(by: placement(clip, bounds: geometry.fittedBounds, canvas: canvas))
            .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: clip.opacity)])
    }

    /// Reveals the rendered title spatially, with a soft leading edge.
    ///
    /// A matte, not a substring: the glyphs are never re-laid out and never
    /// move, so a half-wiped word is the real word with half of it hidden.
    private static func wiped(_ image: CIImage, bounds: CGRect,
                              progress: Double, direction: TextWipeDirection) -> CIImage {
        let box = bounds.isNull || bounds.isEmpty ? image.extent : bounds
        guard box.width > 0, box.height > 0 else { return image }
        let horizontal = direction == .leftToRight || direction == .rightToLeft
        let span = horizontal ? box.width : box.height
        let feather = max(span * 0.08, 1)
        // Travel far enough that 0 hides everything and 1 shows everything,
        // the feather included at both ends.
        let distance = span + feather * 2
        let travelled = min(max(progress, 0), 1) * distance
        let axis: (CGPoint, CGPoint)
        switch direction {
        case .leftToRight:
            // White behind the edge, clear ahead of it: the title is revealed
            // from the left. `CILinearGradient` holds colour0 everywhere beyond
            // point0, so point0 has to sit on the REVEALED side.
            let edge = box.minX - feather + travelled
            axis = (CGPoint(x: edge, y: box.midY), CGPoint(x: edge + feather, y: box.midY))
        case .rightToLeft:
            let edge = box.maxX + feather - travelled
            axis = (CGPoint(x: edge, y: box.midY), CGPoint(x: edge + feather, y: box.midY))
        case .bottomToTop:
            let edge = box.minY - feather + travelled
            axis = (CGPoint(x: box.midX, y: edge), CGPoint(x: box.midX, y: edge + feather))
        case .topToBottom:
            let edge = box.maxY + feather - travelled
            axis = (CGPoint(x: box.midX, y: edge), CGPoint(x: box.midX, y: edge + feather))
        }
        guard let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(cgPoint: axis.0),
            "inputPoint1": CIVector(cgPoint: axis.1),
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
            "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0)
        ])?.outputImage else { return image }
        let extent = image.extent
        return image.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: extent),
            kCIInputMaskImageKey: gradient.cropped(to: extent)
        ]).cropped(to: extent)
    }
    private static func ramp(_ gradient: GradientFill) -> CGGradient? {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [cgColor(gradient.start), cgColor(gradient.end)] as CFArray, locations: [0, 1])
    }
    private static func cgColor(_ color: RGBAColor, opacity: Double = 1) -> CGColor {
        CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha*opacity)
    }
}
