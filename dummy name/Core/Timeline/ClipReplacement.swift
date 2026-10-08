import CoreMedia
import Foundation

enum ClipReplacementTiming: String, CaseIterable, Identifiable {
    case keepDuration, useFullClip
    var id: String { rawValue }
}

/// A replacement is prepared on a copy. The sheet previews the very same
/// transaction that is committed, including ripple, locks and transitions.
enum ClipReplacement {
    struct Plan {
        let project: VideoProject
        let clip: VideoClip
        let durationChange: TimelineTime
        let holdsLastFrame: Bool
    }

    static func prepare(
        clipID: UUID, asset: ProjectMediaAsset, timing: ClipReplacementTiming,
        sourceStart: TimelineTime? = nil, useAudio: Bool = true,
        in project: VideoProject
    ) throws -> Plan {
        let original = try TimelineEditing.editable(clipID, in: project)
        guard asset.videoMetadata != nil || asset.stillImage != nil, asset.audioName == nil else {
            throw TimelineError.invalid(String(localized: "Choose a video or image to replace this clip."))
        }
        var candidate = project
        if let existing = candidate.assets.first(where: { $0.id == asset.id }) {
            guard existing == asset else {
                throw TimelineError.invalid(String(localized: "This media has changed. Choose it again."))
            }
        } else { candidate.addAsset(asset) }

        var clip = original
        clip.assetID = asset.id
        // A cutout's generated masks and hand-traced outline describe the old
        // footage. Colour keys remain portable; analysed cutouts must be redone.
        if clip.backgroundRemoval?.mode != .colorKey { clip.backgroundRemoval = nil }
        else {
            clip.backgroundRemoval?.analysisID = UUID()
            clip.backgroundRemoval?.strokes = []
        }
        clip.shotMatch = nil // Keep its authored grade, release source-dependent provenance.
        clip.embeddedAudio = useAudio && asset.videoMetadata?.hasAudio == true
            ? (original.embeddedAudio ?? EmbeddedAudio()) : nil

        var holdsLastFrame = false
        if asset.stillImage != nil {
            clip.sourceRange = .init(start: .zero, duration: original.placement.duration)
            clip.timeRemap = nil
            clip.playbackSpeed = nil
            clip.blendsRetimedFrames = nil
        } else {
            let start = timing == .useFullClip ? asset.sourceRange.start
                : (sourceStart ?? asset.sourceRange.start)
            let end = try asset.sourceRange.end
            guard start >= asset.sourceRange.start, start < end else {
                throw TimelineError.invalid(String(localized: "Choose a starting point inside the replacement video."))
            }
            let available = try end.subtracting(start)
            let duration = timing == .keepDuration
                ? min(original.sourceRange.duration, available) : available
            clip.sourceRange = .init(start: start, duration: duration)

            if timing == .useFullClip {
                // Speed curves are source-relative; keep their shape across the
                // new footage rather than bunching all points into its beginning.
                if var remap = clip.timeRemap {
                    let factor = duration.seconds / original.sourceRange.duration.seconds
                    remap.points = try remap.points.map { point in
                        var point = point
                        point.sourceOffset = try .seconds(point.sourceOffset.seconds * factor)
                        return point
                    }
                    remap.freezes = try remap.freezes.map { freeze in
                        var freeze = freeze
                        freeze.sourceWidth = min(asset.frameDuration ?? freeze.sourceWidth, duration)
                        freeze.sourceOffset = try min(.seconds(freeze.sourceOffset.seconds * factor),
                                                      duration.subtracting(freeze.sourceWidth))
                        return freeze
                    }
                    clip.timeRemap = remap
                }
                clip.placement.duration = try clip.timelineDuration(forSourceDuration: duration)
            } else if duration < original.sourceRange.duration {
                var remap = original.resolvedRemap.trimmedTail(
                    toSource: duration, sourceDuration: original.sourceRange.duration)
                // Hold the final displayed source frame (the first frame when
                // reversed), using the replacement's actual frame cadence.
                let width = try min(asset.frameDuration ?? project.canvas.frameDuration
                                    ?? .seconds(1.0 / 30), duration)
                let offset = remap.reverses ? TimelineTime.zero : try duration.subtracting(width)
                let heldEnd = try offset.adding(width)
                remap.freezes.removeAll { $0.sourceOffset < heldEnd && $0.sourceEnd > offset }
                let base = TimeMap.cached(remap: remap, sourceDuration: duration)
                let frameTimelineStart = base.timelineOffset(atSourceOffset: offset)
                let frameTimelineEnd = base.timelineOffset(atSourceOffset: try offset.adding(width))
                let frameLength = try max(frameTimelineStart, frameTimelineEnd)
                    .subtracting(min(frameTimelineStart, frameTimelineEnd))
                let missing = try original.placement.duration.subtracting(base.timelineDuration)
                guard missing > .zero else {
                    throw TimelineError.invalid(String(localized: "This speed curve cannot fit the shorter source. Use the full clip instead."))
                }
                remap.freezes.append(.init(sourceOffset: offset,
                    duration: try missing.adding(frameLength), sourceWidth: width,
                    integratesExactly: true, silencesAudio: true))
                // Integration rounds each table cell to a project tick. Absorb
                // that rounding in the hold, so Keep Duration remains exact at
                // fractional frame rates and with an existing speed curve.
                for _ in 0..<6 {
                    let mapped = TimeMap.cached(remap: remap, sourceDuration: duration).timelineDuration
                    let correction = try original.placement.duration.subtracting(mapped)
                    if correction == .zero { break }
                    let index = remap.freezes.count - 1
                    remap.freezes[index].duration = try remap.freezes[index].duration.adding(correction)
                }
                clip.timeRemap = remap
                holdsLastFrame = true
                // The placement remains exact; the common TimeMap handles the
                // last-frame hold in both playback and export.
            }
        }

        let change = try clip.placement.duration.subtracting(original.placement.duration)
        if change != .zero {
            let factor = clip.placement.duration.seconds / original.placement.duration.seconds
            clip.animation = clip.animation?.retimed(by: factor)
            clip.maskedGrades = clip.maskedGrades?.map { $0.retimed(by: factor) }
            if let relight = clip.gradeSettings.advanced?.relight, relight.isAnimated {
                clip.gradeSettings.advanced?.relight = relight.retimed(by: factor)
            }
            let boundary = try original.placement.range.end
            let isMain = candidate.timeline.tracks.first {
                $0.id == original.placement.trackID
            }?.kind == .mainVideo
            for trackIndex in candidate.timeline.tracks.indices {
                let track = candidate.timeline.tracks[trackIndex]
                // Main-track ripple carries later titles and visual overlays.
                // Audio embedded in video follows its parent automatically;
                // standalone audio has independent timing and stays put.
                guard track.id == original.placement.trackID || (isMain && track.kind != .audio) else { continue }
                for itemIndex in track.items.indices {
                    let item = track.items[itemIndex]
                    guard item.id != clipID, item.placement.timelineStart >= boundary else { continue }
                    guard !track.isLocked, !item.placement.isLocked else {
                        throw TimelineError.invalid(String(localized: "Unlock following clips and tracks before changing the replacement's duration."))
                    }
                    var placement = item.placement
                    placement.timelineStart = try placement.timelineStart.adding(change)
                    candidate.timeline.tracks[trackIndex].items[itemIndex] = item.withPlacement(placement)
                }
            }
            if isMain {
                for index in candidate.timeline.markers.indices
                    where candidate.timeline.markers[index].time >= boundary {
                    candidate.timeline.markers[index].time = try candidate.timeline.markers[index].time.adding(change)
                }
            }
        }
        try TimelineEditing.replace(clipID, with: [clip], in: &candidate)
        try TimelineTransitionEditing.reconcile(in: &candidate)
        _ = try TimelineEditing.clips(in: candidate)
        return Plan(project: candidate, clip: clip, durationChange: change, holdsLastFrame: holdsLastFrame)
    }
}
