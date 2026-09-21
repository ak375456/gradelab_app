import UIKit

/// One place for the timeline's palette and its vertical rhythm.
///
/// Every renderer and control reads from here rather than carrying its own
/// literals, so a row height, a corner radius or the accent changes in one
/// edit instead of a dozen scattered through the canvas. Extending the
/// timeline with a new row type therefore starts by adding a metric here, not
/// by copying numbers out of `draw(_:)`.
enum TimelineTheme {

    // MARK: - Surfaces

    /// Very dark charcoal rather than pure black, so raised surfaces read as
    /// surfaces instead of dissolving into the window.
    static let background = UIColor(red: 0.055, green: 0.063, blue: 0.075, alpha: 1)
    /// The empty lane behind a row's clips: one step lighter than the canvas.
    static let lane = UIColor(red: 0.082, green: 0.090, blue: 0.106, alpha: 1)
    static let headerSurface = UIColor(red: 0.098, green: 0.107, blue: 0.125, alpha: 1)
    static let headerSurfaceSelected = UIColor(red: 0.125, green: 0.137, blue: 0.158, alpha: 1)
    static let controlSurface = UIColor(red: 0.149, green: 0.161, blue: 0.184, alpha: 1)
    static let controlSurfaceActive = UIColor(red: 0.196, green: 0.211, blue: 0.239, alpha: 1)
    /// Clip body under a filmstrip that has not loaded yet, and behind a row
    /// with no picture of its own.
    static let clipBody = UIColor(red: 0.125, green: 0.137, blue: 0.160, alpha: 1)

    // MARK: - Lines and text

    static let separator = UIColor(white: 1, alpha: 0.085)
    static let clipBorder = UIColor(white: 1, alpha: 0.14)
    static let textPrimary = UIColor(white: 1, alpha: 0.96)
    static let textSecondary = UIColor(white: 1, alpha: 0.62)
    static let textTertiary = UIColor(white: 1, alpha: 0.42)

    // MARK: - Accents

    /// The timeline's turquoise selection accent. Deliberately a controlled
    /// turquoise rather than a neon cyan: it has to sit against a bright
    /// filmstrip all day without glowing.
    static let accent = UIColor(red: 0.263, green: 0.839, blue: 0.796, alpha: 1)
    /// The same hue lifted, for the waveform's peak line and snap indicator,
    /// where a single hairline needs to stay visible.
    static let accentBright = UIColor(red: 0.376, green: 0.925, blue: 0.878, alpha: 1)
    /// GradeLab's brand blue, used only for the playhead's timecode bubble so
    /// the position readout never reads as another selected object.
    static let playheadBubble = UIColor(red: 0.31, green: 0.69, blue: 0.96, alpha: 1)
    static let playheadLine = UIColor(white: 1, alpha: 0.95)

    static let markerFill = UIColor.systemYellow
    static let lockedTint = UIColor.systemOrange

    // MARK: - Symbols

    /// Two heads closing on a line. Snapping is conventionally a magnet, but
    /// `magnet` is not in the system symbol set on the iOS versions this app
    /// supports, and an absent symbol renders as nothing at all — verified on
    /// device rather than assumed from the SF Symbols catalogue.
    static let snapSymbol = "arrowtriangle.right.and.line.vertical.and.arrowtriangle.left"

    // MARK: - Per-kind tinting

    /// A row's identity colour, used for the clip body and its waveform so an
    /// audio clip, a title and a shape stay distinguishable at a glance.
    static func tint(for clip: TimelineDisplayClip) -> UIColor {
        if clip.isAudio { return UIColor(red: 0.325, green: 0.576, blue: 0.965, alpha: 1) }
        if clip.isText { return UIColor(red: 0.686, green: 0.522, blue: 0.972, alpha: 1) }
        if clip.isShape { return UIColor(red: 0.322, green: 0.784, blue: 0.706, alpha: 1) }
        return UIColor(white: 0.46, alpha: 1)
    }
}

/// The timeline's vertical rhythm and touch geometry.
///
/// Touch targets are separate from the drawn sizes on purpose: a trim handle
/// is a 13pt bar that answers to a 44pt grab region, which is what makes it
/// usable on a phone without turning the clip into a pair of fat bookends.
enum TimelineMetrics {
    /// The ruler band across the top. Rows begin below it. Tall enough for a
    /// line of labels above the ticks, with the playhead's timecode bubble
    /// floating over the top of it.
    static let rulerHeight: CGFloat = 36
    /// Top of the first row inside the canvas.
    static let rowsTop: CGFloat = 38
    /// Height of the floating timecode bubble that rides above the ruler.
    static let timecodeBubbleHeight: CGFloat = 19
    static let rowGap: CGFloat = 8
    /// Breathing room under the last row, so a bottom row is never flush with
    /// the canvas edge while scrolled to the end.
    static let contentBottomInset: CGFloat = 40

    static let clipCornerRadius: CGFloat = 7
    static let overlayCornerRadius: CGFloat = 5
    static let selectedBorderWidth: CGFloat = 2.5
    static let borderWidth: CGFloat = 1

    /// Drawn width of a trim handle, and the half-width of the region that
    /// actually answers a touch. 22 either side of the edge is a 44pt target.
    static let trimHandleWidth: CGFloat = 13
    static let trimHitSlop: CGFloat = 22

    /// The dark strip along a clip's bottom that carries its name.
    static let labelBarHeight: CGFloat = 20
    /// Share of a media clip's height given to its waveform lane.
    static let waveformLaneRatio: CGFloat = 0.36
    static let minimumWaveformLane: CGFloat = 15
    /// Below this the row is a name strip only — no filmstrip, no waveform.
    static let minimumFilmstripHeight: CGFloat = 34

    static let playheadWidth: CGFloat = 1.5
    static let playheadKnobRadius: CGFloat = 5.5

    /// The track-header column. Adaptive so a phone keeps timeline width while
    /// an iPad gets a header wide enough for a full track name. The lower
    /// bound is what four control buttons need side by side.
    static func headerWidth(for width: CGFloat) -> CGFloat {
        min(156, max(116, width * 0.30))
    }

    /// Visible size of a track-header control, and the height of the band that
    /// answers touches for that row of controls. See
    /// `TimelineTrackHeaderView` for why the horizontal target is routed
    /// rather than simply enlarged.
    static let headerControlSize: CGFloat = 26
    static let minimumTouchTarget: CGFloat = 44

    /// Filmstrip cell width for a given picture height, at 16:9. Thumbnails
    /// laid out at their own aspect read as continuous footage rather than as
    /// a row of stretched tiles.
    static func filmstripCellWidth(pictureHeight: CGFloat) -> CGFloat {
        max(44, (pictureHeight * 16 / 9).rounded())
    }
}
