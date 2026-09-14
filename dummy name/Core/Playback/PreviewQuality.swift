import Foundation

/// How much resolution the preview gives up **while it is playing**.
///
/// A 4K60 timeline has to move 8.3 million pixels sixty times a second through
/// decode, the compositor, the texture upload and the grading pass. A phone
/// screen is nowhere near 4K, so playing at full resolution spends most of that
/// work on detail the display cannot show — and drops frames doing it.
///
/// This only ever applies to playback. The moment the picture is paused it goes
/// back to the project's own resolution, so the frame anyone actually grades,
/// scrubs to or inspects is the real one. Export never sees this at all.
enum PreviewQuality: String, CaseIterable, Identifiable, Sendable {
    /// Quarter-HD. For 4K on an older device, or a heavily layered timeline.
    case low
    /// 1080p. Smooth on a phone and still detailed enough to judge a grade.
    case medium
    /// No reduction: play at the project's resolution.
    case full

    var id: String { rawValue }

    /// Longest edge the playing preview is composited at, or nil for no limit.
    var longEdgeLimit: Int? {
        switch self {
        case .low: 960
        case .medium: 1920
        case .full: nil
        }
    }

    var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .full: "Full"
        }
    }

    /// What the transport button shows. Short enough to sit next to the
    /// timecode without crowding it.
    var badge: String {
        switch self {
        case .low: "Low"
        case .medium: "Med"
        case .full: "Full"
        }
    }

    var detail: String {
        switch self {
        case .low: "Plays at up to 960 px. Smoothest on 4K and layered timelines."
        case .medium: "Plays at up to 1920 px."
        case .full: "Plays at the project's own resolution."
        }
    }

    // MARK: - Preference

    private static let defaultsKey = "preview.quality"

    /// Medium by default: it is the setting that makes 4K play properly on a
    /// phone while still looking like the picture.
    static func load() -> PreviewQuality {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let quality = PreviewQuality(rawValue: raw) else { return .medium }
        return quality
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}
