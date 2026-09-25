import SwiftUI

/// The speed graph. One renderer and one set of maths, three interaction models.
///
/// The drawing is identical everywhere — a ramp made on a phone and opened on a
/// Mac is the same picture. What differs is how it is touched, and that is the
/// whole of the difference:
///
/// - **Mac** — a pointer hovers, so the curve reports the rate under the cursor
///   and the point under it lights up before it is clicked. Right-click opens
///   the point's menu. Precision comes from the pointer, so there is no axis
///   lock and no value bubble getting out of the way of a finger.
/// - **iPad** — a Pencil edits and a finger navigates. Points keep a hit region
///   far larger than the dot, because a stylus is precise and a finger is not
///   and both have to work.
/// - **iPhone** — one axis at a time, decided by the direction the drag starts
///   in, and the value shown in a bubble placed clear of the thumb. Dragging a
///   point diagonally on a small screen means neither axis lands where intended.
struct SpeedCurveView: View {
    @ObservedObject var model: EditorViewModel
    @ObservedObject var editor: SpeedEditorModel
    /// Height is set by whoever hosts this: a phone sheet gives it most of the
    /// screen, a Mac panel gives it whatever the divider says.
    var height: CGFloat

    private var usesPointer: Bool { AppPlatform.isMac }

    private var map: TimeMap? { model.selectedTimeMap }
    private var clipDuration: TimelineTime { model.selectedClip?.placement.duration ?? .zero }
    private var points: [SpeedPoint] {
        guard let clip = model.selectedClip else { return [] }
        return clip.resolvedRemap.resolvedPoints(sourceDuration: clip.sourceRange.duration)
    }

    /// Timeline offsets of the authored points, which is where they are drawn.
    /// Points are stored against the source, so this is the conversion.
    private func timelineOffset(of point: SpeedPoint) -> TimelineTime {
        map?.timelineOffset(atSourceOffset: point.sourceOffset) ?? .zero
    }

    private func geometry(in size: CGSize) -> SpeedCurveGeometry {
        SpeedCurveGeometry(
            plot: CGRect(x: Self.gutter, y: Self.padding,
                         width: max(1, size.width - Self.gutter - Self.padding),
                         height: max(1, size.height - Self.padding * 2)),
            duration: clipDuration)
    }

    private static let gutter: CGFloat = 46
    private static let padding: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            let geo = geometry(in: proxy.size)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in draw(in: &context, geo: geo) }
                    .contentShape(Rectangle())
                    // A press on empty graph deselects; a double press adds a
                    // point where it landed. Both are on the background so they
                    // never steal a drag meant for a handle.
                    .onTapGesture(count: 2) { location in
                        model.addSpeedPoint(atTimeline: timelineTime(atX: location.x, geo: geo))
                    }
                    .onTapGesture { _ in editor.selection.removeAll() }
                    .modifier(PointerReadout(enabled: usesPointer, geo: geo, map: map,
                                             hovered: $editor.hoverReadout))

                ForEach(points) { point in
                    handle(point, geo: geo)
                }

                if let bubble = editor.bubble, !usesPointer {
                    valueBubble(bubble, geo: geo)
                }
                if let readout = editor.hoverReadout, usesPointer {
                    hoverReadout(readout)
                }
            }
        }
        .frame(height: height)
        .background(AppColors.editorBackground, in: RoundedRectangle(cornerRadius: AppCornerRadius.card))
        .overlay(RoundedRectangle(cornerRadius: AppCornerRadius.card).stroke(AppColors.border, lineWidth: 1))
        .accessibilityLabel("Speed curve")
        .accessibilityHint("Double tap the graph to add a speed point. Drag a point to change its speed and position.")
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, geo: SpeedCurveGeometry) {
        // Rules at recognisable rates, with 100% picked out — it is the line
        // everything else is read against.
        for speed in SpeedCurveGeometry.gridSpeeds {
            let y = geo.y(forSpeed: speed)
            let isNormal = speed == ClipSpeed.normal
            var line = Path()
            line.move(to: CGPoint(x: geo.plot.minX, y: y))
            line.addLine(to: CGPoint(x: geo.plot.maxX, y: y))
            context.stroke(line,
                           with: .color(isNormal ? AppColors.textTertiary : AppColors.separator),
                           lineWidth: isNormal ? 1 : 0.5)
            context.draw(
                Text(ClipSpeed.percentLabel(speed))
                    .font(AppTypography.caption)
                    .foregroundStyle(isNormal ? AppColors.textSecondary : AppColors.textTertiary),
                at: CGPoint(x: geo.plot.minX - 6, y: y), anchor: .trailing)
        }

        guard let map else { return }

        // The curve, and the area under it, so fast and slow read at a glance
        // without having to find the 100% rule first.
        let samples = geo.curve(from: map)
        guard samples.count > 1 else { return }
        var curve = Path()
        curve.addLines(samples)
        var fill = curve
        fill.addLine(to: CGPoint(x: samples.last!.x, y: geo.y(forSpeed: ClipSpeed.normal)))
        fill.addLine(to: CGPoint(x: samples.first!.x, y: geo.y(forSpeed: ClipSpeed.normal)))
        fill.closeSubpath()
        context.fill(fill, with: .color(AppColors.accent.opacity(0.14)))
        context.stroke(curve, with: .color(AppColors.accent), lineWidth: 2)

        // The playhead, so a point can be placed against the picture rather
        // than against the graph.
        if let playhead = model.playheadInSelectedClip {
            let x = geo.x(forOffset: playhead)
            var line = Path()
            line.move(to: CGPoint(x: x, y: geo.plot.minY))
            line.addLine(to: CGPoint(x: x, y: geo.plot.maxY))
            context.stroke(line, with: .color(AppColors.warning.opacity(0.8)), lineWidth: 1)
        }

        for point in points {
            let position = geo.point(atOffset: timelineOffset(of: point), speed: point.speed)
            let selected = editor.selection.contains(point.id)
            let hovered = editor.hoveredPoint == point.id
            let radius = SpeedCurveGeometry.pointRadius + (selected || hovered ? 2 : 0)
            let box = CGRect(x: position.x - radius, y: position.y - radius,
                             width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: box),
                         with: .color(selected ? AppColors.accent : AppColors.textPrimary))
            context.stroke(Path(ellipseIn: box), with: .color(AppColors.editorBackground), lineWidth: 2)
        }
    }

    // MARK: - Point handles

    /// A drag handle sits on its own view rather than on the canvas.
    ///
    /// The canvas cannot carry a per-point gesture, and a single drag over the
    /// whole graph would have to work out which point it meant on every change —
    /// which goes wrong the moment two points pass each other. A handle belongs
    /// to one point for the whole of its drag.
    @ViewBuilder
    private func handle(_ point: SpeedPoint, geo: SpeedCurveGeometry) -> some View {
        let position = geo.point(atOffset: timelineOffset(of: point), speed: point.speed)
        let reach = SpeedCurveGeometry.hitRadius(forPointer: usesPointer)
        Color.clear
            .frame(width: reach * 2, height: reach * 2)
            .contentShape(Circle())
            .position(position)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in changed(point, value, geo) }
                    .onEnded { value in ended(point, value, geo) }
            )
            .modifier(PointHover(enabled: usesPointer, id: point.id, hovered: $editor.hoveredPoint))
            .contextMenu { SpeedPointMenu(model: model, point: point) }
    }

    private func changed(_ point: SpeedPoint, _ value: DragGesture.Value, _ geo: SpeedCurveGeometry) {
        if editor.dragging != point.id {
            editor.dragging = point.id
            editor.selection = [point.id]
            editor.axis = nil
        }
        // One axis at a time on a touch screen. Which one is decided by the
        // first few points of travel and then held for the rest of the drag, so
        // a thumb that wobbles cannot start changing the other thing halfway.
        if !usesPointer, editor.axis == nil {
            let dx = abs(value.translation.width), dy = abs(value.translation.height)
            if max(dx, dy) > 8 { editor.axis = dx > dy ? .time : .speed }
        }
        let axis = usesPointer ? nil : editor.axis
        let time = axis == .speed ? nil : timelineTime(atX: value.location.x, geo: geo)
        let speed = axis == .time ? nil : geo.speed(forY: value.location.y)
        model.moveSpeedPoint(point.id, toTimeline: time, speed: speed, live: true)
        editor.bubble = SpeedEditorModel.Bubble(
            speed: speed ?? point.speed,
            offset: time.flatMap { try? $0.subtracting(model.selectedClip?.placement.timelineStart ?? .zero) }
                ?? timelineOffset(of: point),
            at: value.location)
    }

    private func ended(_ point: SpeedPoint, _ value: DragGesture.Value, _ geo: SpeedCurveGeometry) {
        defer { editor.dragging = nil; editor.axis = nil; editor.bubble = nil }
        guard editor.dragging == point.id else {
            // A press that never moved is a selection, not a drag.
            editor.selection = [point.id]
            return
        }
        let axis = usesPointer ? nil : editor.axis
        let time = axis == .speed ? nil : timelineTime(atX: value.location.x, geo: geo)
        let speed = axis == .time ? nil : geo.speed(forY: value.location.y)
        model.moveSpeedPoint(point.id, toTimeline: time, speed: speed, live: false)
    }

    /// Graph x to a position on the project timeline.
    private func timelineTime(atX x: CGFloat, geo: SpeedCurveGeometry) -> TimelineTime {
        let start = model.selectedClip?.placement.timelineStart ?? .zero
        return (try? start.adding(geo.offset(forX: x))) ?? start
    }

    // MARK: - Readouts

    /// The value under the finger, placed above it so the thumb is not covering
    /// the number the drag is aiming at.
    private func valueBubble(_ bubble: SpeedEditorModel.Bubble, geo: SpeedCurveGeometry) -> some View {
        VStack(spacing: 1) {
            Text(ClipSpeed.percentLabel(bubble.speed))
                .font(AppTypography.numeric)
                .foregroundStyle(AppColors.textPrimary)
            Text(TimecodeText.short(bubble.offset.seconds))
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textSecondary)
        }
        .padding(.horizontal, AppSpacing.small)
        .padding(.vertical, AppSpacing.xSmall)
        .background(AppColors.surfaceRaised, in: RoundedRectangle(cornerRadius: AppCornerRadius.small))
        .overlay(RoundedRectangle(cornerRadius: AppCornerRadius.small).stroke(AppColors.border, lineWidth: 1))
        .position(x: min(max(bubble.at.x, 54), geo.plot.maxX - 20),
                  y: max(26, bubble.at.y - 52))
        .allowsHitTesting(false)
    }

    /// What a pointer is hovering over. Mac only, and the reason a Mac user can
    /// read a ramp without clicking anything.
    private func hoverReadout(_ readout: SpeedEditorModel.Readout) -> some View {
        HStack(spacing: AppSpacing.xSmall) {
            Text(ClipSpeed.percentLabel(readout.speed)).font(AppTypography.numeric)
            Text(TimecodeText.short(readout.offset.seconds))
                .font(AppTypography.caption).foregroundStyle(AppColors.textSecondary)
        }
        .padding(.horizontal, AppSpacing.small)
        .padding(.vertical, 3)
        .background(AppColors.surfaceRaised.opacity(0.92), in: Capsule())
        .padding(AppSpacing.small)
        .allowsHitTesting(false)
    }
}

/// Hover tracking, compiled in everywhere and switched on only where there is a
/// pointer. Keeping it behind a flag rather than behind `#if` means the phone
/// and the Mac build the same view tree.
private struct PointHover: ViewModifier {
    let enabled: Bool
    let id: UUID
    @Binding var hovered: UUID?

    func body(content: Content) -> some View {
        guard enabled else { return AnyView(content) }
        return AnyView(content.onHover { inside in
            if inside { hovered = id } else if hovered == id { hovered = nil }
        })
    }
}

/// The rate under the pointer, anywhere on the curve.
private struct PointerReadout: ViewModifier {
    let enabled: Bool
    let geo: SpeedCurveGeometry
    let map: TimeMap?
    @Binding var hovered: SpeedEditorModel.Readout?

    func body(content: Content) -> some View {
        guard enabled else { return AnyView(content) }
        return AnyView(content.onContinuousHover { phase in
            switch phase {
            case .active(let location):
                guard let map else { hovered = nil; return }
                let offset = geo.offset(forX: location.x)
                hovered = .init(speed: map.speed(atTimelineOffset: offset), offset: offset)
            case .ended:
                hovered = nil
            @unknown default:
                hovered = nil
            }
        })
    }
}

/// Everything that can be done to one point, in one place.
///
/// Attached to the handle, so on Mac it is a right-click and on a touch screen
/// it is a long press — the same menu, reached the way each platform reaches
/// menus, without either having to go to the inspector for a small change.
struct SpeedPointMenu: View {
    @ObservedObject var model: EditorViewModel
    let point: SpeedPoint

    var body: some View {
        Section(ClipSpeed.percentLabel(point.speed)) {
            ForEach([0.25, 0.5, 1.0, 2.0, 4.0], id: \.self) { speed in
                Button(ClipSpeed.percentLabel(speed)) {
                    model.moveSpeedPoint(point.id, toTimeline: nil, speed: speed)
                }
            }
        }
        Section {
            ForEach(SpeedInterpolation.allCases) { shape in
                Button {
                    model.setSpeedPointInterpolation(point.id, to: shape)
                } label: {
                    Text(shape.title)
                    if shape == point.interpolation { Image(systemName: "checkmark") }
                }
            }
        }
        Section {
            Button(role: .destructive) { model.removeSpeedPoint(point.id) } label: {
                Label("Delete Speed Point", systemImage: "trash")
            }
            Button { model.resetSpeedCurve() } label: {
                Label("Reset Curve", systemImage: "arrow.uturn.backward")
            }
        }
    }
}

/// Short seconds-and-frames style text for the readouts.
enum TimecodeText {
    static func short(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00.00" }
        let whole = Int(seconds)
        let hundredths = Int(((seconds - Double(whole)) * 100).rounded())
        return String(format: "%d:%02d.%02d", whole / 60, whole % 60, min(99, hundredths))
    }
}
