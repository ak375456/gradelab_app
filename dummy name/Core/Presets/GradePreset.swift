import Foundation

// ---------------------------------------------------------------------------
// Grade presets
//
// A preset is the whole grading state under a name — light, colour, all ten
// curves, HSL, wheels, vignette, the look and its strength, and the finishing
// effects. It is deliberately *not* a `.cube`: a LUT can only carry a colour
// transform, and most of what is stored here is not one.
//
// `GradeSettings` is already a Codable value type that holds every one of those
// controls, so a preset stores it whole rather than restating each field. That
// is also what makes copies independent for free: assigning it copies it, with
// no shared reference for a later edit to reach through.
// ---------------------------------------------------------------------------

struct GradePreset: Codable, Identifiable, Equatable, Sendable {
    /// Bumped when the *preset envelope* changes shape. Grading properties
    /// added to `GradeSettings` do not need it: they decode as absent and take
    /// their neutral default, which is exactly what an older preset meant.
    static let currentVersion = 1

    /// Identity is the UUID, never the name. Two presets may share a name;
    /// renaming one must not turn it into a different preset.
    let id: UUID
    var name: String
    var gradeSettings: GradeSettings
    let createdAt: Date
    var updatedAt: Date
    var isFavorite: Bool
    /// File name inside the store's `thumbnails` directory. Optional because a
    /// thumbnail is a convenience for the UI, not part of the grade — a preset
    /// with no picture still applies exactly.
    var thumbnailFilename: String?
    var presetVersion: Int

    init(
        id: UUID = UUID(),
        name: String,
        gradeSettings: GradeSettings,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        isFavorite: Bool = false,
        thumbnailFilename: String? = nil,
        presetVersion: Int = GradePreset.currentVersion
    ) {
        self.id = id
        self.name = name
        self.gradeSettings = gradeSettings
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isFavorite = isFavorite
        self.thumbnailFilename = thumbnailFilename
        self.presetVersion = presetVersion
    }

    /// Decoding is forgiving on purpose. Everything except the identity, the
    /// name and the grade has a safe default, so a preset written by an older
    /// build — or by a newer one that added a field this build does not know —
    /// still loads and still applies.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        gradeSettings = try c.decode(GradeSettings.self, forKey: .gradeSettings)
        let created = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        createdAt = created
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? created
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        thumbnailFilename = try c.decodeIfPresent(String.self, forKey: .thumbnailFilename)
        presetVersion = try c.decodeIfPresent(Int.self, forKey: .presetVersion) ?? 1
    }

    /// The look this preset expects, or nil when it applies none.
    var lutIdentifier: String? { gradeSettings.advanced?.lut }

    /// The preset's grade with its look removed, for the case where the `.cube`
    /// it names is no longer on the device.
    var withoutLook: GradeSettings { gradeSettings.withoutLook }
}

// ---------------------------------------------------------------------------
// Names
// ---------------------------------------------------------------------------

enum GradePresetName {
    static let maximumLength = 60
    static let defaultBase = "My Preset"

    /// Trims and caps a typed name. Returns nil when nothing usable is left, so
    /// an empty name is refused rather than saved as a blank tile.
    static func sanitize(_ proposed: String) -> String? {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximumLength))
    }

    /// "My Preset", then "My Preset 2", "My Preset 3"… Duplicate names are
    /// allowed — identity is the UUID — but offering one by default would be
    /// needlessly confusing.
    static func unique(base: String = defaultBase, among existing: [String]) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var attempt = 2
        while taken.contains("\(base) \(attempt)".lowercased()) { attempt += 1 }
        return String("\(base) \(attempt)".prefix(maximumLength))
    }

    /// Name for a duplicate: "Tokyo Copy", then "Tokyo Copy 2".
    static func copy(of name: String, among existing: [String]) -> String {
        let base = String("\(name) Copy".prefix(maximumLength))
        return unique(base: base, among: existing)
    }
}

// ---------------------------------------------------------------------------
// Ordering
// ---------------------------------------------------------------------------

extension Array where Element == GradePreset {
    /// Favourites first, then most recently updated. One rule, applied
    /// everywhere the list is shown or written.
    var sortedForDisplay: [GradePreset] {
        sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
