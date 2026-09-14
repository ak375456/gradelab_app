import CoreMedia
import Foundation

enum TimelineTransitionType: Int, Codable, CaseIterable, Identifiable, Sendable {
    case crossDissolve = 0
    case dipToBlack
    case dipToWhite
    case slideLeft
    case slideRight
    case slideUp
    case slideDown
    case push
    case zoomIn
    case zoomOut
    case blurDissolve
    case whipPanLeft
    case whipPanRight
    case spin
    case flash
    case wipeLeft
    case wipeRight
    case wipeUp
    case wipeDown
    case iris
    case clockWipe
    case splitHorizontal
    case splitVertical
    case filmBurn
    case rgbSplit
    case softLight
    case glitch
    // Keep new cases appended so raw values in existing project files remain stable.
    case diagonalWipe
    case diamond
    case horizontalBlinds
    case verticalBlinds
    case checkerboard
    case pixelate
    case ripple
    case wave
    case squeeze
    case crossZoom
    case bounce
    case noiseDissolve
    case prism
    case lensWarp
    case kaleidoscope
    case liquid
    case vortex
    case pageTurn

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .crossDissolve: "Dissolve"
        case .dipToBlack: "Dip to Black"
        case .dipToWhite: "Dip to White"
        case .slideLeft: "Slide Left"
        case .slideRight: "Slide Right"
        case .slideUp: "Slide Up"
        case .slideDown: "Slide Down"
        case .push: "Push"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .blurDissolve: "Blur Dissolve"
        case .whipPanLeft: "Whip Left"
        case .whipPanRight: "Whip Right"
        case .spin: "Spin"
        case .flash: "Flash"
        case .wipeLeft: "Wipe Left"
        case .wipeRight: "Wipe Right"
        case .wipeUp: "Wipe Up"
        case .wipeDown: "Wipe Down"
        case .iris: "Iris"
        case .clockWipe: "Clock Wipe"
        case .splitHorizontal: "Split H"
        case .splitVertical: "Split V"
        case .filmBurn: "Film Burn"
        case .rgbSplit: "RGB Split"
        case .softLight: "Soft Light"
        case .glitch: "Glitch"
        case .diagonalWipe: "Diagonal"
        case .diamond: "Diamond"
        case .horizontalBlinds: "Blinds H"
        case .verticalBlinds: "Blinds V"
        case .checkerboard: "Checker"
        case .pixelate: "Pixelate"
        case .ripple: "Ripple"
        case .wave: "Wave"
        case .squeeze: "Squeeze"
        case .crossZoom: "Cross Zoom"
        case .bounce: "Bounce"
        case .noiseDissolve: "Noise"
        case .prism: "Prism"
        case .lensWarp: "Lens Warp"
        case .kaleidoscope: "Kaleido"
        case .liquid: "Liquid"
        case .vortex: "Vortex"
        case .pageTurn: "Page Turn"
        }
    }
    var systemImage: String {
        switch self {
        case .crossDissolve: "circle.lefthalf.filled"
        case .dipToBlack: "moon.fill"
        case .dipToWhite: "sun.max.fill"
        case .slideLeft: "arrow.left"
        case .slideRight: "arrow.right"
        case .slideUp: "arrow.up"
        case .slideDown: "arrow.down"
        case .push: "rectangle.2.swap"
        case .zoomIn: "plus.magnifyingglass"
        case .zoomOut: "minus.magnifyingglass"
        case .blurDissolve: "drop.halffull"
        case .whipPanLeft: "wind"
        case .whipPanRight: "wind.circle"
        case .spin: "rotate.right"
        case .flash: "bolt.fill"
        case .wipeLeft: "arrow.left.to.line"
        case .wipeRight: "arrow.right.to.line"
        case .wipeUp: "arrow.up.to.line"
        case .wipeDown: "arrow.down.to.line"
        case .iris: "circle.inset.filled"
        case .clockWipe: "clock"
        case .splitHorizontal: "rectangle.split.2x1"
        case .splitVertical: "rectangle.split.1x2"
        case .filmBurn: "flame.fill"
        case .rgbSplit: "camera.filters"
        case .softLight: "sparkles"
        case .glitch: "waveform.path.ecg.rectangle"
        case .diagonalWipe: "arrow.up.right"
        case .diamond: "diamond.fill"
        case .horizontalBlinds: "rectangle.split.3x1"
        case .verticalBlinds: "rectangle.split.1x2"
        case .checkerboard: "checkerboard.rectangle"
        case .pixelate: "square.grid.3x3.fill"
        case .ripple: "water.waves"
        case .wave: "waveform.path"
        case .squeeze: "arrow.left.and.right"
        case .crossZoom: "viewfinder"
        case .bounce: "arrow.up.and.down"
        case .noiseDissolve: "circle.hexagongrid.fill"
        case .prism: "triangle"
        case .lensWarp: "camera.aperture"
        case .kaleidoscope: "hexagon"
        case .liquid: "drop.fill"
        case .vortex: "tornado"
        case .pageTurn: "book.pages"
        }
    }
    var category: String {
        switch self {
        case .crossDissolve, .dipToBlack, .dipToWhite: "BASIC"
        case .slideLeft, .slideRight, .slideUp, .slideDown, .push: "MOVEMENT"
        case .zoomIn, .zoomOut, .whipPanLeft, .whipPanRight: "CAMERA"
        case .blurDissolve, .spin, .flash: "CREATIVE"
        case .wipeLeft, .wipeRight, .wipeUp, .wipeDown, .iris, .clockWipe,
             .splitHorizontal, .splitVertical: "WIPES"
        case .filmBurn, .rgbSplit, .softLight, .glitch: "CREATIVE"
        case .diagonalWipe, .diamond, .horizontalBlinds, .verticalBlinds,
             .checkerboard: "GEOMETRIC"
        case .pixelate, .ripple, .wave, .squeeze, .crossZoom, .bounce,
             .noiseDissolve: "STYLIZED"
        case .prism, .lensWarp, .kaleidoscope, .liquid, .vortex,
             .pageTurn: "ADVANCED"
        }
    }
}

struct TimelineTransition: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var type: TimelineTransitionType
    var editTime: TimelineTime
    var outgoingClipID: UUID
    var incomingClipID: UUID
    var duration: TimelineTime
    var enabled: Bool = true
    var version: Int = 1

    var range: TimelineRange? {
        let half = CMTimeMultiplyByRatio(duration.cmTime, multiplier: 1, divisor: 2)
        guard let start = try? TimelineTime(CMTimeSubtract(editTime.cmTime, half)) else { return nil }
        return .init(start: start, duration: duration)
    }

    func progress(at time: CMTime) -> Float? {
        guard enabled, let range, range.duration > .zero,
              time >= range.start.cmTime, time < range.cmTimeRange.end else { return nil }
        return Float(min(1, max(0, CMTimeSubtract(time, range.start.cmTime).seconds / range.duration.seconds)))
    }
}

enum TimelineTransitionEditing {
    static let defaultSeconds = 0.5
    static let minimumSeconds = 0.1
    static let maximumSeconds = 2.0

    struct EditPoint {
        let outgoing: VideoClip
        let incoming: VideoClip
        let time: TimelineTime
    }

    static func transition(in project: VideoProject, at time: TimelineTime, toleranceFrames: Int = 2) -> TimelineTransition? {
        let tolerance = (project.canvas.frameDuration?.seconds ?? 1.0 / 30.0) * Double(toleranceFrames)
        return project.timeline.transitions.min {
            let lhsInside = $0.range?.cmTimeRange.containsTime(time.cmTime) == true
            let rhsInside = $1.range?.cmTimeRange.containsTime(time.cmTime) == true
            if lhsInside != rhsInside { return lhsInside }
            return abs($0.editTime.seconds - time.seconds) < abs($1.editTime.seconds - time.seconds)
        }.flatMap { transition in
            let inside = transition.range?.cmTimeRange.containsTime(time.cmTime) == true
            return inside || abs(transition.editTime.seconds - time.seconds) <= tolerance ? transition : nil
        }
    }

    static func editPoint(in project: VideoProject, at requested: TimelineTime, preferredTrackID: UUID?) throws -> EditPoint? {
        let time = try TimelineEditing.snapped(requested, frame: project.canvas.frameDuration)
        let tolerance = (project.canvas.frameDuration?.seconds ?? 1.0 / 30.0) * 2.01
        let visualTracks = project.timeline.tracks.filter { $0.kind == .mainVideo || $0.kind == .videoOverlay }
        let orderedTracks = visualTracks.sorted { lhs, rhs in
            if lhs.id == preferredTrackID { return true }
            if rhs.id == preferredTrackID { return false }
            if lhs.kind == .mainVideo { return true }
            if rhs.kind == .mainVideo { return false }
            return false
        }
        for track in orderedTracks where track.isEnabled && !track.isLocked {
            let clips = track.items.compactMap { item -> VideoClip? in
                guard case .video(let clip) = item, clip.placement.isEnabled, !clip.placement.isLocked,
                      project.assets.first(where: { $0.id == clip.assetID })?.stillImage == nil else { return nil }
                return clip
            }.sorted { $0.placement.timelineStart < $1.placement.timelineStart }
            for (outgoing, incoming) in zip(clips, clips.dropFirst()) {
                let cut = try outgoing.placement.range.end
                guard cut == incoming.placement.timelineStart else { continue }
                if abs(cut.seconds - time.seconds) <= tolerance {
                    return .init(outgoing: outgoing, incoming: incoming, time: cut)
                }
            }
        }
        return nil
    }

    /// Adds/replaces at a cut, or splits the clip under the playhead first. The
    /// caller runs this inside one project snapshot commit, so split + add is a
    /// single undoable action.
    static func apply(_ type: TimelineTransitionType, at requested: TimelineTime,
                      preferredTrackID: UUID?, in project: inout VideoProject) throws -> UUID {
        let time = try TimelineEditing.snapped(requested, frame: project.canvas.frameDuration)
        if let existing = transition(in: project, at: time) {
            guard let index = project.timeline.transitions.firstIndex(where: { $0.id == existing.id }) else { return existing.id }
            project.timeline.transitions[index].type = type
            project.timeline.transitions[index].enabled = true
            return existing.id
        }
        var point = try editPoint(in: project, at: time, preferredTrackID: preferredTrackID)
        if point == nil {
            let clips = try TimelineEditing.clips(in: project)
            let target = TimelineEditing.activeClip(in: clips.filter { clip in
                (preferredTrackID == nil || clip.placement.trackID == preferredTrackID) &&
                project.assets.first(where: { $0.id == clip.assetID })?.stillImage == nil
            }, at: time.cmTime) ?? TimelineEditing.activeClip(in: clips.filter {
                clip in project.timeline.tracks.first(where: { $0.id == clip.placement.trackID })?.kind == .mainVideo
            }, at: time.cmTime)
            guard let target else { throw TimelineError.invalid("Place the playhead on or inside a video clip.") }
            let rightID = try TimelineEditing.split(target.id, at: time, in: &project)
            guard let left = project.timeline.videoClip(id: target.id),
                  let right = project.timeline.videoClip(id: rightID) else {
                throw TimelineError.invalid("The clip could not be split at the playhead.")
            }
            point = .init(outgoing: left, incoming: right, time: right.placement.timelineStart)
        }
        guard let point else { throw TimelineError.invalid("A transition needs video on both sides.") }
        let maximum = try maximumDuration(for: point.outgoing, incoming: point.incoming, in: project)
        let minimum = try minimumDuration(in: project)
        guard maximum >= minimum else { throw TimelineError.invalid("The clips do not have enough source frames for a transition.") }
        let requestedDuration = try TimelineTime.seconds(defaultSeconds)
        let duration = try snappedDuration(min(requestedDuration, maximum), in: project)
        let transition = TimelineTransition(id: UUID(), type: type, editTime: point.time,
                                            outgoingClipID: point.outgoing.id, incomingClipID: point.incoming.id,
                                            duration: duration)
        project.timeline.transitions.append(transition)
        return transition.id
    }

    static func remove(_ id: UUID, in project: inout VideoProject) {
        project.timeline.transitions.removeAll { $0.id == id }
    }

    static func setDuration(_ id: UUID, seconds: Double, in project: inout VideoProject) throws {
        guard let index = project.timeline.transitions.firstIndex(where: { $0.id == id }),
              let outgoing = project.timeline.videoClip(id: project.timeline.transitions[index].outgoingClipID),
              let incoming = project.timeline.videoClip(id: project.timeline.transitions[index].incomingClipID) else { return }
        let maximum = try maximumDuration(for: outgoing, incoming: incoming, in: project)
        let minimum = try minimumDuration(in: project)
        let proposed = try TimelineTime.seconds(min(max(seconds, minimum.seconds), maximumSeconds))
        project.timeline.transitions[index].duration = try snappedDuration(min(proposed, maximum), in: project)
    }

    static func maximumDuration(for outgoing: VideoClip, incoming: VideoClip, in project: VideoProject) throws -> TimelineTime {
        guard let outgoingAsset = project.assets.first(where: { $0.id == outgoing.assetID }),
              let incomingAsset = project.assets.first(where: { $0.id == incoming.assetID }),
              outgoingAsset.stillImage == nil, incomingAsset.stillImage == nil else { return .zero }
        let outgoingSourceHandle = try outgoingAsset.sourceRange.end.subtracting(outgoing.sourceRange.end)
        let incomingSourceHandle = try incoming.sourceRange.start.subtracting(incomingAsset.sourceRange.start)
        let outgoingHandle = try ClipSpeed.timelineDuration(sourceDuration: max(.zero, outgoingSourceHandle), speed: outgoing.speed)
        let incomingHandle = try ClipSpeed.timelineDuration(sourceDuration: max(.zero, incomingSourceHandle), speed: incoming.speed)
        let half = min(min(outgoingHandle, incomingHandle), min(outgoing.placement.duration, incoming.placement.duration))
        let doubled = try TimelineTime(CMTimeMultiply(half.cmTime, multiplier: 2))
        return min(doubled, try TimelineTime.seconds(maximumSeconds))
    }

    static func minimumDuration(in project: VideoProject) throws -> TimelineTime {
        let absolute = try TimelineTime.seconds(minimumSeconds)
        guard let frame = project.canvas.frameDuration else { return absolute }
        var frames = max(2, Int32(ceil(minimumSeconds / frame.seconds)))
        if !frames.isMultiple(of: 2) { frames += 1 }
        return max(absolute, try TimelineTime(CMTimeMultiply(frame.cmTime, multiplier: frames)))
    }

    static func snappedDuration(_ duration: TimelineTime, in project: VideoProject) throws -> TimelineTime {
        guard let frame = project.canvas.frameDuration else { return duration }
        // A centered transition needs an integral number of frames on each
        // side of its edit. Even counts keep both the start and end on the same
        // frame grid as the cut; an odd count would create half-frame source
        // requests that some decoders cannot satisfy deterministically.
        var frames = max(2, Int32((duration.seconds / frame.seconds).rounded(.down)))
        if !frames.isMultiple(of: 2) { frames -= 1 }
        return try TimelineTime(CMTimeMultiply(frame.cmTime, multiplier: frames))
    }

    static func reconcile(in project: inout VideoProject) throws {
        let clips = project.timeline.tracks.flatMap(\.items).compactMap { item -> VideoClip? in
            if case .video(let clip) = item { return clip }
            return nil
        }
        let clipsByID = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
        var seenCuts = Set<String>()
        project.timeline.transitions = try project.timeline.transitions.compactMap { authored in
            guard let outgoing = clipsByID[authored.outgoingClipID],
                  let incoming = clipsByID[authored.incomingClipID],
                  outgoing.placement.trackID == incoming.placement.trackID,
                  try outgoing.placement.range.end == incoming.placement.timelineStart else { return nil }
            let cutKey = "\(outgoing.id.uuidString):\(incoming.id.uuidString)"
            guard seenCuts.insert(cutKey).inserted else { return nil }
            var updated = authored
            updated.editTime = incoming.placement.timelineStart
            let maximum = try maximumDuration(for: outgoing, incoming: incoming, in: project)
            guard maximum >= (try minimumDuration(in: project)) else { return nil }
            updated.duration = try snappedDuration(min(updated.duration, maximum), in: project)
            return updated
        }
    }

    static func validate(project: VideoProject) throws {
        guard Set(project.timeline.transitions.map(\.id)).count == project.timeline.transitions.count else {
            throw TimelineError.invalid("Duplicate transition identifiers.")
        }
        let clips = project.timeline.tracks.flatMap(\.items).compactMap { item -> VideoClip? in
            if case .video(let clip) = item { return clip }
            return nil
        }
        let byID = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
        var cuts = Set<String>()
        for transition in project.timeline.transitions {
            guard transition.version == 1, transition.duration > .zero,
                  let outgoing = byID[transition.outgoingClipID], let incoming = byID[transition.incomingClipID],
                  outgoing.placement.trackID == incoming.placement.trackID,
                  try outgoing.placement.range.end == incoming.placement.timelineStart,
                  cuts.insert("\(outgoing.id):\(incoming.id)").inserted else {
                throw TimelineError.invalid("A transition must connect one adjacent pair of video clips.")
            }
        }
    }
}
