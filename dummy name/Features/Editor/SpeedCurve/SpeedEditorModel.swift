import Combine
import CoreGraphics
import Foundation

/// The speed editor's interaction state, shared by every platform.
///
/// None of this belongs in the document — it is what is selected, what is being
/// dragged and what is under the pointer, all of which are gone the moment the
/// panel closes. Keeping it here rather than in each container is what lets the
/// phone sheet, the iPad inspector and the Mac panel be three layouts over one
/// editor rather than three editors.
@MainActor
final class SpeedEditorModel: ObservableObject {
    /// Which axis a touch drag is allowed to move along.
    ///
    /// Decided from the first few points of travel and then held. Pointer
    /// platforms never set it: a mouse is precise enough to mean both at once,
    /// and locking it there would feel broken.
    enum Axis { case time, speed }

    struct Bubble {
        var speed: Double
        var offset: TimelineTime
        var at: CGPoint
    }

    struct Readout: Equatable {
        var speed: Double
        var offset: TimelineTime
    }

    /// A set from the start, though only one point can be selected today.
    ///
    /// Multi-selection is a Mac feature that has not been built — shift-click
    /// several points, move them together, change their easing together. The
    /// architecture is the part that has to be right first: every edit already
    /// takes an id rather than "the selected point", so adding the second one
    /// later does not mean unpicking any of this.
    @Published var selection: Set<UUID> = []
    @Published var dragging: UUID?
    @Published var axis: Axis?
    @Published var bubble: Bubble?
    @Published var hoveredPoint: UUID?
    @Published var hoverReadout: Readout?
    /// Whether the clip is being edited as one rate or as a curve. A view
    /// choice, not a document one — a clip with no points shown in Ramp mode is
    /// simply a flat curve waiting for one.
    @Published var showsRamp = false
    /// The phone's dedicated editor, which covers the screen rather than living
    /// in the inspector column.
    @Published var showsPhoneEditor = false

    var selectedPoint: UUID? { selection.first }

    func clearTransientState() {
        dragging = nil
        axis = nil
        bubble = nil
        hoveredPoint = nil
        hoverReadout = nil
    }
}
