import Foundation

/// Ramp authoring, as the panels see it.
///
/// Every one of these is a single undoable action and nothing more. None of
/// them works out a duration, moves a keyframe or ripples a track — that all
/// belongs to `TimelineEditing.retime`, which is the one place it can be got
/// right. A panel that computed a length itself would be a second
/// implementation of the thing the timeline layer exists to own.
extension EditorViewModel {

    // MARK: - What the panels read

    /// The selected clip's retiming, or a neutral one when nothing is selected.
    var selectedRemap: TimeRemap { selectedClip?.resolvedRemap ?? .constant }

    /// The selected clip's time map, for drawing the curve and reading rates.
    var selectedTimeMap: TimeMap? { selectedClip?.timeMap }

    var isSelectionRamped: Bool { selectedClip?.isRamped ?? false }

    /// Where the playhead sits inside the selected clip, or nil when it is
    /// outside. The curve editor draws its own playhead from this and the
    /// "add a point here" action needs it.
    var playheadInSelectedClip: TimelineTime? {
        guard let clip = selectedClip, let end = try? clip.placement.range.end,
              playheadTime >= clip.placement.timelineStart, playheadTime < end else { return nil }
        return try? playheadTime.subtracting(clip.placement.timelineStart)
    }

    /// The rate actually in force under the playhead, for the readout.
    var speedAtPlayhead: Double {
        guard let clip = selectedClip else { return ClipSpeed.normal }
        return clip.speed(at: playheadTime)
    }

    // MARK: - Curve edits

    @discardableResult
    func addSpeedPoint(atTimeline time: TimelineTime? = nil) -> UUID? {
        guard let id = selectedClipID, let clip = selectedClip else { return nil }
        let at = time ?? playheadTime
        var created: UUID?
        applyRetimingEdit(label: String(localized: "Add Speed Point"), live: false) { project in
            created = try TimelineEditing.addSpeedPoint(id, atTimeline: at, in: &project)
        }
        _ = clip
        return created
    }

    func removeSpeedPoint(_ point: UUID) {
        guard let id = selectedClipID else { return }
        applyRetimingEdit(label: String(localized: "Delete Speed Point"), live: false) { project in
            try TimelineEditing.removeSpeedPoint(id, point: point, in: &project)
        }
    }

    /// One drag of a point. `live` while the finger or pointer is down.
    func moveSpeedPoint(_ point: UUID, toTimeline time: TimelineTime?, speed: Double?,
                        live: Bool = false) {
        guard let id = selectedClipID else { return }
        applyRetimingEdit(label: String(localized: "Move Speed Point"), live: live) { project in
            try TimelineEditing.moveSpeedPoint(id, point: point, toTimeline: time,
                                               speed: speed, in: &project)
        }
    }

    func setSpeedPointInterpolation(_ point: UUID, to interpolation: SpeedInterpolation) {
        guard let id = selectedClipID else { return }
        applyRetimingEdit(label: interpolation.title, live: false) { project in
            try TimelineEditing.setSpeedPointInterpolation(id, point: point, to: interpolation,
                                                           in: &project)
        }
    }

    func setSpeedPointHandles(_ point: UUID, outgoing: BezierHandle?, incoming: BezierHandle?,
                              live: Bool = false) {
        guard let id = selectedClipID else { return }
        applyRetimingEdit(label: String(localized: "Shape Ramp"), live: live) { project in
            try TimelineEditing.setSpeedPointHandles(id, point: point, outgoing: outgoing,
                                                     incoming: incoming, in: &project)
        }
    }

    func resetSpeedCurve() {
        guard let id = selectedClipID else { return }
        applyRetimingEdit(label: String(localized: "Reset Speed Curve"), live: false) { project in
            try TimelineEditing.resetSpeedCurve(id, in: &project)
        }
    }

    func applySpeedPreset(_ preset: TimeRemap.Preset) {
        guard let id = selectedClipID else { return }
        applyRetimingEdit(label: preset.title, live: false) { project in
            try TimelineEditing.applySpeedPreset(id, preset: preset, in: &project)
        }
    }

    // MARK: - Clip-wide settings

    func setFrameInterpolation(_ mode: FrameInterpolation) {
        guard let id = selectedClipID else { return }
        applyRetimingEdit(label: mode.title, live: false) { project in
            try TimelineEditing.setFrameInterpolation(id, to: mode, in: &project)
        }
    }

    func setOpticalFlowQuality(_ quality: OpticalFlowQuality) {
        guard let id = selectedClipID else { return }
        applyRetimingEdit(label: String(localized: "Optical Flow Quality"), live: false) { project in
            try TimelineEditing.setOpticalFlowQuality(id, to: quality, in: &project)
        }
    }

    func setRetimedAudioBehaviour(_ behaviour: RetimedAudioBehaviour) {
        guard let id = selectedClipID else { return }
        applyRetimingEdit(label: behaviour.title, live: false) { project in
            try TimelineEditing.setRetimedAudioBehaviour(id, to: behaviour, in: &project)
        }
    }

    // MARK: - Freeze and reverse

    @discardableResult
    func freezeFrame(duration: Double = FreezeSegment.defaultDuration) -> UUID? {
        guard let id = selectedClipID else { return nil }
        var created: UUID?
        let at = playheadTime
        applyRetimingEdit(label: String(localized: "Freeze Frame"), live: false) { project in
            created = try TimelineEditing.freezeFrame(
                id, atTimeline: at,
                duration: try .seconds(duration), in: &project)
        }
        return created
    }

    func setFreezeDuration(_ freeze: UUID, to seconds: Double, live: Bool = false) {
        guard let id = selectedClipID else { return }
        applyRetimingEdit(label: String(localized: "Freeze Length"), live: live) { project in
            try TimelineEditing.setFreezeDuration(id, freeze: freeze,
                                                  to: try .seconds(seconds), in: &project)
        }
    }

    func removeFreeze(_ freeze: UUID) {
        guard let id = selectedClipID else { return }
        applyRetimingEdit(label: String(localized: "Remove Freeze"), live: false) { project in
            try TimelineEditing.removeFreeze(id, freeze: freeze, in: &project)
        }
    }

    func setReversed(_ reversed: Bool) {
        guard let id = selectedClipID else { return }
        applyRetimingEdit(label: reversed ? String(localized: "Reverse Clip")
                                          : String(localized: "Play Forward"), live: false) { project in
            try TimelineEditing.setReversed(id, reversed, in: &project)
        }
    }

    /// Whether a freeze can be placed where the playhead is.
    ///
    /// Not at all when the playhead is outside the clip, and not twice on the
    /// same frame — a second hold on a frame that is already held describes two
    /// lengths for one moment.
    var canFreezeAtPlayhead: Bool {
        guard canChangeSpeed, let clip = selectedClip,
              let local = playheadInSelectedClip else { return false }
        let offset = clip.timeMap.sourceOffset(atTimelineOffset: local)
        return clip.resolvedRemap.freeze(atSourceOffset: offset,
                                         sourceDuration: clip.sourceRange.duration) == nil
    }

    /// The holds on this clip, with where each one lands on the timeline.
    var selectedFreezes: [(freeze: FreezeSegment, timelineOffset: TimelineTime)] {
        guard let clip = selectedClip else { return [] }
        let map = clip.timeMap
        return clip.resolvedRemap
            .resolvedFreezes(sourceDuration: clip.sourceRange.duration)
            .map { ($0, map.timelineOffset(atSourceOffset: $0.sourceOffset)) }
    }

    /// Whether frame interpolation can do anything for this clip.
    ///
    /// At one unchanged rate every output frame lands exactly on a source frame,
    /// so there is nothing between two frames to make — blending or flow there
    /// would cost a pass and change nothing.
    var canInterpolateFrames: Bool {
        canChangeSpeed && (selectedClip?.isRetimed ?? false)
    }
}
