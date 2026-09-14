import SwiftUI
import UIKit

/// A vertical clip drag either lands on an existing visual track or opens a new
/// overlay row at the indicated position. Track ordering itself remains in the
/// Layers sheet, so dragging a clip never unexpectedly moves its neighbours.
enum TimelineLayerDropTarget: Equatable {
    case track(UUID)
    case newOverlay(index: Int)
}

struct TimelineView: UIViewRepresentable {
    let clips: [TimelineDisplayClip]
    let tracks: [TimelineTrack]
    let markers: [TimelineMarker]
    let transitions: [TimelineTransition]
    /// Timeline seconds of the selected clip's keyframes. Only the selection is annotated,
    /// so an ordinary timeline stays uncluttered.
    let keyframeTimes: [Double]
    let assets: [ProjectMediaAsset]
    let assetFrames: [UUID: [UIImage]]
    let waveforms: [UUID: [Float]]
    let sourceRange: TimelineRange
    let minimumDuration: Double
    let name: String
    let currentTime: Double
    let selectedID: UUID?
    let selectedIDs: Set<UUID>
    let selectedTransitionID: UUID?
    let thumbnails: [UIImage]
    let onSelect: (UUID?) -> Void
    let onSelectMany: (Set<UUID>) -> Void
    let onSelectTransition: (UUID) -> Void
    let onDragSelect: (UUID) -> Void
    let onOptions: (UUID) -> Void
    let onMoveClipToLayer: (UUID, TimelineLayerDropTarget, Double) -> Void
    let onEdit: (UUID, TimelineGestureEdit, Double) -> Void
    let onBeginEdit: () -> Void
    let onBeginSeek: () -> Void
    let onSeek: (Double) -> Void
    let onEndSeek: (Double) -> Void

    func makeUIView(context: Context) -> TimelineCanvas { TimelineCanvas() }
    func updateUIView(_ view: TimelineCanvas, context: Context) {
        view.clips = clips; view.sourceRange = sourceRange; view.name = name
        view.tracks = tracks; view.markers = markers; view.assets = assets; view.assetFrames = assetFrames
        view.transitions = transitions
        view.keyframeTimes = keyframeTimes
        view.waveforms = waveforms
        view.minimumDuration = minimumDuration
        view.selectedID = selectedID; view.selectedIDs = selectedIDs; view.thumbnails = thumbnails
        view.selectedTransitionID = selectedTransitionID
        view.onDragSelect = onDragSelect
        view.onOptions = onOptions
        view.onMoveClipToLayer = onMoveClipToLayer
        view.onEdit = onEdit; view.onBeginEdit = onBeginEdit
        view.onSelect = onSelect; view.onBeginSeek = onBeginSeek
        view.onSelectMany = onSelectMany
        view.onSelectTransition = onSelectTransition
        view.onSeek = onSeek; view.onEndSeek = onEndSeek
        view.update(time: currentTime)
    }
    static func dismantleUIView(_ view: TimelineCanvas, coordinator: ()) { view.cancelInteraction() }
}

/// Only the viewport is drawn. UIScrollView supplies touch/inertia, not a giant
/// filmstrip view or thousands of ruler/thumbnail subviews.
final class TimelineCanvas: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var clips: [TimelineDisplayClip] = []
    var tracks: [TimelineTrack] = []
    var markers: [TimelineMarker] = []
    var transitions: [TimelineTransition] = []
    var keyframeTimes: [Double] = []
    var assets: [ProjectMediaAsset] = []
    var assetFrames: [UUID: [UIImage]] = [:]
    var waveforms: [UUID: [Float]] = [:]
    // Text rows are short: a title needs a label, not a filmstrip-sized band.
    private static let textClipHeight: CGFloat = 30
    private static let mediaClipHeight: CGFloat = 68
    private static let rowGap: CGFloat = 8
    private func clipHeight(_ track: TimelineTrack?) -> CGFloat {
        track?.kind == .text ? Self.textClipHeight : Self.mediaClipHeight
    }
    private func clipHeight(trackID: UUID) -> CGFloat { clipHeight(tracks.first { $0.id == trackID }) }
    /// Cumulative top of a row within the scrolled content, so rows may differ in height.
    private func rowTop(_ index: Int, in rows: [TimelineTrack]? = nil) -> CGFloat {
        let rows = rows ?? displayTracks
        return rows.prefix(max(0, index)).reduce(0) { $0 + clipHeight($1) + Self.rowGap }
    }
    private var contentHeight: CGFloat { rowTop(displayTracks.count) + 36 }
    private func rowOffset(_ clip: TimelineDisplayClip) -> CGFloat {
        if clip.id == ghost?.clip.id, let layerDropTarget {
            let destinationID: UUID
            switch layerDropTarget {
            case .track(let id): destinationID = id
            case .newOverlay: destinationID = newOverlayPreviewID
            }
            if let row = displayTracks.firstIndex(where: { $0.id == destinationID }) {
                return rowTop(row) - scroll.contentOffset.y
            }
        }
        return rowTop(displayTracks.firstIndex(where: { $0.id == clip.placement.trackID }) ?? 0) - scroll.contentOffset.y
    }
    private func isLocked(_ clip: TimelineDisplayClip) -> Bool {
        clip.placement.isLocked || tracks.first(where: { $0.id == clip.placement.trackID })?.isLocked == true
    }
    var sourceRange: TimelineRange?
    var minimumDuration = 0.01
    var name = "Video"
    var selectedID: UUID?
    var selectedIDs: Set<UUID> = []
    var selectedTransitionID: UUID?
    var thumbnails: [UIImage] = []
    var onSelect: ((UUID?) -> Void)?
    var onSelectMany: ((Set<UUID>) -> Void)?
    var onSelectTransition: ((UUID) -> Void)?
    var onDragSelect: ((UUID) -> Void)?
    var onOptions: ((UUID) -> Void)?
    var onMoveClipToLayer: ((UUID, TimelineLayerDropTarget, Double) -> Void)?
    private var layerDropTarget: TimelineLayerDropTarget?
    private let newOverlayPreviewID = UUID()
    private var displayTracks: [TimelineTrack] {
        guard case .newOverlay(let index) = layerDropTarget else { return tracks }
        var result = tracks
        result.insert(.init(id: newOverlayPreviewID, name: "+ New overlay", kind: .videoOverlay),
                      at: min(max(0, index), result.count))
        return result
    }
    var onEdit: ((UUID, TimelineGestureEdit, Double) -> Void)?
    var onBeginEdit: (() -> Void)?
    private var editPan: UIPanGestureRecognizer!
    private var ghost: (clip: TimelineDisplayClip, operation: TimelineGestureEdit, time: Double)?
    private var snappedBoundary: Double?
    private var hold: UILongPressGestureRecognizer!
    private var dragTimer: Timer?
    private var dragPoint = CGPoint.zero
    private var dragAnchor = 0.0
    private var holdOrigin = CGPoint.zero
    private var holdStarted = Date.distantPast
    private var hasMoved = false
    private var marqueeOrigin: CGPoint?
    private var marqueePoint: CGPoint?
    private var marqueeSelection: Set<UUID> = []
    private var insertionPreview: [UUID: Double] {
        if layerDropTarget != nil { return [:] }
        guard let ghost, ghost.operation == .move else { return [:] }
        let others = clips.filter { $0.id != ghost.clip.id && $0.placement.trackID == ghost.clip.placement.trackID }
        if tracks.first(where: { $0.id == ghost.clip.placement.trackID })?.kind != .mainVideo { return [ghost.clip.id: ghost.time] }
        let index = others.firstIndex { ghost.time < $0.placement.timelineStart.seconds + $0.placement.duration.seconds/2 } ?? others.count
        let length = ghost.clip.placement.duration.seconds
        let oldEnd = ghost.clip.placement.timelineStart.seconds + length
        var starts = others.map { $0.placement.timelineStart.seconds - ($0.placement.timelineStart.seconds >= oldEnd ? length : 0) }
        let destination = index < starts.count ? starts[index] : (starts.last ?? 0) + (others.last?.placement.duration.seconds ?? 0)
        for i in index..<starts.count { starts[i] += length }
        var result = Dictionary(uniqueKeysWithValues: zip(others.map(\.id), starts))
        result[ghost.clip.id] = destination
        return result
    }
    var onBeginSeek: (() -> Void)?
    var onSeek: ((Double) -> Void)?
    var onEndSeek: ((Double) -> Void)?
    private let scroll = UIScrollView()
    private var zoom = 48.0
    private var pinchZoom = 48.0
    private var currentTime = 0.0
    private var interacting = false
    private var updating = false
    private var pinching = false
    private var playheadSnap: Double?
    private var revealedSelection: UUID?
    private var duration: Double { clips.compactMap { try? $0.placement.range.end.seconds }.max() ?? 0 }
    private var viewport: TimelineViewport {
        .init(pixelsPerSecond: zoom, width: bounds.width,
              offset: interacting && !pinching ? currentTime * zoom : scroll.contentOffset.x)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.075, alpha: 1)
        scroll.backgroundColor = .clear
        scroll.isOpaque = false
        scroll.delegate = self
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceHorizontal = false
        scroll.bounces = false
        scroll.isDirectionalLockEnabled = true
        scroll.decelerationRate = .fast
        scroll.contentInsetAdjustmentBehavior = .never
        addSubview(scroll)
        editPan = UIPanGestureRecognizer(target: self, action: #selector(edited(_:)))
        editPan.delegate = self
        scroll.addGestureRecognizer(editPan)
        scroll.panGestureRecognizer.require(toFail: editPan)
        hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.25
        hold.allowableMovement = 10
        hold.delegate = self
        scroll.addGestureRecognizer(hold)
        scroll.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        scroll.addGestureRecognizer(pinch)
        isAccessibilityElement = true
        accessibilityLabel = "Video and audio timeline"
        accessibilityTraits = .adjustable
        accessibilityHint = "Swipe up or down to seek one second. Hold a clip and drag sideways to move it or vertically to move it to another layer."
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Select clip", target: self, selector: #selector(selectClip)),
            UIAccessibilityCustomAction(name: "Deselect clip", target: self, selector: #selector(deselectClip)),
            UIAccessibilityCustomAction(name: "Zoom in", target: self, selector: #selector(zoomIn)),
            UIAccessibilityCustomAction(name: "Zoom out", target: self, selector: #selector(zoomOut))
        ]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        updating = true
        scroll.frame = bounds
        scroll.contentSize = CGSize(width: duration * zoom + bounds.width, height: max(bounds.height, contentHeight))
        if ghost == nil && !interacting { scroll.contentOffset.x = currentTime * zoom }
        updating = false
        setNeedsDisplay()
    }

    func update(time: Double) {
        if !interacting && ghost == nil {
            currentTime = min(duration, max(0, time))
            updating = true
            scroll.contentSize = CGSize(width: duration * zoom + bounds.width, height: max(bounds.height, contentHeight))
            scroll.contentOffset.x = currentTime * zoom
            if selectedID != revealedSelection, let clip = clips.first(where: { $0.id == selectedID }),
               let row = tracks.firstIndex(where: { $0.id == clip.placement.trackID }) {
                let top = rowTop(row)
                let bottom = top + clipHeight(trackID: clip.placement.trackID) + 44
                if top < scroll.contentOffset.y { scroll.contentOffset.y = top }
                else if bottom > scroll.contentOffset.y+bounds.height {
                    scroll.contentOffset.y = max(0, min(scroll.contentSize.height-bounds.height, bottom-bounds.height))
                }
                revealedSelection = selectedID
            }
            updating = false
        }
        accessibilityValue = "\(Int(currentTime)) of \(Int(duration)) seconds, \(selectedID != nil ? "clip selected" : "no selection")"
        setNeedsDisplay()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { beginInteraction() }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !updating, interacting, !pinching else { return }
        let rawTime = min(duration, max(0, scroll.contentOffset.x / zoom))
        // Keep raw touch travel independent from the displayed snapped position,
        // so the magnet releases naturally rather than trapping the scroll view.
        if let playheadSnap, abs(rawTime-playheadSnap) * zoom <= 22 {
            currentTime = playheadSnap
        } else {
            let snapped = TimelineEditing.snapPlayhead(rawTime, clips: clips, markers: markers, keyframes: keyframeTimes, tolerance: 12/zoom)
            let boundary = snapped != rawTime ? snapped : nil
            if boundary != nil && boundary != playheadSnap { UISelectionFeedbackGenerator().selectionChanged() }
            playheadSnap = boundary
            currentTime = snapped
        }
        onSeek?(currentTime)
        setNeedsDisplay()
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate && !pinching { endInteraction() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { if !pinching { endInteraction() } }
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                  targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let seconds = targetContentOffset.pointee.x / zoom
        if let playheadSnap, abs(scrollView.contentOffset.x/zoom-playheadSnap) * zoom <= 22 {
            targetContentOffset.pointee.x = playheadSnap * zoom
        } else {
            targetContentOffset.pointee.x = TimelineEditing.snapPlayhead(seconds, clips: clips, markers: markers, keyframes: keyframeTimes, tolerance: 12/zoom) * zoom
        }
    }
    private func beginInteraction() {
        guard !interacting else { return }
        playheadSnap = nil
        interacting = true; onBeginSeek?()
    }
    private func endInteraction() {
        guard interacting else { return }
        let snapped = TimelineEditing.snapPlayhead(currentTime, clips: clips, markers: markers, keyframes: keyframeTimes, tolerance: 10/zoom)
        if snapped != currentTime { UISelectionFeedbackGenerator().selectionChanged() }
        currentTime = snapped
        updating = true; scroll.contentOffset.x = currentTime * zoom; updating = false
        interacting = false; onEndSeek?(currentTime)
        playheadSnap = nil
    }
    func cancelInteraction() {
        // Leaving the editor must never resume playback through a delayed seek.
        interacting = false
        dragTimer?.invalidate(); dragTimer = nil; ghost = nil; layerDropTarget = nil
        marqueeOrigin = nil; marqueePoint = nil; marqueeSelection = []
        scroll.panGestureRecognizer.isEnabled = true
        scroll.delegate = nil
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        if point.y < 30 {
            seek(to: viewport.seconds(at: point.x, duration: duration))
        } else if let transition = hitTransition(at: point) {
            onSelectTransition?(transition.id)
        } else {
            onSelect?(hitClip(at: point)?.id)
        }
    }
    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            pinching = true; beginInteraction(); pinchZoom = zoom
            scroll.panGestureRecognizer.isEnabled = false
            scroll.setContentOffset(scroll.contentOffset, animated: false)
        case .changed: setZoom(pinchZoom * recognizer.scale)
        case .ended, .cancelled, .failed:
            scroll.panGestureRecognizer.isEnabled = true
            pinching = false; endInteraction()
        default: break
        }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer
    }
    private func setZoom(_ value: Double) {
        zoom = min(TimelineViewport.zoomRange.upperBound, max(TimelineViewport.zoomRange.lowerBound, value))
        updating = true
        scroll.contentSize.width = duration * zoom + bounds.width
        scroll.contentOffset.x = currentTime * zoom
        updating = false
        setNeedsDisplay()
    }
    private func seek(to time: Double) {
        beginInteraction(); currentTime = min(duration, max(0, time))
        onSeek?(currentTime); endInteraction(); update(time: currentTime)
    }
    override func accessibilityIncrement() { seek(to: currentTime + 1) }
    override func accessibilityDecrement() { seek(to: currentTime - 1) }
    @objc private func selectClip() -> Bool {
        let atPlayhead = clips.first { $0.placement.timelineStart.seconds <= currentTime && currentTime < ((try? $0.placement.range.end.seconds) ?? 0) }
        onSelect?(atPlayhead?.id ?? clips.first?.id); return true
    }
    @objc private func deselectClip() -> Bool { onSelect?(nil); return true }
    @objc private func zoomIn() -> Bool { setZoom(zoom * 2); return true }
    @objc private func zoomOut() -> Bool { setZoom(zoom / 2); return true }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let geometry = viewport
        let interval = geometry.rulerInterval
        let minor = minimumDuration * zoom >= 8 ? minimumDuration : interval/5
        var minorTick = max(0, floor(geometry.seconds(at: 0, duration: duration)/minor)*minor)
        let minorEnd = min(duration, geometry.seconds(at: bounds.width, duration: duration)+minor)
        context.setStrokeColor(UIColor(white: 0.25, alpha: 1).cgColor)
        while minorTick <= minorEnd {
            let x = geometry.x(for: minorTick)
            context.move(to: CGPoint(x: x, y: 26)); context.addLine(to: CGPoint(x: x, y: 30)); context.strokePath()
            minorTick += minor
        }
        let first = max(0, floor(geometry.seconds(at: 0, duration: duration) / interval) * interval)
        let last = min(duration, geometry.seconds(at: bounds.width, duration: duration) + interval)
        var tick = first
        while tick <= last {
            let x = geometry.x(for: tick)
            context.setStrokeColor(UIColor(white: 0.4, alpha: 1).cgColor)
            context.move(to: CGPoint(x: x, y: 23)); context.addLine(to: CGPoint(x: x, y: 29)); context.strokePath()
            let label = interval < 0.1 ? String(format: "%.2fs", tick) : interval < 1 ? String(format: "%.1fs", tick) : String(format: "%02d:%02d", Int(tick)/60, Int(tick)%60)
            (label as NSString).draw(at: CGPoint(x: x + 4, y: 6), withAttributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: UIColor.lightGray])
            tick += interval
        }
        let insertion = insertionPreview
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: 32, width: bounds.width, height: bounds.height-32))
        for clip in clips {
            context.saveGState(); context.translateBy(x: 0, y: rowOffset(clip))
            if tracks.first(where: { $0.id == clip.placement.trackID })?.isEnabled == false { context.setAlpha(0.35) }
            drawClip(clip, context: context, geometry: geometry, insertion: insertion)
            context.restoreGState()
        }
        for (index, track) in displayTracks.enumerated() where track.kind != .text {
            let y = rowTop(index) + 32 - scroll.contentOffset.y
            guard y >= 30, y < bounds.height else { continue }
            let title = (track.isLocked ? "🔒 " : "") + (track.kind == .audio && !track.isEnabled ? "Muted · " : "") + track.name
            let isNewOverlay = track.id == newOverlayPreviewID
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 9, weight: isNewOverlay ? .semibold : .medium),
                .foregroundColor: isNewOverlay ? UIColor.systemMint : UIColor.lightGray
            ]
            let size = (title as NSString).size(withAttributes: attributes)
            context.setFillColor((isNewOverlay ? UIColor.systemMint.withAlphaComponent(0.14) : UIColor.black.withAlphaComponent(0.8)).cgColor)
            context.fill(CGRect(x: 3, y: y, width: size.width+8, height: 13))
            (title as NSString).draw(at: CGPoint(x: 7, y: y), withAttributes: attributes)
            if isNewOverlay {
                context.setStrokeColor(UIColor.systemMint.withAlphaComponent(0.8).cgColor)
                context.setLineWidth(1)
                context.stroke(CGRect(x: 1, y: y+2, width: bounds.width-2,
                                      height: clipHeight(track)-2))
            }
        }
        context.restoreGState()
        for transition in transitions where transition.enabled {
            guard let outgoing = clips.first(where: { $0.id == transition.outgoingClipID }),
                  let row = displayTracks.firstIndex(where: { $0.id == outgoing.placement.trackID }) else { continue }
            let x = geometry.x(for: transition.editTime.seconds)
            let y = rowTop(row) + 36 + clipHeight(trackID: outgoing.placement.trackID) / 2 - scroll.contentOffset.y
            guard x >= -14, x <= bounds.width + 14, y >= 28, y <= bounds.height else { continue }
            let radius: CGFloat = selectedTransitionID == transition.id ? 10 : 8
            context.saveGState()
            context.setShadow(offset: .zero, blur: 4, color: UIColor.black.withAlphaComponent(0.8).cgColor)
            context.setFillColor((selectedTransitionID == transition.id ? UIColor.systemMint : UIColor(white: 0.92, alpha: 1)).cgColor)
            context.move(to: CGPoint(x: x, y: y-radius))
            context.addLine(to: CGPoint(x: x+radius, y: y))
            context.addLine(to: CGPoint(x: x, y: y+radius))
            context.addLine(to: CGPoint(x: x-radius, y: y))
            context.closePath(); context.fillPath()
            context.setStrokeColor(UIColor.black.withAlphaComponent(0.8).cgColor)
            context.setLineWidth(1.5); context.strokePath()
            context.restoreGState()
        }
        for marker in markers {
            let x = geometry.x(for: marker.time.seconds)
            context.setFillColor(UIColor.systemYellow.cgColor)
            context.move(to: CGPoint(x: x, y: 18)); context.addLine(to: CGPoint(x: x+5, y: 23))
            context.addLine(to: CGPoint(x: x, y: 28)); context.addLine(to: CGPoint(x: x-5, y: 23)); context.closePath(); context.fillPath()
        }
        if let selectionRect = marqueeRect {
            context.saveGState()
            context.setFillColor(UIColor.systemMint.withAlphaComponent(0.12).cgColor)
            context.fill(selectionRect)
            context.setStrokeColor(UIColor.systemMint.withAlphaComponent(0.95).cgColor)
            context.setLineWidth(1.5)
            context.setLineDash(phase: 0, lengths: [5, 3])
            context.stroke(selectionRect.insetBy(dx: 0.75, dy: 0.75))
            context.restoreGState()
        }
        if let ghost, ghost.operation == .move, let start = insertion[ghost.clip.id] {
            context.setStrokeColor(UIColor.systemMint.cgColor); context.setLineWidth(3)
            let x = geometry.x(for: start)
            let span = clipHeight(trackID: ghost.clip.placement.trackID)
            context.move(to: CGPoint(x: x, y: 30+rowOffset(ghost.clip))); context.addLine(to: CGPoint(x: x, y: 42+span+rowOffset(ghost.clip))); context.strokePath()
        }
        context.setStrokeColor(UIColor.white.cgColor); context.setLineWidth(1.5)
        context.move(to: CGPoint(x: bounds.midX, y: 0)); context.addLine(to: CGPoint(x: bounds.midX, y: bounds.height)); context.strokePath()
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: bounds.midX-3, y: 0, width: 6, height: 8))
    }

    private func drawClip(_ clip: TimelineDisplayClip, context: CGContext, geometry: TimelineViewport, insertion: [UUID: Double]) {
        let asset = assets.first { $0.id == clip.assetID }
        let thumbnails = assetFrames[clip.assetID] ?? []
        let sourceRange = asset?.sourceRange
        let name = clip.title ?? (asset?.audioName ?? (asset?.stillImage != nil ? "Image overlay" : (asset?.videoMetadata?.fileName ?? self.name)))
        var start = clip.placement.timelineStart.seconds
        var end = (try? clip.placement.range.end.seconds) ?? start
        if let ghost, ghost.clip.id == clip.id {
            switch ghost.operation {
            case .move: break
            case .trimStart: start = ghost.time
            case .trimEnd: end = ghost.time
            }
        }
        if let position = insertion[clip.id] { start = position; end = start + clip.placement.duration.seconds }
        let left = geometry.x(for: start), right = geometry.x(for: end)
        guard right >= 0, left <= bounds.width else { return }
        let selected = selectedIDs.contains(clip.id) || marqueeSelection.contains(clip.id)
        let independentlyEditable = selectedID == clip.id && selectedIDs.count == 1 && marqueeOrigin == nil
        let height = clipHeight(trackID: clip.placement.trackID)
        let clipRect = CGRect(x: left, y: 36, width: max(1, right-left), height: height)
        context.saveGState()
        context.clip(to: clipRect.intersection(bounds))
        context.setFillColor((clip.isAudio ? UIColor.systemBlue.withAlphaComponent(0.25) : clip.isText ? UIColor.systemPurple.withAlphaComponent(0.3) : UIColor(white: 0.18, alpha: 1)).cgColor)
        context.fill(clipRect.intersection(bounds))
        let cellWidth = 72.0
        var cell = max(0, Int(floor(-left / cellWidth)))
        while left + Double(cell) * cellWidth < min(right, bounds.width) {
            let x = left + Double(cell) * cellWidth
            if !clip.isAudio && !thumbnails.isEmpty {
                let sourceTime = clip.sourceRange.start.seconds + (Double(cell) * cellWidth + cellWidth / 2) / zoom
                let fraction = min(0.999999, max(0, (sourceTime - (sourceRange?.start.seconds ?? 0)) / max(0.001, sourceRange?.duration.seconds ?? 1)))
                let image = thumbnails[min(thumbnails.count-1, Int(fraction * Double(thumbnails.count)))]
                let box = CGRect(x: x, y: 36, width: cellWidth, height: height)
                context.saveGState(); context.clip(to: box)
                let scale = max(box.width/image.size.width, box.height/image.size.height)
                image.draw(in: CGRect(x: box.midX-image.size.width*scale/2, y: box.midY-image.size.height*scale/2, width: image.size.width*scale, height: image.size.height*scale))
                context.restoreGState()
            }
            cell += 1
        }
        if clip.isAudio {
            context.setStrokeColor(UIColor.systemCyan.withAlphaComponent(clip.isMuted ? 0.3 : 0.9).cgColor)
            context.setLineWidth(1.5)
            let peaks = waveforms[clip.assetID] ?? []
            var x = max(0, left)
            while x < min(right, bounds.width) {
                let trimOffset = ghost?.clip.id == clip.id && ghost?.operation == .trimStart ? start-clip.placement.timelineStart.seconds : 0
                let sourceTime = clip.sourceRange.start.seconds + (x-left)/zoom + trimOffset
                let fraction = (sourceTime-(sourceRange?.start.seconds ?? 0))/max(0.001, sourceRange?.duration.seconds ?? 1)
                let peak: Float = peaks.isEmpty ? 0 : peaks[min(peaks.count-1, max(0, Int(fraction * Double(peaks.count))))]
                let peakHeight = max(1, CGFloat(sqrt(peak))*18)
                context.move(to: CGPoint(x: x, y: 62-peakHeight)); context.addLine(to: CGPoint(x: x, y: 62+peakHeight))
                x += 3
            }
            context.strokePath()
        }
        // The fade shape, drawn over the waveform the way an editor expects to
        // see it: a wedge where the level is on its way up or down. These are the
        // resolved lengths, so what is drawn is what the mix applies.
        if clip.fade.rise > 0 || clip.fade.fall > 0 {
            let top: CGFloat = 36
            let bottom = top + height
            context.setFillColor(UIColor.black.withAlphaComponent(0.45).cgColor)
            context.setStrokeColor(UIColor.systemCyan.withAlphaComponent(0.9).cgColor)
            context.setLineWidth(1.5)
            if clip.fade.rise > 0 {
                let width = CGFloat(clip.fade.rise * zoom)
                let path = CGMutablePath()
                path.move(to: CGPoint(x: left, y: top))
                path.addLine(to: CGPoint(x: left + width, y: top))
                path.addLine(to: CGPoint(x: left, y: bottom))
                path.closeSubpath()
                context.addPath(path); context.fillPath()
                context.move(to: CGPoint(x: left, y: bottom))
                context.addLine(to: CGPoint(x: left + width, y: top))
                context.strokePath()
            }
            if clip.fade.fall > 0 {
                let width = CGFloat(clip.fade.fall * zoom)
                let path = CGMutablePath()
                path.move(to: CGPoint(x: right, y: top))
                path.addLine(to: CGPoint(x: right - width, y: top))
                path.addLine(to: CGPoint(x: right, y: bottom))
                path.closeSubpath()
                context.addPath(path); context.fillPath()
                context.move(to: CGPoint(x: right - width, y: top))
                context.addLine(to: CGPoint(x: right, y: bottom))
                context.strokePath()
            }
        }
        let labelHeight: CGFloat = min(22, height)
        let labelTop = 36+height-labelHeight
        if !clip.isText {
            context.setFillColor(UIColor.black.withAlphaComponent(0.65).cgColor)
            context.fill(CGRect(x: max(left, 0), y: labelTop, width: min(right, bounds.width)-max(left, 0), height: labelHeight))
        }
        let label = (isLocked(clip) && clip.isText ? "🔒 " : "")
            + (clip.isMuted ? "Muted · " : clip.isAudio || clip.embeddedAudio != nil ? "♫  " : "") + name
        // Media keeps its original baseline inside the dark strip; text centres in its short row.
        let labelY = clip.isText ? 36+(height-13)/2 : labelTop+3
        (label as NSString).draw(at: CGPoint(x: max(left, 0)+8, y: labelY),
            withAttributes: [.font: UIFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: UIColor.white])
        context.restoreGState()
        context.setStrokeColor((selected ? UIColor.systemMint : UIColor.darkGray).cgColor)
        context.setLineWidth(selected ? 2 : 1)
        context.stroke(clipRect.insetBy(dx: 1, dy: 1))
        if independentlyEditable && !isLocked(clip) {
            context.setFillColor(UIColor.systemMint.cgColor)
            context.fill(CGRect(x: left, y: 36, width: 8, height: height))
            context.fill(CGRect(x: right-8, y: 36, width: 8, height: height))
        }
        if independentlyEditable && !keyframeTimes.isEmpty {
            let y = 36 + height - 6
            context.saveGState()
            context.clip(to: clipRect.intersection(bounds))
            for time in keyframeTimes {
                let x = geometry.x(for: time)
                guard x >= -6, x <= bounds.width + 6 else { continue }
                context.setFillColor(UIColor.white.cgColor)
                context.move(to: CGPoint(x: x, y: y-4)); context.addLine(to: CGPoint(x: x+4, y: y))
                context.addLine(to: CGPoint(x: x, y: y+4)); context.addLine(to: CGPoint(x: x-4, y: y))
                context.closePath(); context.fillPath()
                context.setStrokeColor(UIColor.black.withAlphaComponent(0.7).cgColor); context.setLineWidth(0.5)
                context.move(to: CGPoint(x: x, y: y-4)); context.addLine(to: CGPoint(x: x+4, y: y))
                context.addLine(to: CGPoint(x: x, y: y+4)); context.addLine(to: CGPoint(x: x-4, y: y))
                context.closePath(); context.strokePath()
            }
            context.restoreGState()
        }
    }

    private func hitClip(at point: CGPoint) -> TimelineDisplayClip? {
        return clips.first {
            guard (36...(36+clipHeight(trackID: $0.placement.trackID))).contains(point.y-rowOffset($0)) else { return false }
            let left = viewport.x(for: $0.placement.timelineStart.seconds)
            let right = viewport.x(for: (try? $0.placement.range.end.seconds) ?? 0)
            return point.x >= left && point.x <= right
        }
    }

    private func visibleRect(for clip: TimelineDisplayClip) -> CGRect {
        let left = viewport.x(for: clip.placement.timelineStart.seconds)
        let right = viewport.x(for: (try? clip.placement.range.end.seconds) ?? 0)
        return CGRect(x: left, y: 36 + rowOffset(clip), width: max(1, right-left),
                      height: clipHeight(trackID: clip.placement.trackID))
    }

    private var marqueeRect: CGRect? {
        guard let origin = marqueeOrigin, let point = marqueePoint else { return nil }
        return CGRect(x: min(origin.x, point.x), y: min(origin.y, point.y),
                      width: abs(point.x-origin.x), height: abs(point.y-origin.y))
    }

    private func updateMarquee(to point: CGPoint) {
        marqueePoint = point
        guard let rect = marqueeRect else { return }
        let hit = Set(clips.filter { rect.intersects(visibleRect(for: $0)) }.map(\.id))
        if hit != marqueeSelection {
            UISelectionFeedbackGenerator().selectionChanged()
            marqueeSelection = hit
        }
        setNeedsDisplay()
    }

    private func finishMarquee(commit: Bool) {
        let selection = marqueeSelection
        marqueeOrigin = nil; marqueePoint = nil; marqueeSelection = []
        scroll.panGestureRecognizer.isEnabled = true
        if commit { onSelectMany?(selection) }
        setNeedsDisplay()
    }

    private func hitTransition(at point: CGPoint) -> TimelineTransition? {
        transitions.first { transition in
            guard transition.enabled,
                  let outgoing = clips.first(where: { $0.id == transition.outgoingClipID }),
                  let row = displayTracks.firstIndex(where: { $0.id == outgoing.placement.trackID }) else { return false }
            let x = viewport.x(for: transition.editTime.seconds)
            let y = rowTop(row) + 36 + clipHeight(trackID: outgoing.placement.trackID) / 2 - scroll.contentOffset.y
            return abs(point.x - x) <= 18 && abs(point.y - y) <= 22
        }
    }

    private func operation(at point: CGPoint, clip: TimelineDisplayClip) -> TimelineGestureEdit? {
        guard selectedIDs.count == 1,
              (30...(42+clipHeight(trackID: clip.placement.trackID))).contains(point.y-rowOffset(clip)),
              !isLocked(clip) else { return nil }
        let left = viewport.x(for: clip.placement.timelineStart.seconds)
        let right = viewport.x(for: (try? clip.placement.range.end.seconds) ?? 0)
        if abs(point.x-left) < 18 { return .trimStart }
        if abs(point.x-right) < 18 { return .trimEnd }
        return nil
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === hold {
            // Holding a clip moves it; holding open timeline space starts a
            // desktop-style marquee across as many rows as the drag crosses.
            return gestureRecognizer.location(in: self).y >= 30
        }
        guard gestureRecognizer === editPan else { return true }
        guard let clip = clips.first(where: { $0.id == selectedID }) else { return false }
        return operation(at: gestureRecognizer.location(in: self), clip: clip) != nil
    }
    @objc private func edited(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            guard let clip = clips.first(where: { $0.id == selectedID }),
                  let operation = operation(at: recognizer.location(in: self), clip: clip) else { return }
            onBeginEdit?()
            let time = operation == .trimEnd ? ((try? clip.placement.range.end.seconds) ?? 0) : clip.placement.timelineStart.seconds
            ghost = (clip, operation, time); snappedBoundary = nil
        case .changed:
            guard var ghost else { return }
            let sourceRange = assets.first(where: { $0.id == ghost.clip.assetID })?.sourceRange
            let base = ghost.operation == .trimEnd ? ((try? ghost.clip.placement.range.end.seconds) ?? 0) : ghost.clip.placement.timelineStart.seconds
            let rawTarget = max(0, base + recognizer.translation(in: self).x / zoom)
            // A title belongs to the edit, not just its otherwise-empty text
            // row. Its handles therefore see every picture cut and marker.
            let trackFilter = ghost.clip.isText ? nil : ghost.clip.placement.trackID
            let proposed = TimelineEditing.snapClipEdge(
                rawTarget, clips: clips, markers: markers, excluding: ghost.clip.id,
                trackID: trackFilter, playhead: currentTime, tolerance: 14/zoom)
            let targetIsSticky = snappedBoundary.map { abs($0-rawTarget) <= 22/zoom } == true
            var target = targetIsSticky ? snappedBoundary! : proposed
            let newSnap = target == rawTarget ? nil : target
            if let newSnap, newSnap != snappedBoundary { UISelectionFeedbackGenerator().selectionChanged() }
            snappedBoundary = newSnap
            let end = (try? ghost.clip.placement.range.end.seconds) ?? 0
            let start = ghost.clip.placement.timelineStart.seconds
            // The main video track ripples: it is repacked from zero after the
            // edit, so a neighbour moves along instead of stopping the handle.
            // The limits that remain are the ones that are real -- how much
            // source there is, and the minimum length.
            let ripples = tracks.first { $0.id == ghost.clip.placement.trackID }?.kind == .mainVideo
            if ghost.operation == .trimStart {
                let neighbours = clips.filter { $0.id != ghost.clip.id && $0.placement.trackID == ghost.clip.placement.trackID && $0.placement.timelineStart.seconds < start }
                // One frame short of the previous clip's start, so repacking
                // cannot reorder the two.
                let previousLimit = (ripples
                    ? neighbours.map { $0.placement.timelineStart.seconds + minimumDuration }
                    : neighbours.compactMap { try? $0.placement.range.end.seconds }).max() ?? 0
                let sourceLimit = ghost.clip.isText ? 0 : start - ghost.clip.sourceRange.start.seconds + (sourceRange?.start.seconds ?? 0)
                target = max(max(previousLimit, sourceLimit), min(target, end - minimumDuration))
            }
            if ghost.operation == .trimEnd {
                let nextStart = ripples ? Double.greatestFiniteMagnitude
                    : clips.filter { $0.id != ghost.clip.id && $0.placement.trackID == ghost.clip.placement.trackID && $0.placement.timelineStart.seconds >= end }
                        .map { $0.placement.timelineStart.seconds }.min() ?? .greatestFiniteMagnitude
                let isStill = assets.first(where: { $0.id == ghost.clip.assetID })?.stillImage != nil
                let sourceEnd = isStill || ghost.clip.isText ? Double.greatestFiniteMagnitude : ((try? sourceRange?.end.seconds) ?? end)
                let clipSourceEnd = (try? ghost.clip.sourceRange.end.seconds) ?? end
                target = min(min(nextStart, end + sourceEnd - clipSourceEnd), max(target, start + minimumDuration))
            }
            ghost.time = target; self.ghost = ghost; setNeedsDisplay()
        case .ended:
            if let ghost { onEdit?(ghost.clip.id, ghost.operation, ghost.time) }
            ghost = nil; setNeedsDisplay()
        case .cancelled, .failed: ghost = nil; setNeedsDisplay()
        default: break
        }
    }

    @objc private func held(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            let location = recognizer.location(in: self)
            guard let clip = hitClip(at: location), !isLocked(clip) else {
                marqueeOrigin = location
                marqueePoint = location
                marqueeSelection = []
                scroll.panGestureRecognizer.isEnabled = false
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                setNeedsDisplay()
                return
            }
            onBeginEdit?()
            selectedID = clip.id
            ghost = (clip, .move, clip.placement.timelineStart.seconds)
            dragPoint = recognizer.location(in: self)
            holdOrigin = dragPoint; holdStarted = .now; hasMoved = false; snappedBoundary = nil; layerDropTarget = nil
            dragAnchor = (dragPoint.x + scroll.contentOffset.x - bounds.midX) / zoom - clip.placement.timelineStart.seconds
            scroll.panGestureRecognizer.isEnabled = false
            onDragSelect?(clip.id)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            dragTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.scrollWhileDragging() }
            }
            if let dragTimer { RunLoop.main.add(dragTimer, forMode: .common) }
            setNeedsDisplay()
        case .changed:
            if marqueeOrigin != nil {
                updateMarquee(to: recognizer.location(in: self))
                return
            }
            dragPoint = recognizer.location(in: self)
            if hypot(dragPoint.x-holdOrigin.x, dragPoint.y-holdOrigin.y) > 8 { hasMoved = true }
            if layerDropTarget != nil ||
                (ghost.map { !$0.clip.isAudio && !$0.clip.isText } == true && abs(dragPoint.y-holdOrigin.y) > 24 &&
                 abs(dragPoint.y-holdOrigin.y) > abs(dragPoint.x-holdOrigin.x)*1.2) {
                updateLayerDrag(); return
            }
            if hasMoved { updateDrag() }
        case .ended:
            if marqueeOrigin != nil { finishMarquee(commit: true); return }
            let finished = hasMoved ? ghost : nil
            let destination = layerDropTarget
            finishDrag()
            if let finished, let destination {
                onMoveClipToLayer?(finished.clip.id, destination, finished.time)
            } else if let finished {
                onEdit?(finished.clip.id, .move, finished.time)
            }
        case .cancelled, .failed:
            if marqueeOrigin != nil { finishMarquee(commit: false) }
            else { finishDrag() }
        default: break
        }
    }

    private func finishDrag() {
        dragTimer?.invalidate(); dragTimer = nil
        ghost = nil; snappedBoundary = nil; layerDropTarget = nil
        scroll.panGestureRecognizer.isEnabled = true
        updating = true
        scroll.contentSize.height = max(bounds.height, contentHeight)
        updating = false
        setNeedsDisplay()
    }

    private func scrollWhileDragging() {
        guard ghost?.operation == .move else { return }
        if layerDropTarget != nil {
            let delta: CGFloat = dragPoint.y > bounds.height-24 ? 3 : dragPoint.y < 50 ? -3 : 0
            updating = true
            scroll.contentOffset.y = max(0, min(scroll.contentSize.height-bounds.height, scroll.contentOffset.y+delta))
            updating = false; updateLayerDrag(); return
        }
        if !hasMoved {
            if Date.now.timeIntervalSince(holdStarted) >= 0.65, let id = ghost?.clip.id {
                finishDrag()
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onOptions?(id)
            }
            return
        }
        let edge = 44.0
        let speed = dragPoint.x < edge ? -min(1, (edge-dragPoint.x)/edge)
            : dragPoint.x > bounds.width-edge ? min(1, (dragPoint.x-bounds.width+edge)/edge) : 0
        guard speed != 0 else { return }
        updating = true
        scroll.contentOffset.x = min(duration*zoom, max(0, scroll.contentOffset.x + speed*4))
        updating = false
        updateDrag()
    }

    private func updateDrag() {
        guard var ghost else { return }
        let target = max(0, (dragPoint.x + scroll.contentOffset.x - bounds.midX) / zoom - dragAnchor)
        if tracks.first(where: { $0.id == ghost.clip.placement.trackID })?.kind != .mainVideo {
            let sticky = snappedBoundary.flatMap { abs($0-target) <= 22/zoom ? $0 : nil }
            let destination = sticky ?? TimelineEditing.snapMovingClipStart(
                target, duration: ghost.clip.placement.duration.seconds,
                clips: clips, markers: markers, excluding: ghost.clip.id,
                playhead: currentTime, tolerance: 14/zoom)
            if destination != target && destination != snappedBoundary { UISelectionFeedbackGenerator().selectionChanged() }
            ghost.time = destination; self.ghost = ghost
            snappedBoundary = destination == target ? nil : destination
            setNeedsDisplay(); return
        }
        let others = clips.filter { $0.id != ghost.clip.id && $0.placement.trackID == ghost.clip.placement.trackID }
        let next = others.first { target < $0.placement.timelineStart.seconds + $0.placement.duration.seconds/2 }
        let slot = next?.placement.timelineStart.seconds ?? ((try? others.last?.placement.range.end.seconds) ?? 0)
        if snappedBoundary != slot { UISelectionFeedbackGenerator().selectionChanged() }
        snappedBoundary = slot
        ghost.time = slot
        self.ghost = ghost
        setNeedsDisplay()
    }
    private func updateLayerDrag() {
        guard let moving = ghost?.clip, !moving.isAudio, !moving.isText, !tracks.isEmpty else { return }
        let y = dragPoint.y+scroll.contentOffset.y-32
        let visual = tracks.indices.filter { tracks[$0].kind == .mainVideo || tracks[$0].kind == .videoOverlay }
        guard !visual.isEmpty else { return }

        // The middle of a row is an existing-layer target. Its top/bottom edge
        // is a roomy insertion target, so users do not have to hit the tiny
        // eight-point gap exactly to create a layer.
        let existing = visual.first { index in
            let top = rowTop(index, in: tracks)
            let inset = min(16, clipHeight(tracks[index]) * 0.24)
            return y >= top + inset && y <= top + clipHeight(tracks[index]) - inset
        }
        let target: TimelineLayerDropTarget
        if let existing {
            target = .track(tracks[existing].id)
        } else {
            let proposed = tracks.indices.first { index in
                y < rowTop(index, in: tracks) + clipHeight(tracks[index]) / 2
            } ?? tracks.count
            // An overlay below the main picture would normally be hidden by it.
            // Clamp new visual rows immediately above the main row instead.
            let main = tracks.firstIndex { $0.kind == .mainVideo } ?? tracks.count
            target = .newOverlay(index: min(proposed, main))
        }
        if target != layerDropTarget { UISelectionFeedbackGenerator().selectionChanged() }
        layerDropTarget = target

        // Horizontal travel remains live during a vertical layer drag, including
        // magnetic alignment with playhead, markers and other clip edges.
        guard var movingGhost = ghost else { return }
        let raw = max(0, (dragPoint.x + scroll.contentOffset.x - bounds.midX) / zoom - dragAnchor)
        let sticky = snappedBoundary.flatMap { abs($0-raw) <= 22/zoom ? $0 : nil }
        let snapped = sticky ?? TimelineEditing.snapMovingClipStart(
            raw, duration: moving.placement.duration.seconds,
            clips: clips, markers: markers, excluding: moving.id,
            playhead: currentTime, tolerance: 14/zoom)
        if snapped != raw && snapped != snappedBoundary { UISelectionFeedbackGenerator().selectionChanged() }
        snappedBoundary = snapped == raw ? nil : snapped
        movingGhost.time = snapped
        ghost = movingGhost
        updating = true
        scroll.contentSize.height = max(bounds.height, contentHeight)
        updating = false
        setNeedsDisplay()
    }
}
