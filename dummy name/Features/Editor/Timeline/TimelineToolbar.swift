import SwiftUI

/// Zoom expressed as 0...1 for a slider.
///
/// The range spans four pixels a second to a frame twenty points wide, so a
/// linear slider would spend nine tenths of its travel in frame territory. A
/// logarithmic mapping gives every order of magnitude the same amount of
/// thumb, which is what makes the control usable.
enum TimelineZoomScale {
    static let range = TimelineViewport.zoomRange

    static func normalized(_ pixelsPerSecond: Double) -> Double {
        let clamped = min(range.upperBound, max(range.lowerBound, pixelsPerSecond))
        return log(clamped / range.lowerBound) / log(range.upperBound / range.lowerBound)
    }

    static func pixelsPerSecond(_ normalized: Double) -> Double {
        let clamped = min(1, max(0, normalized))
        return range.lowerBound * pow(range.upperBound / range.lowerBound, clamped)
    }

    /// One press of − or +. A factor rather than a step, so a press changes the
    /// view by the same proportion wherever the slider happens to be.
    static func stepped(_ pixelsPerSecond: Double, by factor: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, pixelsPerSecond * factor))
    }
}

/// The timeline's own controls: add a track, split at the playhead, toggle
/// snapping, and zoom.
///
/// Deliberately separate from the canvas. The canvas owns gestures over clips;
/// these are commands about the timeline as a whole, and keeping them in
/// SwiftUI means a new command is a new button rather than another UIKit
/// subview to lay out by hand.
struct TimelineToolbar<AddTrackMenu: View>: View {
    @Binding var pixelsPerSecond: Double
    @Binding var isSnappingEnabled: Bool
    var canSplit: Bool
    var onSplit: () -> Void
    @ViewBuilder var addTrackMenu: () -> AddTrackMenu

    /// Exactly one touch target tall. The labels inside claim the same 44pt,
    /// so the bar costs the timeline the least height it can while every
    /// control stays comfortably tappable.
    static var height: CGFloat { TimelineMetrics.minimumTouchTarget }

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                addTrackMenu()
            } label: {
                TimelineToolbarLabel(systemImage: "plus", title: "Add Track")
            }
            .accessibilityLabel("Add a track")

            separator

            Button(action: onSplit) {
                TimelineToolbarLabel(systemImage: "scissors", title: "Split")
            }
            .disabled(!canSplit)
            .accessibilityLabel("Split at playhead")

            Button {
                isSnappingEnabled.toggle()
                UISelectionFeedbackGenerator().selectionChanged()
            } label: {
                TimelineToolbarLabel(systemImage: TimelineTheme.snapSymbol, title: "Snap",
                                     isOn: isSnappingEnabled, showsIndicator: true)
            }
            .accessibilityLabel("Snapping")
            .accessibilityValue(isSnappingEnabled ? Text("On") : Text("Off"))

            Spacer(minLength: 8)

            zoomControl
        }
        .frame(height: Self.height)
        .padding(.horizontal, 6)
        .background(Color(TimelineTheme.background))
        .overlay(alignment: .top) {
            Rectangle().fill(Color(TimelineTheme.separator)).frame(height: 0.5)
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color(TimelineTheme.separator))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 4)
            .accessibilityHidden(true)
    }

    /// `− ──●── +`. The buttons keep 44pt targets around smaller glyphs, and
    /// the slider carries the whole zoom range logarithmically.
    private var zoomControl: some View {
        HStack(spacing: 2) {
            zoomButton(systemImage: "minus", label: "Zoom out", factor: 1 / 1.8)
            Slider(
                value: Binding(
                    get: { TimelineZoomScale.normalized(pixelsPerSecond) },
                    set: { pixelsPerSecond = TimelineZoomScale.pixelsPerSecond($0) }
                ),
                in: 0...1
            )
            .tint(Color(TimelineTheme.accent))
            .frame(minWidth: 68, idealWidth: 120, maxWidth: 160)
            .accessibilityLabel("Timeline zoom")
            zoomButton(systemImage: "plus", label: "Zoom in", factor: 1.8)
        }
        .padding(.horizontal, 4)
        .frame(height: 36)
        .background(Color(TimelineTheme.controlSurface),
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func zoomButton(systemImage: String, label: LocalizedStringKey, factor: Double) -> some View {
        Button {
            pixelsPerSecond = TimelineZoomScale.stepped(pixelsPerSecond, by: factor)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(TimelineTheme.textSecondary))
                .frame(width: 34, height: 32)
                .contentShape(Rectangle())
        }
        .frame(width: 40, height: TimelineMetrics.minimumTouchTarget)
        .accessibilityLabel(label)
    }
}

/// An icon over a caption, sized so the visible glyph stays compact while the
/// control keeps a 44pt touch target.
private struct TimelineToolbarLabel: View {
    let systemImage: String
    let title: LocalizedStringKey
    var isOn = false
    var showsIndicator = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 30, height: 20)
                if showsIndicator && isOn {
                    Circle()
                        .fill(Color(TimelineTheme.accentBright))
                        .frame(width: 5, height: 5)
                        .offset(x: 1, y: -1)
                }
            }
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(tint)
        .frame(minWidth: 52, minHeight: TimelineMetrics.minimumTouchTarget)
        .contentShape(Rectangle())
    }

    private var tint: Color {
        if !isEnabled { return Color(TimelineTheme.textTertiary).opacity(0.6) }
        return isOn ? Color(TimelineTheme.accent) : Color(TimelineTheme.textSecondary)
    }
}
