import CoreGraphics
import CoreImage
import Foundation

/// Screen-independent shape renderer. Every dimension is in authored canvas
/// points, exactly as `TextRenderer` treats a font size, and the finished layer
/// is scaled once for the surface it is going onto — so what the editor draws is
/// what the export writes.
///
/// The placement maths is deliberately the SAME expression `TextRenderer` uses
/// rather than a second one that happens to agree: anchor, scale, rotation and
/// position have one meaning in this app, and a shape and a title dragged to the
/// same spot must land in the same spot.
enum ShapeRenderer {
    private struct Cached {
        let clip: ShapeClip; let canvas: CGSize; let image: CIImage
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


    /// The shape's own box, untransformed, origin at zero. This is the frame
    /// anchors are measured against and the frame the canvas handles draw.
    static func bounds(_ clip: ShapeClip) -> CGRect {
        CGRect(x: 0, y: 0, width: max(1, clip.width), height: max(1, clip.height))
    }

    /// The outline, in the same space as `bounds`. Y is up, as CoreGraphics has it.
    static func path(_ clip: ShapeClip) -> CGPath {
        let box = bounds(clip)
        let limit = CGFloat(clip.maximumCornerRadius)
        switch clip.kind {
        case .rectangle:
            let radius = min(max(0, clip.cornerRadius), limit)
            guard radius > 0 else { return CGPath(rect: box, transform: nil) }
            return CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil)
        case .ellipse:
            return CGPath(ellipseIn: box, transform: nil)
        case .line:
            // Always fully rounded: a capsule is what a divider or an underline
            // is, and it is the one thing a rectangle with a radius cannot be
            // without the radius being re-derived every time the size changes.
            return CGPath(roundedRect: box, cornerWidth: limit, cornerHeight: limit, transform: nil)
        case .triangle:
            let path = CGMutablePath()
            path.move(to: CGPoint(x: box.midX, y: box.maxY))
            path.addLine(to: CGPoint(x: box.maxX, y: box.minY))
            path.addLine(to: CGPoint(x: box.minX, y: box.minY))
            path.closeSubpath()
            return path
        case .polygon, .star:
            return radial(clip, in: box)
        case .arrow:
            let head = min(box.width, box.width * 0.42)
            let shaft = box.height * 0.44
            let path = CGMutablePath()
            path.addLines(between: [
                CGPoint(x: box.minX, y: box.midY - shaft/2),
                CGPoint(x: box.maxX - head, y: box.midY - shaft/2),
                CGPoint(x: box.maxX - head, y: box.minY),
                CGPoint(x: box.maxX, y: box.midY),
                CGPoint(x: box.maxX - head, y: box.maxY),
                CGPoint(x: box.maxX - head, y: box.midY + shaft/2),
                CGPoint(x: box.minX, y: box.midY + shaft/2)
            ])
            path.closeSubpath()
            return path
        }
    }

    /// Stars and polygons are the same construction: vertices on the box's
    /// inscribed ellipse, starting at the top so an odd-pointed star stands up.
    /// A star simply alternates onto a second, smaller ellipse.
    private static func radial(_ clip: ShapeClip, in box: CGRect) -> CGPath {
        let count = clip.resolvedPointCount
        let waist = clip.kind == .star ? min(0.95, max(0.05, clip.innerRadius)) : 1
        let steps = clip.kind == .star ? count * 2 : count
        let rx = box.width/2, ry = box.height/2
        let path = CGMutablePath()
        for step in 0..<steps {
            let angle = .pi/2 + Double(step) * 2 * .pi / Double(steps)
            let scale = clip.kind == .star && step % 2 == 1 ? waist : 1
            let point = CGPoint(x: box.midX + cos(angle) * rx * scale,
                                y: box.midY + sin(angle) * ry * scale)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// Canvas placement of a shape's box — the shared definition, so a shape and
    /// a title with the same transform land in the same place.
    static func placement(_ clip: ShapeClip, bounds: CGRect, canvas: CGSize) -> CGAffineTransform {
        clip.transform.placement(bounds: bounds, canvas: canvas)
    }

    /// Renders an authored shape into a composition surface.
    ///
    /// `authoredCanvas` is the coordinate system the sizes, stroke, corner
    /// radius, shadow and glow were authored in. When the surface differs — a 4K
    /// export, or a reduced-quality preview — the layer is drawn once in the
    /// authored system and scaled, which is the only way a shadow offset of four
    /// points stays four points relative to the picture.
    static func image(
        _ clip: ShapeClip,
        canvas: CGSize,
        authoredCanvas: CGSize? = nil
    ) -> CIImage? {
        if let authoredCanvas,
           authoredCanvas.width > 0, authoredCanvas.height > 0,
           authoredCanvas != canvas {
            guard let authored = image(clip, canvas: authoredCanvas) else { return nil }
            return authored.transformed(by: .init(
                scaleX: canvas.width / authoredCanvas.width,
                y: canvas.height / authoredCanvas.height
            ))
        }
        guard clip.width > 0, clip.height > 0 else { return nil }
        // A shape with nothing to draw is not an error, it is invisible.
        guard clip.fillColor.alpha > 0 || clip.gradient != nil || clip.strokeWidth > 0 else { return nil }
        let geometry = bounds(clip)
        // Cache the raster: moving, scaling and rotating only change the CI
        // transform applied afterwards, which is most of what animation does.
        var key = clip
        key.transform = .init()
        key.opacity = 1
        key.placement = .init(id: clip.id, trackID: clip.placement.trackID, timelineStart: .zero, duration: .zero)
        lock.lock()
        let existing = cache[clip.id]
        // A hit is a use: without this the order would record only when each
        // raster was first made, and eviction would drop the one being read
        // every frame in favour of one nothing has touched since.
        if existing != nil { order.removeAll { $0 == clip.id }; order.append(clip.id) }
        lock.unlock()
        let raster: CIImage
        if let existing, existing.clip == key, existing.canvas == canvas {
            raster = existing.image
        } else {
            let outline = path(clip)
            let stroke = max(0, clip.strokeWidth)
            let drawn = geometry.union(outline.boundingBoxOfPath).insetBy(dx: -stroke/2 - 1, dy: -stroke/2 - 1)
            let extra = max(2, max(clip.shadowRadius*3 + abs(clip.shadowOffsetX) + abs(clip.shadowOffsetY),
                                   clip.glowRadius*3))
            let pixels = drawn.insetBy(dx: -extra, dy: -extra).integral
            let quality = min(1, min(8192/max(pixels.width, pixels.height),
                                     sqrt(16_000_000/max(1, pixels.width*pixels.height))))
            guard let context = CGContext(data: nil,
                width: max(1, Int(ceil(pixels.width*quality))),
                height: max(1, Int(ceil(pixels.height*quality))),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.scaleBy(x: quality, y: quality)
            context.translateBy(x: -pixels.minX, y: -pixels.minY)
            if let gradient = clip.gradient, let ramp = ramp(gradient) {
                // Clip to the outline so the ramp follows the shape rather than
                // a rectangle around it.
                context.saveGState()
                context.addPath(outline)
                context.clip()
                let angle = gradient.angleDegrees * .pi/180
                let radius = (abs(cos(angle))*geometry.width + abs(sin(angle))*geometry.height)/2
                let axis = CGPoint(x: cos(angle)*radius, y: sin(angle)*radius)
                context.drawLinearGradient(ramp,
                    start: CGPoint(x: geometry.midX-axis.x, y: geometry.midY-axis.y),
                    end: CGPoint(x: geometry.midX+axis.x, y: geometry.midY+axis.y),
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                context.restoreGState()
            } else if clip.fillColor.alpha > 0 {
                context.addPath(outline)
                context.setFillColor(cgColor(clip.fillColor))
                context.fillPath()
            }
            if stroke > 0 {
                // Centred on the outline, which is what a stroke means in every
                // drawing tool. Text strokes are drawn under the glyphs at double
                // width instead, because there the stroke has to read as an
                // outline around letters rather than as a border on a figure.
                context.addPath(outline)
                context.setStrokeColor(cgColor(clip.strokeColor))
                context.setLineWidth(stroke)
                context.setLineJoin(.round)
                context.strokePath()
            }
            guard let drawnImage = context.makeImage() else { return nil }
            let figure = CIImage(cgImage: drawnImage)
            var composed = CIImage(color: .clear).cropped(to: figure.extent)
            // Tint and blur the figure's own alpha rather than redrawing it, so a
            // shadow or glow never darkens or brightens the fill it sits behind.
            func halo(_ color: RGBAColor, opacity: Double, radius: Double) -> CIImage {
                figure.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity*color.alpha),
                    "inputBiasVector": CIVector(x: color.red, y: color.green, z: color.blue, w: 0)
                ]).applyingFilter("CIGaussianBlur", parameters: ["inputRadius": radius*quality])
            }
            if clip.shadowOpacity > 0 {
                composed = halo(clip.shadowColor, opacity: clip.shadowOpacity, radius: clip.shadowRadius)
                    .transformed(by: .init(translationX: clip.shadowOffsetX*quality,
                                           y: -clip.shadowOffsetY*quality))
                    .composited(over: composed)
            }
            if clip.glowOpacity > 0 {
                composed = halo(clip.glowColor, opacity: clip.glowOpacity, radius: clip.glowRadius)
                    .composited(over: composed)
            }
            raster = figure.composited(over: composed).cropped(to: figure.extent)
                .transformed(by: .init(scaleX: 1/quality, y: 1/quality))
                .transformed(by: .init(translationX: pixels.minX, y: pixels.minY))
            lock.lock()
            remember(.init(clip: key, canvas: canvas, image: raster), for: clip.id)
            lock.unlock()
        }
        return raster.transformed(by: placement(clip, bounds: geometry, canvas: canvas))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: clip.opacity)
            ])
    }

    private static func ramp(_ gradient: GradientFill) -> CGGradient? {
        CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                   colors: [cgColor(gradient.start), cgColor(gradient.end)] as CFArray,
                   locations: [0, 1])
    }
    private static func cgColor(_ color: RGBAColor, opacity: Double = 1) -> CGColor {
        CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha*opacity)
    }
}
