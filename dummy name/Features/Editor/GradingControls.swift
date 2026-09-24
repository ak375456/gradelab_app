import SwiftUI
import UIKit

/// The Color tab: the panel strip and the eight tools behind it.
///
/// Lifted out of `EditorView` unchanged so the still-image editor can present
/// the same tools rather than a second interface that happens to look similar.
/// A photograph and a video clip are graded by the identical controls, writing
/// into the identical `GradeSettings`; the only difference between the two
/// editors is what surrounds this view.
struct GradingControls<Model: GradingModel>: View {
    @ObservedObject var model: Model
    /// Opens the "Save Grade as Preset" sheet, which the host presents.
    var onSaveGrade: () -> Void = {}
    @Binding private var scrollPosition: ScrollPosition

    @State private var selectedParameter: GradeParameter = .exposure

    init(model: Model, onSaveGrade: @escaping () -> Void = {},
         scrollPosition: Binding<ScrollPosition> = .constant(ScrollPosition(y: 0))) {
        self.model = model
        self.onSaveGrade = onSaveGrade
        self._scrollPosition = scrollPosition
    }

    var body: some View {
        VStack(spacing: 0) {
            if let name = model.editingMaskName { maskContextBar(name) }
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(model.availablePanels) { panel in
                        Button { model.selectedPanel = panel } label: {
                            VStack(spacing: 3) {
                                Image(systemName: panel.symbol).font(.system(size: 14))
                                    // Says the tool holds animation. The
                                    // diamonds inside it say which parameter.
                                    .overlay(alignment: .topTrailing) {
                                        GradeAnimationDot(model: model, panel: panel).offset(x: 5, y: -1)
                                    }
                                Text(panel.rawValue).font(.caption.weight(.medium))
                            }.frame(width: 58, height: 44)
                                .foregroundStyle(model.selectedPanel == panel ? AppColors.textPrimary : AppColors.textSecondary)
                                .background(model.selectedPanel == panel ? AppColors.surfaceRaised : .clear, in: RoundedRectangle(cornerRadius: 12))
                                // The whole 58x44 tile takes the click. An
                                // unselected tab's background is `.clear`,
                                // which SwiftUI does not hit-test, so without
                                // this only the glyph and the word themselves
                                // answered — a pointer a pixel off either one
                                // hit nothing at all.
                                .contentShape(RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain).accessibilityAddTraits(model.selectedPanel == panel ? .isSelected : [])
                    }
                }.padding(.horizontal, 12)
            }.frame(height: 44).scrollIndicators(.hidden)
            ScrollView {
                VStack(spacing: 20) {
                    // The keyframe hint and the "playhead is outside the clip"
                    // notice, shown above whichever tool offers animation. The
                    // two mask tools carry their own.
                    if ![.mask, .masks].contains(model.selectedPanel) {
                        GradeKeyframeHeader(model: model)
                    }
                    switch model.selectedPanel {
                    case .light, .color:
                        // A Mac window has the height to show every slider in
                        // the group at once, which is how a desktop grading
                        // panel reads: Temperature, Tint, Saturation and
                        // Vibrance together, not one at a time behind a chip.
                        // Phone and iPad keep the chips — there the picture
                        // would lose the room.
                        if AppPlatform.isMac {
                            ForEach(model.visibleParameters) { parameter in
                                if let property = AnimatableProperty.light(parameter) {
                                    GradeSlider(model: model, property: property,
                                                title: parameter.title,
                                                range: parameter.range, step: parameter.step,
                                                valueFormatter: AdjustmentValueFormatters.signed(
                                                    fractionDigits: parameter == .exposure ? 2 : 0))
                                }
                            }
                        } else {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(model.visibleParameters) { parameter in
                                    Button { selectedParameter = parameter } label: {
                                        HStack(spacing: 5) {
                                            Text(parameter.title).font(.subheadline)
                                            // One chip is visible at a time, so
                                            // without this an animating exposure
                                            // is hidden behind whichever
                                            // parameter is open.
                                            if let property = AnimatableProperty.light(parameter),
                                               model.keyframeHost?.keyframeState(property) != .off,
                                               model.keyframeHost != nil {
                                                Circle().fill(AppColors.accent).frame(width: 5, height: 5)
                                            }
                                        }
                                        .padding(.horizontal, 14).frame(height: 40)
                                        .background(selectedParameter == parameter ? AppColors.surfaceRaised : .clear, in: Capsule())
                                        // Same reason as the panel strip: an
                                        // unselected chip is clear, so the
                                        // whole capsule has to be asked for.
                                        .contentShape(Capsule())
                                    }.foregroundStyle(selectedParameter == parameter ? AppColors.textPrimary : AppColors.textSecondary)
                                }
                            }
                        }.frame(height: 44).scrollIndicators(.hidden)
                        if let property = AnimatableProperty.light(selectedParameter) {
                            GradeSlider(model: model, property: property, title: selectedParameter.title,
                                        range: selectedParameter.range, step: selectedParameter.step,
                                        valueFormatter: AdjustmentValueFormatters.signed(
                                            fractionDigits: selectedParameter == .exposure ? 2 : 0))
                        }
                        }
                    case .curves: CurvesPanel(model: model)
                    case .warper: ColorWarperPanel(model: model)
                    case .hsl: HSLPanel(model: model)
                    case .wheels: WheelsPanel(model: model)
                    case .mask: GradeMaskPanel(model: model)
                    case .masks:
                        if let editor = model as? EditorViewModel {
                            MaskPanel(model: editor)
                        }
                    case .lut: LUTPanel(model: model, onSaveGrade: onSaveGrade)
                    case .vignette:
                        vignette("Amount", .gradeVignette, -100...100, 0)
                        vignette("Midpoint", .gradeVignetteMidpoint, 0...100, 50)
                        vignette("Feather", .gradeVignetteFeather, 0...100, 70)
                    case .effects: FilmEffectsPanel(model: model)
                    }
                }.padding(.horizontal, 20).padding(.bottom, 24)
            }
            .scrollPosition($scrollPosition)
            .scrollIndicators(.visible)
        }
        .onChange(of: model.selectedPanel, initial: true) { _, panel in
            selectedParameter = panel == .color ? .temperature : .exposure
        }
    }

    /// The context indicator. Deliberately unmissable and always in the same
    /// place: the Color controls look identical in both contexts, so this bar is
    /// the only thing that says an exposure change is going to land on one face
    /// rather than on the whole clip.
    @ViewBuilder
    private func maskContextBar(_ name: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.dashed.inset.filled")
                .font(.caption)
            Text("Editing \(name)")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let editor = model as? EditorViewModel {
                Button("Global") { editor.selectMask(nil) }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(AppColors.textPrimary)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(AppColors.surfaceRaised, in: Capsule())
                    .accessibilityHint("Return to grading the whole clip")
            }
        }
        .foregroundStyle(AppColors.accent)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(AppColors.accentMuted)
        .overlay(alignment: .bottom) { Rectangle().fill(AppColors.accent.opacity(0.35)).frame(height: 1) }
    }

    private func vignette(
        _ title: String, _ property: AnimatableProperty,
        _ range: ClosedRange<Float>, _ neutral: Float
    ) -> some View {
        GradeSlider(model: model, property: property, title: title, range: range,
                    neutral: neutral, valueFormatter: AdjustmentValueFormatters.signed())
    }
}

/// Local grading window. Sliders use source-relative percentages so the values
/// stay understandable and remain identical at every preview/export size.
private struct GradeMaskPanel<Model: GradingModel>: View {
    @ObservedObject var model: Model
    @State private var activeProperty: AnimatableProperty?
    @State private var selectedKeyframe: TimelineTime?
    @State private var keyframeHelp = false
    @State private var confirmsRemoveAll = false

    private let localMaskProperties: [(AnimatableProperty, ClosedRange<Double>, Double, String)] = [
        (.localMaskPositionX, 0...1, 100, "%"),
        (.localMaskPositionY, 0...1, 100, "%"),
        (.localMaskWidth, 0.01...2, 100, "%"),
        (.localMaskHeight, 0.01...2, 100, "%"),
        (.localMaskRotation, -180...180, 1, "°"),
        (.localMaskFeather, 0...1, 100, "%"),
        (.localMaskOpacity, 0...1, 100, "%")
    ]

    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Toggle("Use grading mask", isOn: model.gradeMaskBinding(\.isEnabled))
                    .tint(AppColors.accent)
                Text(model.gradeMask.isEnabled
                     ? "Only the area marked on the picture receives your colour adjustments."
                     : "Turn this on to limit colour adjustments to one area.")
                    .font(.caption2)
                    .foregroundStyle(AppColors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !model.settings.hasCreativeChangeIgnoringMask {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(AppColors.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("The mask is ready, but the grade is neutral.")
                            .font(.caption.weight(.semibold))
                        Text("Open Light or Color and move a slider to see the masked result.")
                            .font(.caption2)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Button("Light") { model.selectedPanel = .light }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.accent)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .padding(12)
                .appSurface(fill: AppColors.accentMuted, border: AppColors.accent.opacity(0.30))
            }

            Picker("Shape", selection: model.gradeMaskBinding(\.shape)) {
                ForEach(GradeMaskShape.allCases) { shape in
                    Text(shape.title).tag(shape)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 8) {
                Text("Apply grade")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.textSecondary)
                Picker("Apply grade", selection: model.gradeMaskBinding(\.isInverted)) {
                    Text("Inside shape").tag(false)
                    Text("Outside shape").tag(true)
                }
                .pickerStyle(.segmented)
            }

            HStack {
                Text("Drag the shape on the picture to position it.")
                    .font(.caption2)
                    .foregroundStyle(AppColors.textSecondary)
                Spacer(minLength: 8)
                Button("Center") {
                    if let editor = model as? EditorViewModel {
                        editor.setAnimatableValue(.localMaskPositionX, .number(0.5))
                        editor.setAnimatableValue(.localMaskPositionY, .number(0.5))
                    } else {
                        model.gradeMaskBinding(\.centerX).wrappedValue = 50
                        model.gradeMaskBinding(\.centerY).wrappedValue = 50
                    }
                    model.flushGradeHistory()
                }
                .font(.caption.weight(.semibold))
                .frame(minHeight: 44)
            }

            if let editor = model as? EditorViewModel {
                KeyframeSectionHeader(model: editor, help: $keyframeHelp,
                                      confirmsRemoveAll: $confirmsRemoveAll)
                ForEach(localMaskProperties, id: \.0) { property, range, scale, suffix in
                    KeyframePropertyRow(model: editor, property: property, range: range,
                                        activeProperty: $activeProperty,
                                        selectedKeyframe: $selectedKeyframe,
                                        displayScale: scale, suffix: suffix)
                }
            } else {
                maskAdjustment("Position X", \.centerX, 0...100, 50)
                maskAdjustment("Position Y", \.centerY, 0...100, 50)
                maskAdjustment("Width", \.width, 1...200, 60)
                maskAdjustment("Height", \.height, 1...200, 40)
                maskAdjustment("Rotation", \.rotation, -180...180, 0, suffix: "°")
                maskAdjustment("Feather", \.feather, 0...100, 25)
                maskAdjustment("Opacity", \.opacity, 0...100, 100)
            }

            Text("Tip: on a layered timeline, select the top visible clip. A clip above the selected one can hide its colour change.")
                .font(.caption2)
                .foregroundStyle(AppColors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(!model.canGrade)
        .onChange(of: model.gradeSubjectID) { _, _ in
            activeProperty = nil; selectedKeyframe = nil
        }
        .sheet(isPresented: $keyframeHelp) { KeyframeHelp() }
        .confirmationDialog("Remove all animation from this clip?", isPresented: $confirmsRemoveAll,
                            titleVisibility: .visible) {
            if let editor = model as? EditorViewModel {
                Button("Remove All Animation", role: .destructive) {
                    editor.removeAllAnimation(); activeProperty = nil; selectedKeyframe = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Every animated property keeps the value you can see now.") }
    }

    private func maskAdjustment(
        _ title: String,
        _ keyPath: WritableKeyPath<GradeMask, Float>,
        _ range: ClosedRange<Float>,
        _ neutral: Float,
        suffix: String = "%"
    ) -> some View {
        AdjustmentSlider(
            value: model.gradeMaskBinding(keyPath), title: title, range: range,
            step: 1, neutralValue: neutral,
            valueFormatter: { "\(Int($0.rounded()))\(suffix)" }
        )
    }
}

/// An editing-only guide over the picture. The mask stays visible while it is
/// off so choosing Ellipse or Rectangle never appears to do nothing. It is not
/// rendered into scopes or exports.
struct GradeMaskOverlay<Model: GradingModel>: View {
    @ObservedObject var model: Model
    /// The renderer returns an aspect-fit rectangle in normalized view space.
    /// Keeping this as a closure lets the guide follow the exact same
    /// letterboxing as Metal without putting renderer details in GradingModel.
    let displayedRect: () -> CGRect?

    @State private var dragOrigin: CGPoint?
    @State private var snappedToVerticalCenter = false
    @State private var snappedToHorizontalCenter = false

    var body: some View {
        GeometryReader { proxy in
            let picture = pictureRect(in: proxy.size)
            let mask = model.displayedGradeMask
            let center = CGPoint(
                x: picture.minX + picture.width * CGFloat(mask.centerX / 100),
                y: picture.minY + picture.height * CGFloat(mask.centerY / 100)
            )
            let maskSize = CGSize(
                width: max(12, picture.width * CGFloat(mask.width / 100)),
                height: max(12, picture.height * CGFloat(mask.height / 100))
            )

            ZStack {
                Canvas { context, _ in
                    context.clip(to: Path(picture))
                    if snappedToVerticalCenter {
                        var guide = Path()
                        guide.move(to: CGPoint(x: picture.midX, y: picture.minY))
                        guide.addLine(to: CGPoint(x: picture.midX, y: picture.maxY))
                        context.stroke(guide, with: .color(AppColors.accent.opacity(0.9)),
                                       style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                    if snappedToHorizontalCenter {
                        var guide = Path()
                        guide.move(to: CGPoint(x: picture.minX, y: picture.midY))
                        guide.addLine(to: CGPoint(x: picture.maxX, y: picture.midY))
                        context.stroke(guide, with: .color(AppColors.accent.opacity(0.9)),
                                       style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                .allowsHitTesting(false)

                maskGuide(shape: mask.shape, enabled: mask.isEnabled)
                    .frame(width: maskSize.width, height: maskSize.height)
                    .rotationEffect(.degrees(Double(mask.rotation)))
                    .contentShape(Rectangle())
                    .position(center)
                    .gesture(moveGesture(in: picture))

            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.displayedGradeMask.shape.title + " grading mask")
        .accessibilityValue(model.displayedGradeMask.isEnabled ? "On" : "Off")
        .accessibilityHint("Drag to move the mask on the picture")
    }

    @ViewBuilder
    private func maskGuide(shape: GradeMaskShape, enabled: Bool) -> some View {
        let color = enabled ? AppColors.accent : AppColors.textSecondary
        ZStack {
            if shape == .ellipse {
                Ellipse().stroke(.black.opacity(0.8), lineWidth: 5)
                Ellipse().stroke(color, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            } else {
                Rectangle().stroke(.black.opacity(0.8), lineWidth: 5)
                Rectangle().stroke(color, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            }
            Circle()
                .fill(color)
                .overlay(Circle().stroke(.black.opacity(0.75), lineWidth: 2))
                .frame(width: 14, height: 14)
        }
        .shadow(color: .black.opacity(0.45), radius: 2)
    }

    private func pictureRect(in size: CGSize) -> CGRect {
        guard let normalized = displayedRect(),
              normalized.width > 0, normalized.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        return CGRect(
            x: normalized.minX * size.width,
            y: normalized.minY * size.height,
            width: normalized.width * size.width,
            height: normalized.height * size.height
        )
    }

    private func moveGesture(in picture: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = CGPoint(x: CGFloat(model.displayedGradeMask.centerX),
                                         y: CGFloat(model.displayedGradeMask.centerY))
                }
                guard let dragOrigin else { return }
                var x = min(100, max(0, dragOrigin.x + value.translation.width / max(picture.width, 1) * 100))
                var y = min(100, max(0, dragOrigin.y + value.translation.height / max(picture.height, 1) * 100))
                let snapX = abs(x - 50) <= 1_200 / max(picture.width, 1)
                let snapY = abs(y - 50) <= 1_200 / max(picture.height, 1)
                if snapX { x = 50 }
                if snapY { y = 50 }
                if (snapX && !snappedToVerticalCenter) || (snapY && !snappedToHorizontalCenter) {
                    UISelectionFeedbackGenerator().selectionChanged()
                }
                snappedToVerticalCenter = snapX
                snappedToHorizontalCenter = snapY
                if let editor = model as? EditorViewModel {
                    editor.setAnimatableValue(.localMaskPositionX, .number(Double(x) / 100))
                    editor.setAnimatableValue(.localMaskPositionY, .number(Double(y) / 100))
                } else {
                    model.gradeMaskBinding(\.centerX).wrappedValue = Float(x)
                    model.gradeMaskBinding(\.centerY).wrappedValue = Float(y)
                }
            }
            .onEnded { _ in
                dragOrigin = nil
                snappedToVerticalCenter = false
                snappedToHorizontalCenter = false
                model.flushGradeHistory()
            }
    }
}

/// The grading actions that are not a slider: copy, paste, reset and save.
/// Shared for the same reason the panels are — both editors offer exactly these.
struct GradeActionsMenu<Model: GradingModel>: View {
    @ObservedObject var model: Model
    var onSaveGrade: () -> Void
    @ObservedObject private var store = ProStore.shared
    @State private var paywallFeature: ProFeature?
    /// Raised when a paste would land on a clip that is already graded. Pasting
    /// silently replaced that work, which is a lot to lose to one menu tap.
    @State private var confirmsPaste = false

    var body: some View {
        Menu {
            Button("Copy Grade", systemImage: "doc.on.doc", action: model.copyGrade)
                .disabled(!model.canCopyGrade)
            Button("Paste Grade", systemImage: "doc.on.clipboard") {
                if model.pasteWouldOverwriteGrade { confirmsPaste = true }
                else { model.pasteGrade(.replace) }
            }
                .disabled(!model.canPasteGrade)
            Button("Reset Grade", systemImage: "arrow.counterclockwise", action: model.resetGrade)
                .disabled(!model.canResetGrade)
            Divider()
            // The other exception to preview-free gating: a saved preset is a
            // library entry, not something that reaches a rendered frame.
            Button(store.hasPro ? "Save Grade as Preset" : "Save Grade as Preset (Pro)",
                   systemImage: store.hasPro ? "square.and.arrow.down" : "lock.fill") {
                if store.hasPro { onSaveGrade() } else { paywallFeature = .gradePresets }
            }
            .disabled(!model.canGrade)
        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
            .accessibilityLabel("Grade options")
            .paywallSheet($paywallFeature)
            .confirmationDialog("Already graded", isPresented: $confirmsPaste, titleVisibility: .visible) {
                Button("Add on Top") { model.pasteGrade(.addOnTop) }
                Button("Replace", role: .destructive) { model.pasteGrade(.replace) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Keep this grade and add the copied one, or replace it?")
            }
    }
}
