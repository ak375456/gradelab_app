import SwiftUI
import UIKit

// ---------------------------------------------------------------------------
// Color Warper panel
//
// Two planes through one mesh. `ColorWarpGeometry` is the only thing that knows
// the difference between them - a wheel where angle is hue and distance is
// saturation, or a rectangle of chroma against luma - so the drawing, the
// gestures and the readout are written once.
//
// The interaction contract is the curve graph's, deliberately: the canvas takes
// no drags, so the panel still scrolls; only a control point carries a gesture;
// a movement under the slop stays a tap and opens no undo entry; and one gesture
// produces exactly one undo entry through `beginCurveEdit`/`endCurveEdit`.
// ---------------------------------------------------------------------------

struct ColorWarperPanel<Model: GradingModel>: View {
    @ObservedObject var model: Model

    private var warp: ColorWarp { model.colorWarp }
    private var mode: ColorWarpMode { model.selectedWarpMode }
    private var selected: ColorWarpPoint? { model.selectedWarpPointValue }

    var body: some View {
        VStack(spacing: AppSpacing.compact) {
            modePicker
            ProPanelNotice(feature: .colorWarper)

            ColorWarpMesh(
                warp: warp,
                mode: mode,
                selectedPoint: model.selectedWarpPointBinding,
                onBegin: { model.beginCurveEdit(String(localized: "Color Warper")) },
                onAdd: { x, y in model.addColorWarpPoint(x: x, y: y, mode: mode) },
                onMove: { id, x, y in model.moveColorWarpPoint(id: id, toX: x, y: y) },
                onReset: { id in model.resetColorWarpPoint(id: id) },
                onEnd: { model.endCurveEdit() }
            )
            .frame(height: mode == .hueSaturation ? 280 : 220)
            .disabled(!model.canGrade)

            readout
            rangeSlider

            GradeSlider(
                model: model,
                property: .gradeColorWarpStrength,
                title: String(localized: "Strength"),
                range: 0...100,
                neutral: 100,
                valueFormatter: { String(format: "%.0f%%", locale: .current, $0) }
            )
            .disabled(!model.canGrade || warp.isNeutral)

            preserveLuminanceToggle
            densityPicker
            resetActions

            Text(GradePanel.warper.help)
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: model.selectedWarpMode) { _, _ in model.selectedWarpPoint = nil }
        .onChange(of: model.gradeSubjectID) { _, _ in
            model.selectedWarpPoint = nil
            model.isPickingWarpColor = false
        }
        .onDisappear { model.isPickingWarpColor = false }
    }

    // MARK: - Which plane

    private var modePicker: some View {
        Picker(String(localized: "Plane"), selection: model.selectedWarpModeBinding) {
            ForEach(ColorWarpMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .disabled(!model.canGrade)
        // Both planes stay live; this only chooses what the mesh shows. Said
        // out loud because a segmented control usually means "one or the other".
        .accessibilityHint("Chooses which plane to edit. Both stay applied.")
    }

    // MARK: - Readout and point actions

    private var readout: some View {
        HStack(spacing: AppSpacing.small) {
            if let point = selected {
                value(mode.xLabel, mode.formattedX(point.sourceX), mode.formattedX(point.targetX))
                value(mode.yLabel, mode.formattedY(point.sourceY), mode.formattedY(point.targetY))
            } else if warp.activePoints(mode).isEmpty {
                Text("Tap the mesh, or pick a color from the picture")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textTertiary)
            } else {
                Text("\(warp.activePoints(mode).count) adjustments")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textTertiary)
            }

            Spacer(minLength: AppSpacing.small)

            actionButton(
                "eyedropper",
                label: model.isPickingWarpColor
                    ? String(localized: "Cancel color picking")
                    : String(localized: "Pick a color from the picture"),
                isActive: model.isPickingWarpColor
            ) {
                model.isPickingWarpColor.toggle()
                model.isPickingCurveHue = false
                if model.isPickingWarpColor { CurveHaptics.select() }
            }
            .disabled(!model.canGrade)

            actionButton("trash", label: String(localized: "Delete the selected point")) {
                guard let point = selected else { return }
                model.removeColorWarpPoint(id: point.id)
                CurveHaptics.remove()
            }
            .disabled(selected == nil || !model.canGrade)
        }
        .foregroundStyle(AppColors.textPrimary)
    }

    /// Source on the left, destination on the right — the whole point of the
    /// tool is the difference between the two, so both are always shown.
    private func value(_ label: String, _ from: String, _ to: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(AppTypography.caption).foregroundStyle(AppColors.textSecondary)
            Text(from).font(AppTypography.numeric).foregroundStyle(AppColors.textSecondary)
            if from != to {
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(AppColors.textTertiary)
                Text(to).font(AppTypography.numeric)
            }
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

    // MARK: - Range

    /// How much of the surrounding colour comes along. Belongs to the selected
    /// point rather than to the tool, because "how far does this reach" is a
    /// different answer for skin than it is for a sky.
    private var rangeSlider: some View {
        AdjustmentSlider(
            value: Binding(
                get: { (model.selectedWarpPointRadius ?? warp.density.defaultRadius) * 100 },
                set: { value in
                    guard let id = model.selectedWarpPoint else { return }
                    model.setColorWarpRadius(id: id, value / 100)
                }
            ),
            title: String(localized: "Range"),
            range: ColorWarpPoint.minimumRadius * 100...100,
            step: 1,
            neutralValue: warp.density.defaultRadius * 100,
            valueFormatter: { String(format: "%.0f%%", locale: .current, $0) },
            accessory: { EmptyView() }
        )
        .disabled(!model.canGrade || selected == nil)
    }

    // MARK: - Options

    private var preserveLuminanceToggle: some View {
        Toggle(isOn: model.colorWarpPreservesLuminanceBinding) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Preserve Luminance")
                    .font(AppTypography.bodyEmphasized)
                    .foregroundStyle(AppColors.textPrimary)
                Text("Holds brightness while hue and saturation move. Chroma / Luma is unaffected.")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(AppColors.accent)
        .disabled(!model.canGrade)
    }

    private var densityPicker: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            HStack {
                Text("Mesh")
                    .font(AppTypography.bodyEmphasized)
                    .foregroundStyle(AppColors.textPrimary)
                Spacer(minLength: AppSpacing.small)
                Picker(String(localized: "Mesh"), selection: model.colorWarpDensityBinding) {
                    ForEach(ColorWarpDensity.allCases) { density in
                        Text(density.title).tag(density)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
            }
            // Worth saying, because in most tools changing a mesh resolution
            // resamples and loses work. Here a point stores its own place rather
            // than a lattice index, so this only changes where new handles land.
            Text("How finely the mesh is divided. Changing it never moves adjustments you have already made.")
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!model.canGrade)
    }

    private var resetActions: some View {
        HStack(spacing: AppSpacing.small) {
            Button(String(localized: "Reset point")) {
                guard let point = selected else { return }
                model.resetColorWarpPoint(id: point.id)
                CurveHaptics.reset()
            }
            .disabled(selected?.isResting ?? true)

            Button(String(localized: "Reset plane")) {
                model.resetColorWarp(mode)
                CurveHaptics.reset()
            }
            .disabled(warp.activePoints(mode).isEmpty)

            Spacer(minLength: 0)

            Button(String(localized: "Reset all"), role: .destructive) {
                model.resetColorWarp()
                CurveHaptics.reset()
            }
            .disabled(!model.hasColorWarpEdits)
        }
        .font(AppTypography.caption.weight(.semibold))
        .buttonStyle(.plain)
        .foregroundStyle(AppColors.accent)
        .frame(height: 44)
        .disabled(!model.canGrade)
    }
}

// ---------------------------------------------------------------------------
// Geometry
//
// Maps between a plane's own axes and the plot, in one place, so a drawn handle
// and a touched handle cannot end up in different positions — the same reason
// `CurveGeometry` exists.
// ---------------------------------------------------------------------------

private struct ColorWarpGeometry {
    let rect: CGRect
    let mode: ColorWarpMode

    init(size: CGSize, mode: ColorWarpMode) {
        let inset: CGFloat = 18
        let available = CGRect(x: inset, y: inset,
                               width: max(size.width - inset * 2, 1),
                               height: max(size.height - inset * 2, 1))
        if mode == .hueSaturation {
            // The wheel has to be round, so the plot is the largest square that
            // fits rather than the whole box.
            let side = min(available.width, available.height)
            rect = CGRect(x: available.midX - side / 2, y: available.midY - side / 2,
                          width: side, height: side)
        } else {
            rect = available
        }
        self.mode = mode
    }

    var centre: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
    var radius: CGFloat { rect.width / 2 }

    /// Hue 0 sits at the top and increases clockwise, which is how a colour
    /// wheel is read. Saturation is distance from the centre.
    func point(_ x: Float, _ y: Float) -> CGPoint {
        switch mode {
        case .hueSaturation:
            let angle = (Double(x) * 2 - 0.5) * .pi
            let r = radius * CGFloat(min(max(y, 0), 1))
            return CGPoint(x: centre.x + r * cos(angle), y: centre.y + r * sin(angle))
        case .chromaLuma:
            return CGPoint(x: rect.minX + CGFloat(min(max(x, 0), 1)) * rect.width,
                           y: rect.maxY - CGFloat(min(max(y, 0), 1)) * rect.height)
        }
    }

    func coordinate(_ location: CGPoint) -> SIMD2<Float> {
        switch mode {
        case .hueSaturation:
            let dx = location.x - centre.x
            let dy = location.y - centre.y
            let distance = min(hypot(dx, dy) / max(radius, 1), 1)
            let angle = atan2(dy, dx)
            return SIMD2(ColorWarpMath.wrap(Float(angle / (2 * .pi) + 0.25)), Float(distance))
        case .chromaLuma:
            return SIMD2(
                Float(min(max((location.x - rect.minX) / rect.width, 0), 1)),
                Float(min(max((rect.maxY - location.y) / rect.height, 0), 1))
            )
        }
    }

    /// A tap lands on the nearest mesh intersection. That is what the density
    /// control actually buys: the STORED point is still continuous, so nothing
    /// here can be lost by changing density later.
    ///
    /// The eyedropper deliberately does not go through this - a colour taken off
    /// the picture should land exactly where that colour is.
    func snapped(_ coordinate: SIMD2<Float>, density: ColorWarpDensity) -> SIMD2<Float> {
        let columns = Float(density.columns)
        let rows = Float(density.rows)
        switch mode {
        case .hueSaturation:
            // Never the centre: a fully desaturated pixel has no hue to move,
            // and a handle there could not do anything.
            let ring = min(max((coordinate.y * rows).rounded(), 1), rows)
            return SIMD2(ColorWarpMath.wrap((coordinate.x * columns).rounded() / columns), ring / rows)
        case .chromaLuma:
            return SIMD2((coordinate.x * columns).rounded() / columns,
                         (coordinate.y * rows).rounded() / rows)
        }
    }
}

// ---------------------------------------------------------------------------
// The mesh
// ---------------------------------------------------------------------------

private struct ColorWarpMesh: View {
    let warp: ColorWarp
    let mode: ColorWarpMode
    @Binding var selectedPoint: UUID?
    let onBegin: () -> Void
    let onAdd: (Float, Float) -> UUID?
    let onMove: (UUID, Float, Float) -> Void
    let onReset: (UUID) -> Void
    let onEnd: () -> Void

    @State private var dragging: UUID?

    /// Comfortably past the 44pt minimum on the diagonal, and small enough that
    /// a mesh with several points still leaves room to place another.
    private static let handleSize: CGFloat = 46
    /// How far a finger must travel on a handle before it counts as a drag. Below
    /// this the point is not moved and no undo entry is opened, so tapping a
    /// point to select it stays exact.
    private static let dragSlop: CGFloat = 4
    private static let space = "colorWarpMesh"

    private var points: [ColorWarpPoint] { warp.points.filter { $0.mode == mode } }

    var body: some View {
        GeometryReader { proxy in
            let geometry = ColorWarpGeometry(size: proxy.size, mode: mode)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in draw(in: &context, geometry: geometry) }
                    .allowsHitTesting(false)

                // Everything that is not a handle falls through to the panel's
                // scroll view; only a tap is taken here.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { location in handleTap(location, geometry) }

                ForEach(points) { point in
                    handle(point, geometry)
                }

                if let id = dragging, let point = points.first(where: { $0.id == id }) {
                    magnifier(point, geometry)
                }
            }
            .coordinateSpace(.named(Self.space))
        }
        .background(AppColors.editorBackground, in: RoundedRectangle(cornerRadius: AppCornerRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: AppCornerRadius.card)
                .strokeBorder(AppColors.border, lineWidth: 1))
        .accessibilityElement()
        .accessibilityLabel(mode.title)
        .accessibilityValue(points.isEmpty
                            ? String(localized: "Neutral")
                            : String(localized: "\(points.count) adjustments"))
        .accessibilityHint("Tap the mesh to place a point, drag it to move that color, double-tap a point to reset it.")
    }

    /// One control point's touch target. Invisible: the canvas underneath draws
    /// the handle at the same place.
    ///
    /// Locations come back in the mesh's own coordinate space rather than the
    /// handle's, because the handle moves with the point it is dragging and a
    /// local reading would drift behind the finger.
    private func handle(_ point: ColorWarpPoint, _ geometry: ColorWarpGeometry) -> some View {
        Circle()
            .fill(Color.white.opacity(0.001))
            .frame(width: Self.handleSize, height: Self.handleSize)
            .position(geometry.point(point.targetX, point.targetY))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                    .onChanged { value in handleChange(point.id, value, geometry) }
                    .onEnded { value in handleEnd(point.id, value, geometry) }
            )
            .onTapGesture(count: 2) {
                onReset(point.id)
                selectedPoint = point.id
                CurveHaptics.reset()
            }
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, geometry: ColorWarpGeometry) {
        drawBackground(in: &context, geometry: geometry)
        drawMesh(in: &context, geometry: geometry)
        drawPoints(in: &context, geometry: geometry)
    }

    /// The plane itself, so a position on it obviously means a colour.
    private func drawBackground(in context: inout GraphicsContext, geometry: ColorWarpGeometry) {
        switch mode {
        case .hueSaturation:
            let stops = (0...12).map { index in
                // Matching `ColorWarpGeometry.point`: hue 0 at the top, and the
                // conic gradient's own zero angle is at three o'clock.
                Gradient.Stop(color: Color(hue: Double(index) / 12, saturation: 0.9, brightness: 0.95),
                              location: Double(index) / 12)
            }
            let wheel = Path(ellipseIn: geometry.rect)
            context.fill(wheel, with: .conicGradient(Gradient(stops: stops),
                                                     center: geometry.centre,
                                                     angle: .degrees(-90)))
            // Saturation falls to nothing at the centre, so the picture matches
            // what the radius means.
            context.fill(wheel, with: .radialGradient(
                Gradient(colors: [AppColors.editorBackground, AppColors.editorBackground.opacity(0)]),
                center: geometry.centre, startRadius: 0, endRadius: geometry.radius))
            context.stroke(wheel, with: .color(.white.opacity(0.12)), lineWidth: 1)
        case .chromaLuma:
            // Chroma left to right, brightness bottom to top — drawn as a plain
            // luminance ramp rather than a hue, because this plane is about how
            // colourful and how bright, not about which colour.
            context.fill(
                Path(roundedRect: geometry.rect, cornerRadius: AppCornerRadius.small),
                with: .linearGradient(
                    Gradient(colors: [.black, .white]),
                    startPoint: CGPoint(x: 0, y: geometry.rect.maxY),
                    endPoint: CGPoint(x: 0, y: geometry.rect.minY)))
            context.fill(
                Path(roundedRect: geometry.rect, cornerRadius: AppCornerRadius.small),
                with: .linearGradient(
                    Gradient(colors: [AppColors.editorBackground.opacity(0.85), .clear]),
                    startPoint: CGPoint(x: geometry.rect.minX, y: 0),
                    endPoint: CGPoint(x: geometry.rect.maxX, y: 0)))
        }
    }

    /// The deformed mesh.
    ///
    /// Every vertex is displaced through `ColorWarpFieldFactory.displacement`,
    /// which is the same function and the same normalisation the GPU table is
    /// built from. So this is the deformation being applied, not a drawing that
    /// resembles it.
    private func drawMesh(in context: inout GraphicsContext, geometry: ColorWarpGeometry) {
        let density = warp.density
        let active = warp.activePoints(mode)
        let columns = density.columns
        let rows = density.rows

        func warped(_ x: Float, _ y: Float) -> CGPoint {
            guard !active.isEmpty else { return geometry.point(x, y) }
            let displacement = ColorWarpFieldFactory.displacement(at: x, y, points: active, mode: mode)
            return geometry.point(x + displacement.x, y + displacement.y)
        }

        var path = Path()
        let samples = 6
        // Lines of constant y.
        for row in (mode == .hueSaturation ? 1 : 0)...rows {
            let y = Float(row) / Float(rows)
            let steps = columns * samples
            for step in 0...steps {
                let x = Float(step) / Float(steps)
                let point = warped(x, y)
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
        // Lines of constant x.
        let firstRow = mode == .hueSaturation ? 1 : 0
        for column in 0..<columns {
            let x = Float(column) / Float(columns)
            let steps = (rows - firstRow) * samples
            guard steps > 0 else { continue }
            for step in 0...steps {
                let y = (Float(firstRow) + Float(step) / Float(samples)) / Float(rows)
                let point = warped(x, y)
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
        context.stroke(path, with: .color(.white.opacity(active.isEmpty ? 0.10 : 0.22)), lineWidth: 1)
    }

    private func drawPoints(in context: inout GraphicsContext, geometry: ColorWarpGeometry) {
        for point in points {
            let source = geometry.point(point.sourceX, point.sourceY)
            let target = geometry.point(point.targetX, point.targetY)
            let isSelected = point.id == selectedPoint

            if isSelected {
                context.stroke(rangeContour(point, geometry),
                               with: .color(.white.opacity(0.45)),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            }

            if !point.isResting {
                var leash = Path()
                leash.move(to: source)
                leash.addLine(to: target)
                // Drawn twice: a dark stroke under a light one, so the line
                // stays visible over a yellow on the wheel and over white at the
                // top of the chroma/luma plane alike.
                context.stroke(leash, with: .color(.black.opacity(0.45)),
                               style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                context.stroke(leash, with: .color(.white.opacity(0.9)),
                               style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                // Where the colour came from, held open so the move reads as a
                // move rather than as a point that happens to be somewhere.
                let ring = Path(ellipseIn: CGRect(x: source.x - 3.5, y: source.y - 3.5,
                                                  width: 7, height: 7))
                context.stroke(ring, with: .color(.black.opacity(0.45)), lineWidth: 3)
                context.stroke(ring, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
            }

            // Every plane this sits on is coloured, and the wheel runs from
            // near-black to near-white around it, so a handle cannot rely on one
            // contrasting colour. A dark ring outside a light one reads on all
            // of them, and selection is carried by size and by the accent fill.
            let size: CGFloat = isSelected ? 7 : 5
            let handle = Path(ellipseIn: CGRect(x: target.x - size, y: target.y - size,
                                                width: size * 2, height: size * 2))
            context.stroke(handle, with: .color(.black.opacity(0.55)), lineWidth: 4)
            context.fill(handle, with: .color(isSelected ? AppColors.accent : .black.opacity(0.65)))
            context.stroke(handle, with: .color(.white.opacity(isSelected ? 1 : 0.85)), lineWidth: 2)
        }
    }

    /// The edge of a point's influence, drawn in the PLANE's coordinates rather
    /// than as a circle on screen.
    ///
    /// The range is a distance in hue-and-saturation, not a distance in points.
    /// On the wheel that is a curved patch which grows wider the further out it
    /// sits, and on the chroma/luma rectangle it is an ellipse whenever the plot
    /// is not square. A screen circle would be neither, and would promise an
    /// influence the warp does not have.
    private func rangeContour(_ point: ColorWarpPoint, _ geometry: ColorWarpGeometry) -> Path {
        let radius = max(point.radius, ColorWarpPoint.minimumRadius)
        var path = Path()
        let steps = 72
        for step in 0...steps {
            let angle = Double(step) / Double(steps) * 2 * .pi
            let x = point.sourceX + radius * Float(cos(angle))
            let y = point.sourceY + radius * Float(sin(angle))
            let location = geometry.point(x, y)
            if step == 0 { path.move(to: location) } else { path.addLine(to: location) }
        }
        return path
    }

    // MARK: - Magnified precision
    //
    // A finger covers the handle it is dragging, and on a phone the move that
    // matters is often a few degrees. The readout says where the colour is
    // going while it is going there, and disappears the moment it lands - it is
    // precision during a gesture, not another permanent row of numbers.

    private func magnifier(_ point: ColorWarpPoint, _ geometry: ColorWarpGeometry) -> some View {
        let anchor = geometry.point(point.targetX, point.targetY)
        return VStack(spacing: 1) {
            Text("\(mode.xLabel) \(mode.formattedX(point.sourceX)) → \(mode.formattedX(point.targetX))")
            Text("\(mode.yLabel) \(mode.formattedY(point.sourceY)) → \(mode.formattedY(point.targetY))")
        }
        .font(AppTypography.caption.monospacedDigit())
        .foregroundStyle(AppColors.textPrimary)
        .padding(.horizontal, AppSpacing.small)
        .padding(.vertical, 5)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: AppCornerRadius.small))
        // Always above the finger, never flipped to the other side: a readout
        // that jumps sides mid-drag is disorienting, and riding over the top of
        // the mesh is fine.
        .position(x: min(max(anchor.x, 60), geometry.rect.maxX),
                  y: max(anchor.y - 46, 18))
        .allowsHitTesting(false)
    }

    // MARK: - Interaction

    private func handleChange(_ id: UUID, _ value: DragGesture.Value, _ geometry: ColorWarpGeometry) {
        if dragging != id {
            // Under the slop this is still a tap, and opening the edit here
            // would put an entry that changed nothing into undo.
            guard hypot(value.translation.width, value.translation.height) > Self.dragSlop else { return }
            dragging = id
            selectedPoint = id
            onBegin()
        }
        let coordinate = geometry.coordinate(value.location)
        onMove(id, coordinate.x, coordinate.y)
    }

    private func handleEnd(_ id: UUID, _ value: DragGesture.Value, _ geometry: ColorWarpGeometry) {
        if dragging == id {
            onEnd()
            dragging = nil
            return
        }
        selectedPoint = id
        CurveHaptics.select()
    }

    /// A tap on the mesh places a handle at the nearest intersection, or selects
    /// the one already there.
    private func handleTap(_ location: CGPoint, _ geometry: ColorWarpGeometry) {
        let raw = geometry.coordinate(location)
        if mode == .hueSaturation {
            // Outside the wheel is not a colour. `coordinate` clamps to the rim,
            // so the reading has to be taken before it does.
            let distance = hypot(location.x - geometry.centre.x, location.y - geometry.centre.y)
            guard distance <= geometry.radius + 12 else { return }
        } else {
            guard geometry.rect.insetBy(dx: -12, dy: -12).contains(location) else { return }
        }
        let snapped = geometry.snapped(raw, density: warp.density)
        onBegin()
        let created = onAdd(snapped.x, snapped.y)
        onEnd()
        selectedPoint = created
        CurveHaptics.add()
    }
}
