import SwiftUI
import UIKit

// ---------------------------------------------------------------------------
// Curves panel
//
// Two groups sharing one graph: the four tone curves, and the six colour
// curves. Which axes the graph shows, whether it carries a hue spectrum, and
// what the readout says all come from `CurveType`, so adding a curve type never
// means adding a view.
// ---------------------------------------------------------------------------

struct CurvesPanel<Model: GradingModel>: View {
    @ObservedObject var model: Model
    /// Open the first time someone reaches this panel, and remembered after
    /// that: a guide that has been read once should not keep taking up the
    /// space the graph wants.
    @AppStorage("curvesGuideExpanded") private var showsGuide = true

    private var type: CurveType { model.selectedCurve }
    /// The curve at the playhead. Animated curves resolve to the blended shape,
    /// so the graph shows and edits the curve the picture is actually using.
    private var curve: AdvancedCurve { model.curves[type] }
    /// An animated curve can only be reshaped at a frame the clip occupies,
    /// which is the rule every other animated control follows.
    private var canEditCurve: Bool {
        AnimatableProperty.curve(type).map { model.canEditGradeValue($0) } ?? true
    }

    var body: some View {
        // Selector and controls first, graph underneath. A drag inside the
        // graph shapes the curve rather than scrolling the panel, so anything
        // the user has to be able to reach has to sit above it.
        VStack(spacing: AppSpacing.compact) {
            selector
            // Only while a Pro curve is actually selected. Someone shaping the
            // master curve — which is free, and unlimited — should not be sold
            // anything.
            if ProAccessPolicy.curveRequiresPro(type) {
                ProPanelNotice(feature: .colorCurves)
            }
            readout

            CurveGraph(
                curve: curve,
                selectedPoint: model.selectedCurvePointBinding,
                tint: tint,
                onBegin: { model.beginCurveEdit("\(type.title) curve") },
                onEdit: { edit in model.editCurve(type, edit) },
                onEnd: { model.endCurveEdit() }
            )
            .frame(height: 178)
            .disabled(!model.canGrade || !canEditCurve)

            if let property = AnimatableProperty.curve(type) {
                GradeKeyframeLane(model: model, property: property)
            }

            VStack(alignment: .leading, spacing: AppSpacing.small) {
                Text(type.help)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                guideToggle
                if showsGuide { guide }
                proNote
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: model.selectedCurve) { _, _ in model.selectedCurvePoint = nil }
        .onChange(of: model.gradeSubjectID) { _, _ in
            model.selectedCurvePoint = nil
            model.isPickingCurveHue = false
        }
        .onDisappear { model.isPickingCurveHue = false }
    }

    // MARK: - Curve selector

    /// One horizontal strip for all ten curves, with a rule between the tone
    /// group and the colour group.
    ///
    /// A second row of controls to pick the group would cost more vertical
    /// space than the panel has, and full names beat abbreviations - "H-S" is
    /// not something to make anyone decode. It scrolls to the selected curve so
    /// the current one is always in view.
    private var selector: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: AppSpacing.small) {
                    ForEach(CurveType.toneCurves) { chip($0) }
                    Rectangle()
                        .fill(AppColors.separator)
                        .frame(width: 1, height: 20)
                        .accessibilityHidden(true)
                    ForEach(CurveType.colorCurves) { chip($0) }
                }
                .padding(.horizontal, 2)
            }
            .frame(height: 44)
            .scrollIndicators(.hidden)
            .onAppear { proxy.scrollTo(type, anchor: .center) }
            .onChange(of: model.selectedCurve) { _, value in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(value, anchor: .center) }
            }
        }
    }

    private func chip(_ candidate: CurveType) -> some View {
        // Free to open and shape; the paywall is at export. The lock only says
        // which of the ten this applies to.
        let marked = ProAccessPolicy.curveRequiresPro(candidate) && !ProStore.shared.hasPro
        return Button { select(candidate) } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(color(for: candidate))
                    .frame(width: 7, height: 7)
                    .opacity(model.curves[candidate].isFlat ? 0 : 1)
                Text(candidate.shortTitle)
                    .font(AppTypography.caption)
                    .lineLimit(1)
                if marked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(ProStyle.gold)
                }
            }
            .padding(.horizontal, AppSpacing.compact)
            .frame(height: 32)
            .background(
                candidate == type ? AppColors.surfacePressed : AppColors.surface,
                in: Capsule())
            .overlay(
                Capsule().strokeBorder(
                    candidate == type ? AppColors.accent : .clear, lineWidth: 1))
            .foregroundStyle(
                candidate == type ? AppColors.textPrimary : AppColors.textSecondary)
        }
        .buttonStyle(.plain)
        .frame(height: 44)
        .id(candidate)
        .accessibilityLabel(marked ? "\(candidate.title). Pro feature" : candidate.title)
        .accessibilityValue(model.curves[candidate].isFlat ? "Neutral" : "Adjusted")
        .accessibilityAddTraits(candidate == type ? .isSelected : [])
    }

    // MARK: - Guide

    private var guideToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { showsGuide.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "questionmark.circle")
                Text(showsGuide ? "Hide guide" : "How to use")
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(showsGuide ? 180 : 0))
            }
            .font(AppTypography.caption.weight(.medium))
            .foregroundStyle(AppColors.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(height: 44, alignment: .leading)
        .accessibilityLabel(showsGuide ? "Hide the curves guide" : "Show the curves guide")
        .accessibilityAddTraits(showsGuide ? .isSelected : [])
    }

    private var guide: some View {
        VStack(alignment: .leading, spacing: 7) {
            step(1, String(localized: "Pick a curve above. Master, R, G and B shape tone and the three channels; the six color curves each target one hue, one saturation range, or one part of the tonal range."))
            step(2, String(localized: "Tap the graph to drop a point, then drag that point to shape the curve."))
            step(3, String(localized: "Tap a point to select it — the numbers above the graph are its exact values. Tap it again to remove it."))
            step(4, String(localized: "On the hue curves, the eyedropper samples a color straight off the picture and builds a selection around it: a centre point to drag, and one either side holding the neighbouring colors still."))
            step(5, String(localized: "Reset returns the curve to neutral. Drag anywhere off a point to scroll this panel."))
        }
        .padding(AppSpacing.compact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surface, in: RoundedRectangle(cornerRadius: AppCornerRadius.control))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.small) {
            Text("\(number)")
                .font(AppTypography.caption.monospacedDigit())
                .foregroundStyle(AppColors.accent)
                .frame(width: 9, alignment: .trailing)
            Text(text)
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// Curves are the sharpest tool in the app. Rather than hiding them behind
    /// a warning, this says so and points at the way out.
    private var proNote: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AppColors.warning)
            Text("Pro tools, sharp edges. Not sure what a curve does? Poke a point and watch the picture — Reset forgives everything.")
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Readout and actions

    private var readout: some View {
        HStack(spacing: AppSpacing.small) {
            if let point = selected {
                value(type.inputLabel, type.formattedInput(point.x))
                Text("·").foregroundStyle(AppColors.textTertiary)
                value(type.outputLabel, type.formattedOutput(point.y))
            } else {
                Text(curve.isFlat ? "Neutral" : "\(curve.points.count) points")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textTertiary)
            }
            Spacer(minLength: AppSpacing.small)

            if type.isCyclic {
                actionButton(
                    "eyedropper",
                    label: model.isPickingCurveHue ? "Cancel color picking" : "Pick a color from the video",
                    isActive: model.isPickingCurveHue
                ) {
                    model.isPickingCurveHue.toggle()
                    if model.isPickingCurveHue { CurveHaptics.select() }
                }
                .disabled(!model.canGrade)
            }

            actionButton("trash", label: "Delete the selected point") {
                guard let point = selected else { return }
                model.beginCurveEdit("Delete point")
                model.editCurve(type) { $0.removePoint(id: point.id) }
                model.endCurveEdit()
                model.selectedCurvePoint = nil
                CurveHaptics.remove()
            }
            .disabled(selected.map { !curve.canRemovePoint(id: $0.id) } ?? true)

            actionButton("arrow.counterclockwise", label: "Reset the \(type.title) curve") {
                model.resetCurve(type)
                model.selectedCurvePoint = nil
                CurveHaptics.reset()
            }
            .disabled(!model.canGrade || curve.isNeutral)

            // The curve animates as ONE shape: a single diamond for the whole
            // graph, never one per control point. Two snapshots need not share a
            // topology — the blend samples both and interpolates the heights.
            if let property = AnimatableProperty.curve(type) {
                GradeKeyframeDiamond(model: model, property: property)
            }
        }
        .foregroundStyle(AppColors.textPrimary)
    }

    private func value(_ label: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(AppTypography.caption).foregroundStyle(AppColors.textSecondary)
            Text(text).font(AppTypography.numeric)
        }
    }

    private func actionButton(
        _ symbol: String,
        label: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 34, height: 30)
                .background(isActive ? AppColors.accentMuted : AppColors.surface,
                            in: RoundedRectangle(cornerRadius: AppCornerRadius.small))
                .foregroundStyle(isActive ? AppColors.accent : AppColors.textSecondary)
        }
        .buttonStyle(.plain)
        .frame(height: 44)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var selected: CurvePoint? {
        model.selectedCurvePoint.flatMap { id in curve.points.first { $0.id == id } }
    }

    private func select(_ candidate: CurveType) {
        model.selectedCurve = candidate
        model.selectedCurvePoint = nil
        if !candidate.isCyclic { model.isPickingCurveHue = false }
        CurveHaptics.select()
    }

    private var tint: Color { color(for: type) }

    private func color(for type: CurveType) -> Color {
        switch type {
        case .red: .red
        case .green: .green
        case .blue: .blue
        case .master: AppColors.textPrimary
        default: AppColors.accent
        }
    }
}

// ---------------------------------------------------------------------------
// The graph
// ---------------------------------------------------------------------------

/// Maps between curve space and the plot rectangle. One place, so a drawn point
/// and a touched point cannot end up in different places.
private struct CurveGeometry {
    let rect: CGRect
    let type: CurveType

    init(size: CGSize, type: CurveType) {
        // Room for the point at the very corner, and for the spectrum strip.
        let inset: CGFloat = 14
        let bottom: CGFloat = type.isCyclic ? 26 : inset
        rect = CGRect(x: inset, y: inset,
                      width: max(size.width - inset * 2, 1),
                      height: max(size.height - inset - bottom, 1))
        self.type = type
    }

    func point(_ x: Float, _ y: Float) -> CGPoint {
        CGPoint(x: rect.minX + CGFloat(x) * rect.width, y: rect.minY + CGFloat(1 - normalized(y)) * rect.height)
    }

    func curveX(_ px: CGFloat) -> Float { Float((px - rect.minX) / rect.width) }

    func curveY(_ py: CGFloat) -> Float {
        let n = Float(1 - (py - rect.minY) / rect.height)
        return type.isMapping ? n : n * 2 - 1
    }

    /// y in 0...1 of the plot, whichever range the curve uses.
    private func normalized(_ y: Float) -> Float { type.isMapping ? y : (y + 1) * 0.5 }

    var neutralLineY: CGFloat { type.isMapping ? rect.maxY : rect.midY }
    var spectrumRect: CGRect {
        CGRect(x: rect.minX, y: rect.maxY + 7, width: rect.width, height: 6)
    }
}

private struct CurveGraph: View {
    let curve: AdvancedCurve
    @Binding var selectedPoint: UUID?
    let tint: Color
    let onBegin: () -> Void
    let onEdit: ((inout AdvancedCurve) -> Void) -> Void
    let onEnd: () -> Void

    @State private var dragging: UUID?
    /// Which side of neutral the dragged point was on, so the haptic fires once
    /// per crossing rather than continuously.
    @State private var wasAboveNeutral: Bool?

    /// Touch target around a control point. Comfortably past the 44pt minimum
    /// on the diagonal, and small enough that a graph with a few points still
    /// leaves most of its area free to scroll the panel.
    private static let handleSize: CGFloat = 46
    /// How far a finger must travel on a handle before it counts as a drag
    /// rather than a tap. Below this the point is not moved and no undo entry
    /// is opened, so tapping a point to select or delete it stays exact.
    private static let dragSlop: CGFloat = 4
    private static let space = "curveGraph"

    // The panel this lives in scrolls, so the graph must not take drags it does
    // not need. Only the control points carry a drag gesture; everywhere else
    // the touch falls through to the scroll view. Adding a point is a tap,
    // which coexists with scrolling because a tap that moves is abandoned.
    var body: some View {
        GeometryReader { proxy in
            let geometry = CurveGeometry(size: proxy.size, type: curve.type)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    draw(in: &context, geometry: geometry)
                }
                .allowsHitTesting(false)

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { location in handleTap(location, geometry) }

                ForEach(curve.points) { point in
                    handle(point, geometry)
                }
            }
            .coordinateSpace(.named(Self.space))
        }
        .background(AppColors.editorBackground, in: RoundedRectangle(cornerRadius: AppCornerRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: AppCornerRadius.card)
                .strokeBorder(AppColors.border, lineWidth: 1))
        .accessibilityElement()
        .accessibilityLabel("\(curve.type.title) curve")
        .accessibilityValue(curve.isFlat ? "Neutral" : "\(curve.points.count) control points")
        .accessibilityHint("Tap the graph to add a point, drag a point to shape the curve, tap a selected point to remove it.")
    }

    /// One control point's touch target. Invisible: the point itself is drawn
    /// by the canvas underneath, at the same place.
    ///
    /// Locations come back in the graph's own coordinate space rather than the
    /// handle's, because the handle moves with the point it is dragging and a
    /// local reading would drift behind the finger.
    private func handle(_ point: CurvePoint, _ geometry: CurveGeometry) -> some View {
        Circle()
            .fill(Color.white.opacity(0.001))
            .frame(width: Self.handleSize, height: Self.handleSize)
            .position(geometry.point(point.x, point.y))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                    .onChanged { value in handleChange(point.id, value, geometry) }
                    .onEnded { value in handleEnd(point.id, value, geometry) }
            )
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, geometry: CurveGeometry) {
        let rect = geometry.rect

        // Hue curves get a spectrum under the axis, so it is obvious which
        // colour a position on the graph refers to.
        if curve.type.isCyclic {
            let stops = (0...12).map { Gradient.Stop(
                color: Color(hue: Double($0) / 12, saturation: 0.85, brightness: 0.95),
                location: Double($0) / 12) }
            context.fill(
                Path(roundedRect: geometry.spectrumRect, cornerRadius: 3),
                with: .linearGradient(Gradient(stops: stops),
                                      startPoint: CGPoint(x: rect.minX, y: 0),
                                      endPoint: CGPoint(x: rect.maxX, y: 0)))
        }

        var grid = Path()
        let columns = curve.type.isCyclic ? 6 : 4
        for i in 0...columns {
            let x = rect.minX + rect.width * CGFloat(i) / CGFloat(columns)
            grid.move(to: CGPoint(x: x, y: rect.minY))
            grid.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        for i in 0...4 {
            let y = rect.minY + rect.height * CGFloat(i) / 4
            grid.move(to: CGPoint(x: rect.minX, y: y))
            grid.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        context.stroke(grid, with: .color(.white.opacity(0.08)), lineWidth: 1)

        // The neutral shape, so it is clear how far the curve has been taken.
        var reference = Path()
        if curve.type.isMapping {
            reference.move(to: geometry.point(0, 0))
            reference.addLine(to: geometry.point(1, 1))
        } else {
            reference.move(to: CGPoint(x: rect.minX, y: geometry.neutralLineY))
            reference.addLine(to: CGPoint(x: rect.maxX, y: geometry.neutralLineY))
        }
        context.stroke(reference, with: .color(.white.opacity(0.20)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

        let evaluator = CurveEvaluator(curve)
        var line = Path()
        let steps = max(Int(rect.width), 32)
        for step in 0...steps {
            let x = Float(step) / Float(steps)
            let point = geometry.point(x, evaluator.value(at: x))
            if step == 0 { line.move(to: point) } else { line.addLine(to: point) }
        }
        context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 2, lineCap: .round))

        for point in curve.points {
            let centre = geometry.point(point.x, point.y)
            let isSelected = point.id == selectedPoint
            let radius: CGFloat = isSelected ? 7 : 5
            let circle = Path(ellipseIn: CGRect(
                x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
            context.fill(circle, with: .color(isSelected ? tint : AppColors.editorBackground))
            context.stroke(circle, with: .color(isSelected ? .white : tint), lineWidth: 2)
        }
    }

    // MARK: - Interaction

    private func handleChange(_ id: UUID, _ value: DragGesture.Value, _ geometry: CurveGeometry) {
        if dragging != id {
            // Under the slop this is still a tap, and opening the edit here
            // would put an entry that changed nothing into undo.
            guard hypot(value.translation.width, value.translation.height) > Self.dragSlop else { return }
            dragging = id
            selectedPoint = id
            wasAboveNeutral = nil
            onBegin()
        }
        let x = geometry.curveX(value.location.x)
        let y = geometry.curveY(value.location.y)
        onEdit { $0.movePoint(id: id, x: x, y: y) }

        // One tick as the point passes its neutral value, which is the moment
        // worth feeling. Nothing while it is merely moving.
        let neutral = curve.type.neutralY(at: max(0, min(1, x)))
        let above = y >= neutral
        if let previous = wasAboveNeutral, previous != above, abs(y - neutral) > 0.01 {
            CurveHaptics.crossNeutral()
        }
        if wasAboveNeutral == nil || abs(y - neutral) > 0.01 { wasAboveNeutral = above }
    }

    private func handleEnd(_ id: UUID, _ value: DragGesture.Value, _ geometry: CurveGeometry) {
        if dragging == id {
            onEnd()
            dragging = nil
            wasAboveNeutral = nil
            return
        }
        // A tap on a point: select it, or remove it if it was already selected.
        if selectedPoint == id, curve.canRemovePoint(id: id) {
            onBegin()
            onEdit { $0.removePoint(id: id) }
            onEnd()
            selectedPoint = nil
            CurveHaptics.remove()
        } else {
            selectedPoint = id
            CurveHaptics.select()
        }
    }

    /// A tap on the graph itself adds a point there.
    private func handleTap(_ location: CGPoint, _ geometry: CurveGeometry) {
        guard geometry.rect.insetBy(dx: -12, dy: -12).contains(location) else { return }
        onBegin()
        var created: UUID?
        onEdit { curve in
            created = curve.addPoint(x: geometry.curveX(location.x),
                                     y: geometry.curveY(location.y))
        }
        onEnd()
        selectedPoint = created
        CurveHaptics.add()
    }
}

// ---------------------------------------------------------------------------

/// Deliberately sparse: a tick when something discrete happens, and one as a
/// point crosses neutral. Never a stream while a finger is moving.
enum CurveHaptics {
    static func add() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func remove() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func reset() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func select() { UISelectionFeedbackGenerator().selectionChanged() }
    static func crossNeutral() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.5) }
}
