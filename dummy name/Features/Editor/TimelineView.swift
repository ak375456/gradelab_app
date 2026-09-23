import SwiftUI
import UIKit

/// A vertical clip drag either lands on an existing row of the clip's own kind
/// or opens a new row at the indicated position. Track ordering itself remains
/// in the Layers sheet, so dragging a clip never unexpectedly moves its
/// neighbours.
///
/// Landing on an occupied row is normal, not a collision: a row holds a
/// sequence, so a second sound or title shares it with one already there as
/// long as the two never run at the same time.
enum TimelineLayerDropTarget: Equatable {
    case track(UUID)
    case newTrack(kind: TimelineTrack.Kind, index: Int)
}

/// The choices themselves live on the track, in the document. What each one
/// measures is a question about this screen, so it stays here.
extension TimelineTrackHeightChoice {
    /// Regular media rows are sized to hold a 16:9 filmstrip above a readable
    /// waveform lane; below that the row drops to a name strip.
    ///
    /// Deliberately tighter than the drawing would like. The timeline shares a
    /// phone screen with a picture, a transport, a tool panel and the mode bar,
    /// and a row that reads beautifully on its own is not worth pushing one of
    /// those off the bottom for.
    func points(for kind: TimelineTrack.Kind) -> CGFloat {
        switch self {
        case .compact: kind.isDrawnOverlay ? 24 : 26
        case .regular: kind.isDrawnOverlay ? 30 : 66
        case .tall: kind.isDrawnOverlay ? 44 : 96
        }
    }
}

extension TimelineWaveformSize {
    var scale: CGFloat { self == .small ? 0.55 : self == .large ? 1.35 : 1 }
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
    /// Points per second, owned by the view that hosts the timeline so the zoom
    /// control and the canvas's pinch stay in step.
    let pixelsPerSecond: Double
    /// Magnetic alignment for the playhead, trim handles and clip moves. The
    /// main video track still ripples when it is off: packing is how that track
    /// works, not a snap.
    let isSnappingEnabled: Bool
    /// Whether clips carry their file name and their length. Both are settings
    /// rather than state, so someone who would rather see the picture and the
    /// waveform can uncover them.
    let showsClipNames: Bool
    let showsClipDurations: Bool
    let onZoomChange: (Double) -> Void
    let onSelect: (UUID?) -> Void
    let onSelectMany: (Set<UUID>) -> Void
    let onSelectTransition: (UUID) -> Void
    let onDragSelect: (UUID) -> Void
    let onOptions: (UUID) -> Void
    /// A media-bin drag let go over the timeline: the asset and the second it
    /// landed on.
    let onDropAsset: (UUID, Double) -> Void
    let onMoveClipToLayer: (UUID, TimelineLayerDropTarget, Double) -> Void
    let onToggleTrackVisibility: (UUID) -> Void
    let onToggleTrackLock: (UUID) -> Void
    let onToggleTrackMute: (UUID) -> Void
    let onSetTrackHeight: (UUID, TimelineTrackHeightChoice) -> Void
    let onSetWaveformSize: (UUID, TimelineWaveformSize) -> Void
    let onEdit: (UUID, TimelineGestureEdit, Double) -> Void
    let onTrimMany: (Set<UUID>, TimelineGestureEdit, Double) -> Void
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
        view.isSnappingEnabled = isSnappingEnabled
        view.showsClipNames = showsClipNames
        view.showsClipDurations = showsClipDurations
        view.onZoomChange = onZoomChange
        view.onDragSelect = onDragSelect
        view.onOptions = onOptions
        view.onDropAsset = onDropAsset
        view.onMoveClipToLayer = onMoveClipToLayer
        view.onToggleTrackVisibility = onToggleTrackVisibility
        view.onToggleTrackLock = onToggleTrackLock
        view.onToggleTrackMute = onToggleTrackMute
        view.onSetTrackHeight = onSetTrackHeight
        view.onSetWaveformSize = onSetWaveformSize
        view.onEdit = onEdit; view.onTrimMany = onTrimMany; view.onBeginEdit = onBeginEdit
        view.onSelect = onSelect; view.onBeginSeek = onBeginSeek
        view.onSelectMany = onSelectMany
        view.onSelectTransition = onSelectTransition
        view.onSeek = onSeek; view.onEndSeek = onEndSeek
        view.applyExternalZoom(pixelsPerSecond)
        view.updateTrackControls()
        view.update(time: currentTime)
    }
    static func dismantleUIView(_ view: TimelineCanvas, coordinator: ()) { view.cancelInteraction() }
}

/// Only the viewport is drawn. UIScrollView supplies touch/inertia, not a giant
/// filmstrip view or thousands of ruler/thumbnail subviews.
///
/// The canvas owns interaction and the composition's geometry; everything it
/// puts on screen is drawn by `TimelineClipRenderer` and
/// `TimelineChromeRenderer`, and the track headers are real UIKit views. New
/// row types, overlays and badges are therefore added by describing them to a
/// renderer rather than by growing `draw(_:)`.
final class TimelineCanvas: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var clips: [TimelineDisplayClip] = []
    var tracks: [TimelineTrack] = []
    var markers: [TimelineMarker] = []
    var transitions: [TimelineTransition] = []
    var keyframeTimes: [Double] = []
    var assets: [ProjectMediaAsset] = []
    var assetFrames: [UUID: [UIImage]] = [:]
    var waveforms: [UUID: [Float]] = [:] {
        // Envelopes for assets that have left the timeline are released here
        // rather than during drawing: membership changes with the document,
        // not sixty times a second while someone scrolls.
        didSet {
            guard waveforms.count != oldValue.count else { return }
            waveformCache.retain(assetIDs: Set(waveforms.keys))
        }
    }
    private func clipHeight(_ track: TimelineTrack?) -> CGFloat {
        let kind = track?.kind ?? .mainVideo
        let preferred = track.map { $0.resolvedHeight.points(for: $0.kind) }
            ?? TimelineTrackHeightChoice.regular.points(for: kind)
        // A row taller than the canvas is a row with its bottom cut off. When
        // the workspace hands the timeline less height than one row wants — a
        // short phone, or a picture someone dragged large — shrink the row
        // instead, down to the compact size. More rows than fit still scroll,
        // which is what scrolling is for; a single clipped row is just wrong.
        let available = bounds.height - TimelineMetrics.rowsTop - 4
        guard bounds.height > 0, available < preferred else { return preferred }
        return max(TimelineTrackHeightChoice.compact.points(for: kind), available)
    }
    private func clipHeight(trackID: UUID) -> CGFloat { clipHeight(tracks.first { $0.id == trackID }) }
    /// Cumulative top of a row within the scrolled content, so rows may differ in height.
    private func rowTop(_ index: Int, in rows: [TimelineTrack]? = nil) -> CGFloat {
        let rows = rows ?? displayTracks
        return rows.prefix(max(0, index)).reduce(0) { $0 + clipHeight($1) + TimelineMetrics.rowGap }
    }
    private var contentHeight: CGFloat { rowTop(displayTracks.count) + TimelineMetrics.rowsTop }
    private func rowOffset(_ clip: TimelineDisplayClip) -> CGFloat {
        if clip.id == ghost?.clip.id, let layerDropTarget {
            let destinationID: UUID
            switch layerDropTarget {
            case .track(let id): destinationID = id
            case .newTrack: destinationID = newOverlayPreviewID
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
    var isSnappingEnabled = true
    var showsClipNames = true
    var showsClipDurations = true
    var onZoomChange: ((Double) -> Void)?
    var onSelect: ((UUID?) -> Void)?
    var onSelectMany: ((Set<UUID>) -> Void)?
    var onSelectTransition: ((UUID) -> Void)?
    var onDragSelect: ((UUID) -> Void)?
    var onOptions: ((UUID) -> Void)?
    var onDropAsset: ((UUID, Double) -> Void)?
    /// Where a media-bin drag would land, while it is over the timeline.
    private var dropPreviewTime: Double?
    var onMoveClipToLayer: ((UUID, TimelineLayerDropTarget, Double) -> Void)?
    var onToggleTrackVisibility: ((UUID) -> Void)?
    var onToggleTrackLock: ((UUID) -> Void)?
    var onToggleTrackMute: ((UUID) -> Void)?
    var onSetTrackHeight: ((UUID, TimelineTrackHeightChoice) -> Void)?
    var onSetWaveformSize: ((UUID, TimelineWaveformSize) -> Void)?
    private var layerDropTarget: TimelineLayerDropTarget?
    private let newOverlayPreviewID = UUID()
    private var displayTracks: [TimelineTrack] {
        guard case .newTrack(let kind, let index) = layerDropTarget else { return tracks }
        var result = tracks
        result.insert(.init(id: newOverlayPreviewID,
                            name: TimelineTrack.localizedName(TimelineTrack.defaultName(for: kind)), kind: kind),
                      at: min(max(0, index), result.count))
        return result
    }
    var onEdit: ((UUID, TimelineGestureEdit, Double) -> Void)?
    /// A trim carrying every selected clip. The third value is how far the
    /// edge travelled, not where it landed: each clip applies it to its own.
    var onTrimMany: ((Set<UUID>, TimelineGestureEdit, Double) -> Void)?
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
    /// Whether the edge scroll has taken the playhead with it, so the seek it
    /// opened is closed exactly once when the marquee ends.
    private var marqueeSeeking = false
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
    /// Opaque backing for the header column, so clips scrolling past never show
    /// through the gaps between one header and the next.
    private let headerBackdrop = TimelinePassthroughView()
    private var trackHeaders: [UUID: TimelineTrackHeaderView] = [:]
    private let waveformCache = TimelineWaveformCache()
    private var zoom = 48.0
    private var pinchZoom = 48.0
    private var currentTime = 0.0
    private var interacting = false
    private var updating = false
    private var pinching = false
    private var playheadSnap: Double?
    private var revealedSelection: UUID?
    private var duration: Double { clips.compactMap { try? $0.placement.range.end.seconds }.max() ?? 0 }
    /// Left edge of the scrolling content: everything left of it belongs to the
    /// track headers.
    private var contentLeft: CGFloat { TimelineMetrics.headerWidth(for: bounds.width) }
    private var viewport: TimelineViewport {
        .init(pixelsPerSecond: zoom, width: bounds.width,
              offset: interacting && !pinching ? currentTime * zoom : scroll.contentOffset.x)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = TimelineTheme.background
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
        headerBackdrop.backgroundColor = TimelineTheme.background
        headerBackdrop.isOpaque = true
        addSubview(headerBackdrop)
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
        // Right-click, which a trackpad's two-finger tap and a Magic Mouse's
        // right side both produce. Holding a clip is how a touch screen asks
        // for the same menu; on a desktop that gesture is a drag, so the menu
        // needs a button of its own rather than a duration.
        let secondaryClick = UITapGestureRecognizer(target: self, action: #selector(secondaryClicked(_:)))
        secondaryClick.buttonMaskRequired = .secondary
        // `buttonMaskRequired` filters BUTTONS, and a finger presses none, so
        // on its own it does not exclude direct touches — every tap on the
        // timeline opened the clip menu on iPad and iPhone. Restricting the
        // recogniser to an indirect pointer is what actually makes this a
        // trackpad and mouse gesture. Touch keeps hold-to-open, unchanged.
        secondaryClick.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        scroll.addGestureRecognizer(secondaryClick)
        addInteraction(UIDropInteraction(delegate: self))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.delegate = self
        scroll.addGestureRecognizer(pinch)
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Video and audio timeline")
        accessibilityTraits = .adjustable
        accessibilityHint = String(localized: "Swipe up or down to seek one second. Pinch to zoom. Hold a clip and drag sideways to move it or vertically to move it to another layer.")
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: String(localized: "Select clip"), target: self, selector: #selector(selectClip)),
            UIAccessibilityCustomAction(name: String(localized: "Deselect clip"), target: self, selector: #selector(deselectClip)),
            UIAccessibilityCustomAction(name: String(localized: "Zoom in"), target: self, selector: #selector(zoomIn)),
            UIAccessibilityCustomAction(name: String(localized: "Zoom out"), target: self, selector: #selector(zoomOut))
        ]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        updating = true
        scroll.frame = bounds
        headerBackdrop.frame = CGRect(x: 0, y: TimelineMetrics.rulerHeight, width: contentLeft,
                                      height: max(0, bounds.height - TimelineMetrics.rulerHeight))
        scroll.contentSize = CGSize(width: duration * zoom + bounds.width, height: max(bounds.height, contentHeight))
        if ghost == nil && !interacting { scroll.contentOffset.x = currentTime * zoom }
        updating = false
        layoutTrackControls()
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

    /// Adopts a zoom chosen outside the canvas — the slider, or its own pinch
    /// having been reported back through SwiftUI state. Ignored mid-pinch so a
    /// live gesture is never fought by a stale value.
    func applyExternalZoom(_ value: Double) {
        guard !pinching, value.isFinite, abs(value - zoom) > 0.0001 else { return }
        setZoom(value, notifying: false)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { beginInteraction() }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        layoutTrackControls()
        guard !updating, interacting, !pinching else { return }
        let rawTime = min(duration, max(0, scroll.contentOffset.x / zoom))
        // Keep raw touch travel independent from the displayed snapped position,
        // so the magnet releases naturally rather than trapping the scroll view.
        if let playheadSnap, abs(rawTime-playheadSnap) * zoom <= 22 {
            currentTime = playheadSnap
        } else {
            let snapped = TimelineEditing.snapPlayhead(rawTime, clips: clips, markers: markers, keyframes: keyframeTimes, tolerance: snapTolerance(12))
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
            targetContentOffset.pointee.x = TimelineEditing.snapPlayhead(seconds, clips: clips, markers: markers, keyframes: keyframeTimes, tolerance: snapTolerance(12)) * zoom
        }
    }

    /// Magnet strength in seconds for a given touch slack in points, or zero
    /// when the magnet button is off.
    private func snapTolerance(_ points: Double) -> Double {
        isSnappingEnabled ? points / zoom : 0
    }

    private func beginInteraction() {
        guard !interacting else { return }
        playheadSnap = nil
        interacting = true; onBeginSeek?()
    }
    private func endInteraction() {
        guard interacting else { return }
        let snapped = TimelineEditing.snapPlayhead(currentTime, clips: clips, markers: markers, keyframes: keyframeTimes, tolerance: snapTolerance(10))
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
        // The header column is a control panel, not timeline content.
        guard point.x >= contentLeft else { return }
        if point.y < TimelineMetrics.rulerHeight {
            seek(to: viewport.seconds(at: point.x, duration: duration))
        } else if let transition = hitTransition(at: point) {
            onSelectTransition?(transition.id)
        } else {
            onSelect?(hitClip(at: point)?.id)
        }
    }
    /// A secondary click on a clip opens its options. On empty timeline or on
    /// the ruler it does nothing, rather than opening a menu about no clip.
    @objc private func secondaryClicked(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: self)
        guard point.x >= contentLeft, point.y >= TimelineMetrics.rulerHeight,
              let clip = hitClip(at: point) else { return }
        onOptions?(clip.id)
    }

    private func setDropPreview(_ time: Double?) {
        guard dropPreviewTime != time else { return }
        dropPreviewTime = time
        setNeedsDisplay()
    }

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            pinching = true; beginInteraction(); pinchZoom = zoom
            scroll.panGestureRecognizer.isEnabled = false
            scroll.setContentOffset(scroll.contentOffset, animated: false)
        // Not reported while the fingers are down: the zoom lives in SwiftUI
        // state, and publishing it sixty times a second would re-evaluate the
        // whole editor on every frame of the gesture.
        case .changed: setZoom(pinchZoom * recognizer.scale, notifying: false)
        case .ended, .cancelled, .failed:
            scroll.panGestureRecognizer.isEnabled = true
            pinching = false; endInteraction()
            onZoomChange?(zoom)
        default: break
        }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer
    }
    private func setZoom(_ value: Double, notifying: Bool = true) {
        let clamped = min(TimelineViewport.zoomRange.upperBound, max(TimelineViewport.zoomRange.lowerBound, value))
        guard clamped != zoom else { return }
        zoom = clamped
        updating = true
        scroll.contentSize.width = duration * zoom + bounds.width
        scroll.contentOffset.x = currentTime * zoom
        updating = false
        if notifying { onZoomChange?(zoom) }
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

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let geometry = viewport
        let rows = displayTracks
        let chrome = TimelineChromeRenderer(context: context, canvas: bounds,
                                            geometry: geometry, contentLeft: contentLeft)
        // Clips are culled and their chips pinned against the content area, so
        // nothing is drawn under the header column and a name chip stops at
        // the timeline's own left edge.
        let content = CGRect(x: contentLeft, y: 0, width: max(0, bounds.width - contentLeft),
                             height: bounds.height)
        let clipRenderer = TimelineClipRenderer(context: context, canvas: content, geometry: geometry,
                                                pixelsPerSecond: zoom, waveformCache: waveformCache)

        context.saveGState()
        context.clip(to: CGRect(x: 0, y: TimelineMetrics.rulerHeight, width: bounds.width,
                                height: max(0, bounds.height - TimelineMetrics.rulerHeight)))

        // Lanes first: a track reads as a channel that continues past its last
        // clip rather than as rectangles floating in space.
        let laneWidth = max(0, bounds.width - contentLeft)
        for (index, track) in rows.enumerated() {
            let top = TimelineMetrics.rowsTop + rowTop(index, in: rows) - scroll.contentOffset.y
            let height = clipHeight(track)
            guard top + height >= TimelineMetrics.rulerHeight, top <= bounds.height else { continue }
            let isPreview = track.id == newOverlayPreviewID
            chrome.drawLane(CGRect(x: contentLeft, y: top, width: laneWidth, height: height),
                            isDropTarget: isPreview)
            if isPreview {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: TimelineTheme.accent
                ]
                (String(localized: "New overlay") as NSString).draw(
                    at: CGPoint(x: contentLeft + 10, y: top + height / 2 - 7), withAttributes: attributes)
            }
        }

        let insertion = insertionPreview
        for clip in clips {
            clipRenderer.draw(presentation(for: clip, insertion: insertion))
        }

        for transition in transitions where transition.enabled {
            guard let outgoing = clips.first(where: { $0.id == transition.outgoingClipID }),
                  let row = rows.firstIndex(where: { $0.id == outgoing.placement.trackID }) else { continue }
            let point = transitionPoint(row: row, trackID: outgoing.placement.trackID,
                                        time: transition.editTime.seconds, in: rows)
            guard point.x >= -14, point.x <= bounds.width + 14,
                  point.y >= TimelineMetrics.rulerHeight, point.y <= bounds.height else { continue }
            chrome.drawTransition(at: point, isSelected: selectedTransitionID == transition.id)
        }

        if let ghost, ghost.operation == .move, let start = insertion[ghost.clip.id] {
            let top = TimelineMetrics.rowsTop + rowOffset(ghost.clip) - 4
            chrome.drawInsertionLine(x: geometry.x(for: start), top: top,
                                     height: clipHeight(trackID: ghost.clip.placement.trackID) + 8)
        }
        if let dropPreviewTime {
            chrome.drawInsertionLine(x: geometry.x(for: dropPreviewTime), top: TimelineMetrics.rulerHeight,
                                     height: max(0, bounds.height - TimelineMetrics.rulerHeight))
        }
        if let selectionRect = marqueeRect { chrome.drawMarquee(selectionRect) }
        context.restoreGState()

        // Chrome above the rows: the ruler repaints its own band, so a clip
        // scrolled up can never bleed into it.
        chrome.drawRuler(scale: TimelineRulerScale(pixelsPerSecond: zoom, frameDuration: minimumDuration),
                         duration: duration)
        for marker in markers { chrome.drawMarker(at: geometry.x(for: marker.time.seconds)) }
        if let boundary = snappedBoundary ?? playheadSnap {
            chrome.drawSnapIndicator(at: geometry.x(for: boundary))
        }
        chrome.drawPlayhead(at: bounds.midX, time: currentTime, isScrubbing: interacting)
    }

    /// Resolves one clip's appearance, including any live trim or move ghost.
    /// The renderer sees only the result, never the timeline.
    private func presentation(for clip: TimelineDisplayClip, insertion: [UUID: Double]) -> TimelineClipPresentation {
        let asset = assets.first { $0.id == clip.assetID }
        let assetRange = asset?.sourceRange
        var start = clip.placement.timelineStart.seconds
        var end = (try? clip.placement.range.end.seconds) ?? start
        var trimOffset = 0.0
        if let ghost, ghost.operation != .move,
           ghost.clip.id == clip.id || trimmingPartners.contains(where: { $0.id == clip.id }) {
            // Partners move by the anchor's travel, so the preview shows the
            // same relationship the commit will produce.
            let delta = ghost.time - trimEdge(of: ghost.clip, operation: ghost.operation)
            switch ghost.operation {
            case .move: break
            case .trimStart:
                start = clip.placement.timelineStart.seconds + delta
                trimOffset = delta
            case .trimEnd:
                end = ((try? clip.placement.range.end.seconds) ?? end) + delta
            }
        }
        if let position = insertion[clip.id] { start = position; end = start + clip.placement.duration.seconds }

        let geometry = viewport
        let left = geometry.x(for: start), right = geometry.x(for: end)
        let track = tracks.first { $0.id == clip.placement.trackID }
        let title = clip.title
            ?? asset?.audioName
            ?? (asset?.stillImage != nil ? String(localized: "Image overlay") : nil)
            ?? asset?.videoMetadata?.fileName
            ?? name

        var presentation = TimelineClipPresentation(
            clip: clip,
            rect: CGRect(x: left, y: TimelineMetrics.rowsTop + rowOffset(clip),
                         width: max(1, right - left), height: clipHeight(trackID: clip.placement.trackID)),
            title: title,
            duration: max(0, end - start))
        presentation.isSelected = selectedIDs.contains(clip.id) || marqueeSelection.contains(clip.id)
        presentation.isFocused = selectedID == clip.id && selectedIDs.count == 1 && marqueeOrigin == nil
        presentation.showsTrimHandles = selectedIDs.contains(clip.id) && marqueeOrigin == nil
        presentation.isLocked = isLocked(clip)
        presentation.isDimmed = track?.isEnabled == false
        presentation.isStillImage = asset?.stillImage != nil
        presentation.showsName = showsClipNames
        presentation.showsDuration = showsClipDurations
        presentation.mapping = TimelineSourceMapping(
            sourceStart: clip.sourceRange.start.seconds + trimOffset * clip.speed,
            speed: clip.speed,
            assetStart: assetRange?.start.seconds ?? 0,
            assetDuration: assetRange?.duration.seconds ?? max(0.001, clip.sourceRange.duration.seconds))
        presentation.thumbnails = clip.isAudio ? [] : (assetFrames[clip.assetID] ?? [])
        if clip.isAudio || clip.embeddedAudio != nil {
            presentation.waveform = waveformCache.waveform(for: clip.assetID, peaks: waveforms[clip.assetID] ?? [])
            presentation.waveformScale = track?.resolvedWaveformSize.scale ?? 1
        }
        presentation.fade = clip.fade
        if presentation.isFocused { presentation.keyframeTimes = keyframeTimes }
        return presentation
    }

    private func transitionPoint(row: Int, trackID: UUID, time: Double, in rows: [TimelineTrack]) -> CGPoint {
        CGPoint(x: viewport.x(for: time),
                y: TimelineMetrics.rowsTop + rowTop(row, in: rows) + clipHeight(trackID: trackID) / 2
                    - scroll.contentOffset.y)
    }

    // MARK: - Hit testing

    private func hitClip(at point: CGPoint) -> TimelineDisplayClip? {
        guard point.x >= contentLeft else { return nil }
        return clips.first {
            let top = TimelineMetrics.rowsTop + rowOffset($0)
            guard (top...(top + clipHeight(trackID: $0.placement.trackID))).contains(point.y) else { return false }
            let left = viewport.x(for: $0.placement.timelineStart.seconds)
            let right = viewport.x(for: (try? $0.placement.range.end.seconds) ?? 0)
            return point.x >= left && point.x <= right
        }
    }

    private func visibleRect(for clip: TimelineDisplayClip) -> CGRect {
        let left = viewport.x(for: clip.placement.timelineStart.seconds)
        let right = viewport.x(for: (try? clip.placement.range.end.seconds) ?? 0)
        return CGRect(x: left, y: TimelineMetrics.rowsTop + rowOffset(clip), width: max(1, right-left),
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
        dragTimer?.invalidate(); dragTimer = nil
        // Finish the seek the edge scroll started, the same way letting go of a
        // scroll by hand does: settle the playhead and report it once.
        if marqueeSeeking { marqueeSeeking = false; endInteraction() }
        let selection = marqueeSelection
        marqueeOrigin = nil; marqueePoint = nil; marqueeSelection = []
        scroll.panGestureRecognizer.isEnabled = true
        if commit { onSelectMany?(selection) }
        setNeedsDisplay()
    }

    private func hitTransition(at point: CGPoint) -> TimelineTransition? {
        let rows = displayTracks
        return transitions.first { transition in
            guard transition.enabled,
                  let outgoing = clips.first(where: { $0.id == transition.outgoingClipID }),
                  let row = rows.firstIndex(where: { $0.id == outgoing.placement.trackID }) else { return false }
            let centre = transitionPoint(row: row, trackID: outgoing.placement.trackID,
                                         time: transition.editTime.seconds, in: rows)
            return abs(point.x - centre.x) <= 18 && abs(point.y - centre.y) <= 22
        }
    }

    /// The clip edge this operation moves.
    private func trimEdge(of clip: TimelineDisplayClip, operation: TimelineGestureEdit) -> Double {
        operation == .trimEnd
            ? ((try? clip.placement.range.end.seconds) ?? 0)
            : clip.placement.timelineStart.seconds
    }

    /// How far one clip's edge may travel: the neighbours on its row, the
    /// source it still has left, and one frame of minimum length.
    ///
    /// Pulled out of the drag so it can be asked about a clip that is NOT the
    /// one under the finger — a multi-clip trim has to know what every selected
    /// clip can give before it moves any of them.
    private func trimBounds(for clip: TimelineDisplayClip,
                            operation: TimelineGestureEdit) -> (lower: Double, upper: Double) {
        Self.trimBounds(for: clip, operation: operation, clips: clips, tracks: tracks,
                        assets: assets, minimumDuration: minimumDuration)
    }

    static func trimBounds(for clip: TimelineDisplayClip, operation: TimelineGestureEdit,
                           clips: [TimelineDisplayClip], tracks: [TimelineTrack],
                           assets: [ProjectMediaAsset],
                           minimumDuration: Double) -> (lower: Double, upper: Double) {
        let assetRange = assets.first { $0.id == clip.assetID }?.sourceRange
        let start = clip.placement.timelineStart.seconds
        let end = (try? clip.placement.range.end.seconds) ?? 0
        // The main video track ripples: it is repacked from zero after the
        // edit, so a neighbour moves along instead of stopping the handle. The
        // limits that remain are the ones that are real -- how much source
        // there is, and the minimum length.
        let ripples = tracks.first { $0.id == clip.placement.trackID }?.kind == .mainVideo
        switch operation {
        case .move:
            return (-.greatestFiniteMagnitude, .greatestFiniteMagnitude)
        case .trimStart:
            let neighbours = clips.filter {
                $0.id != clip.id && $0.placement.trackID == clip.placement.trackID
                    && $0.placement.timelineStart.seconds < start
            }
            // One frame short of the previous clip's start, so repacking cannot
            // reorder the two.
            let previousLimit = (ripples
                ? neighbours.map { $0.placement.timelineStart.seconds + minimumDuration }
                : neighbours.compactMap { try? $0.placement.range.end.seconds }).max() ?? 0
            let sourceLimit = clip.isDrawnOverlay
                ? 0 : start - clip.sourceRange.start.seconds + (assetRange?.start.seconds ?? 0)
            return (max(previousLimit, sourceLimit), end - minimumDuration)
        case .trimEnd:
            let nextStart = ripples ? Double.greatestFiniteMagnitude
                : clips.filter {
                    $0.id != clip.id && $0.placement.trackID == clip.placement.trackID
                        && $0.placement.timelineStart.seconds >= end
                }.map { $0.placement.timelineStart.seconds }.min() ?? .greatestFiniteMagnitude
            let isStill = assets.first { $0.id == clip.assetID }?.stillImage != nil
            let sourceEnd = isStill || clip.isDrawnOverlay
                ? Double.greatestFiniteMagnitude : ((try? assetRange?.end.seconds) ?? end)
            let clipSourceEnd = (try? clip.sourceRange.end.seconds) ?? end
            return (start + minimumDuration, min(nextStart, end + sourceEnd - clipSourceEnd))
        }
    }

    /// How far a trim may actually travel when it is carrying several clips.
    ///
    /// The narrowest of them decides. Letting each clip stop at its own limit
    /// instead would let the group drift apart mid-drag, which is not what
    /// grabbing one handle for all of them means — they came in with a fixed
    /// relationship and they should leave with it.
    static func clampedTrimDelta(
        _ proposed: Double,
        carried: [(edge: Double, limits: (lower: Double, upper: Double))]
    ) -> Double {
        carried.reduce(proposed) { delta, clip in
            max(clip.limits.lower - clip.edge, min(delta, clip.limits.upper - clip.edge))
        }
    }

    /// The other clips a trim is carrying, in stable timeline order. Empty for
    /// an ordinary single-clip trim, which keeps its exact previous behaviour.
    private var trimmingPartners: [TimelineDisplayClip] {
        guard let ghost, ghost.operation != .move, selectedIDs.count > 1 else { return [] }
        return clips.filter { selectedIDs.contains($0.id) && $0.id != ghost.clip.id && !isLocked($0) }
    }

    /// Which edge a touch is reaching for. The handles are 13pt wide but
    /// answer within 22pt either side of the edge, so the grab region is the
    /// 44pt a finger needs.
    private func operation(at point: CGPoint, clip: TimelineDisplayClip) -> TimelineGestureEdit? {
        let top = TimelineMetrics.rowsTop + rowOffset(clip)
        let height = clipHeight(trackID: clip.placement.trackID)
        guard point.x >= contentLeft,
              ((top - 6)...(top + height + 6)).contains(point.y),
              !isLocked(clip) else { return nil }
        let left = viewport.x(for: clip.placement.timelineStart.seconds)
        let right = viewport.x(for: (try? clip.placement.range.end.seconds) ?? 0)
        if abs(point.x-left) < TimelineMetrics.trimHitSlop { return .trimStart }
        if abs(point.x-right) < TimelineMetrics.trimHitSlop { return .trimEnd }
        return nil
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === hold {
            // Holding a clip moves it; holding open timeline space starts a
            // desktop-style marquee across as many rows as the drag crosses.
            let location = gestureRecognizer.location(in: self)
            return location.y >= TimelineMetrics.rulerHeight && location.x >= contentLeft
        }
        guard gestureRecognizer === editPan else { return true }
        return trimTarget(at: gestureRecognizer.location(in: self)) != nil
    }

    /// The handle a touch has landed on, across the whole selection.
    ///
    /// The clip whose edge was grabbed becomes the anchor the drag follows, so
    /// it does not matter which of several selected clips the finger found.
    /// The focused clip is offered first, so a single selection behaves exactly
    /// as it did.
    private func trimTarget(at point: CGPoint) -> (clip: TimelineDisplayClip, operation: TimelineGestureEdit)? {
        let ordered = clips.filter { selectedIDs.contains($0.id) }
            .sorted { ($0.id == selectedID ? 0 : 1) < ($1.id == selectedID ? 0 : 1) }
        for clip in ordered {
            if let operation = operation(at: point, clip: clip) { return (clip, operation) }
        }
        return nil
    }
    @objc private func edited(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            guard let target = trimTarget(at: recognizer.location(in: self)) else { return }
            onBeginEdit?()
            ghost = (target.clip, target.operation,
                     trimEdge(of: target.clip, operation: target.operation))
            snappedBoundary = nil
        case .changed:
            guard var ghost else { return }
            let base = trimEdge(of: ghost.clip, operation: ghost.operation)
            let rawTarget = max(0, base + recognizer.translation(in: self).x / zoom)
            // A title belongs to the edit, not just its otherwise-empty text
            // row. Its handles therefore see every picture cut and marker.
            let trackFilter = ghost.clip.isDrawnOverlay ? nil : ghost.clip.placement.trackID
            let proposed = TimelineEditing.snapClipEdge(
                rawTarget, clips: clips, markers: markers, excluding: ghost.clip.id,
                trackID: trackFilter, playhead: currentTime, tolerance: snapTolerance(14))
            let targetIsSticky = snappedBoundary.map { abs($0-rawTarget) <= 22/zoom } == true
            var target = targetIsSticky ? snappedBoundary! : proposed
            let newSnap = target == rawTarget ? nil : target
            if let newSnap, newSnap != snappedBoundary { UISelectionFeedbackGenerator().selectionChanged() }
            snappedBoundary = newSnap
            let anchorLimits = trimBounds(for: ghost.clip, operation: ghost.operation)
            target = max(anchorLimits.lower, min(target, anchorLimits.upper))

            // Several clips selected: the handle drags them all by the same
            // amount, so they keep whatever lengths they already had relative
            // to each other. The travel is clamped to what the most restricted
            // of them can give — letting each stop at its own limit would let
            // the group drift apart mid-drag, which is not what grabbing one
            // handle for all of them means.
            if trimmingPartners.isEmpty {
                ghost.time = target
            } else {
                let carried = (trimmingPartners + [ghost.clip]).map { clip in
                    (edge: trimEdge(of: clip, operation: ghost.operation),
                     limits: trimBounds(for: clip, operation: ghost.operation))
                }
                ghost.time = base + Self.clampedTrimDelta(target - base, carried: carried)
                if ghost.time != target { snappedBoundary = nil }
            }
            self.ghost = ghost; setNeedsDisplay()
        case .ended:
            if let ghost {
                if trimmingPartners.isEmpty {
                    onEdit?(ghost.clip.id, ghost.operation, ghost.time)
                } else {
                    let delta = ghost.time - trimEdge(of: ghost.clip, operation: ghost.operation)
                    onTrimMany?(Set(([ghost.clip] + trimmingPartners).map(\.id)), ghost.operation, delta)
                }
            }
            ghost = nil; snappedBoundary = nil; setNeedsDisplay()
        case .cancelled, .failed: ghost = nil; snappedBoundary = nil; setNeedsDisplay()
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
                dragPoint = location
                scroll.panGestureRecognizer.isEnabled = false
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                startDragTimer()
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
            startDragTimer()
            setNeedsDisplay()
        case .changed:
            if marqueeOrigin != nil {
                dragPoint = recognizer.location(in: self)
                updateMarquee(to: dragPoint)
                return
            }
            dragPoint = recognizer.location(in: self)
            if hypot(dragPoint.x-holdOrigin.x, dragPoint.y-holdOrigin.y) > 8 { hasMoved = true }
            if layerDropTarget != nil ||
                (ghost != nil && abs(dragPoint.y-holdOrigin.y) > 24 &&
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

    private func startDragTimer() {
        dragTimer?.invalidate()
        dragTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scrollWhileDragging() }
        }
        if let dragTimer { RunLoop.main.add(dragTimer, forMode: .common) }
    }

    /// How fast the timeline travels when a drag is held near an edge, and in
    /// which direction. Ramped by how far into the margin the finger is, so a
    /// gentle push creeps and a firm one covers ground.
    static func edgeScrollDelta(_ point: CGPoint, in region: CGRect,
                                margin: CGFloat, speed: CGFloat) -> CGVector {
        func axis(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            guard margin > 0, high > low else { return 0 }
            if value < low + margin { return -min(1, (low + margin - value) / margin) * speed }
            if value > high - margin { return min(1, (value - high + margin) / margin) * speed }
            return 0
        }
        return CGVector(dx: axis(point.x, region.minX, region.maxX),
                        dy: axis(point.y, region.minY, region.maxY))
    }

    private func edgeScrollDelta(_ point: CGPoint, margin: CGFloat, speed: CGFloat) -> CGVector {
        Self.edgeScrollDelta(point,
                             in: CGRect(x: contentLeft, y: TimelineMetrics.rulerHeight,
                                        width: max(0, bounds.width - contentLeft),
                                        height: max(0, bounds.height - TimelineMetrics.rulerHeight)),
                             margin: margin, speed: speed)
    }

    /// A marquee that cannot reach past the edge of the screen can only ever
    /// select what is already on it. Pushing the drag into either margin now
    /// travels the timeline underneath it, so the selection can run off the
    /// visible region in any direction.
    ///
    /// Sideways travel is a **seek**, not a scroll. This timeline pins the
    /// playhead to the middle of the screen and moves the film under it, so
    /// `contentOffset.x` is not an independent position — `layoutSubviews` and
    /// `update(time:)` both put it back to `currentTime * zoom` whenever
    /// nothing is being dragged. Writing the offset on its own is undone on the
    /// very next update, which is exactly what stopped this working. Taking the
    /// playhead along is also the only way to look further down the timeline
    /// here, and it is what dragging the timeline by hand already does.
    private func scrollWhileMarqueeing() {
        let delta = edgeScrollDelta(dragPoint, margin: 56, speed: 9)
        guard delta.dx != 0 || delta.dy != 0 else { return }
        let beforeX = scroll.contentOffset.x, beforeY = scroll.contentOffset.y
        if delta.dx != 0 {
            // `interacting` is what tells the update path to leave the offset
            // alone, and it is the same flag a scroll by hand raises.
            beginInteraction()
            marqueeSeeking = true
            currentTime = min(duration, max(0, currentTime + delta.dx / zoom))
            updating = true
            scroll.contentOffset.x = currentTime * zoom
            updating = false
            onSeek?(currentTime)
        }
        if delta.dy != 0 {
            updating = true
            scroll.contentOffset.y = max(0, min(max(0, scroll.contentSize.height-bounds.height), beforeY + delta.dy))
            updating = false
        }
        // The origin is a point on the timeline, not on the screen. The content
        // moved under it, so it has to move with the content or the rectangle
        // would slowly shear away from the clip it was anchored to.
        marqueeOrigin?.x -= scroll.contentOffset.x - beforeX
        marqueeOrigin?.y -= scroll.contentOffset.y - beforeY
        updateMarquee(to: dragPoint)
    }

    private func scrollWhileDragging() {
        if marqueeOrigin != nil { scrollWhileMarqueeing(); return }
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
                playhead: currentTime, tolerance: snapTolerance(14))
            if destination != target && destination != snappedBoundary { UISelectionFeedbackGenerator().selectionChanged() }
            ghost.time = destination; self.ghost = ghost
            snappedBoundary = destination == target ? nil : destination
            setNeedsDisplay(); return
        }
        // The main video track packs from zero whatever the magnet button says:
        // a gap in it is not representable, so the slot is the edit, not a snap.
        let others = clips.filter { $0.id != ghost.clip.id && $0.placement.trackID == ghost.clip.placement.trackID }
        let next = others.first { target < $0.placement.timelineStart.seconds + $0.placement.duration.seconds/2 }
        let slot = next?.placement.timelineStart.seconds ?? ((try? others.last?.placement.range.end.seconds) ?? 0)
        if snappedBoundary != slot { UISelectionFeedbackGenerator().selectionChanged() }
        snappedBoundary = slot
        ghost.time = slot
        self.ghost = ghost
        setNeedsDisplay()
    }
    /// The rows a dragged clip may land on, and where a new one for it may be
    /// opened.
    ///
    /// A row holds one kind and, within that kind, a sequence. So the test is
    /// two-part: the row must take this kind of clip at all, and it must be free
    /// at the moment the clip would land — which is why the horizontal magnet
    /// has to have spoken before any of this is asked.
    static func canDrop(_ clip: TimelineDisplayClip, kind: TimelineTrack.Kind,
                        on track: TimelineTrack, startingAt start: Double) -> Bool {
        guard !track.isLocked else { return false }
        guard kind == .videoOverlay
            ? (track.kind == .mainVideo || track.kind == .videoOverlay)
            : track.kind == kind else { return false }
        // The main row packs from zero: a clip dropped on it is inserted between
        // its neighbours rather than laid over them, so nothing there is busy.
        guard track.kind != .mainVideo else { return true }
        let end = start + clip.placement.duration.seconds
        return !track.items.contains { item in
            guard item.id != clip.id else { return false }
            let otherStart = item.placement.timelineStart.seconds
            let otherEnd = (try? item.placement.range.end.seconds) ?? otherStart
            return start < otherEnd && otherStart < end
        }
    }

    /// Where a new row of this kind belongs. Sound goes under the picture and
    /// drawn layers over it — a visual overlay below the main row would simply
    /// be hidden by it, and sound above the picture reads as a mistake.
    static func clampedInsertion(_ proposed: Int, kind: TimelineTrack.Kind,
                                 in tracks: [TimelineTrack]) -> Int {
        let main = tracks.firstIndex { $0.kind == .mainVideo } ?? tracks.count
        let bounded: Int
        switch kind {
        case .audio: bounded = max(proposed, main + 1)
        case .mainVideo: bounded = proposed
        case .videoOverlay, .text, .shape: bounded = min(proposed, main)
        }
        return min(max(bounded, 0), tracks.count)
    }

    private func updateLayerDrag() {
        guard let moving = ghost?.clip, !tracks.isEmpty else { return }
        let kind = Self.movingTrackKind(moving)

        // Horizontal travel stays live during a vertical layer drag, and it is
        // resolved FIRST: whether a row can take this clip depends on where
        // along it the clip would land, so the magnet — playhead, markers and
        // every other clip edge — has to have settled before a row is chosen.
        let raw = max(0, (dragPoint.x + scroll.contentOffset.x - bounds.midX) / zoom - dragAnchor)
        let sticky = snappedBoundary.flatMap { abs($0-raw) <= 22/zoom ? $0 : nil }
        let snapped = sticky ?? TimelineEditing.snapMovingClipStart(
            raw, duration: moving.placement.duration.seconds,
            clips: clips, markers: markers, excluding: moving.id,
            playhead: currentTime, tolerance: snapTolerance(14))
        if snapped != raw && snapped != snappedBoundary { UISelectionFeedbackGenerator().selectionChanged() }
        snappedBoundary = snapped == raw ? nil : snapped

        let y = dragPoint.y + scroll.contentOffset.y - TimelineMetrics.rowsTop
        let open = tracks.indices.filter {
            Self.canDrop(moving, kind: kind, on: tracks[$0], startingAt: snapped)
        }

        // The middle of a row is an existing-layer target. Its top/bottom edge
        // is a roomy insertion target, so users do not have to hit the tiny
        // eight-point gap exactly to create a layer.
        let existing = open.first { index in
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
            target = .newTrack(kind: kind, index: Self.clampedInsertion(proposed, kind: kind, in: tracks))
        }
        if target != layerDropTarget { UISelectionFeedbackGenerator().selectionChanged() }
        layerDropTarget = target

        guard var movingGhost = ghost else { return }
        movingGhost.time = snapped
        ghost = movingGhost
        updating = true
        scroll.contentSize.height = max(bounds.height, contentHeight)
        updating = false
        setNeedsDisplay()
    }

    /// The kind of row a dragged clip belongs on. Mirrors `TimelineItem.trackKind`;
    /// the timeline only ever sees the display adapter.
    static func movingTrackKind(_ clip: TimelineDisplayClip) -> TimelineTrack.Kind {
        if clip.isAudio { return .audio }
        if clip.isText { return .text }
        if clip.isShape { return .shape }
        return .videoOverlay
    }

    // MARK: - Track headers

    /// Track headers are UIKit subviews of the canvas, not children of its
    /// horizontal scroll view. Their names and buttons therefore stay put while
    /// clips, waveforms and thumbnails travel underneath the playhead.
    func updateTrackControls() {
        let liveIDs = Set(tracks.map(\.id))
        for id in trackHeaders.keys.filter({ !liveIDs.contains($0) }) {
            trackHeaders[id]?.removeFromSuperview()
            trackHeaders[id] = nil
        }
        let selectedTrackID = clips.first { $0.id == selectedID }?.placement.trackID
        for track in tracks {
            let model = headerModel(for: track, isSelected: track.id == selectedTrackID)
            let header: TimelineTrackHeaderView
            if let existing = trackHeaders[track.id] {
                header = existing
                if existing.model != model { existing.apply(model) }
            } else {
                header = TimelineTrackHeaderView(trackID: track.id, model: model)
                let id = track.id
                header.onToggleLock = { [weak self] in self?.onToggleTrackLock?(id) }
                header.onToggleVisibility = { [weak self] in self?.onToggleTrackVisibility?(id) }
                header.onToggleMute = { [weak self] in self?.onToggleTrackMute?(id) }
                addSubview(header)
                trackHeaders[track.id] = header
            }
            header.menu = trackMenu(track)
        }
        layoutTrackControls()
        setNeedsLayout(); setNeedsDisplay()
    }

    /// "3 clips · 00:12" — what the row holds and how far it runs, which is the
    /// question a header actually answers.
    private func headerModel(for track: TimelineTrack, isSelected: Bool) -> TimelineTrackHeaderView.Model {
        let count = track.items.count
        let end = track.items.compactMap { try? $0.placement.range.end.seconds }.max() ?? 0
        let clipCount = count == 1
            ? String(localized: "1 clip")
            : String(format: String(localized: "%lld clips"), count)
        return .init(title: track.layerDisplayName,
                     subtitle: "\(clipCount) · \(TimecodeFormatter.string(from: end))",
                     kind: track.kind,
                     isLocked: track.isLocked,
                     isEnabled: track.isEnabled,
                     isAudioMuted: track.isAudioMuted,
                     hasAudioContent: track.hasAudioContent,
                     isSelected: isSelected)
    }

    private func layoutTrackControls() {
        let width = contentLeft
        headerBackdrop.frame = CGRect(x: 0, y: TimelineMetrics.rulerHeight, width: width,
                                      height: max(0, bounds.height - TimelineMetrics.rulerHeight))
        bringSubviewToFront(headerBackdrop)
        for (index, track) in tracks.enumerated() {
            guard let header = trackHeaders[track.id] else { continue }
            let height = clipHeight(track)
            let y = TimelineMetrics.rowsTop + rowTop(index, in: tracks) - scroll.contentOffset.y
            header.isHidden = y + height <= TimelineMetrics.rulerHeight || y >= bounds.height
            header.frame = CGRect(x: 0, y: y, width: width, height: height)
            bringSubviewToFront(header)
        }
    }

    private func trackMenu(_ track: TimelineTrack) -> UIMenu {
        let selectedHeight = track.resolvedHeight
        let heights = TimelineTrackHeightChoice.allCases.map { choice in
            UIAction(title: choice.title, state: choice == selectedHeight ? .on : .off) { [weak self] _ in
                self?.onSetTrackHeight?(track.id, choice)
            }
        }
        var children: [UIMenuElement] = [UIMenu(title: String(localized: "Track height"), children: heights)]
        if track.hasAudioContent {
            let selectedWaveform = track.resolvedWaveformSize
            let waveforms = TimelineWaveformSize.allCases.map { choice in
                UIAction(title: choice.title, state: choice == selectedWaveform ? .on : .off) { [weak self] _ in
                    self?.onSetWaveformSize?(track.id, choice)
                }
            }
            children.append(UIMenu(title: String(localized: "Audio waveform size"), children: waveforms))
        }
        return UIMenu(children: children)
    }
}

/// A backdrop that paints but never intercepts. The header column has to be
/// opaque so clips do not show through it, yet a drag that starts over it
/// should still reach the timeline underneath.
final class TimelinePassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

/// Dropping media from the bin.
///
/// The drop lands as its own overlay layer at the second it was released on,
/// which is what someone aiming a clip at a point on the timeline is asking
/// for. Appending to the main track — which packs and ripples, so a position
/// means nothing there — is what the bin's own button and double-click do.
extension TimelineCanvas: UIDropInteractionDelegate {
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        session.canLoadObjects(ofClass: NSString.self)
    }

    func dropInteraction(_ interaction: UIDropInteraction,
                         sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        guard let time = dropTime(for: session) else {
            setDropPreview(nil)
            return UIDropProposal(operation: .cancel)
        }
        setDropPreview(time)
        return UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
        setDropPreview(nil)
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
        setDropPreview(nil)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        let time = dropTime(for: session) ?? 0
        setDropPreview(nil)
        session.loadObjects(ofClass: NSString.self) { [weak self] items in
            guard let payload = items.first as? String,
                  let assetID = MediaBinEntry.assetID(fromDrag: payload) else { return }
            self?.onDropAsset?(assetID, time)
        }
    }

    /// The second under the pointer, or nil where a drop would mean nothing —
    /// the track headers, which are a control panel, and the ruler, which is
    /// the transport.
    private func dropTime(for session: UIDropSession) -> Double? {
        let point = session.location(in: self)
        guard point.x >= contentLeft, point.y >= TimelineMetrics.rulerHeight else { return nil }
        return max(0, viewport.seconds(at: point.x, duration: duration))
    }
}
