import Foundation

/// How tall a row is drawn, and how large its waveform.
///
/// Both live on the track, in the document. They are display-only, like `name`
/// — nothing in the composition, render or export path reads them — but they
/// are still something a person arranged about *this* project's rows, and a
/// row someone set to compact should still be compact tomorrow.
///
/// The raw values are the stored representation and are **English in every
/// language**, for the same reason `TimelineTrack.defaultName(for:)` is: they
/// are written into the document, and a project made in one language must not
/// stop decoding when opened in another. `title` is what anybody reads.
enum TimelineTrackHeightChoice: String, Codable, CaseIterable, Sendable {
    case compact = "Compact"
    case regular = "Regular"
    case tall = "Tall"

    var title: String {
        switch self {
        case .compact: String(localized: "Compact")
        case .regular: String(localized: "Regular")
        case .tall: String(localized: "Tall")
        }
    }
}

enum TimelineWaveformSize: String, Codable, CaseIterable, Sendable {
    case small = "Small"
    case medium = "Medium"
    case large = "Large"

    var title: String {
        switch self {
        case .small: String(localized: "Small")
        case .medium: String(localized: "Medium")
        case .large: String(localized: "Large")
        }
    }
}

struct TimelineTrack: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case mainVideo, videoOverlay, text, shape, audio

        /// Rows whose picture the app draws rather than reads from media. They
        /// have no filmstrip and no waveform, so the timeline gives them a
        /// short row and sizes itself accordingly.
        var isDrawnOverlay: Bool { self == .text || self == .shape }
    }
    let id: UUID
    var name: String
    var kind: Kind
    var isEnabled = true
    var isLocked = false
    var items: [TimelineItem] = []
    /// How tall this row is drawn, and how large its waveform; nil means the
    /// default. Optional rather than defaulted, because a synthesized decoder
    /// ignores property defaults and throws on a missing key — this is what
    /// keeps every project written before row heights readable.
    var heightChoice: TimelineTrackHeightChoice? = nil
    var waveformSize: TimelineWaveformSize? = nil

    var resolvedHeight: TimelineTrackHeightChoice { heightChoice ?? .regular }
    var resolvedWaveformSize: TimelineWaveformSize { waveformSize ?? .medium }

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

    /// The stored name a new track is given. **English, deliberately, in every
    /// language.** It is the document value, and it is also compared — a track
    /// still carrying its default name is treated as unnamed by
    /// `layerDisplayName` and by the rename field. Localising it would mean a
    /// project made in one language stopped matching when opened in another,
    /// and a renamed track would be indistinguishable from a default one.
    /// `localizedName(_:)` is what the user actually reads.
    static func defaultName(for kind: Kind) -> String {
        switch kind {
        case .mainVideo: "Main Video"
        case .videoOverlay: "Overlay"
        case .text: "Text"
        case .shape: "Shape"
        case .audio: "Audio"
        }
    }

    /// A track name as it should be shown. A name the user chose is their own
    /// words and is returned untouched; one the app supplied is translated.
    static func localizedName(_ name: String) -> String {
        switch name {
        case "Main Video": String(localized: "Main Video")
        case "Overlay": String(localized: "Overlay")
        case "Text": String(localized: "Text")
        case "Shape": String(localized: "Shape")
        case "Audio": String(localized: "Audio")
        default: name
        }
    }

    /// The Layers sheet describes a default text track by the words the viewer
    /// will actually see. A deliberately renamed track keeps its custom name.
    /// Text tracks normally contain one clip; after a split, the earliest clip
    /// provides the stable row label.
    var layerDisplayName: String {
        if kind == .shape, name == Self.defaultName(for: .shape) {
            let firstShape = items.compactMap { item -> ShapeClip? in
                guard case .shape(let clip) = item else { return nil }
                return clip
            }.min { $0.placement.timelineStart < $1.placement.timelineStart }
            guard let firstShape else { return Self.localizedName(name) }
            return Self.sanitizedName(firstShape.kind.title, kind: .shape)
        }
        guard kind == .text, name == Self.defaultName(for: .text) else { return Self.localizedName(name) }
        let firstText = items.compactMap { item -> TextClip? in
            guard case .text(let clip) = item else { return nil }
            return clip
        }.min { $0.placement.timelineStart < $1.placement.timelineStart }
        guard let firstText else { return Self.localizedName(name) }
        return Self.sanitizedName(firstText.text, kind: .text)
    }

    var hasAudioContent: Bool {
        items.contains { item in
            switch item {
            case .audio: true
            case .video(let clip): clip.embeddedAudio != nil
            case .text, .shape: false
            }
        }
    }

    var isAudioMuted: Bool {
        let states = items.compactMap { item -> Bool? in
            switch item {
            case .audio(let clip): clip.isMuted
            case .video(let clip): clip.embeddedAudio?.isMuted
            case .text, .shape: nil
            }
        }
        return !states.isEmpty && states.allSatisfy { $0 }
    }

    func accepts(_ item: TimelineItem) -> Bool {
        switch (kind, item) {
        case (.mainVideo, .video), (.videoOverlay, .video), (.text, .text),
             (.shape, .shape), (.audio, .audio): true
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
