import CoreMedia
import Foundation

/// How another layer's rendering is read as this layer's coverage.
///
/// Both implemented readings take the source's ALPHA and nothing else; they
/// differ only in which side of it keeps the target. The luma readings are the
/// same relationship again with a different channel, and will append here
/// rather than arriving as a separate document key.
///
/// Raw values are persisted, so a case is only ever APPENDED and `alpha` keeps
/// the spelling every existing project was written with.
enum TrackMatteMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// The source's alpha. Its colour is irrelevant: opaque black and opaque
    /// white reveal the target identically.
    case alpha
    /// One minus the source's alpha. The target survives where the source is
    /// TRANSPARENT — video everywhere except inside the letters.
    case alphaInverted

    var id: String { rawValue }
    var title: String {
        switch self {
        case .alpha: String(localized: "Alpha Matte")
        case .alphaInverted: String(localized: "Alpha Inverted Matte")
        }
    }

    /// One line under the picker, because "inverted" on its own does not say
    /// which side of the letters survives.
    var explanation: String {
        switch self {
        case .alpha:
            String(localized: "This layer is kept where the matte source is opaque.")
        case .alphaInverted:
            String(localized: "This layer is kept where the matte source is transparent.")
        }
    }

    /// Whether coverage is `1 - sourceAlpha` rather than `sourceAlpha`.
    ///
    /// The single place the two modes differ. Everything before it — the
    /// source's transform, its opacity, its structural layer mask, its
    /// keyframes — resolves to one final coverage value, and this decides which
    /// end of that value keeps the target. Nothing is thresholded, so a glyph
    /// edge at 0.15 becomes 0.85 and stays as smooth as it was.
    var isInverted: Bool { self == .alphaInverted }
}

/// One layer's track matte: another timeline item supplies this layer's
/// coverage.
///
/// This is a THIRD thing, next to the two that already exist. A `LayerMask`
/// changes a clip's own alpha with a shape it carries; a `MaskedGradeLayer`
/// (a power window) restricts grading and never changes transparency at all.
/// A track matte takes the coverage of a DIFFERENT layer and multiplies this
/// layer's alpha by it.
///
/// The configuration lives on the TARGET. The source knows nothing about who
/// reads it, so one source can drive several targets and deleting a target
/// touches nothing else.
struct TrackMatteConfiguration: Codable, Equatable, Sendable {
    /// The item whose coverage is read. A stable item id on purpose: reordering
    /// tracks, or moving a clip to another row, must not reassign the matte —
    /// which is exactly what "the layer above" would do.
    var sourceItemID: UUID
    var mode: TrackMatteMode = .alpha
    /// Optional so a document written before the switch existed decodes as the
    /// professional default rather than as `false`. Read through
    /// `drawsSourceSeparately`.
    var rendersSource: Bool? = nil

    /// Whether the source ALSO appears in the picture in its own right.
    ///
    /// Off by default, which is what a track matte means everywhere else: the
    /// title is consumed to cut the video, not drawn again on top of it.
    var drawsSourceSeparately: Bool {
        get { rendersSource ?? false }
        set { rendersSource = newValue }
    }
}

extension TimelineItem {
    /// This item's track matte, whatever kind of item it is.
    var trackMatte: TrackMatteConfiguration? {
        switch self {
        case .video(let clip): clip.trackMatte
        case .text(let clip): clip.trackMatte
        case .shape(let clip): clip.trackMatte
        case .audio: nil
        }
    }

    /// Whether this item can be a matte source or a matte target at all. Audio
    /// has no picture, so it is neither.
    var isCompositable: Bool {
        switch self {
        case .video, .text, .shape: true
        case .audio: false
        }
    }

    /// The same item with its track matte replaced. Audio is returned unchanged.
    func settingTrackMatte(_ configuration: TrackMatteConfiguration?) -> TimelineItem {
        switch self {
        case .video(var clip): clip.trackMatte = configuration; return .video(clip)
        case .text(var clip): clip.trackMatte = configuration; return .text(clip)
        case .shape(var clip): clip.trackMatte = configuration; return .shape(clip)
        case .audio: return self
        }
    }
}

extension Timeline {
    /// Every target → matte-source edge in the document.
    var trackMatteEdges: [UUID: UUID] {
        var edges: [UUID: UUID] = [:]
        for track in tracks {
            for item in track.items {
                guard let matte = item.trackMatte else { continue }
                edges[item.id] = matte.sourceItemID
            }
        }
        return edges
    }

    var hasTrackMatte: Bool {
        tracks.contains { $0.items.contains { $0.trackMatte != nil } }
    }

    /// Items that are being consumed as a matte and must not also be drawn into
    /// the picture on their own.
    ///
    /// Read once per frame by the compositor. Deliberately independent of time:
    /// a source that appeared for the seconds it is not covering a target would
    /// flash on and off, which is not what anyone means by using it as a matte.
    var trackMatteConsumedSourceIDs: Set<UUID> {
        var consumed = Set<UUID>()
        for track in tracks {
            for item in track.items {
                guard let matte = item.trackMatte, !matte.drawsSourceSeparately else { continue }
                consumed.insert(matte.sourceItemID)
            }
        }
        return consumed
    }

    /// Whether pointing `target` at `source` would close a loop.
    ///
    /// Each item has at most one matte, so the graph is a functional one and the
    /// whole question is answered by walking the chain forward from the proposed
    /// source. The visited set guards against a cycle that does not include the
    /// target, which a repaired document should not contain but a hand-edited
    /// one might.
    func trackMatteWouldCycle(target: UUID, source: UUID) -> Bool {
        if target == source { return true }
        let edges = trackMatteEdges
        var visited = Set<UUID>()
        var cursor: UUID? = source
        while let current = cursor {
            if current == target { return true }
            // A loop that does not pass through the target is a pre-existing
            // fault `reconcileTrackMattes` removes; it is not created by this
            // edge, so it does not make this edge invalid.
            guard visited.insert(current).inserted else { return false }
            cursor = edges[current]
        }
        return false
    }

    /// Drops track matte relationships that cannot be rendered, leaving
    /// everything else untouched.
    ///
    /// Called on every document mutation and once on decode, so a deleted source
    /// never leaves a dangling id behind and a loop can never reach the
    /// compositor. It removes relationships; it never deletes a layer, changes a
    /// transform, a mask or a grade.
    @discardableResult
    mutating func reconcileTrackMattes() -> Bool {
        // Cheap enough to call from every mutation, including a slider drag,
        // because a timeline with no matte at all answers here.
        guard hasTrackMatte else { return false }
        let compositable = Set(tracks.flatMap(\.items).filter(\.isCompositable).map(\.id))
        var changed = false
        // Pass one: the source is gone, is not something that can be drawn, or
        // is the target itself.
        for t in tracks.indices {
            for i in tracks[t].items.indices {
                guard let matte = tracks[t].items[i].trackMatte else { continue }
                let id = tracks[t].items[i].id
                guard !compositable.contains(matte.sourceItemID) || matte.sourceItemID == id
                        || !compositable.contains(id) else { continue }
                tracks[t].items[i] = tracks[t].items[i].settingTrackMatte(nil)
                changed = true
            }
        }
        // Pass two: break loops. Walking in document order means each loop is
        // broken at its first member, which is stable across repeated repairs.
        var edges = trackMatteEdges
        for t in tracks.indices {
            for i in tracks[t].items.indices {
                let id = tracks[t].items[i].id
                guard edges[id] != nil else { continue }
                var visited: Set<UUID> = [id]
                var cursor = edges[id]
                var loops = false
                while let current = cursor {
                    if current == id { loops = true; break }
                    guard visited.insert(current).inserted else { break }
                    cursor = edges[current]
                }
                guard loops else { continue }
                tracks[t].items[i] = tracks[t].items[i].settingTrackMatte(nil)
                edges[id] = nil
                changed = true
            }
        }
        return changed
    }
}

/// Reading and writing one layer's track matte, and the rules the document has
/// to satisfy for the compositor to be able to resolve it.
enum TrackMatteEditing {
    /// A matte source offered in the picker.
    struct Candidate: Identifiable, Equatable {
        let id: UUID
        /// What the person sees. Never a uuid.
        let name: String
        /// Where and when it is, for telling two similar layers apart.
        let detail: String
        /// False when this source does not cover the whole target. Offered
        /// anyway — a short matte is a legitimate edit — but said out loud.
        let coversTarget: Bool
    }

    static func matte(of id: UUID, in project: VideoProject) -> TrackMatteConfiguration? {
        project.timeline.item(id: id)?.trackMatte
    }

    /// Sets or clears the matte on one item, whatever kind of item it is.
    ///
    /// Routed through the ordinary per-kind editing entry points so a locked
    /// track refuses this for the same reason, with the same message, that it
    /// refuses any other edit.
    static func setMatte(
        _ configuration: TrackMatteConfiguration?,
        on id: UUID,
        in project: inout VideoProject
    ) throws {
        guard let item = project.timeline.item(id: id) else {
            throw TimelineError.invalid(String(localized: "The selected layer is no longer in the timeline."))
        }
        if let configuration {
            guard item.isCompositable else {
                throw TimelineError.invalid(String(localized: "Only video, image, text and shape layers can use a track matte."))
            }
            guard let source = project.timeline.item(id: configuration.sourceItemID), source.isCompositable else {
                throw TimelineError.invalid(String(localized: "Choose a layer that draws a picture as the matte."))
            }
            guard !project.timeline.trackMatteWouldCycle(target: id, source: configuration.sourceItemID) else {
                throw TimelineError.invalid(String(localized: "That layer already depends on this one, so using it would create a loop."))
            }
        }
        switch item {
        case .video(var clip):
            clip.trackMatte = configuration
            try TimelineEditing.replace(id, with: [clip], in: &project)
        case .text(var clip):
            clip.trackMatte = configuration
            try OverlayEditing.replace(id, with: clip, in: &project)
        case .shape(var clip):
            clip.trackMatte = configuration
            try OverlayEditing.replace(id, with: clip, in: &project)
        case .audio:
            throw TimelineError.invalid(String(localized: "An audio clip has no picture to cut."))
        }
    }

    /// Every layer that could supply this target's coverage, topmost first.
    ///
    /// Excludes the target itself and anything that would close a loop, so a
    /// relationship the compositor cannot resolve is not offerable in the first
    /// place rather than rejected afterwards.
    static func candidates(for targetID: UUID, in project: VideoProject) -> [Candidate] {
        guard let target = project.timeline.item(id: targetID) else { return [] }
        let targetEnd = (try? target.placement.range.end) ?? target.placement.timelineStart
        var results: [Candidate] = []
        for track in project.timeline.tracks {
            let videoOrdinals = track.items.filter { if case .video = $0 { return true } else { return false } }
            for item in track.items {
                guard item.isCompositable, item.id != targetID,
                      !project.timeline.trackMatteWouldCycle(target: targetID, source: item.id) else { continue }
                let end = (try? item.placement.range.end) ?? item.placement.timelineStart
                let covers = item.placement.timelineStart <= target.placement.timelineStart && end >= targetEnd
                results.append(.init(
                    id: item.id,
                    name: name(for: item, track: track, ordinals: videoOrdinals, project: project),
                    // `locale: .current` is not optional here: without it a
                    // German or French build prints 1.50s where the rest of the
                    // app prints 1,50s.
                    detail: String(
                        format: "%@ · %.2fs – %.2fs",
                        locale: .current,
                        track.layerDisplayName,
                        item.placement.timelineStart.seconds,
                        end.seconds
                    ),
                    coversTarget: covers
                ))
            }
        }
        return results
    }

    /// Whether the chosen source is present for every frame of the target.
    /// Where it is absent there is no coverage, so the target is transparent —
    /// correct for an alpha matte, and worth saying before it surprises anyone.
    static func sourceCoversTarget(_ targetID: UUID, in project: VideoProject) -> Bool {
        guard let target = project.timeline.item(id: targetID),
              let matte = target.trackMatte,
              let source = project.timeline.item(id: matte.sourceItemID),
              let targetEnd = try? target.placement.range.end,
              let sourceEnd = try? source.placement.range.end else { return true }
        return source.placement.timelineStart <= target.placement.timelineStart && sourceEnd >= targetEnd
    }

    private static func name(
        for item: TimelineItem,
        track: TimelineTrack,
        ordinals: [TimelineItem],
        project: VideoProject
    ) -> String {
        switch item {
        case .text(let clip):
            let line = clip.text.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return line.isEmpty ? String(localized: "Text") : "\(String(localized: "Text")) · \(String(line.prefix(28)))"
        case .shape(let clip):
            return "\(String(localized: "Shape")) · \(clip.kind.title)"
        case .video(let clip):
            let index = (ordinals.firstIndex { $0.id == clip.id } ?? 0) + 1
            let isStill = project.assets.first { $0.id == clip.assetID }?.stillImage != nil
            let noun = isStill ? String(localized: "Image") : String(localized: "Clip")
            return ordinals.count > 1 ? "\(track.layerDisplayName) · \(noun) \(index)"
                                      : "\(track.layerDisplayName) · \(noun)"
        case .audio:
            return track.layerDisplayName
        }
    }

    /// Document-level rules. Reached only by a document that was not repaired —
    /// `reconcileTrackMattes` runs on decode and on every edit — so this is the
    /// backstop that keeps an unresolvable graph from reaching the compositor.
    static func validate(project: VideoProject) throws {
        let compositable = Set(project.timeline.tracks.flatMap(\.items).filter(\.isCompositable).map(\.id))
        for track in project.timeline.tracks {
            for item in track.items {
                guard let matte = item.trackMatte else { continue }
                guard item.isCompositable else {
                    throw TimelineError.invalid(String(localized: "Only a layer that draws a picture can use a track matte."))
                }
                guard matte.sourceItemID != item.id else {
                    throw TimelineError.invalid(String(localized: "A layer cannot be its own track matte."))
                }
                guard compositable.contains(matte.sourceItemID) else {
                    throw TimelineError.invalid(String(localized: "A track matte points at a layer that is not in the timeline."))
                }
                guard !project.timeline.trackMatteWouldCycle(target: item.id, source: matte.sourceItemID) else {
                    throw TimelineError.invalid(String(localized: "Track mattes form a loop."))
                }
            }
        }
    }
}
