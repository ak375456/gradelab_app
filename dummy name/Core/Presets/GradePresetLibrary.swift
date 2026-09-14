import Combine
import Foundation
import SwiftUI
import UIKit

/// The saved presets, as the UI sees them.
///
/// One place owns the list, the ordering rule and the writes, so every screen
/// showing "My Presets" is showing the same thing. Mutations write straight
/// through to disk: there are only ever a handful of small records, and a
/// preset that vanished because the app was killed before an autosave would be
/// a poor trade for the saved milliseconds.
@MainActor
final class GradePresetLibrary: ObservableObject {
    @Published private(set) var presets: [GradePreset] = []
    /// Surfaces a write that failed, so a save that did not happen is never
    /// reported as one that did.
    @Published var errorMessage: String?

    private let store: GradePresetStore
    /// Decoded thumbnails, so scrolling the grid does not re-read JPEGs. They
    /// are ~400px, and the cache is dropped under memory pressure by NSCache.
    private let thumbnails = NSCache<NSString, UIImage>()

    init(store: GradePresetStore = GradePresetStore()) {
        self.store = store
        reload()
    }

    func reload() {
        do {
            presets = try store.load()
        } catch {
            presets = []
            errorMessage = "Saved presets could not be read. \(error.localizedDescription)"
        }
    }

    var isEmpty: Bool { presets.isEmpty }

    func preset(id: UUID) -> GradePreset? { presets.first { $0.id == id } }

    /// The name the save sheet offers: "My Preset", or the first free number
    /// after it.
    func suggestedName() -> String {
        GradePresetName.unique(among: presets.map(\.name))
    }

    // MARK: - Creating

    /// Saves the given grade under `name`.
    ///
    /// `settings` is a value, so what lands here is already an independent
    /// snapshot: later edits to the clip it came from cannot reach it, and
    /// applying it later hands out another independent copy.
    @discardableResult
    func add(
        name proposedName: String,
        gradeSettings: GradeSettings,
        isFavorite: Bool = false,
        thumbnail: UIImage? = nil
    ) throws -> GradePreset {
        guard let name = GradePresetName.sanitize(proposedName) else {
            throw GradeLabError.invalidPresetName
        }
        let id = UUID()
        // A thumbnail that cannot be written must not cost the preset: the
        // picture is a convenience, the grade is the point.
        let filename = thumbnail.flatMap { try? store.writeThumbnail($0, for: id) }
        let preset = GradePreset(
            id: id,
            name: name,
            gradeSettings: gradeSettings,
            isFavorite: isFavorite,
            thumbnailFilename: filename
        )
        try mutate { $0.append(preset) }
        if let thumbnail, let filename { thumbnails.setObject(thumbnail, forKey: filename as NSString) }
        return preset
    }

    // MARK: - Editing

    /// Renaming keeps the identity, the grade and the picture. Nothing about
    /// the preset changes except what it is called.
    func rename(_ id: UUID, to proposedName: String) throws {
        guard let name = GradePresetName.sanitize(proposedName) else {
            throw GradeLabError.invalidPresetName
        }
        try mutate { presets in
            guard let index = presets.firstIndex(where: { $0.id == id }), presets[index].name != name else { return }
            presets[index].name = name
            presets[index].updatedAt = .now
        }
    }

    /// A duplicate is a new preset: new identity, its own copy of the grade and
    /// its own thumbnail file. Editing or deleting either one afterwards leaves
    /// the other alone.
    @discardableResult
    func duplicate(_ id: UUID) throws -> GradePreset? {
        guard let original = preset(id: id) else { return nil }
        let newID = UUID()
        let copy = GradePreset(
            id: newID,
            name: GradePresetName.copy(of: original.name, among: presets.map(\.name)),
            gradeSettings: original.gradeSettings,
            isFavorite: false,
            thumbnailFilename: original.thumbnailFilename.flatMap { store.copyThumbnail($0, to: newID) }
        )
        try mutate { $0.append(copy) }
        return copy
    }

    func toggleFavorite(_ id: UUID) {
        try? mutate { presets in
            guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
            presets[index].isFavorite.toggle()
            presets[index].updatedAt = .now
        }
    }

    /// Replaces a preset's grade in place — the optional "Update Preset" path.
    /// Clips the preset was already applied to are untouched: they hold their
    /// own copy of the settings and never look back at this record.
    func update(_ id: UUID, gradeSettings: GradeSettings, thumbnail: UIImage? = nil) throws {
        guard presets.contains(where: { $0.id == id }) else { return }
        let filename = thumbnail.flatMap { try? store.writeThumbnail($0, for: id) }
        if let filename { thumbnails.removeObject(forKey: filename as NSString) }
        try mutate { presets in
            guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
            presets[index].gradeSettings = gradeSettings
            presets[index].updatedAt = .now
            if let filename { presets[index].thumbnailFilename = filename }
        }
        if let thumbnail, let filename { thumbnails.setObject(thumbnail, forKey: filename as NSString) }
    }

    /// Deletes the saved record and its picture, and nothing else. Any clip the
    /// preset was applied to keeps the grade it was given.
    func delete(_ id: UUID) {
        guard let existing = preset(id: id) else { return }
        try? mutate { $0.removeAll { $0.id == id } }
        if let filename = existing.thumbnailFilename {
            thumbnails.removeObject(forKey: filename as NSString)
            store.removeThumbnail(filename)
        }
    }

    // MARK: - Thumbnails

    func thumbnail(for preset: GradePreset) -> UIImage? {
        guard let filename = preset.thumbnailFilename else { return nil }
        if let cached = thumbnails.object(forKey: filename as NSString) { return cached }
        guard let image = store.loadThumbnail(filename) else { return nil }
        thumbnails.setObject(image, forKey: filename as NSString)
        return image
    }

    // MARK: - Writing

    /// Every change goes through here: apply it to a copy, order it, write it,
    /// and only then publish. A failed write leaves the visible list exactly as
    /// it was rather than showing something the disk does not agree with.
    private func mutate(_ change: (inout [GradePreset]) -> Void) throws {
        var updated = presets
        change(&updated)
        let ordered = updated.sortedForDisplay
        guard ordered != presets else { return }
        do {
            try store.save(ordered)
        } catch {
            errorMessage = "The preset could not be saved. \(error.localizedDescription)"
            throw error
        }
        presets = ordered
    }
}
