import Combine
import Foundation
import SwiftUI

/// The grade clipboard: one copied grading state, for the length of the session.
///
/// Deliberately in memory only. A copied grade is a working convenience, not a
/// document: it is never written to disk, never stored inside a project, and is
/// gone on the next launch. What a paste produces *is* persisted, because by
/// then it belongs to the clip.
///
/// Shared rather than owned by one editor so a grade copied in one project can
/// be pasted in another during the same session.
///
/// `GradeSettings` is a value type all the way down — the curves, their control
/// points, the hue bands, the wheels and the effects are all structs — so
/// storing one here copies it. Nothing is shared with the clip it came from,
/// and nothing a later edit does can reach back into it.
@MainActor
final class GradeClipboard: ObservableObject {
    static let shared = GradeClipboard()

    /// The copied grade, or nil when nothing has been copied yet.
    @Published private(set) var grade: GradeSettings?
    /// What it was copied from, for the paste action's wording. Display only.
    @Published private(set) var sourceName: String?

    init() {}

    var hasGrade: Bool { grade != nil }

    /// Replaces whatever was held. There is no history: the last thing copied
    /// is the thing that pastes.
    func copy(_ grade: GradeSettings, from sourceName: String? = nil) {
        self.grade = grade
        self.sourceName = sourceName
    }

    func clear() {
        grade = nil
        sourceName = nil
    }
}
