import UIKit

/// Small cached SF Symbols for the canvas. Rendered once and reused, because
/// `UIImage(systemName:)` is not free and the canvas redraws on every scroll
/// tick.
enum TimelineGlyph {
    static let film = symbol("film.fill", size: 8.5, color: TimelineTheme.textPrimary)
    static let note = symbol("music.note", size: 9, color: TimelineTheme.accentBright)
    static let mutedNote = symbol("speaker.slash.fill", size: 8, color: TimelineTheme.textTertiary)
    static let image = symbol("photo.fill", size: 8.5, color: TimelineTheme.textPrimary)
    static let text = symbol("textformat", size: 8.5, color: TimelineTheme.textPrimary)
    static let shape = symbol("square.on.circle.fill", size: 8.5, color: TimelineTheme.textPrimary)
    static let lock = symbol("lock.fill", size: 8, color: TimelineTheme.lockedTint)

    private static func symbol(_ name: String, size: CGFloat, color: UIColor) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .semibold))?
            .withTintColor(color, renderingMode: .alwaysOriginal)
    }

    /// The icon that introduces a clip's name, by what the clip actually is.
    static func leading(for clip: TimelineDisplayClip, isStill: Bool) -> UIImage? {
        if clip.isAudio { return note }
        if clip.isText { return text }
        if clip.isShape { return shape }
        return isStill ? image : film
    }
}

/// Where a clip's source sits under a point on screen.
///
/// Kept as a value so the filmstrip and the waveform share one definition of
/// "which part of the source is under this column", including while a trim
/// handle is dragging and the left edge is moving.
struct TimelineSourceMapping {
    /// Source seconds at the clip's left edge.
    var sourceStart: Double
    var speed: Double
    /// The asset's own decoded range, which thumbnails and envelopes index into.
    var assetStart: Double
    var assetDuration: Double

    /// Position within the decoded asset, 0...1, `offset` points right of the
    /// clip's left edge.
    func fraction(atOffset offset: Double, pixelsPerSecond: Double) -> Double {
        let sourceTime = sourceStart + (offset / max(0.0001, pixelsPerSecond)) * speed
        let fraction = (sourceTime - assetStart) / max(0.001, assetDuration)
        return min(1, max(0, fraction))
    }
}

/// One clip's fully resolved appearance.
///
/// The canvas resolves this; the renderer never reaches back into the
/// timeline. That split is what lets a new row type — an adjustment layer, a
/// nested sequence — be drawn by describing it here rather than by adding
/// another branch inside the drawing code.
struct TimelineClipPresentation {
    var clip: TimelineDisplayClip
    /// The clip's body in canvas coordinates, already offset for its row.
    var rect: CGRect
    var title: String
    /// Length shown on the clip's duration chip.
    var duration: Double
    var isSelected = false
    /// The single selection that owns keyframe markers.
    var isFocused = false
    /// Whether this clip draws trim handles. Every selected clip does: a trim
    /// carries the whole selection, so any of their edges is a valid grab and
    /// all of them have to look like one.
    var showsTrimHandles = false
    var isLocked = false
    /// A row that is hidden or muted draws faded rather than disappearing.
    var isDimmed = false
    var isStillImage = false
    /// The two chips a clip carries. Both are preferences rather than state:
    /// an editor who knows their own footage often wants the picture and the
    /// waveform uncovered, and these are what cover them.
    var showsName = true
    var showsDuration = true
    var mapping = TimelineSourceMapping(sourceStart: 0, speed: 1, assetStart: 0, assetDuration: 1)
    var thumbnails: [UIImage] = []
    var waveform: TimelineWaveform?
    var waveformScale: CGFloat = 1
    var keyframeTimes: [Double] = []
    /// Resolved fade lengths in seconds, drawn as the wedges the mix applies.
    var fade: (rise: Double, fall: Double) = (0, 0)
}

/// How a clip's height is divided between picture, waveform and label.
///
/// Separate from drawing so hit-testing and future overlays (transition
/// handles, effect badges) can ask where a lane is without re-deriving it.
struct TimelineClipLayout {
    let body: CGRect
    let cornerRadius: CGFloat
    /// Filmstrip area. Nil for audio, drawn overlays and rows too short for a
    /// picture.
    let picture: CGRect?
    /// Waveform lane. Nil when the clip carries no audio.
    let waveform: CGRect?
    /// True when the row is too short for chips and gets a single centred name.
    let isCompact: Bool

    init(presentation: TimelineClipPresentation) {
        body = presentation.rect
        cornerRadius = presentation.clip.isDrawnOverlay
            ? TimelineMetrics.overlayCornerRadius
            : TimelineMetrics.clipCornerRadius
        let height = body.height
        isCompact = height < TimelineMetrics.minimumFilmstripHeight

        let hasAudio = presentation.clip.isAudio || presentation.clip.embeddedAudio != nil
        if presentation.clip.isAudio {
            // An audio clip is all waveform: there is no picture to share with.
            picture = nil
            waveform = body.insetBy(dx: 0, dy: isCompact ? 1 : 3)
        } else if presentation.clip.isDrawnOverlay || isCompact {
            picture = nil
            waveform = nil
        } else if hasAudio,
                  height - max(TimelineMetrics.minimumWaveformLane,
                               (height * TimelineMetrics.waveformLaneRatio).rounded())
                      >= TimelineMetrics.minimumFilmstripHeight {
            let lane = max(TimelineMetrics.minimumWaveformLane,
                           (height * TimelineMetrics.waveformLaneRatio).rounded())
            picture = CGRect(x: body.minX, y: body.minY, width: body.width, height: height - lane)
            waveform = CGRect(x: body.minX, y: body.maxY - lane, width: body.width, height: lane)
        } else {
            // Carving a lane out of a short row would leave the picture a
            // stripe. A squeezed row shows the picture and drops the waveform;
            // the row has to be tall enough for both to get both.

            picture = body
            waveform = nil
        }
    }
}

/// Draws one clip: rounded body, filmstrip, waveform lane, name and duration
/// chips, fades, trim handles and keyframes.
struct TimelineClipRenderer {
    let context: CGContext
    /// The visible content area — the canvas minus the track-header column.
    /// Culling and chip pinning both work against this, so a name chip lands
    /// at the edge of the timeline rather than underneath the headers.
    let canvas: CGRect
    let geometry: TimelineViewport
    let pixelsPerSecond: Double
    let waveformCache: TimelineWaveformCache

    private static let titleAttributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
        .foregroundColor: TimelineTheme.textPrimary
    ]
    private static let durationAttributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
        .foregroundColor: TimelineTheme.textPrimary
    ]

    func draw(_ presentation: TimelineClipPresentation) {
        let layout = TimelineClipLayout(presentation: presentation)
        let body = layout.body
        guard body.maxX >= canvas.minX, body.minX <= canvas.maxX, body.width > 0 else { return }

        context.saveGState()
        if presentation.isDimmed { context.setAlpha(0.35) }

        let path = UIBezierPath(roundedRect: body, cornerRadius: min(layout.cornerRadius, body.width / 2)).cgPath
        context.saveGState()
        context.addPath(path)
        context.clip()

        fillBody(presentation, layout: layout)
        if let picture = layout.picture { drawFilmstrip(presentation, in: picture) }
        if let lane = layout.waveform { drawWaveform(presentation, in: lane, isSoleContent: layout.picture == nil) }
        drawFades(presentation, layout: layout)
        drawLabels(presentation, layout: layout)

        context.restoreGState()

        drawBorder(presentation, path: path)
        if presentation.showsTrimHandles && !presentation.isLocked { drawTrimHandles(presentation, layout: layout) }
        if presentation.isFocused { drawKeyframes(presentation, layout: layout) }

        context.restoreGState()
    }

    // MARK: - Body

    private func fillBody(_ presentation: TimelineClipPresentation, layout: TimelineClipLayout) {
        let clip = presentation.clip
        let fill: UIColor
        if clip.isDrawnOverlay {
            fill = TimelineTheme.tint(for: clip).withAlphaComponent(0.34)
        } else if clip.isAudio {
            fill = TimelineTheme.tint(for: clip).withAlphaComponent(0.20)
        } else {
            fill = TimelineTheme.clipBody
        }
        context.setFillColor(fill.cgColor)
        context.fill(layout.body.intersection(canvas))
    }

    // MARK: - Filmstrip

    /// Continuous 16:9 cells across the clip, sampled from the asset's cached
    /// thumbnails. Cells are aligned to the clip's own left edge so they do not
    /// crawl sideways while the timeline scrolls.
    private func drawFilmstrip(_ presentation: TimelineClipPresentation, in picture: CGRect) {
        let thumbnails = presentation.thumbnails
        guard !thumbnails.isEmpty else {
            context.setFillColor(UIColor(white: 0.16, alpha: 1).cgColor)
            context.fill(picture.intersection(canvas))
            return
        }
        let cellWidth = TimelineMetrics.filmstripCellWidth(pictureHeight: picture.height)
        let firstVisible = max(0, Int(((canvas.minX - picture.minX) / cellWidth).rounded(.down)))
        var index = firstVisible
        while picture.minX + CGFloat(index) * cellWidth < min(picture.maxX, canvas.maxX) {
            let x = picture.minX + CGFloat(index) * cellWidth
            let width = min(cellWidth, picture.maxX - x)
            guard width > 0.5 else { break }
            let offset = Double(CGFloat(index) * cellWidth + cellWidth / 2)
            let fraction = presentation.mapping.fraction(atOffset: offset, pixelsPerSecond: pixelsPerSecond)
            let image = thumbnails[min(thumbnails.count - 1, Int(fraction * Double(thumbnails.count)))]
            let box = CGRect(x: x, y: picture.minY, width: width, height: picture.height)
            context.saveGState()
            context.clip(to: box)
            let scale = max(cellWidth / image.size.width, box.height / image.size.height)
            let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: x + cellWidth / 2 - drawn.width / 2,
                                  y: box.midY - drawn.height / 2,
                                  width: drawn.width, height: drawn.height))
            context.restoreGState()
            index += 1
        }
    }

    // MARK: - Waveform

    /// A filled peak envelope mirrored about the lane's centre line, on its own
    /// darker translucent background so it reads as an audio section of the
    /// clip rather than as marks on the picture.
    private func drawWaveform(_ presentation: TimelineClipPresentation, in lane: CGRect, isSoleContent: Bool) {
        let visible = lane.intersection(canvas)
        guard visible.width > 0.5 else { return }

        if !isSoleContent {
            context.setFillColor(UIColor(white: 0.02, alpha: 0.55).cgColor)
            context.fill(visible)
            context.setFillColor(TimelineTheme.separator.cgColor)
            context.fill(CGRect(x: visible.minX, y: lane.minY, width: visible.width, height: 0.5))
        }

        let muted = presentation.clip.isMuted
        let tint = presentation.clip.isAudio ? TimelineTheme.tint(for: presentation.clip) : TimelineTheme.accent
        let bright = presentation.clip.isAudio
            ? tint.withAlphaComponent(muted ? 0.35 : 1) : TimelineTheme.accentBright.withAlphaComponent(muted ? 0.35 : 1)

        // The note glyph marks the lane, and a narrow gutter keeps the
        // envelope from starting underneath it.
        var plot = visible
        let gutter: CGFloat = 14
        if !isSoleContent, lane.height >= 14, visible.minX <= lane.minX + 1, lane.minX >= canvas.minX {
            let glyph = muted ? TimelineGlyph.mutedNote : TimelineGlyph.note
            glyph?.draw(at: CGPoint(x: lane.minX + 4,
                                    y: lane.midY - (glyph?.size.height ?? 0) / 2))
            plot.origin.x += gutter
            plot.size.width -= gutter
        }
        guard plot.width > 1, let waveform = presentation.waveform, !waveform.isEmpty else {
            context.setFillColor(TimelineTheme.separator.cgColor)
            context.fill(CGRect(x: max(plot.minX, visible.minX), y: lane.midY - 0.5,
                                width: max(0, plot.width), height: 1))
            return
        }

        let start = presentation.mapping.fraction(atOffset: Double(plot.minX - lane.minX),
                                                  pixelsPerSecond: pixelsPerSecond)
        let end = presentation.mapping.fraction(atOffset: Double(plot.maxX - lane.minX),
                                                pixelsPerSecond: pixelsPerSecond)
        let columns = max(2, min(2048, Int(plot.width.rounded(.up))))
        let centre = lane.midY
        // Perceptual rather than linear: a quiet passage should still show an
        // envelope instead of a flat line.
        let amplitude = max(2, lane.height / 2 - 2) * min(1.6, max(0.4, presentation.waveformScale))

        context.saveGState()
        context.clip(to: visible)
        waveformCache.withAmplitudes(of: waveform, from: start, to: end, columns: columns) { peaks, bodies in
            guard peaks.count >= 2 else { return }
            let step = plot.width / CGFloat(peaks.count - 1)
            /// Mirrors a half-envelope about the lane's centre line, which is
            /// how a magnitude envelope shows both polarities.
            func mirrored(_ values: ArraySlice<Float>) -> CGPath {
                let path = CGMutablePath()
                var upper = [CGPoint]()
                upper.reserveCapacity(values.count)
                for (index, value) in values.enumerated() {
                    let x = plot.minX + CGFloat(index) * step
                    let height = max(0.5, CGFloat(sqrt(max(0, value))) * amplitude)
                    upper.append(CGPoint(x: x, y: centre - height))
                }
                path.addLines(between: upper)
                for point in upper.reversed() {
                    path.addLine(to: CGPoint(x: point.x, y: centre + (centre - point.y)))
                }
                path.closeSubpath()
                return path
            }

            // Peak envelope first, then the average level filled solid inside
            // it. Zoomed in the two coincide and this reads as one waveform;
            // zoomed out the pale outer reach is the transients and the solid
            // core is where the sound actually sits.
            let envelope = mirrored(peaks)
            context.setFillColor(tint.withAlphaComponent(muted ? 0.14 : 0.34).cgColor)
            context.addPath(envelope)
            context.fillPath()

            context.setFillColor(tint.withAlphaComponent(muted ? 0.22 : 0.72).cgColor)
            context.addPath(mirrored(bodies))
            context.fillPath()

            context.setStrokeColor(bright.withAlphaComponent(muted ? 0.35 : 0.85).cgColor)
            context.setLineWidth(1)
            context.setLineJoin(.round)
            context.addPath(envelope)
            context.strokePath()
        }
        // The zero line, so a silent stretch still reads as audio.
        context.setFillColor(bright.withAlphaComponent(0.28).cgColor)
        context.fill(CGRect(x: plot.minX, y: centre - 0.25, width: plot.width, height: 0.5))
        context.restoreGState()
    }

    // MARK: - Fades

    /// The fade shape an editor expects to see: a wedge where the level is on
    /// its way up or down, drawn at the resolved lengths the mix applies.
    private func drawFades(_ presentation: TimelineClipPresentation, layout: TimelineClipLayout) {
        let fade = presentation.fade
        guard fade.rise > 0 || fade.fall > 0 else { return }
        let area = layout.waveform ?? layout.body
        context.setFillColor(UIColor.black.withAlphaComponent(0.5).cgColor)
        context.setStrokeColor(TimelineTheme.accentBright.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(1.5)
        if fade.rise > 0 {
            let width = CGFloat(fade.rise * pixelsPerSecond)
            let wedge = CGMutablePath()
            wedge.move(to: CGPoint(x: area.minX, y: area.minY))
            wedge.addLine(to: CGPoint(x: area.minX + width, y: area.minY))
            wedge.addLine(to: CGPoint(x: area.minX, y: area.maxY))
            wedge.closeSubpath()
            context.addPath(wedge); context.fillPath()
            context.move(to: CGPoint(x: area.minX, y: area.maxY))
            context.addLine(to: CGPoint(x: area.minX + width, y: area.minY))
            context.strokePath()
        }
        if fade.fall > 0 {
            let width = CGFloat(fade.fall * pixelsPerSecond)
            let wedge = CGMutablePath()
            wedge.move(to: CGPoint(x: area.maxX, y: area.minY))
            wedge.addLine(to: CGPoint(x: area.maxX - width, y: area.minY))
            wedge.addLine(to: CGPoint(x: area.maxX, y: area.maxY))
            wedge.closeSubpath()
            context.addPath(wedge); context.fillPath()
            context.move(to: CGPoint(x: area.maxX - width, y: area.minY))
            context.addLine(to: CGPoint(x: area.maxX, y: area.maxY))
            context.strokePath()
        }
    }

    // MARK: - Name and duration

    private func drawLabels(_ presentation: TimelineClipPresentation, layout: TimelineClipLayout) {
        let icon = presentation.isLocked
            ? TimelineGlyph.lock
            : TimelineGlyph.leading(for: presentation.clip, isStill: presentation.isStillImage)

        // Audio has no filmstrip, but a tall audio row still wants chips rather
        // than one line of text lying across its waveform. A drawn overlay
        // never does: its row is too short for a name chip and a duration chip
        // to sit clear of one another.
        let chipArea = layout.picture
            ?? (presentation.clip.isAudio && layout.body.height >= 44 ? layout.body : nil)
        guard let picture = chipArea, picture.height >= 26 else {
            // Short rows get one centred name and no chips: there is no room
            // for anything else, and a title row needs a label, not furniture.
            guard presentation.showsName else { return }
            let area = layout.body.intersection(canvas)
            guard area.width > 24, layout.body.height >= 13 else { return }
            context.saveGState()
            context.clip(to: area.insetBy(dx: 5, dy: 0))
            var x = max(layout.body.minX, canvas.minX) + 6
            if let icon, area.width > 40 {
                icon.draw(at: CGPoint(x: x, y: layout.body.midY - icon.size.height / 2))
                x += icon.size.width + 4
            }
            let font = UIFont.systemFont(ofSize: 10.5, weight: .medium)
            (presentation.title as NSString).draw(
                at: CGPoint(x: x, y: layout.body.midY - font.lineHeight / 2),
                withAttributes: [.font: font, .foregroundColor: TimelineTheme.textPrimary])
            context.restoreGState()
            return
        }

        // Name chip, pinned to the visible left edge so a clip scrolled
        // half-way off screen still says what it is.
        let chipLeft = max(picture.minX + 5, canvas.minX + 5)
        if presentation.showsName, chipLeft < picture.maxX - 12 {
            drawChip(text: presentation.title, icon: icon,
                     attributes: Self.titleAttributes,
                     origin: CGPoint(x: chipLeft, y: picture.minY + 5),
                     maximumRight: picture.maxX - 5)
        }

        // Duration chip, diagonally opposite so the two never collide.
        guard presentation.showsDuration else { return }
        let duration = TimecodeFormatter.string(from: presentation.duration)
        let size = (duration as NSString).size(withAttributes: Self.durationAttributes)
        let chipWidth = size.width + 12
        if picture.width > chipWidth + 60, picture.maxX > canvas.minX + chipWidth {
            let right = min(picture.maxX - 5, canvas.maxX - 5)
            drawChip(text: duration, icon: nil, attributes: Self.durationAttributes,
                     origin: CGPoint(x: right - chipWidth, y: picture.maxY - size.height - 9),
                     maximumRight: right)
        }
    }

    /// A dark translucent pill behind short text, so a name stays readable
    /// over any frame the filmstrip happens to show.
    private func drawChip(text: String, icon: UIImage?,
                          attributes: [NSAttributedString.Key: Any],
                          origin: CGPoint, maximumRight: CGFloat) {
        let string = text as NSString
        let textSize = string.size(withAttributes: attributes)
        let iconWidth = icon.map { $0.size.width + 4 } ?? 0
        let width = min(textSize.width + iconWidth + 12, max(24, maximumRight - origin.x))
        let height = textSize.height + 6
        let chip = CGRect(x: origin.x, y: origin.y, width: width, height: height)
        context.saveGState()
        context.addPath(UIBezierPath(roundedRect: chip, cornerRadius: height / 2).cgPath)
        context.setFillColor(UIColor.black.withAlphaComponent(0.62).cgColor)
        context.fillPath()
        context.clip(to: chip.insetBy(dx: 5, dy: 0))
        var x = chip.minX + 6
        if let icon {
            icon.draw(at: CGPoint(x: x, y: chip.midY - icon.size.height / 2))
            x += icon.size.width + 4
        }
        string.draw(at: CGPoint(x: x, y: chip.midY - textSize.height / 2), withAttributes: attributes)
        context.restoreGState()
    }

    // MARK: - Border, handles and keyframes

    private func drawBorder(_ presentation: TimelineClipPresentation, path: CGPath) {
        context.addPath(path)
        if presentation.isSelected {
            context.setStrokeColor(TimelineTheme.accent.cgColor)
            context.setLineWidth(TimelineMetrics.selectedBorderWidth)
        } else {
            context.setStrokeColor(TimelineTheme.clipBorder.cgColor)
            context.setLineWidth(TimelineMetrics.borderWidth)
        }
        context.strokePath()
    }

    /// Obvious grab targets on both edges. The bar is 13pt wide; the region
    /// that answers a touch is 44pt, which the canvas enforces in
    /// `operation(at:clip:)`.
    private func drawTrimHandles(_ presentation: TimelineClipPresentation, layout: TimelineClipLayout) {
        let body = layout.body
        let width = min(TimelineMetrics.trimHandleWidth, max(4, body.width / 3))
        let radius = min(layout.cornerRadius, width / 2)
        for isLeading in [true, false] {
            let rect = CGRect(x: isLeading ? body.minX : body.maxX - width,
                              y: body.minY, width: width, height: body.height)
            guard rect.maxX >= canvas.minX, rect.minX <= canvas.maxX else { continue }
            let handle = UIBezierPath(
                roundedRect: rect,
                byRoundingCorners: isLeading ? [.topLeft, .bottomLeft] : [.topRight, .bottomRight],
                cornerRadii: CGSize(width: radius, height: radius)).cgPath
            context.addPath(handle)
            context.setFillColor(TimelineTheme.accent.cgColor)
            context.fillPath()
            // Two grips, so the bar reads as something to pull rather than as
            // a coloured end cap.
            context.setFillColor(UIColor(white: 0.05, alpha: 0.55).cgColor)
            let gripHeight = min(14, max(6, body.height * 0.34))
            for offset in [-2.0, 1.0] {
                context.fill(CGRect(x: rect.midX + offset, y: rect.midY - gripHeight / 2,
                                    width: 1.5, height: gripHeight))
            }
        }
    }

    private func drawKeyframes(_ presentation: TimelineClipPresentation, layout: TimelineClipLayout) {
        guard !presentation.keyframeTimes.isEmpty else { return }
        let y = layout.body.maxY - 6
        context.saveGState()
        context.clip(to: layout.body.intersection(canvas))
        for time in presentation.keyframeTimes {
            let x = geometry.x(for: time)
            guard x >= canvas.minX - 6, x <= canvas.maxX + 6 else { continue }
            let diamond = CGMutablePath()
            diamond.move(to: CGPoint(x: x, y: y - 4))
            diamond.addLine(to: CGPoint(x: x + 4, y: y))
            diamond.addLine(to: CGPoint(x: x, y: y + 4))
            diamond.addLine(to: CGPoint(x: x - 4, y: y))
            diamond.closeSubpath()
            context.addPath(diamond)
            context.setFillColor(UIColor.white.cgColor)
            context.fillPath()
            context.addPath(diamond)
            context.setStrokeColor(UIColor.black.withAlphaComponent(0.7).cgColor)
            context.setLineWidth(0.5)
            context.strokePath()
        }
        context.restoreGState()
    }
}
