import SwiftUI

struct ShapeToolPanel: View {
    @ObservedObject var model: EditorViewModel
    // Owned by EditorView so a redraw of this panel cannot bounce the user back
    // to the first tab, exactly as the text panel's sections are.
    @Binding var section: String
    @Binding var appearance: String
    @State private var activeProperty: AnimatableProperty?
    @State private var selectedKeyframe: TimelineTime?
    @State private var keyframeHelp = false
    @State private var confirmsRemoveAll = false
    private let sections = ["Shape", "Transform", "Appearance"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.selectedShapeCount > 1 {
                Label("\(model.selectedShapeCount) shape layers selected", systemImage: "square.stack.3d.up.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.accent)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppColors.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
            tabs(sections, selection: $section)
            if let clip = model.selectedShape {
                switch section {
                case "Shape":
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64, maximum: 84), spacing: 10)], spacing: 10) {
                        ForEach(ShapeKind.allCases) { kind in
                            Button { model.editShape("Shape", immediate: true) { $0.kind = kind } } label: {
                                ShapeKindTile(kind: kind, selected: clip.kind == kind)
                            }.accessibilityLabel(kind.title)
                        }
                    }
                    number(String(localized: "Duration (s)"),
                           Binding(get: { model.selectedShape?.placement.duration.seconds ?? 3 },
                                   set: model.setShapeDuration), 0.1...600, reset: 3)
                    keyframeHeader
                    // Bounded by the canvas rather than by a fixed 4096, for the
                    // same reason the corner radius is bounded by the shape: a
                    // slider whose useful values sit in its first tenth is not a
                    // slider. Anything larger is what Scale is for.
                    animated(.shapeWidth, 4...sizeLimit(\.width))
                    animated(.shapeHeight, 4...sizeLimit(\.height))
                    if clip.kind.usesCornerRadius {
                        // Bounded by what this shape can actually show, not by a
                        // fixed ceiling: at a typical size the old 0...1024
                        // slider spent nine tenths of its travel past the point
                        // where the corners had already met.
                        animated(.cornerRadius, 0...cornerRadiusLimit)
                        Text("Drag to the end for fully rounded. A square shape becomes a circle; a wider one becomes a capsule.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if clip.kind.usesPointCount {
                        Stepper(value: binding(\.pointCount),
                                in: ShapeKind.pointCountRange, step: 1) {
                            HStack {
                                Text(clip.kind == .star ? "Points" : "Corners").font(.caption)
                                Spacer()
                                Text(clip.resolvedPointCount.formatted()).font(.caption.monospacedDigit())
                                    .foregroundStyle(AppColors.textSecondary)
                            }
                        }.frame(minHeight: 44)
                    }
                    if clip.kind.usesInnerRadius { animated(.shapeInnerRadius, 0.05...0.95) }
                case "Transform":
                    keyframeHeader
                    CanvasAlignmentRow(model: model)
                    animated(.positionX, -1...2)
                    animated(.positionY, -1...2)
                    animated(.scale, 0.05...6)
                    Toggle("Lock aspect ratio", isOn: binding(\.transform.locksAspectRatio))
                    animated(.widthScale, 0.1...6)
                    animated(.heightScale, 0.1...6)
                    // Wide enough for two full turns by dragging; type more for further spins.
                    animated(.rotation, -720...720)
                    number(String(localized: "Anchor X"), value(\.transform.anchorX), 0...1, reset: 0.5)
                    number(String(localized: "Anchor Y"), value(\.transform.anchorY), 0...1, reset: 0.5)
                    animated(.opacity, 0...1)
                    Picker("Blend", selection: binding(\.blendMode)) {
                        ForEach(VisualBlendMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    // Written out twice rather than as a ternary inside `Text`:
                    // only a plain literal is reliably extracted for translation.
                    if model.selectedShapeCount > 1 {
                        Text("Position moves every selected shape together, so they keep their spacing.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Drag the shape in the preview. Pinch to resize; turn with two fingers to rotate.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                default:
                    tabs(["Fill", "Gradient", "Stroke", "Shadow", "Glow"], selection: $appearance)
                    keyframeHeader
                    switch appearance {
                    case "Fill":
                        animatedColor(.fillColor)
                        animated(.opacity, 0...1)
                        Text("A fill color with zero opacity leaves an outline-only shape. Set a stroke width under Stroke.")
                            .font(.caption2).foregroundStyle(.secondary)
                    case "Gradient":
                        Toggle("Gradient fill", isOn: Binding(get: { clip.gradient != nil }, set: { on in
                            model.editShape { c in
                                c.gradient = on ? (c.gradient ?? .init(start: c.fillColor, end: GradientFill().end)) : nil
                            }
                        })).font(.caption).frame(minHeight: 44)
                        if clip.gradient != nil {
                            ColorPicker("Start color", selection: colorBinding(gradient(\.start)), supportsOpacity: true)
                                .font(.caption).frame(minHeight: 44)
                            ColorPicker("End color", selection: colorBinding(gradient(\.end)), supportsOpacity: true)
                                .font(.caption).frame(minHeight: 44)
                            number(String(localized: "Angle"), gradient(\.angleDegrees), -180...180, reset: 90)
                        } else {
                            Text("A gradient replaces the flat fill. Stroke, shadow and glow keep their own colors.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    case "Stroke": animatedColor(.strokeColor); animated(.strokeWidth, 0...64)
                    case "Shadow":
                        animatedColor(.shadowColor)
                        animated(.shadowOpacity, 0...1)
                        animated(.shadowRadius, 0...100)
                        animated(.shadowOffsetX, -150...150)
                        animated(.shadowOffsetY, -150...150)
                    default:
                        animatedColor(.glowColor)
                        animated(.glowOpacity, 0...1)
                        animated(.glowRadius, 0...100)
                    }
                }
            }
        }.padding(.horizontal, 20).padding(.bottom, 20)
        .onChange(of: model.selectedClipID) { _, _ in activeProperty = nil; selectedKeyframe = nil }
        .sheet(isPresented: $keyframeHelp) { KeyframeHelp() }
        .confirmationDialog("Remove all animation from this shape?", isPresented: $confirmsRemoveAll, titleVisibility: .visible) {
            Button("Remove All Animation", role: .destructive) { model.removeAllAnimation(); activeProperty = nil; selectedKeyframe = nil }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Every animated property keeps the value you can see now.") }
    }

    /// The largest a shape's own dimension is worth dragging to on this canvas:
    /// half again the frame, which is enough to bleed off every edge. The floor
    /// keeps the range usable on a very small canvas.
    private func sizeLimit(_ axis: KeyPath<CGSize, CGFloat>) -> Double {
        let canvas = SequenceComposition.previewRenderSize(
            width: model.project.canvas.width, height: model.project.canvas.height)
        return max(512, Double(canvas[keyPath: axis]) * 1.5)
    }

    /// How round the SELECTED shape can get, read at the playhead so an animated
    /// width or height moves the ceiling with the figure on screen.
    private var cornerRadiusLimit: Double {
        (model.evaluatedShape ?? model.selectedShape)?.maximumCornerRadius ?? 1
    }

    private var keyframeHeader: some View {
        KeyframeSectionHeader(model: model, help: $keyframeHelp, confirmsRemoveAll: $confirmsRemoveAll)
    }

    private func animated(_ property: AnimatableProperty, _ range: ClosedRange<Double>) -> some View {
        KeyframePropertyRow(model: model, property: property, range: range,
                            activeProperty: $activeProperty, selectedKeyframe: $selectedKeyframe)
    }

    private func animatedColor(_ property: AnimatableProperty) -> some View {
        KeyframeColorRow(model: model, property: property,
                         activeProperty: $activeProperty, selectedKeyframe: $selectedKeyframe)
    }

    private func binding<T>(_ key: WritableKeyPath<ShapeClip, T>) -> Binding<T> {
        let selected = model.selectedShape
            ?? ShapeClip(placement: .init(id: UUID(), trackID: UUID(), timelineStart: .zero, duration: .zero))
        return Binding(get: { (model.selectedShape ?? selected)[keyPath: key] }, set: { v in
            guard model.selectedShape?.id == selected.id else { return }
            model.editShape { $0[keyPath: key] = v }
        })
    }
    private func value(_ key: WritableKeyPath<ShapeClip, Double>) -> Binding<Double> { binding(key) }
    private func gradient<T>(_ key: WritableKeyPath<GradientFill, T>) -> Binding<T> {
        Binding(get: { (model.selectedShape?.gradient ?? .init())[keyPath: key] }, set: { v in
            model.editShape { c in var g = c.gradient ?? .init(); g[keyPath: key] = v; c.gradient = g }
        })
    }
    private func number(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, reset: Double) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.caption); Spacer()
                NumericEntryLabel(title: title, text: value.wrappedValue.formatted(.number.precision(.fractionLength(0...2))),
                                  value: value.wrappedValue, range: range, tint: .primary) { typed in
                    value.wrappedValue = typed; model.flushGradeHistory()
                }.font(.caption.monospacedDigit())
            }
            ResettableSlider(value: value, range: range, resetValue: reset, label: title,
                             onEditingChanged: { if !$0 { model.flushGradeHistory() } })
        }
    }
    /// Display only, as in the text panel: `section` is switched on and bound
    /// from outside this view, so the identity has to stay the English string.
    private static func tabLabel(_ value: String) -> String {
        switch value {
        case "Shape": String(localized: "Shape")
        case "Transform": String(localized: "Transform")
        case "Appearance": String(localized: "Appearance")
        case "Fill": String(localized: "Fill")
        case "Gradient": String(localized: "Gradient")
        case "Stroke": String(localized: "Stroke")
        case "Shadow": String(localized: "Shadow")
        case "Glow": String(localized: "Glow")
        default: value
        }
    }
    private func tabs(_ values: [String], selection: Binding<String>) -> some View {
        ScrollView(.horizontal) { HStack(spacing: 16) { ForEach(values, id: \.self) { v in
            Button(Self.tabLabel(v)) { selection.wrappedValue = v }.font(.caption.weight(.medium)).frame(minHeight: 36)
                .foregroundStyle(selection.wrappedValue == v ? Color.cyan : .secondary)
        } } }.scrollIndicators(.hidden)
    }
    private func colorBinding(_ value: Binding<RGBAColor>) -> Binding<Color> {
        Binding(get: { let c = value.wrappedValue; return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha) }, set: { color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
            value.wrappedValue = .init(red: r, green: g, blue: b, alpha: a)
        })
    }
}

/// A kind tile drawn from the SAME path the renderer uses, so the picker cannot
/// promise a figure the composition does not draw.
struct ShapeKindTile: View {
    let kind: ShapeKind
    let selected: Bool

    var body: some View {
        VStack(spacing: 4) {
            Canvas { context, size in
                let inset: CGFloat = 8
                let box = CGRect(x: inset, y: inset, width: size.width-inset*2, height: size.height-inset*2)
                guard box.width > 0, box.height > 0 else { return }
                var clip = ShapeClip(placement: .init(id: UUID(), trackID: UUID(),
                                                      timelineStart: .zero, duration: .zero), kind: kind)
                clip.width = box.width
                clip.height = kind == .line ? max(3, box.height*0.22) : box.height
                clip.cornerRadius = kind == .rectangle ? min(7, box.width*0.18) : 0
                // CoreGraphics builds the path Y-up; a Canvas draws Y-down. Flip
                // it and centre what is left, or a triangle would point downward.
                let pad = (box.height - clip.height)/2
                let flip = CGAffineTransform(scaleX: 1, y: -1)
                    .concatenating(.init(translationX: box.minX, y: box.minY + clip.height + pad))
                context.fill(Path(ShapeRenderer.path(clip)).applying(flip),
                             with: .color(selected ? AppColors.accent : AppColors.textSecondary))
            }
            .frame(height: 46)
            Text(kind.title).font(.system(size: 9)).lineLimit(1)
                .foregroundStyle(selected ? AppColors.accent : AppColors.textSecondary)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(selected ? AppColors.accent.opacity(0.14) : .white.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(selected ? AppColors.accent : .clear, lineWidth: 1))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
