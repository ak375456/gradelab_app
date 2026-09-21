import SwiftUI

/// The vertical budget for the editor's tall layout.
///
/// The picture and the timeline both get a fixed height, and a `VStack` does
/// not shrink rigid children — it lays them out at the size they asked for and
/// lets the ones at the end fall off the bottom. So the two of them together
/// have to be checked against the window, or the mode bar goes off screen,
/// taking the first-run "preparing layers" notice with it. That is exactly what
/// happened when the timeline gained its toolbar.
///
/// Everything here is arithmetic over constants that the views themselves fix,
/// which is what makes it testable: `EditorWorkspaceBudgetTests` asserts the
/// whole column fits on real device heights rather than trusting the numbers.
enum EditorWorkspaceBudget {

    // MARK: - What the surrounding chrome costs

    /// Project name, undo/redo, options and Export — a row of 44pt controls.
    static let header: CGFloat = 44
    /// One `WorkspaceDivider`.
    static let divider: CGFloat = WorkspaceDivider.thickness
    /// Transport: a row of 44pt controls. The playback error line below it is
    /// transient and deliberately not budgeted for.
    static let transport: CGFloat = 44
    /// `modeButtons` fixes its own height.
    static let modeButtons: CGFloat = 52
    /// The first-run compositor warm-up notice under the mode bar: two lines of
    /// `caption2` plus its bottom padding. Budgeted because a new user has to
    /// be able to read it — it is the only thing on screen explaining a minute
    /// of shader compilation — but not over-budgeted, because every point
    /// reserved here is a point the timeline does not get.
    static let warmupNotice: CGFloat = 36
    /// Enough tool panel to keep its action row and hint line on screen. The
    /// panel ends in a `Spacer`, so anything above this it gives up for free.
    static let minimumInspector: CGFloat = 72
    /// Toolbar, ruler and one short row: less than this and the timeline is not
    /// a timeline.
    static let minimumTimeline: CGFloat = 120

    /// Everything in the tall layout that is neither the picture nor the
    /// timeline: header, both handles, transport, a usable tool panel and the
    /// whole mode bar.
    static func chrome(showsTimeline: Bool, showsWarmupNotice: Bool) -> CGFloat {
        header
            + divider                              // under the picture
            + transport
            + (showsTimeline ? divider : 0)        // under the timeline
            + minimumInspector
            + modeButtons
            + (showsWarmupNotice ? warmupNotice : 0)
    }

    // MARK: - Ceilings

    /// The most the picture may take.
    ///
    /// With a timeline below it the ceiling is what is left after the chrome
    /// and a minimum timeline, not a flat fraction: a picture dragged to
    /// two-thirds of an iPad's height was enough on its own to push the mode
    /// bar off the bottom.
    static func previewCeiling(height: CGFloat, floor: CGFloat,
                               showsTimeline: Bool, showsWarmupNotice: Bool) -> CGFloat {
        guard showsTimeline else { return max(floor, height * 0.72) }
        let available = height - chrome(showsTimeline: true, showsWarmupNotice: showsWarmupNotice) - minimumTimeline
        return max(floor, min(height * 0.72, available))
    }

    /// The most the timeline may take before it starts pushing the mode bar off
    /// the bottom of the screen.
    static func timelineCeiling(height: CGFloat, previewHeight: CGFloat,
                                showsWarmupNotice: Bool) -> CGFloat {
        max(minimumTimeline,
            height - previewHeight - chrome(showsTimeline: true, showsWarmupNotice: showsWarmupNotice))
    }
}
