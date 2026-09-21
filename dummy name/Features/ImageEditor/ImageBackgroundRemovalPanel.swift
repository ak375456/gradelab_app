import SwiftUI

struct ImageBackgroundRemovalPanel: View {
    @ObservedObject var model: ImageEditorViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("REMOVE BACKGROUND").font(.caption.weight(.semibold)).tracking(1.2)
                HStack(spacing: 8) {
                    mode("Auto", "person.crop.rectangle", model.selectedBackgroundRemoval?.mode == .automatic,
                         model.startAutomaticBackgroundRemoval)
                    mode("Lasso", "lasso",
                         model.selectedBackgroundRemoval?.mode == .lasso || model.isDrawingBackgroundLasso,
                         model.armBackgroundLasso)
                    mode("Color", "eyedropper", model.selectedBackgroundRemoval?.mode == .colorKey,
                         model.useColorBackgroundRemoval)
                }
                if let progress = model.backgroundAnalysisProgress {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { ProgressView().controlSize(.small); Text("Analyzing Background"); Spacer(); Text("\(Int(progress.fraction*100))%").monospacedDigit() }
                        ProgressView(value: progress.fraction)
                        Button("Cancel", action: model.cancelBackgroundAnalysis).foregroundStyle(AppColors.accent)
                    }.font(.caption).padding(12).background(AppColors.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
                }
                if let message = model.backgroundAnalysisMessage {
                    Text(message).font(.caption).foregroundStyle(AppColors.textSecondary)
                }
                if let settings = model.selectedBackgroundRemoval {
                    if settings.mode == .lasso {
                        section("OUTLINE")
                        if settings.lasso?.isDrawn == true {
                            HStack(spacing: 8) {
                                lassoButton("Redraw", "lasso.badge.sparkles",
                                            model.isDrawingBackgroundLasso, model.armBackgroundLasso)
                                lassoButton("Clear", "xmark", false, model.clearBackgroundLasso)
                            }
                            Text("Everything outside the outline is removed. Turn on Invert to cut out the object instead.")
                                .font(.caption2).foregroundStyle(AppColors.textTertiary)
                        } else {
                            lassoButton("Draw Lasso", "lasso", true, model.armBackgroundLasso)
                            Text("Trace around the object on the picture. The shape closes itself when you lift your finger.")
                                .font(.caption2).foregroundStyle(AppColors.textTertiary)
                        }
                    }
                    if settings.mode == .colorKey {
                        section("COLOR")
                        Button(action: model.armBackgroundColorPicker) {
                            HStack { Label("Pick Key Color", systemImage: "eyedropper"); Spacer()
                                Circle().fill(Color(red: settings.colorKey.color.red,
                                                    green: settings.colorKey.color.green,
                                                    blue: settings.colorKey.color.blue)).frame(width: 24, height: 24) }
                                .frame(minHeight: 44)
                        }
                        slider("Similarity", model.backgroundRemovalBinding(\.colorKey.similarity), 0...100, reset: 38)
                        slider("Smoothness", model.backgroundRemovalBinding(\.colorKey.smoothness), 0...100, reset: 18)
                        slider("Spill", model.backgroundRemovalBinding(\.colorKey.spill), 0...100, reset: 35)
                    }
                    section("REFINE")
                    HStack(spacing: 8) { brush("Add", .add, "plus.circle"); brush("Remove", .remove, "minus.circle") }
                    if model.backgroundBrush != nil {
                        slider("Brush Size", $model.backgroundBrushSize, 0.005...0.20, reset: 0.04, percent: true)
                        slider("Softness", $model.backgroundBrushSoftness, 0...1, reset: 0.65, percent: true)
                    }
                    section("EDGE")
                    slider("Feather", model.backgroundRemovalBinding(\.feather), 0...100, reset: 0)
                    slider("Shift Edge", model.backgroundRemovalBinding(\.edgeShift), -100...100, reset: 0)
                    Toggle("Show Matte", isOn: $model.showsBackgroundMatte).frame(minHeight: 44)
                    Toggle("Invert", isOn: model.backgroundRemovalBinding(\.isInverted)).frame(minHeight: 44)
                    Button("Reset Refinement", action: model.resetBackgroundRefinement)
                        .frame(maxWidth: .infinity, minHeight: 44).background(AppColors.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                    Button(role: .destructive, action: model.removeBackgroundRemoval) {
                        Text("Remove Background Removal").frame(maxWidth: .infinity, minHeight: 44)
                    }.background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }
            }.padding(20)
        }.scrollIndicators(.visible)
    }

    private func lassoButton(_ title: LocalizedStringKey, _ symbol: String, _ prominent: Bool,
                             _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(prominent ? AppColors.accent.opacity(0.18) : AppColors.surfaceRaised,
                            in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(prominent ? AppColors.accent : AppColors.textPrimary)
        }
        .buttonStyle(.plain)
    }

    private func mode(_ title: LocalizedStringKey, _ symbol: String, _ selected: Bool,
                      _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) { Image(systemName: symbol); Text(title).font(.caption) }
                .frame(maxWidth: .infinity, minHeight: 62)
                .background(selected ? AppColors.accent.opacity(0.18) : AppColors.surfaceRaised,
                            in: RoundedRectangle(cornerRadius: 11))
                .foregroundStyle(selected ? AppColors.accent : AppColors.textPrimary)
        }
    }
    private func brush(_ title: LocalizedStringKey, _ kind: BackgroundRemovalBrush, _ symbol: String) -> some View {
        let selected = model.backgroundBrush == kind
        return Button {
            model.isDrawingBackgroundLasso = false
            model.backgroundBrush = selected ? nil : kind
        } label: {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, minHeight: 44)
                .background(selected ? AppColors.accent.opacity(0.18) : AppColors.surfaceRaised,
                            in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(selected ? AppColors.accent : AppColors.textPrimary)
        }
    }
    private func section(_ title: LocalizedStringKey) -> some View {
        Text(title).font(.caption.weight(.semibold)).tracking(1).foregroundStyle(AppColors.textSecondary)
            .padding(.top, 4)
    }
    private func slider(_ title: String, _ binding: Binding<Double>, _ range: ClosedRange<Double>, reset: Double,
                        percent: Bool = false) -> some View {
        let floatBinding = Binding<Float>(get: { Float(binding.wrappedValue) },
                                          set: { binding.wrappedValue = Double($0) })
        let span = range.upperBound - range.lowerBound
        return AdjustmentSlider(
            value: floatBinding, title: title,
            range: Float(range.lowerBound)...Float(range.upperBound),
            step: span <= 0.25 ? 0.001 : span <= 1 ? 0.01 : 1,
            neutralValue: Float(reset),
            valueFormatter: { percent ? "\(Int($0 * 100))%" : "\(Int($0))" })
    }
}

struct ImageBackgroundRemovalOverlay: View {
    @ObservedObject var model: ImageEditorViewModel
    let displayedRect: () -> CGRect?
    /// True while the preview is being pinched. The pinch's first finger lands
    /// as an ordinary drag here, so without this a zoom would leave a stray dab
    /// or replace the outline with however far that finger had travelled.
    var isZooming = false
    @State private var points: [MaskPoint] = []
    @State private var displayPoints: [CGPoint] = []

    private var isDrawingLasso: Bool { model.isDrawingBackgroundLasso }
    private var isArmed: Bool {
        model.backgroundBrush != nil || isDrawingLasso || model.isPickingBackgroundColor
    }
    /// The committed outline, shown whenever there is one: a lasso the user
    /// cannot see is a selection they cannot check or correct.
    private var committedOutline: [CGPoint]? {
        guard let settings = model.selectedBackgroundRemoval, settings.mode == .lasso,
              let lasso = settings.lasso, lasso.isDrawn, !isDrawingLasso else { return nil }
        return lasso.outline(atLocal: nil)
    }

    var body: some View {
        GeometryReader { proxy in
            let rect = pictureRect(proxy.size)
            ZStack {
                Canvas { context, _ in
                    if let outline = committedOutline {
                        var path = Path()
                        let placed = outline.map {
                            CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height)
                        }
                        guard let first = placed.first else { return }
                        path.move(to: first)
                        for point in placed.dropFirst() { path.addLine(to: point) }
                        path.closeSubpath()
                        context.stroke(path, with: .color(.black.opacity(0.55)), lineWidth: 3)
                        context.stroke(path, with: .color(AppColors.accent),
                                       style: .init(lineWidth: 1.5, dash: [6, 4]))
                    }
                    guard isDrawingLasso, displayPoints.count > 1 else { return }
                    var path = Path()
                    path.move(to: displayPoints[0])
                    for point in displayPoints.dropFirst() { path.addLine(to: point) }
                    context.stroke(path, with: .color(.black.opacity(0.55)),
                                   style: .init(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    context.stroke(path, with: .color(AppColors.accent),
                                   style: .init(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    if let last = displayPoints.last, let first = displayPoints.first {
                        var closing = Path()
                        closing.move(to: last); closing.addLine(to: first)
                        context.stroke(closing, with: .color(.white.opacity(0.75)),
                                       style: .init(lineWidth: 1.5, dash: [5, 5]))
                    }
                }.allowsHitTesting(false)
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard !isZooming else { points.removeAll(); displayPoints.removeAll(); return }
                            guard model.backgroundBrush != nil || isDrawingLasso else { return }
                            let p = normalized(value.location, size: proxy.size)
                            let step = isDrawingLasso ? 0.0008 : 0.002
                            guard points.last.map({ hypot($0.x - p.x, $0.y - p.y) > step }) ?? true else { return }
                            points.append(p)
                            displayPoints.append(value.location)
                        }
                        .onEnded { value in
                            let p = normalized(value.location, size: proxy.size)
                            defer { points.removeAll(); displayPoints.removeAll() }
                            guard !isZooming else { return }
                            if model.backgroundBrush != nil {
                                model.addBackgroundStroke(points.isEmpty ? [p] : points)
                            } else if isDrawingLasso {
                                model.commitBackgroundLasso(points)
                            } else if model.isPickingBackgroundColor {
                                model.pickBackgroundColor(at: CGPoint(x: p.x, y: p.y))
                            }
                        })
                    .allowsHitTesting(isArmed)
            }
        }
    }

    private func pictureRect(_ size: CGSize) -> CGRect {
        guard let value = displayedRect() else { return CGRect(origin: .zero, size: size) }
        return CGRect(x: value.minX * size.width, y: value.minY * size.height,
                      width: value.width * size.width, height: value.height * size.height)
    }

    private func normalized(_ point: CGPoint, size: CGSize) -> MaskPoint {
        let rect = pictureRect(size)
        return .init(x: min(max((point.x - rect.minX) / max(rect.width, 1), 0), 1),
                     y: min(max((point.y - rect.minY) / max(rect.height, 1), 0), 1))
    }
}
