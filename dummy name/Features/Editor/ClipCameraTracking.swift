import Combine
import Foundation
import CoreMedia

@MainActor
final class ClipCameraTracking: ObservableObject {
    @Published private(set) var targetID: UUID?
    @Published private(set) var progress: Double?
    @Published private(set) var message: String?
    private var operation: UUID?
    private var worker: Task<Void, Never>?

    func choose(_ id: UUID) {
        cancel()
        targetID = id
        message = nil
    }

    func cancel() {
        operation = nil
        worker?.cancel()
        worker = nil
        targetID = nil
        progress = nil
        message = nil
    }

    func track(at point: CGPoint, in model: EditorViewModel) {
        guard let targetID, let target = model.cameraTrackingTargets.first(where: { $0.id == targetID }),
              let clip = model.selectedClip, let source = model.cameraSourceFrame, !source.isStill,
              let local = model.animationTime,
              let coordinates = try? MaskTrackingCoordinates(encodedSize: source.encoded,
                                                              preferredTransform: source.preferred) else {
            cancel()
            return
        }
        let upright = coordinates.displayToSource(point)
        let topToBottom = CGAffineTransform(a: source.encoded.width, b: 0, c: 0,
                                            d: -source.encoded.height, tx: 0, ty: source.encoded.height)
        let raw = upright.applying(topToBottom).applying(source.stabilization.inverted())
            .applying(topToBottom.inverted())
        let halfWidth = min(0.2, 0.06 * min(1, 1 / coordinates.aspect))
        let halfHeight = min(0.2, 0.06 * min(1, coordinates.aspect))
        let geometry = MaskGeometry(shape: .rectangle,
            centerX: min(1 - halfWidth, max(halfWidth, raw.x)),
            centerY: min(1 - halfHeight, max(halfHeight, raw.y)),
            width: 2 * halfWidth, height: 2 * halfHeight)
        let request = MaskTrackingRequest(url: source.url, clip: clip,
            mask: MaskedGradeLayer(name: String(localized: "Track Graphic"), geometry: geometry),
            anchor: local, sourceAnchor: source.time, direction: .both)
        let id = UUID()
        let canvas = model.cameraCanvasSize
        model.playback.pause()
        model.flushGradeHistory()
        self.targetID = nil
        operation = id
        progress = 0
        worker = Task { [weak self, weak model] in
            let analysis = Task.detached(priority: .userInitiated) { [weak self] in
                await MaskTrackingService.analyze(request) { [weak self] status in
                    Task { @MainActor in
                        guard self?.operation == id else { return }
                        self?.progress = status.fraction
                    }
                }
            }
            let result = await withTaskCancellationHandler {
                await analysis.value
            } onCancel: {
                analysis.cancel()
            }
            guard let self, self.operation == id else { return }
            self.operation = nil
            self.worker = nil
            self.progress = nil
            guard let model,
                  model.project.timeline.videoClip(id: clip.id) == clip,
                  model.cameraCanvasSize == canvas,
                  model.cameraTrackingTargets.first(where: { $0.id == target.id })?.item == target.item else {
                self.message = String(localized: "The shot or graphic changed. Start tracking again.")
                return
            }
            guard Self.apply(result, request: request, target: target.item,
                             coordinates: coordinates, model: model) else {
                self.message = String(localized: "Tracking couldn’t hold this point. Try a sharper detail.")
                return
            }
            self.message = result.lostTime == nil && result.message == nil
                ? String(localized: "Graphic position keyframes added.")
                : String(localized: "Tracking lost the detail. Keyframes cover the part it could follow.")
        }
    }

    private static func apply(_ result: MaskTrackingResult, request: MaskTrackingRequest, target: TimelineItem,
                              coordinates: MaskTrackingCoordinates, model: EditorViewModel) -> Bool {
        let clip = request.clip
        let animation = clip.animation ?? ClipAnimation()
        guard let anchorTime = animation.compositionTime(forLocal: request.anchor, clipStart: clip.placement.timelineStart),
              let end = try? target.placement.range.end else { return false }
        let canvas = model.cameraCanvasSize
        func position(_ point: CGPoint, at time: TimelineTime) -> CGPoint {
            let encoded = coordinates.encodedSize
            let correction = clip.stabilizationCorrection(at: time.cmTime, size: encoded)
            let flip = CGAffineTransform(a: encoded.width, b: 0, c: 0, d: -encoded.height, tx: 0, ty: encoded.height)
            let map = coordinates.sourceToCanvasTransform(clip.evaluated(at: time), canvas: canvas,
                sourceCorrection: flip.concatenating(correction).concatenating(flip.inverted()))
            return point.applying(map)
        }
        let seed = request.anchorValues
        let origin = position(CGPoint(x: seed.x, y: seed.y), at: anchorTime)
        let samples = result.samples.sorted { $0.localTime < $1.localTime }.compactMap { sample -> (TimelineTime, CGPoint)? in
            guard let time = animation.compositionTime(forLocal: sample.localTime, clipStart: clip.placement.timelineStart),
                  time >= target.placement.timelineStart, time < end else { return nil }
            let point = position(CGPoint(x: sample.values.x, y: sample.values.y), at: time)
            return (time, CGPoint(x: point.x - origin.x, y: point.y - origin.y))
        }
        guard samples.count > 1 else { return false }
        let step = max(1, Int(ceil(Double(samples.count) / Double(AnimationTrack.keyframeLimit - 3))))
        let frames = samples.enumerated().compactMap { index, sample in
            index % step == 0 || index == samples.count - 1 || sample.0 == anchorTime ? sample : nil
        }
        let label = String(localized: "Track Graphic")
        model.commit(label, rebuildsSequence: false, preservingSelection: true) { project in
            func animated<Clip: AnimatableClip>(_ clip: Clip) -> Clip {
                var updated = clip
                var animation = clip.animation ?? ClipAnimation()
                for (property, axis) in [(AnimatableProperty.positionX, \CGPoint.x), (.positionY, \CGPoint.y)] {
                    let base = clip.baseValue(of: property)?.number ?? 0.5
                    let keys = frames.compactMap { time, offset -> Keyframe? in
                        guard let local = clip.localTime(for: time), local >= .zero else { return nil }
                        let value = property.clamped(base + offset[keyPath: axis])
                        return Keyframe(time: local, value: .number(value), interpolation: .linear)
                    }
                    animation.update(property) { $0 = AnimationTrack(property: property, keyframes: keys) }
                }
                updated.animation = animation
                return updated
            }
            switch target {
            case .text(let clip): try OverlayEditing.replace(clip.id, with: animated(clip), in: &project)
            case .shape(let clip): try OverlayEditing.replace(clip.id, with: animated(clip), in: &project)
            case .video(let clip): try TimelineEditing.replace(clip.id, with: [animated(clip)], in: &project)
            case .audio, .camera: return nil
            }
            return request.clip.id
        }
        return true
    }
}

struct ClipCameraTrackingTarget: Identifiable {
    let item: TimelineItem
    let title: String
    var id: UUID { item.id }
}

extension EditorViewModel {
    var cameraTrackingTargets: [ClipCameraTrackingTarget] {
        guard canEditCamera, let clip = selectedClip, isPlayheadInsideSelection,
              project.assets.first(where: { $0.id == clip.assetID })?.videoMetadata != nil else { return [] }
        return project.timeline.tracks.prefix { $0.id != clip.placement.trackID }.flatMap { track in
            guard track.isEnabled, !track.isLocked else { return [ClipCameraTrackingTarget]() }
            return track.items.compactMap { item -> ClipCameraTrackingTarget? in
                guard item.placement.isEnabled, !item.placement.isLocked,
                      item.placement.timelineStart <= playheadTime,
                      let end = try? item.placement.range.end, playheadTime < end else { return nil }
                func hasPositionAnimation(_ animation: ClipAnimation?) -> Bool {
                    animation?.track(.positionX) != nil || animation?.track(.positionY) != nil
                }
                switch item {
                case .text(let overlay) where !hasPositionAnimation(overlay.animation):
                    return .init(item: item, title: String(overlay.text.prefix(40)))
                case .shape(let overlay) where !hasPositionAnimation(overlay.animation):
                    return .init(item: item, title: overlay.kind.title)
                case .video(let overlay) where !hasPositionAnimation(overlay.animation):
                    guard let asset = project.assets.first(where: { $0.id == overlay.assetID }),
                          asset.stillImage != nil else { return nil }
                    return .init(item: item, title: asset.url.deletingPathExtension().lastPathComponent)
                default: return nil
                }
            }
        }
    }
}
