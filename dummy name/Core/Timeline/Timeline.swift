import Foundation

struct TimelineTrack: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case mainVideo, videoOverlay, text, audio }
    let id: UUID
    var name: String
    var kind: Kind
    var isEnabled = true
    var isLocked = false
    var items: [TimelineItem] = []

    /// Layer names are display-only: nothing in the composition, render or export path
    /// reads them, so they are free to edit. Sanitising here keeps a pasted paragraph or an
    /// all-whitespace entry from producing an unreadable or empty row.
    static func sanitizedName(_ proposed: String, kind: Kind) -> String {
        let flattened = proposed.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let collapsed = flattened.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return collapsed.isEmpty ? defaultName(for: kind) : String(collapsed.prefix(60))
    }

    static func defaultName(for kind: Kind) -> String {
        switch kind {
        case .mainVideo: "Main Video"
        case .videoOverlay: "Overlay"
        case .text: "Text"
        case .audio: "Audio"
        }
    }

    func accepts(_ item: TimelineItem) -> Bool {
        switch (kind, item) {
        case (.mainVideo, .video), (.videoOverlay, .video), (.text, .text), (.audio, .audio): true
        default: false
        }
    }
}

struct TimelineMarker: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var time: TimelineTime
    var label: String = ""
}

struct Timeline: Codable, Equatable, Sendable {
    /// Topmost track first. Render visual tracks in reverse order, bottom to top.
    var tracks: [TimelineTrack]
    var markers: [TimelineMarker] = []
    /// Visual transitions live at edit points, independently of either clip's
    /// grade. A custom decoder keeps V1/V2 documents (which have no such key)
    /// readable as an empty transition list.
    var transitions: [TimelineTransition] = []

    init(tracks: [TimelineTrack], markers: [TimelineMarker] = [], transitions: [TimelineTransition] = []) {
        self.tracks = tracks
        self.markers = markers
        self.transitions = transitions
    }

    private enum CodingKeys: String, CodingKey { case tracks, markers, transitions }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tracks = try container.decode([TimelineTrack].self, forKey: .tracks)
        markers = try container.decodeIfPresent([TimelineMarker].self, forKey: .markers) ?? []
        transitions = try container.decodeIfPresent([TimelineTransition].self, forKey: .transitions) ?? []
    }

    /// Disabled/locked clips retain their extent. Markers never extend the movie.
    var duration: TimelineTime {
        tracks.flatMap(\.items).compactMap { try? $0.placement.range.end }.max() ?? .zero
    }

    func videoClip(id: UUID) -> VideoClip? {
        for track in tracks {
            for case .video(let clip) in track.items where clip.id == id { return clip }
        }
        return nil
    }

    var firstVideoClip: VideoClip? {
        for track in tracks {
            for case .video(let clip) in track.items { return clip }
        }
        return nil
    }

    @discardableResult
    mutating func setGrade(_ settings: GradeSettings, for clipID: UUID) -> Bool {
        for trackIndex in tracks.indices where !tracks[trackIndex].isLocked {
            for itemIndex in tracks[trackIndex].items.indices {
                guard case .video(var clip) = tracks[trackIndex].items[itemIndex],
                      clip.id == clipID, !clip.placement.isLocked else { continue }
                guard clip.gradeSettings != settings else { return false }
                clip.gradeSettings = settings
                tracks[trackIndex].items[itemIndex] = .video(clip)
                return true
            }
        }
        return false
    }
}
