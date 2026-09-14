import Foundation
import CoreMedia

struct MaskTrackingPlan: Identifiable, Sendable {
    let id = UUID()
    let request: MaskTrackingRequest
    let original: MaskedGradeLayer
}

struct MaskTrackingSession {
    let id: UUID
    let clipID: UUID
    let maskID: UUID
    let name: String
    var progress: MaskTrackingProgress
    var stopping = false
}

struct MaskTrackingNotice {
    let clipID: UUID
    let maskID: UUID
    let text: String
    var continueDirection: MaskTrackingDirection?
}

struct MaskTrackingOutcome: Sendable {
    var result: MaskTrackingResult
    var animation: ClipAnimation?
}

extension EditorViewModel {
    var canTrackSelectedMask: Bool {
        guard canGrade, !isPreparingTimeline, maskTrackingSession == nil, !isDrawingMask,
              let clip = selectedClip, let mask = displayedSelectedMask,
              mask.geometry.shape != .linear, mask.geometry.isRenderable,
              isPlayheadInsideSelection,
              project.assets.first(where: { $0.id == clip.assetID })?.videoMetadata != nil else { return false }
        return true
    }

    func requestMaskTracking(_ direction: MaskTrackingDirection) {
        guard canTrackSelectedMask, let clip = selectedClip, let mask = displayedSelectedMask,
              let original = selectedMask, let anchor = maskAnimationTime,
              let asset = project.assets.first(where: { $0.id == clip.assetID }),
              let sourceAnchor = try? clip.sourceTime(at: playheadTime) else { return }
        playback.pause()
        flushGradeHistory()
        let request = MaskTrackingRequest(url: asset.url, clip: clip, mask: mask, anchor: anchor,
                                          sourceAnchor: sourceAnchor, direction: direction)
        let plan = MaskTrackingPlan(request: request, original: original)
        // A track with keys straddling the range still animates within it.
        // Ask whenever any driven property already has animation.
        if original.animation?.tracks.contains(where: {
            MaskTrackingMotion.properties.contains($0.property) && !$0.isEmpty
        }) == true {
            pendingMaskTracking = plan
        } else { startMaskTracking(plan) }
    }

    func confirmMaskTracking() {
        guard let plan = pendingMaskTracking else { return }
        pendingMaskTracking = nil
        startMaskTracking(plan)
    }

    func startMaskTracking(_ plan: MaskTrackingPlan) {
        guard maskTrackingSession == nil, trackingContextMatches(plan) else {
            editError = "The clip or mask changed. Place the playhead and start tracking again."
            return
        }
        let request = plan.request
        maskTrackingNotice = nil
        maskTrackingSession = .init(id: plan.id, clipID: request.clip.id, maskID: plan.original.id,
            name: plan.original.name, progress: .init(fraction: 0, frames: 0,
                direction: request.direction == .backward ? .backward : .forward, preparing: true))
        let worker = Task.detached(priority: .userInitiated) { [weak self] in
            var result = await MaskTrackingService.analyze(request) { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard self?.maskTrackingSession?.id == plan.id else { return }
                    self?.maskTrackingSession?.progress = progress
                }
            }
            var animation: ClipAnimation?
            if result.samples.count > 1 {
                do { animation = try MaskTrackingMotion.animation(for: result, request: request, original: plan.original) }
                catch {
                    result.message = error.localizedDescription
                    result.lostTime = nil
                }
            }
            return MaskTrackingOutcome(result: result, animation: animation)
        }
        maskTrackingWorker = worker
        Task { [weak self] in
            let outcome = await worker.value
            self?.finishMaskTracking(plan, outcome: outcome)
        }
    }

    func stopMaskTracking() {
        guard maskTrackingSession != nil else { return }
        maskTrackingSession?.stopping = true
        maskTrackingWorker?.cancel()
    }

    func isTrackingMask(_ id: UUID) -> Bool { maskTrackingSession?.maskID == id }

    func trackingContextMatches(_ plan: MaskTrackingPlan) -> Bool {
        let reference = plan.request.clip
        guard let clip = project.timeline.videoClip(id: reference.id),
              let mask = clip.resolvedMaskedGrades.first(where: { $0.id == plan.original.id }),
              clip.assetID == reference.assetID, clip.sourceRange == reference.sourceRange,
              clip.speed == reference.speed, clip.placement == reference.placement,
              clip.animation?.startOffset == reference.animation?.startOffset,
              project.assets.first(where: { $0.id == clip.assetID })?.url == plan.request.url,
              mask.geometry == plan.original.geometry else { return false }
        let geometry = MaskedGradeLayer.geometryProperties
        return (mask.animation?.tracks.filter { geometry.contains($0.property) } ?? []) ==
            (plan.original.animation?.tracks.filter { geometry.contains($0.property) } ?? [])
    }

    private func finishMaskTracking(_ plan: MaskTrackingPlan, outcome: MaskTrackingOutcome) {
        guard maskTrackingSession?.id == plan.id else { return }
        maskTrackingSession = nil
        maskTrackingWorker = nil
        guard trackingContextMatches(plan) else {
            editError = "Tracking stopped because the clip or mask geometry changed. Start tracking again from the current frame."
            return
        }
        let result = outcome.result
        if let animation = outcome.animation {
            guard commitMaskTracking(plan, animation: animation) else { return }
        }
        let request = plan.request
        let text: String
        var continueDirection: MaskTrackingDirection?
        if let lost = result.lostTime {
            let composition = (request.clip.animation ?? ClipAnimation()).compositionTime(forLocal: lost,
                clipStart: request.clip.placement.timelineStart)
            if selectedClipID == request.clip.id, selectedMaskID == request.mask.id, let composition {
                playback.seekPrecisely(to: composition.cmTime)
                showsMaskOverlay = true
            }
            let seconds = composition?.seconds ?? lost.seconds
            let minutes = Int(seconds / 60), remainder = seconds - Double(minutes * 60)
            text = String(format: "Tracking lost at %02d:%05.2f. Reposition the mask, then continue.", minutes, remainder)
            continueDirection = result.lastDirection
        } else if let message = result.message {
            text = message
        } else if result.stopped {
            text = outcome.animation == nil ? "Tracking stopped before motion was found." : "Tracking stopped. Successful motion has been kept."
            if outcome.animation != nil, let last = result.samples.last,
               selectedClipID == request.clip.id, selectedMaskID == request.mask.id,
               let composition = (request.clip.animation ?? ClipAnimation()).compositionTime(
                forLocal: last.localTime, clipStart: request.clip.placement.timelineStart) {
                playback.seekPrecisely(to: composition.cmTime)
                continueDirection = result.lastDirection
            }
        } else {
            let count = outcome.animation?.track(.localMaskPositionX)?.keyframes.count ?? 0
            text = outcome.animation == nil ? "No additional source frames in this direction." : "Tracking complete · \(count) position keyframes. Scrub or play to review."
        }
        maskTrackingNotice = .init(clipID: request.clip.id, maskID: request.mask.id, text: text,
                                   continueDirection: continueDirection)
    }

    func clearMaskGeometryAnimation(_ id: UUID) {
        guard !isTrackingMask(id), let displayed = displayedMask(id) else { return }
        flushGradeHistory()
        updateMask(id, label: "Clear Mask Geometry Animation", immediate: true) { mask in
            guard var animation = mask.animation else { return }
            for property in MaskedGradeLayer.geometryProperties {
                animation.removeAnimation(of: property)
                if let value = displayed.baseKeyframeValue(of: property) { mask.setBaseKeyframeValue(value, of: property) }
            }
            mask.animation = animation.isEmpty ? nil : animation
        }
        maskTrackingNotice = nil
    }
}
