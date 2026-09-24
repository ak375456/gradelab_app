import SwiftUI

/// The Masks tool: add a window, pick which one the Color controls are pointed
/// at, and shape it.
///
/// There are no colour controls here on purpose. A mask's grade is edited with
/// the Light, Color, Curves, HSL and Wheels tools this tab already has — the
/// only thing selecting a mask changes is which grading state those write into.
struct MaskPanel: View {
    @ObservedObject var model: EditorViewModel
    @State private var renaming: UUID?
    @State private var draftName = ""
    @State private var confirmsDelete: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.standard) {
            if let session = model.maskTrackingSession {
                trackingProgress(session)
            }
            addRow
            if model.maskedGrades.isEmpty {
                emptyHint
            } else {
                maskList
                if let mask = model.selectedMask {
                    Rectangle().fill(AppColors.separator).frame(height: 1)
                    MaskInspector(model: model, mask: mask, confirmsDelete: $confirmsDelete)
                        .disabled(!model.canGrade)
                } else {
                    Text("Select a mask to grade it. With none selected, every control in this tab changes the whole clip.")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textSecondary)
                }
            }
        }
        .confirmationDialog("Replace existing mask motion in this range?", isPresented: Binding(
            get: { model.pendingMaskTracking != nil },
            set: { if !$0 { model.pendingMaskTracking = nil } }
        ), titleVisibility: .visible) {
            Button("Replace Tracking Range", role: .destructive) { model.confirmMaskTracking() }
            Button("Cancel", role: .cancel) { model.pendingMaskTracking = nil }
        } message: {
            Text("Position and size animation will be replaced only over successfully tracked frames. Rotation, feather, strength and local grading are preserved.")
        }
        .alert("Rename mask", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let id = renaming { model.renameMask(id, to: draftName) }
                renaming = nil
            }
        }
        .confirmationDialog(
            "Delete this mask?",
            isPresented: Binding(get: { confirmsDelete != nil }, set: { if !$0 { confirmsDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Mask", role: .destructive) {
                if let id = confirmsDelete { model.deleteMask(id) }
                confirmsDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmsDelete = nil }
        } message: {
            Text("The window and its own colour adjustments are removed. The clip's main grade is untouched, and Undo brings the mask back.")
        }
    }

    private func trackingProgress(_ session: MaskTrackingSession) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Tracking \(session.name)")
                        .font(AppTypography.bodyEmphasized).lineLimit(1)
                    Text(session.stopping ? "Stopping · keeping successful motion" :
                         session.progress.preparing ? "Preparing source frames" :
                         "\(session.progress.direction == .backward ? "Backward" : "Forward") · \(session.progress.frames) frames")
                        .font(.caption2).foregroundStyle(AppColors.textSecondary)
                }
                Spacer(minLength: 8)
                Text("\(Int(session.progress.fraction * 100))%")
                    .font(AppTypography.caption.monospacedDigit())
                Button("Stop", systemImage: "stop.fill") { model.stopMaskTracking() }
                    .font(AppTypography.caption.weight(.semibold))
                    .frame(minWidth: 60, minHeight: 44)
                    .disabled(session.stopping)
            }
            ProgressView(value: session.progress.fraction).tint(AppColors.accent)
                .accessibilityLabel("Mask tracking progress")
        }
        .padding(AppSpacing.compact)
        .appSurface(fill: AppColors.accentMuted, border: AppColors.accent.opacity(0.3))
    }

    // MARK: - Add

    private var addRow: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            AppSectionHeader("Add mask") {}
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: AppSpacing.small), count: 4),
                      spacing: AppSpacing.small) {
                ForEach(MaskShape.allCases) { shape in
                    Button { model.addMask(shape) } label: {
                        VStack(spacing: 5) {
                            Image(systemName: shape.symbol).font(.system(size: 16))
                            Text(shape.title).font(.caption2.weight(.medium)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity).frame(height: 58)
                        .foregroundStyle(AppColors.textPrimary)
                        .appSurface(cornerRadius: AppCornerRadius.control, fill: AppColors.surfaceRaised)
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canAddMask)
                    .opacity(model.canAddMask ? 1 : 0.4)
                    .accessibilityLabel("Add \(shape.title) mask")
                }
            }
        }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("No masks on this clip.")
                .font(AppTypography.bodyEmphasized)
            Text("Add one, drag it over the part of the picture you want to change, then use Light and Color as usual — only that area moves.")
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.compact)
        .appSurface()
    }

    // MARK: - List

    private var maskList: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            AppSectionHeader("Masks") {}
            // List order is composition order, so it is stated rather than left
            // to be discovered.
            Text("Applied top to bottom, over your main grade.")
                .font(.caption2)
                .foregroundStyle(AppColors.textSecondary)
            VStack(spacing: 4) {
                ForEach(model.maskedGrades) { mask in
                    row(mask)
                }
            }
        }
    }

    private func row(_ mask: MaskedGradeLayer) -> some View {
        let isSelected = model.selectedMaskID == mask.id
        return HStack(spacing: AppSpacing.small) {
            Button {
                model.selectMask(isSelected ? nil : mask.id)
            } label: {
                HStack(spacing: AppSpacing.small) {
                    Image(systemName: mask.geometry.shape.symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(isSelected ? AppColors.accent : AppColors.textSecondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(mask.name)
                            .font(AppTypography.bodyEmphasized)
                            .foregroundStyle(mask.isEnabled ? AppColors.textPrimary : AppColors.textDisabled)
                            .lineLimit(1)
                        Text(subtitle(mask))
                            .font(.caption2)
                            .foregroundStyle(AppColors.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                model.setMaskEnabled(mask.id, !mask.isEnabled)
            } label: {
                Image(systemName: mask.isEnabled ? "eye" : "eye.slash")
                    .font(.system(size: 14))
                    .foregroundStyle(mask.isEnabled ? AppColors.textPrimary : AppColors.textDisabled)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(mask.isEnabled ? "Hide \(mask.name)" : "Show \(mask.name)")
        }
        .padding(.leading, AppSpacing.compact)
        .frame(minHeight: 52)
        .background(isSelected ? AppColors.accentMuted : AppColors.surface,
                    in: RoundedRectangle(cornerRadius: AppCornerRadius.control))
        .overlay(
            RoundedRectangle(cornerRadius: AppCornerRadius.control)
                .stroke(isSelected ? AppColors.accent.opacity(0.5) : AppColors.border, lineWidth: 1))
        .contextMenu {
            Button("Rename", systemImage: "pencil") { draftName = mask.name; renaming = mask.id }
            Button("Duplicate", systemImage: "plus.square.on.square") { model.duplicateMask(mask.id) }
            Button("Reset Mask Grade", systemImage: "arrow.uturn.backward") { model.resetMaskGrade(mask.id) }
            Divider()
            Button("Delete Mask", systemImage: "trash", role: .destructive) { confirmsDelete = mask.id }
                .disabled(model.isTrackingMask(mask.id))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Says what the mask is doing, not what it is made of: whether its grade is
    /// still neutral is the thing a user actually needs to know.
    private func subtitle(_ mask: MaskedGradeLayer) -> String {
        var parts = [mask.geometry.shape.title]
        if mask.geometry.isInverted { parts.append(String(localized: "inverted")) }
        if !mask.localGrade.hasCreativeChangeIgnoringMask && !mask.hasGradeAnimation {
            parts.append(String(localized: "no grade yet"))
        } else if mask.resolvedStrength < 1 {
            parts.append("\(Int((mask.resolvedStrength * 100).rounded()))%")
        }
        // A mask whose colour animates is doing something the list would
        // otherwise describe as neutral at whichever frame is showing.
        if mask.hasGradeAnimation { parts.append(String(localized: "animated grade")) }
        else if mask.isAnimated { parts.append(String(localized: "animated")) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Inspector

/// One mask's window controls. Geometry only — its colour is the rest of the tab.
private struct MaskInspector: View {
    @ObservedObject var model: EditorViewModel
    let mask: MaskedGradeLayer
    @Binding var confirmsDelete: UUID?

    private var shape: MaskShape { mask.geometry.shape }
    private var isMatte: Bool { model.maskMatteID == mask.id }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.standard) {
            AppSectionHeader(LocalizedStringKey(mask.name)) {}

            if !mask.localGrade.hasCreativeChangeIgnoringMask && !mask.hasGradeAnimation {
                neutralHint
            }

            viewToggles

            Picker("Apply grade", selection: Binding(
                get: { mask.geometry.isInverted },
                set: { value in model.updateMask(mask.id, label: "Invert Mask", immediate: true) { $0.geometry.isInverted = value } }
            )) {
                Text("Inside").tag(false)
                Text("Outside").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(model.isTrackingMask(mask.id))

            if shape == .freehand { freehandControls.disabled(model.isTrackingMask(mask.id)) }

            MaskTrackingControls(model: model, mask: mask)

            geometryControls.disabled(model.isTrackingMask(mask.id))

            qualifierControls

            HStack(spacing: AppSpacing.small) {
                Button("Reset Mask Grade") { model.resetMaskGrade(mask.id) }
                    .font(AppTypography.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(AppColors.surfaceRaised, in: RoundedRectangle(cornerRadius: AppCornerRadius.control))
                    .foregroundStyle(AppColors.textPrimary)
                Button("Delete Mask") { confirmsDelete = mask.id }
                    .disabled(model.isTrackingMask(mask.id))
                    .font(AppTypography.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(AppColors.surfaceRaised, in: RoundedRectangle(cornerRadius: AppCornerRadius.control))
                    .foregroundStyle(AppColors.destructive)
            }
            .buttonStyle(.plain)
        }
    }

    /// The colour qualifier: select by what a pixel is, not where it is.
    ///
    /// Folded into the mask inspector rather than given a tool of its own
    /// because the two are the same idea — both decide which pixels this
    /// layer's grade reaches — and because combining them is the point: a key
    /// restricted to a window is how you grade one person's skin and not
    /// everybody's.
    @ViewBuilder
    private var qualifierControls: some View {
        let key = mask.qualifier ?? .skin
        VStack(alignment: .leading, spacing: AppSpacing.compact) {
            Toggle(isOn: Binding(
                get: { key.isEnabled },
                set: { model.setMaskQualifierEnabled(mask.id, $0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Colour Selection").font(AppTypography.caption.weight(.semibold))
                    Text("Grade only pixels of a chosen colour.")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textTertiary)
                }
            }
            .tint(AppColors.accent)

            if key.isEnabled {
                Button {
                    model.isPickingMaskQualifier.toggle()
                } label: {
                    HStack(spacing: AppSpacing.small) {
                        Image(systemName: "eyedropper")
                        Text(model.isPickingMaskQualifier ? "Tap the picture…" : "Pick Colour")
                    }
                    .font(AppTypography.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(model.isPickingMaskQualifier ? AppColors.accent.opacity(0.18)
                                                            : AppColors.surfaceRaised,
                                in: RoundedRectangle(cornerRadius: AppCornerRadius.control))
                    .foregroundStyle(model.isPickingMaskQualifier ? AppColors.accent
                                                                  : AppColors.textPrimary)
                }
                .buttonStyle(.plain)

                qualifierSlider("Hue", \.hueCenter, 0...360, "°")
                qualifierSlider("Hue range", \.hueRange, 1...180, "°")
                qualifierSlider("Saturation from", \.saturationMin, 0...1, "%", scale: 100)
                qualifierSlider("Saturation to", \.saturationMax, 0...1, "%", scale: 100)
                qualifierSlider("Luma from", \.lumaMin, 0...1, "%", scale: 100)
                qualifierSlider("Luma to", \.lumaMax, 0...1, "%", scale: 100)
                qualifierSlider("Softness", \.softness, 0...1, "%", scale: 100)

                Toggle("Invert selection", isOn: model.maskQualifierFlagBinding(mask.id, \.isInverted))
                    .font(AppTypography.caption)
                    .tint(AppColors.accent)
                Toggle("Whole frame", isOn: model.maskQualifierFlagBinding(mask.id, \.ignoresShape))
                    .font(AppTypography.caption)
                    .tint(AppColors.accent)
            }
        }
        .padding(AppSpacing.compact)
        .background(AppColors.surface, in: RoundedRectangle(cornerRadius: AppCornerRadius.control))
    }

    private func qualifierSlider(
        _ title: String,
        _ keyPath: WritableKeyPath<ColorQualifier, Double>,
        _ range: ClosedRange<Double>,
        _ suffix: String,
        scale: Double = 1
    ) -> some View {
        let binding = model.maskQualifierBinding(mask.id, keyPath)
        return AdjustmentSlider(
            value: Binding(get: { Float(binding.wrappedValue * scale) },
                           set: { binding.wrappedValue = Double($0) / scale }),
            title: title,
            range: Float(range.lowerBound * scale)...Float(range.upperBound * scale),
            step: 1,
            valueFormatter: { "\(Int($0))\(suffix)" }
        )
    }

    private var neutralHint: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill").foregroundStyle(AppColors.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("This mask is placed, but its grade is neutral.")
                    .font(AppTypography.caption.weight(.semibold))
                Text("Open Light or Color and move a slider — it will change only this area.")
                    .font(.caption2)
                    .foregroundStyle(AppColors.textSecondary)
            }
            Spacer(minLength: 0)
            Button("Light") { model.selectedPanel = .light }
                .font(AppTypography.caption.weight(.semibold))
                .foregroundStyle(AppColors.accent)
                .frame(minWidth: 44, minHeight: 44)
        }
        .padding(AppSpacing.compact)
        .appSurface(fill: AppColors.accentMuted, border: AppColors.accent.opacity(0.30))
    }

    /// Show Matte and the coverage tint. Both are editor guides: neither is ever
    /// composited into a frame, and the exporters cannot reach either one.
    private var viewToggles: some View {
        HStack(spacing: AppSpacing.small) {
            toggle(String(localized: "Show Mask"), systemImage: "circle.righthalf.filled", isOn: isMatte) {
                model.maskMatteID = isMatte ? nil : mask.id
            }
            toggle(String(localized: "Overlay"), systemImage: "square.on.square.dashed", isOn: model.showsMaskOverlay) {
                model.showsMaskOverlay.toggle()
            }
        }
    }

    private func toggle(_ title: String, systemImage: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(AppTypography.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(isOn ? AppColors.accentMuted : AppColors.surfaceRaised,
                            in: RoundedRectangle(cornerRadius: AppCornerRadius.control))
                .foregroundStyle(isOn ? AppColors.accent : AppColors.textPrimary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var freehandControls: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            HStack(spacing: AppSpacing.small) {
                Button(model.isDrawingMask ? "Done Drawing" : "Draw Points") {
                    if model.isDrawingMask { model.finishDrawingMask(mask.id) }
                    else { model.isDrawingMask = true }
                }
                .font(AppTypography.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(model.isDrawingMask ? AppColors.accentMuted : AppColors.surfaceRaised,
                            in: RoundedRectangle(cornerRadius: AppCornerRadius.control))
                .foregroundStyle(model.isDrawingMask ? AppColors.accent : AppColors.textPrimary)

                Button("Clear Shape") { model.clearMaskPoints(mask.id) }
                    .font(AppTypography.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(AppColors.surfaceRaised, in: RoundedRectangle(cornerRadius: AppCornerRadius.control))
                    .foregroundStyle(AppColors.textPrimary)
            }
            .buttonStyle(.plain)
            Text(model.isDrawingMask
                 ? "Tap around the subject on the picture. Three points or more make a shape; tap a point to remove it once you are done."
                 : "\(mask.geometry.points.count) points. Drag a point on the picture to move it, or drag inside the shape to move the whole mask.")
                .font(.caption2)
                .foregroundStyle(AppColors.textSecondary)
        }
    }

    private var geometryControls: some View {
        VStack(alignment: .leading, spacing: AppSpacing.compact) {
            Text(shape == .linear
                 ? "Drag the line on the picture to place it; rotate to change its direction."
                 : "Drag the shape on the picture to position it.")
                .font(.caption2)
                .foregroundStyle(AppColors.textSecondary)

            slider(.localMaskPositionX, "Position X", 0...1, 100, "%")
            slider(.localMaskPositionY, "Position Y", 0...1, 100, "%")
            if shape != .linear {
                slider(.localMaskWidth, shape == .freehand ? "Scale X" : "Width", 0.01...2, 100, "%")
                slider(.localMaskHeight, shape == .freehand ? "Scale Y" : "Height", 0.01...2, 100, "%")
            }
            slider(.localMaskRotation, "Rotation", -180...180, 1, "°")
            if shape.hasCornerRadius {
                slider(.localMaskCornerRadius, "Corner radius", 0...1, 100, "%")
            }
            slider(.localMaskFeather, "Feather", 0...1, 100, "%")
            slider(.localMaskStrength, "Strength", 0...1, 100, "%")
        }
    }

    /// One geometry row, with its keyframe diamond.
    ///
    /// The diamond drives the project's own keyframe engine — the same tracks,
    /// interpolation and clip-local times transform animation uses — so a mask
    /// can be moved by hand across a shot today, and driven by a tracker later,
    /// without either one needing a second animation system.
    private func slider(
        _ property: AnimatableProperty,
        _ title: String,
        _ range: ClosedRange<Double>,
        _ scale: Double,
        _ suffix: String
    ) -> some View {
        let state = model.maskKeyframeState(mask.id, property)
        return VStack(spacing: 4) {
            AdjustmentSlider(
                value: Binding(
                    get: { Float(model.maskGeometryBinding(mask.id, property).wrappedValue * scale) },
                    set: { model.setMaskValue(mask.id, property, Double($0) / scale) }
                ),
                title: title,
                range: Float(range.lowerBound * scale)...Float(range.upperBound * scale),
                step: 1,
                neutralValue: Float((property.defaultValue.number ?? 0) * scale),
                valueFormatter: { "\(Int($0.rounded()))\(suffix)" }
            )
            HStack(spacing: AppSpacing.small) {
                Button {
                    model.toggleMaskKeyframe(mask.id, property)
                } label: {
                    Image(systemName: state == .onKeyframe ? "diamond.fill" : "diamond")
                        .font(.system(size: 11))
                        .foregroundStyle(state == .off ? AppColors.textTertiary : AppColors.accent)
                        .frame(width: 44, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.isPlayheadInsideSelection)
                .accessibilityLabel("\(title) keyframe")

                if state != .off {
                    Text("Animated")
                        .font(.caption2)
                        .foregroundStyle(AppColors.accent)
                    Button("Remove") { model.removeMaskAnimation(mask.id, property) }
                        .font(.caption2.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(AppColors.textSecondary)
                        .frame(minHeight: 32)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// Compact motion controls live with the selected window, beside manual animation.
private struct MaskTrackingControls: View {
    @ObservedObject var model: EditorViewModel
    let mask: MaskedGradeLayer
    @State private var confirmsClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            AppSectionHeader("Tracking") {}
            if mask.geometry.shape == .linear {
                Text("Tracking is available for Ellipse, Rectangle and Freehand windows.")
                    .font(.caption2).foregroundStyle(AppColors.textSecondary)
            } else {
                Text("Place the mask over your subject. Tracking starts at the playhead.")
                    .font(.caption2).foregroundStyle(AppColors.textSecondary)
                HStack(spacing: AppSpacing.small) {
                    trackButton(.backward, symbol: "backward.end.fill", title: "Backward")
                    trackButton(.forward, symbol: "forward.end.fill", title: "Forward")
                }
                trackButton(.both, symbol: "arrow.left.and.right", title: "Track Both Directions")
                if !mask.geometry.isRenderable {
                    Text("Finish drawing at least three points to track this window.")
                        .font(.caption2).foregroundStyle(AppColors.textSecondary)
                } else if !model.isPlayheadInsideSelection {
                    Text("Move the playhead inside this clip to choose a reference frame.")
                        .font(.caption2).foregroundStyle(AppColors.textSecondary)
                }
            }
            if let notice = model.maskTrackingNotice,
               notice.clipID == model.selectedClipID, notice.maskID == mask.id {
                VStack(alignment: .leading, spacing: 6) {
                    Text(notice.text).font(AppTypography.caption)
                        .foregroundStyle(AppColors.textSecondary)
                    if let direction = notice.continueDirection {
                        Button(direction == .backward ? "Continue Backward" : "Continue Forward") {
                            model.requestMaskTracking(direction)
                        }
                        .font(AppTypography.caption.weight(.semibold))
                        .frame(minHeight: 44)
                        .disabled(!model.canTrackSelectedMask)
                    }
                }
                .padding(AppSpacing.compact).appSurface()
            }
            if mask.animation?.tracks.contains(where: { MaskedGradeLayer.geometryProperties.contains($0.property) }) == true {
                Button("Clear Mask Geometry Animation") { confirmsClear = true }
                    .font(AppTypography.caption).foregroundStyle(AppColors.textSecondary)
                    .frame(minHeight: 44)
                    .disabled(model.isTrackingMask(mask.id))
            }
        }
        .confirmationDialog("Clear mask geometry animation?", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("Clear Geometry Animation", role: .destructive) { model.clearMaskGeometryAnimation(mask.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes manual and tracked position, size, rotation, corner radius, feather and strength keyframes. Keeps the current shape and all local grading animation. Undo restores the motion.")
        }
    }

    private func trackButton(_ direction: MaskTrackingDirection, symbol: String, title: String) -> some View {
        Button { model.requestMaskTracking(direction) } label: {
            Label(title, systemImage: symbol)
                .font(AppTypography.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(AppColors.surfaceRaised, in: RoundedRectangle(cornerRadius: AppCornerRadius.control))
                .foregroundStyle(model.canTrackSelectedMask ? AppColors.textPrimary : AppColors.textDisabled)
        }
        .buttonStyle(.plain)
        .disabled(!model.canTrackSelectedMask)
        .accessibilityLabel(direction.title)
    }
}
