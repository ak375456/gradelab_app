import Foundation

/// Undo/redo for a grade.
///
/// The same shape and the same rules as `TimelineHistory` — record a
/// before/after pair, undo returns the before, redo returns the after, and a
/// recording clears the redo stack — but over a `GradeSettings` rather than a
/// whole timeline document, because in an image project the grade is the only
/// thing an edit can change.
struct GradeHistory {
    struct Entry { let name: String; let before: GradeSettings; let after: GradeSettings }

    private(set) var undoEntries: [Entry] = []
    private(set) var redoEntries: [Entry] = []

    mutating func record(_ name: String, before: GradeSettings, after: GradeSettings) {
        guard before != after else { return }
        undoEntries.append(.init(name: name, before: before, after: after))
        if undoEntries.count > 100 { undoEntries.removeFirst() }
        redoEntries.removeAll()
    }

    mutating func undo() -> GradeSettings? {
        guard let entry = undoEntries.popLast() else { return nil }
        redoEntries.append(entry)
        return entry.before
    }

    mutating func redo() -> GradeSettings? {
        guard let entry = redoEntries.popLast() else { return nil }
        undoEntries.append(entry)
        return entry.after
    }
}

/// Whole-document history for the photo editor now that a photo can carry
/// authored alpha as well as a grade.
struct ImageProjectHistory {
    struct Entry { let name: String; let before: ImageProject; let after: ImageProject }
    private(set) var undoEntries: [Entry] = []
    private(set) var redoEntries: [Entry] = []

    mutating func record(_ name: String, before: ImageProject, after: ImageProject) {
        guard before != after else { return }
        undoEntries.append(.init(name: name, before: before, after: after))
        if undoEntries.count > 100 { undoEntries.removeFirst() }
        redoEntries.removeAll()
    }
    mutating func undo() -> ImageProject? {
        guard let entry = undoEntries.popLast() else { return nil }
        redoEntries.append(entry); return entry.before
    }
    mutating func redo() -> ImageProject? {
        guard let entry = redoEntries.popLast() else { return nil }
        undoEntries.append(entry); return entry.after
    }
}
