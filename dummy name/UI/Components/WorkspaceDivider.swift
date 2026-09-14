import SwiftUI

/// A draggable edge between two panes of the editor.
///
/// Thin on screen, generous to the finger: the rule itself is a hairline and
/// the grabber a few points, but the touch target is 20 across. That is what
/// makes it usable on a phone without stealing real space from the panes it
/// separates.
///
/// The divider owns no size of its own. It reports drag deltas and lets the
/// layout decide what they mean, so the same control resizes a side panel, a
/// timeline or a preview without knowing which.
struct WorkspaceDivider: View {
    /// Which way the rule runs. `.horizontal` separates a top pane from a
    /// bottom one and is dragged up and down; `.vertical` separates left from
    /// right and is dragged sideways.
    enum Orientation { case horizontal, vertical }

    let orientation: Orientation
    let label: String
    /// Movement since the last call, in points. Positive is down or trailing.
    let onResize: (CGFloat) -> Void
    /// Bracket the interaction so expensive work can stand down for its
    /// duration - see `MetalVideoRenderer.setInteractiveResize(_:)`.
    var onBegin: () -> Void = {}
    var onEnd: () -> Void = {}
    /// Double tap: back to the automatic size.
    var onReset: () -> Void = {}
    /// One VoiceOver or Full Keyboard Access step.
    var step: CGFloat = 32

    /// Deltas are reported in whole steps of this many points. Sub-point moves
    /// would spend a whole SwiftUI layout pass - and on the preview side a
    /// Metal drawable resize - to move nothing anyone can see.
    private static let quantum: CGFloat = 2
    private static let thickness: CGFloat = 20

    @State private var delivered: CGFloat = 0
    @State private var isDragging = false

    var body: some View {
        ZStack {
            // The rule reads as the edge; the grabber says it can be moved.
            Rectangle()
                .fill(AppColors.separator)
                .frame(width: orientation == .vertical ? 1 : nil,
                       height: orientation == .horizontal ? 1 : nil)
            Capsule()
                .fill(isDragging ? AppColors.accent : AppColors.border)
                .frame(width: orientation == .horizontal ? 40 : 4,
                       height: orientation == .horizontal ? 4 : 40)
        }
        .frame(width: orientation == .vertical ? Self.thickness : nil,
               height: orientation == .horizontal ? Self.thickness : nil)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        delivered = 0
                        onBegin()
                    }
                    let travelled = orientation == .horizontal
                        ? value.translation.height
                        : value.translation.width
                    let stepped = (travelled / Self.quantum).rounded() * Self.quantum
                    guard stepped != delivered else { return }
                    onResize(stepped - delivered)
                    delivered = stepped
                }
                .onEnded { _ in
                    delivered = 0
                    isDragging = false
                    onEnd()
                }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded { onReset() })
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityHint("Drag to resize. Double tap to restore the automatic size.")
        .accessibilityAdjustableAction { direction in
            onBegin()
            onResize(direction == .increment ? step : -step)
            onEnd()
        }
    }
}
