import SwiftUI
import UniformTypeIdentifiers

/// The eight hue ranges. Each of the twenty-four values is an ordinary
/// animatable grading property, so every slider here carries the same diamond
/// the Transform tools do.
struct HSLPanel<Model: GradingModel>: View {
    @ObservedObject var model: Model
    @State private var selected = 0
    var body: some View {
        VStack(spacing: 18) {
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(0..<8) { i in
                        Button { selected = i } label: {
                            Circle().fill(Color(hue: Double(HueBand.centers[i])/360, saturation: 0.8, brightness: 0.95))
                                .frame(width: 24, height: 24).padding(5)
                                .overlay(Circle().stroke(selected == i ? Color.white : .clear, lineWidth: 2))
                                .overlay(alignment: .topTrailing) { animationDot(band: i) }
                                .frame(width: 44, height: 44)
                        }.accessibilityLabel(HueBand.names[i]).accessibilityAddTraits(selected == i ? .isSelected : [])
                    }
                }
            }.frame(height: 44).scrollIndicators(.hidden)
            Text(HueBand.names[selected]).font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
            // The slider offers the working range; the property itself stores a
            // wider one, so a hue arriving from elsewhere is never snapped by
            // being keyframed.
            slider(.hue, "Hue", -30...30) { "\(Int($0))°" }
            slider(.saturation, "Saturation", -100...100, AdjustmentValueFormatters.signed())
            slider(.luminance, "Lightness", -100...100, AdjustmentValueFormatters.signed())
        }
    }

    @ViewBuilder
    private func slider(
        _ component: HueBandComponent, _ title: String,
        _ range: ClosedRange<Float>, _ formatter: @escaping (Float) -> String
    ) -> some View {
        if let property = AnimatableProperty.hsl(band: selected, component) {
            GradeSlider(model: model, property: property, title: title,
                        range: range, valueFormatter: formatter)
        }
    }

    /// Marks a band that carries animation, so a hue range animating out of
    /// view is not invisible behind seven other swatches.
    @ViewBuilder
    private func animationDot(band: Int) -> some View {
        let animated = [HueBandComponent.hue, .saturation, .luminance].contains { component in
            AnimatableProperty.hsl(band: band, component)
                .map { model.keyframeHost?.keyframeState($0) != .off } ?? false
        }
        if animated {
            Circle().fill(AppColors.accent)
                .frame(width: 6, height: 6)
                .overlay(Circle().stroke(AppColors.editorBackground, lineWidth: 1))
                .accessibilityHidden(true)
        }
    }
}

/// Shadows, midtones and highlights. The wheel writes the MODEL values — hue
/// and strength — not raw touch coordinates, so what animates is what the
/// shader reads, and hue takes the short way round the circle.
struct WheelsPanel<Model: GradingModel>: View {
    @ObservedObject var model: Model
    @State private var selected = 0

    private func value(_ component: WheelComponent) -> Float {
        AnimatableProperty.wheel(index: selected, component)
            .map { model.gradeBinding($0).wrappedValue } ?? 0
    }

    var body: some View {
        VStack(spacing: 18) {
            Picker("Tonal range", selection: $selected) { Text("Shadows").tag(0); Text("Midtones").tag(1); Text("Highlights").tag(2) }.pickerStyle(.segmented)
            let hue = value(.hue), strength = value(.strength)
            ZStack {
                Circle().fill(AngularGradient(colors: (0...12).map { Color(hue: Double($0)/12, saturation: 0.9, brightness: 0.9) }, center: .center))
                Circle().fill(RadialGradient(colors: [AppColors.surfaceRaised, .clear], center: .center, startRadius: 0, endRadius: 88))
                Circle().stroke(.white.opacity(0.3), lineWidth: 1)
                Circle().fill(.white).frame(width: 12, height: 12).shadow(color: .black, radius: 2)
                    .offset(x: cos(Double(hue) * .pi / 180) * Double(strength) / 100 * 88,
                            y: sin(Double(hue) * .pi / 180) * Double(strength) / 100 * 88)
            }.frame(width: 176, height: 176).contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                    let x = gesture.location.x-88, y = gesture.location.y-88
                    write(.hue, Float((atan2(y, x)*180 / .pi + 360).truncatingRemainder(dividingBy: 360)))
                    write(.strength, Float(min(hypot(x, y)/88, 1)*100))
                })
                .accessibilityHidden(true)
                .disabled(!model.canGrade || !canEdit)
            slider(.hue, "Hue", 0...360) { "\(Int($0))°" }
            slider(.strength, "Color strength", 0...100) { "\(Int($0))%" }
            slider(.brightness, "Brightness", -100...100, AdjustmentValueFormatters.signed())
        }
    }

    /// A drag on the wheel moves two properties at once. Both go through the
    /// same write rule as their sliders, so dragging an animated wheel writes
    /// two keyframes at the playhead rather than overwriting the base values.
    private func write(_ component: WheelComponent, _ value: Float) {
        guard let property = AnimatableProperty.wheel(index: selected, component) else { return }
        model.gradeBinding(property).wrappedValue = value
    }

    private var canEdit: Bool {
        [WheelComponent.hue, .strength].allSatisfy { component in
            AnimatableProperty.wheel(index: selected, component)
                .map { model.canEditGradeValue($0) } ?? true
        }
    }

    @ViewBuilder
    private func slider(
        _ component: WheelComponent, _ title: String,
        _ range: ClosedRange<Float>, _ formatter: @escaping (Float) -> String
    ) -> some View {
        if let property = AnimatableProperty.wheel(index: selected, component) {
            GradeSlider(model: model, property: property, title: title,
                        range: range, valueFormatter: formatter)
        }
    }
}

/// Picks a creative look and sets its strength, and lists the user's saved
/// grade presets.
///
/// The two are kept apart on purpose. A look is a `.cube`: a colour transform,
/// and nothing else — grain, halation and vignette are not something it can
/// carry. A grade preset is the whole app grading state under a name. Putting
/// them in one list would suggest they are interchangeable, and they are not.
struct LUTPanel<Model: GradingModel>: View {
    @ObservedObject var model: Model
    /// Opens the save sheet, which lives with the editor so it can be reached
    /// from the options menu as well as from here.
    var onSaveGrade: () -> Void = {}
    @State private var isImporting = false
    @State private var confirmsRemoval = false
    @State private var section: LookSection = .looks

    private enum LookSection: String, CaseIterable, Identifiable {
        case looks = "Looks"
        case presets = "My Presets"
        var id: String { rawValue }
    }

    private var selected: LUTAsset? { model.selectedLook }

    /// `.cube` has no registered system type, so the picker asks for the dynamic
    /// type for that extension and falls back to any file. The extension and the
    /// contents are both checked on import, so a wrong pick is refused with a
    /// reason rather than stored.
    private var importableTypes: [UTType] {
        [UTType(filenameExtension: "cube"), .data].compactMap { $0 }
    }

    var body: some View {
        VStack(spacing: 14) {
            Picker("Section", selection: $section) {
                ForEach(LookSection.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            switch section {
            case .looks: sdrBody
            case .presets:
                MyPresetsGrid(model: model, presets: model.presets, onSaveGrade: onSaveGrade)
            }
        }
    }

    private var sdrBody: some View {
        VStack(spacing: 14) {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    lookTile(
                        title: "None",
                        preview: model.lookPreviews[LookPreviewKey.original],
                        isSelected: selected == nil
                    ) { model.selectLook(nil) }
                    ForEach(model.availableLooks) { asset in
                        lookTile(
                            title: asset.name,
                            preview: model.lookPreviews[asset.id],
                            isSelected: selected?.id == asset.id,
                            requiresPro: ProAccessPolicy.requiresPro(asset)
                        ) { model.selectLook(asset) }
                    }
                    Button { isImporting = true } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.down").font(.system(size: 20))
                                .foregroundStyle(ProStore.shared.hasPro ? AppColors.textSecondary : ProStyle.gold)
                                .frame(width: tileWidth, height: tileHeight)
                                .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(alignment: .topTrailing) {
                                    if !ProStore.shared.hasPro { ProBadge(compact: true).padding(4) }
                                }
                            if ProStore.shared.hasPro {
                                Text("Import").font(.caption2).lineLimit(1)
                            } else {
                                Text("Import").font(.caption2).lineLimit(1)
                                    .foregroundStyle(ProStyle.gold)
                            }
                        }
                    }
                    .buttonStyle(.plain).foregroundStyle(AppColors.textSecondary)
                    .accessibilityLabel("Import a look from Files")
                }.padding(.horizontal, 2)
            }.frame(height: tileHeight + 22).scrollIndicators(.hidden)

            if let selected {
                // The look itself stays a discrete choice; its strength is an
                // ordinary animatable value, which is what a look fade-in is.
                GradeSlider(
                    model: model,
                    property: .gradeLookIntensity,
                    title: "Strength",
                    range: 0...100,
                    neutral: 100,
                    valueFormatter: { "\(Int($0))%" }
                )
                Text(selected.summary)
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Text("Built for \(selected.inputColorSpace) footage. Applied before the other tools.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if selected.origin == .device {
                        Button("Remove", role: .destructive) { confirmsRemoval = true }
                            .font(.caption).frame(height: 44)
                    }
                }
            } else {
                Text("No look applied. Choose one above, import a .cube file from Files, then use the other tools to fine-tune.")
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { model.refreshLookPreviews(force: false) }
        .onChange(of: model.gradeSubjectID) { _, _ in model.refreshLookPreviews(force: false) }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: importableTypes, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): model.importLooks(from: urls)
            case .failure(let error): model.editError = error.localizedDescription
            }
        }
        .confirmationDialog(
            "Remove “\(selected?.name ?? "")” from this device?",
            isPresented: $confirmsRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Look", role: .destructive) {
                if let selected { model.removeLook(selected) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The .cube file is deleted from the app. Any clip using it goes back to no look.")
        }
    }

    private var tileWidth: CGFloat { LookTileMetrics.width }
    private var tileHeight: CGFloat { LookTileMetrics.height }

    /// One entry in the strip: the current frame with that look applied, so the
    /// choice is made by eye rather than by name. The thumbnail appears when it
    /// finishes rendering; until then the tile shows a placeholder rather than
    /// jumping the layout.
    private func lookTile(
        title: String,
        preview: UIImage?,
        isSelected: Bool,
        requiresPro: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let marked = requiresPro && !ProStore.shared.hasPro
        return Button(action: action) {
            VStack(spacing: 6) {
                Group {
                    if let preview {
                        Image(uiImage: preview).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        AppColors.surface
                    }
                }
                .frame(width: tileWidth, height: tileHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? AppColors.textPrimary : .white.opacity(0.12),
                                lineWidth: isSelected ? 2 : 1)
                )
                // The thumbnail itself is never covered: the whole point of the
                // strip is choosing a look by eye, and a Pro look is free to
                // try on your own frame. Only the corner says it costs money.
                .overlay(alignment: .topTrailing) {
                    if marked { ProBadge(compact: true).padding(4) }
                }
                Text(title).font(.caption2).lineLimit(1).frame(width: tileWidth + 12)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? AppColors.textPrimary : AppColors.textSecondary)
        .accessibilityLabel(marked ? "\(title). Pro feature" : title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}


/// Look-strip tile size. A plain constant rather than a static on `LUTPanel`,
/// which is generic over its model and so cannot hold stored statics.
private enum LookTileMetrics {
    static let width: CGFloat = 56
    static let height: CGFloat = 56
}
