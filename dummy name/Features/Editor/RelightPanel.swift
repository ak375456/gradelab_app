import SwiftUI
import UIKit

/// The Relight tool.
///
/// One panel serves every device, laid out by the room it has. A Mac or an
/// iPad inspector shows everything at once — analysis, presets, the light
/// list, the selected light and the scene — because that is how a desktop
/// lighting panel reads. A phone splits the same controls into three short
/// sections so the picture keeps its room. The controls themselves are the
/// same views on all three.
struct RelightPanel: View {
    @ObservedObject var model: EditorViewModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var section: CompactSection = .lights
    @State private var renaming: UUID?
    @State private var draftName = ""
    @State private var confirmsDelete: UUID?
    @State private var confirmsClearCache = false
    @State private var showsAdvanced = false

    private enum CompactSection: String, CaseIterable, Identifiable {
        case lights, light, scene
        var id: String { rawValue }
        var title: String {
            switch self {
            case .lights: String(localized: "Lights")
            case .light: String(localized: "Adjust")
            case .scene: String(localized: "Scene")
            }
        }
    }

    private var isCompact: Bool { sizeClass == .compact && !AppPlatform.isMac }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let reason = model.relightUnavailableReason {
                unavailable(reason)
            } else {
                analysisCard
                if isCompact {
                    Picker("Section", selection: $section) {
                        ForEach(CompactSection.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    switch section {
                    case .lights:
                        presets
                        lightList
                    case .light:
                        if let light = model.selectedLight { LightInspector(model: model, light: light,
                                                                            showsAdvanced: $showsAdvanced,
                                                                            confirmsDelete: $confirmsDelete,
                                                                            isCompact: true) }
                        else { selectHint }
                    case .scene:
                        sceneControls
                    }
                } else {
                    presets
                    lightList
                    if let light = model.selectedLight {
                        Rectangle().fill(AppColors.separator).frame(height: 1)
                        LightInspector(model: model, light: light, showsAdvanced: $showsAdvanced,
                                       confirmsDelete: $confirmsDelete, isCompact: false)
                    } else if !model.relightLights.isEmpty {
                        selectHint
                    }
                    Rectangle().fill(AppColors.separator).frame(height: 1)
                    sceneControls
                }
                footer
            }
        }
        .alert("Rename light", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let id = renaming { model.renameLight(id, to: draftName) }
                renaming = nil
            }
        }
        .confirmationDialog("Delete this light?",
                            isPresented: Binding(get: { confirmsDelete != nil },
                                                 set: { if !$0 { confirmsDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Light", role: .destructive) {
                if let id = confirmsDelete { model.deleteLight(id) }
                confirmsDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmsDelete = nil }
        } message: {
            Text("The light and its keyframes are removed. Undo brings it back.")
        }
        .confirmationDialog("Clear this clip's scene analysis?", isPresented: $confirmsClearCache,
                            titleVisibility: .visible) {
            Button("Clear Analysis", role: .destructive) { model.clearRelightCache() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The stored depth is deleted at both qualities. Your lights are kept; they light nothing until the scene is analysed again.")
        }
        .onChange(of: model.selectedLightID) { _, id in
            // On a phone, picking a light is a request to adjust it.
            if isCompact, id != nil, section == .lights { section = .light }
        }
    }

    // MARK: - Unavailable

    private func unavailable(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Relight is not available here", systemImage: "lightbulb.slash")
                .font(AppTypography.caption.weight(.semibold))
                .foregroundStyle(AppColors.accent)
            Text(reason).font(.caption2).foregroundStyle(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(AppColors.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Analysis

    @ViewBuilder
    private var analysisCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isAnalyzingSelectedClip, let progress = model.relightProgress {
                analysingRow(progress)
            } else {
                analysisStatus
            }
            VStack(alignment: .leading, spacing: 4) {
                Picker("Preview quality", selection: Binding(
                    get: { model.relightQuality },
                    set: { model.setRelightQuality($0) })) {
                    ForEach(RelightQuality.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("How finely the preview analyses and draws depth. Export always uses High.")
                    .font(.caption2).foregroundStyle(AppColors.textTertiary)
            }
            if let notice = model.relightNotice {
                Text(notice).font(.caption2).foregroundStyle(AppColors.destructive)
            }
        }
        .padding(12)
        .background(AppColors.surface, in: RoundedRectangle(cornerRadius: AppCornerRadius.control))
    }

    private func analysingRow(_ progress: RelightAnalysisProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(progress.isThermallyPaused ? "Paused — the device is hot"
                         : progress.isPreparing ? "Preparing scene analysis" : "Analysing scene")
                        .font(AppTypography.bodyEmphasized)
                    Text(progress.totalFrames > 0
                         ? "\(progress.frames) of \(progress.totalFrames) frames · lights work as it fills in"
                         : "Starting at the playhead")
                        .font(.caption2).foregroundStyle(AppColors.textSecondary)
                }
                Spacer(minLength: 8)
                Text("\(Int((progress.fraction * 100).rounded()))%")
                    .font(AppTypography.caption.monospacedDigit())
                Button("Cancel", systemImage: "stop.fill") { model.cancelRelightAnalysis() }
                    .font(AppTypography.caption.weight(.semibold))
                    .frame(minWidth: 60, minHeight: 44)
            }
            ProgressView(value: progress.fraction)
                .tint(progress.isThermallyPaused ? AppColors.textSecondary : AppColors.accent)
                .accessibilityLabel("Scene analysis progress")
        }
    }

    @ViewBuilder
    private var analysisStatus: some View {
        let coverage = model.relightCoverage(model.relightQuality) ?? 0
        let other: RelightQuality = model.relightQuality == .high ? .fast : .high
        let otherCoverage = model.relightCoverage(other) ?? 0
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: coverage > 0.995 ? "checkmark.circle.fill" : "cube.transparent")
                .foregroundStyle(coverage > 0.995 ? AppColors.accent : AppColors.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                if coverage > 0.995 {
                    Text("Scene analysed").font(AppTypography.bodyEmphasized)
                } else if coverage > 0.005 {
                    Text("Partly analysed · \(Int((coverage * 100).rounded()))%").font(AppTypography.bodyEmphasized)
                } else if otherCoverage > 0.005 {
                    Text("Analysed at \(other.title)").font(AppTypography.bodyEmphasized)
                } else {
                    Text("Scene not analysed yet").font(AppTypography.bodyEmphasized)
                }
                Text(estimatorLine)
                    .font(.caption2).foregroundStyle(AppColors.textSecondary)
            }
            Spacer(minLength: 0)
        }
        HStack(spacing: 8) {
            if coverage <= 0.995 {
                Button {
                    model.analyzeRelight()
                } label: {
                    Label(coverage > 0.005 ? "Continue Analysis" : "Analyze Scene", systemImage: "wand.and.rays")
                        .font(AppTypography.caption.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(AppColors.accent.opacity(0.18),
                                    in: RoundedRectangle(cornerRadius: AppCornerRadius.control))
                        .foregroundStyle(AppColors.accent)
                }
                .buttonStyle(.plain)
            } else {
                Button("Re-analyze") { model.analyzeRelight(restart: true) }
                    .font(AppTypography.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(AppColors.surfaceRaised, in: RoundedRectangle(cornerRadius: AppCornerRadius.control))
                    .foregroundStyle(AppColors.textPrimary)
                    .buttonStyle(.plain)
            }
            if coverage > 0.005 || otherCoverage > 0.005 {
                Button("Clear") { confirmsClearCache = true }
                    .font(AppTypography.caption.weight(.semibold))
                    .frame(minWidth: 72, minHeight: 44)
                    .background(AppColors.surfaceRaised, in: RoundedRectangle(cornerRadius: AppCornerRadius.control))
                    .foregroundStyle(AppColors.textSecondary)
                    .buttonStyle(.plain)
            }
        }
        .disabled(!model.canEditRelight)
    }

    private var estimatorLine: String {
        if let manifest = model.relightManifest {
            return String(localized: "\(manifest.estimator.title) · \(manifest.quality.title) · stored on this device, not in the project")
        }
        return RelightCoreMLEstimator.isInstalled
            ? String(localized: "Uses the installed Core ML depth model. Runs once, in the background, from the playhead.")
            : String(localized: "Uses the built-in scene geometry, strongest on people. Runs once, in the background, from the playhead.")
    }

    // MARK: - Presets

    private var presets: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PRESETS").font(.caption.weight(.semibold)).tracking(1.2)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(RelightPreset.all) { preset in
                        Button { model.applyRelightPreset(preset) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: preset.symbol).font(.system(size: 12))
                                Text(preset.title)
                            }
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14).frame(height: 38)
                            .background(AppColors.surfaceRaised, in: Capsule())
                            .contentShape(Capsule())
                            .foregroundStyle(AppColors.textPrimary)
                        }
                        .buttonStyle(.plain)
                        .disabled(!model.canEditRelight)
                        .help(preset.summary)
                        .accessibilityHint(preset.summary)
                    }
                }
                .padding(.horizontal, 1)
            }
            .frame(height: 42).scrollIndicators(.hidden)
            Text("A preset replaces this clip's lights. Every value it sets is an ordinary one you can change.")
                .font(.caption2).foregroundStyle(AppColors.textTertiary)
        }
    }

    // MARK: - Lights

    private var lightList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("LIGHTS").font(.caption.weight(.semibold)).tracking(1.2)
                Spacer()
                if !model.relightLights.isEmpty {
                    Toggle("Relight", isOn: Binding(
                        get: { model.relightSettings?.isEnabled ?? true },
                        set: { model.setRelightEnabled($0) }))
                    .labelsHidden()
                    .tint(AppColors.accent)
                    .disabled(!model.canEditRelight)
                    .accessibilityLabel("Relight on")
                }
            }
            HStack(spacing: 8) {
                ForEach(RelightLightType.allCases) { type in
                    Button { model.addLight(type) } label: {
                        VStack(spacing: 5) {
                            Image(systemName: type.symbol).font(.system(size: 16))
                            Text(type.title).font(.caption2.weight(.medium)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity).frame(height: isCompact ? 60 : 54)
                        .foregroundStyle(AppColors.textPrimary)
                        .appSurface(cornerRadius: AppCornerRadius.control, fill: AppColors.surfaceRaised)
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canAddLight)
                    .opacity(model.canAddLight ? 1 : 0.4)
                    .accessibilityLabel("Add \(type.title) light")
                }
            }
            if model.relightLights.isEmpty {
                Text("Add a light, or start from a preset. Directional is a distant source like the sun or a window; Point is a lamp in the scene; Spot is an aimed cone.")
                    .font(AppTypography.caption).foregroundStyle(AppColors.textSecondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(model.relightLights) { light in row(light) }
                }
            }
        }
    }

    private func row(_ light: RelightLight) -> some View {
        let isSelected = model.selectedLightID == light.id
        let swatch = RelightColorScience.swatch(light)
        return HStack(spacing: AppSpacing.small) {
            Button { model.selectLight(isSelected ? nil : light.id) } label: {
                HStack(spacing: AppSpacing.small) {
                    ZStack {
                        Circle().fill(Color(.sRGB, red: swatch.x, green: swatch.y, blue: swatch.z, opacity: 1))
                        Image(systemName: light.type.symbol)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.black.opacity(0.7))
                    }
                    .frame(width: 24, height: 24)
                    .opacity(light.isEnabled ? 1 : 0.4)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(light.name)
                            .font(AppTypography.bodyEmphasized)
                            .foregroundStyle(light.isEnabled ? AppColors.textPrimary : AppColors.textDisabled)
                            .lineLimit(1)
                        Text(subtitle(light))
                            .font(.caption2).foregroundStyle(AppColors.textSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { model.setLightEnabled(light.id, !light.isEnabled) } label: {
                Image(systemName: light.isEnabled ? "eye" : "eye.slash")
                    .font(.system(size: 14))
                    .foregroundStyle(light.isEnabled ? AppColors.textPrimary : AppColors.textDisabled)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!model.canEditRelight)
            .accessibilityLabel(light.isEnabled ? "Disable \(light.name)" : "Enable \(light.name)")
        }
        .padding(.leading, AppSpacing.compact)
        .frame(minHeight: isCompact ? 56 : 50)
        .background(isSelected ? AppColors.accentMuted : AppColors.surface,
                    in: RoundedRectangle(cornerRadius: AppCornerRadius.control))
        .overlay(RoundedRectangle(cornerRadius: AppCornerRadius.control)
            .stroke(isSelected ? AppColors.accent.opacity(0.5) : AppColors.border, lineWidth: 1))
        .contextMenu {
            Button("Rename", systemImage: "pencil") { draftName = light.name; renaming = light.id }
            Button("Duplicate", systemImage: "plus.square.on.square") { model.duplicateLight(light.id) }
                .disabled(!model.canAddLight)
            Button(light.isEnabled ? "Disable" : "Enable", systemImage: light.isEnabled ? "eye.slash" : "eye") {
                model.setLightEnabled(light.id, !light.isEnabled)
            }
            Button("Reset", systemImage: "arrow.uturn.backward") { model.resetLight(light.id) }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { confirmsDelete = light.id }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func subtitle(_ light: RelightLight) -> String {
        var parts = [light.type.title, "\(Int(light.intensity.rounded()))%"]
        if abs(light.temperature - 6500) > 50 { parts.append("\(Int(light.temperature.rounded()))K") }
        if light.intensity < 0 { parts.append(String(localized: "negative")) }
        if light.isAnimated { parts.append(String(localized: "animated")) }
        return parts.joined(separator: " · ")
    }

    private var selectHint: some View {
        Text("Select a light in the list or on the picture to adjust it.")
            .font(AppTypography.caption).foregroundStyle(AppColors.textSecondary)
    }

    // MARK: - Scene

    private var sceneControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SCENE").font(.caption.weight(.semibold)).tracking(1.2)
            strengthSlider
            percentSlider(String(localized: "Preserve Highlights"), \.preserveHighlights, neutral: 0.7,
                          detail: String(localized: "Rolls added light off smoothly before it reaches white."))
            percentSlider(String(localized: "Protect Blacks"), \.protectBlacks, neutral: 0.35,
                          detail: String(localized: "Keeps the deepest shadows from being lifted into grey."))
            formSlider
            affectPicker
        }
        .disabled(!model.canEditRelight)
    }

    private var strengthSlider: some View {
        let state = model.relightStrengthKeyframeState
        let binding = model.relightStrengthBinding
        return VStack(spacing: 4) {
            AdjustmentSlider(
                value: Binding(get: { Float(binding.wrappedValue * 100) },
                               set: { binding.wrappedValue = Double($0) / 100 }),
                title: String(localized: "Strength"), range: 0...100, step: 1, neutralValue: 100,
                valueFormatter: { "\(Int($0.rounded()))%" }
            ) {
                KeyframeDiamond(state: state, title: String(localized: "Strength"),
                                enabled: model.relightAnimationTime != nil && model.canEditRelight) {
                    model.toggleRelightStrengthKeyframe()
                }
            }
            if state != .off {
                animatedRow { model.removeRelightStrengthAnimation() }
            }
        }
    }

    private func percentSlider(_ title: String, _ keyPath: WritableKeyPath<RelightSettings, Double>,
                               neutral: Double, detail: String) -> some View {
        let binding = model.relightSceneBinding(keyPath, label: title)
        return VStack(alignment: .leading, spacing: 2) {
            AdjustmentSlider(
                value: Binding(get: { Float(binding.wrappedValue * 100) },
                               set: { binding.wrappedValue = Double($0) / 100 }),
                title: title, range: 0...100, step: 1, neutralValue: Float(neutral * 100),
                valueFormatter: { "\(Int($0.rounded()))%" })
            Text(detail).font(.caption2).foregroundStyle(AppColors.textTertiary)
        }
    }

    private var formSlider: some View {
        let binding = model.relightSceneBinding(\.form, label: String(localized: "Form"))
        let range = RelightSettings.formRange
        return VStack(alignment: .leading, spacing: 2) {
            AdjustmentSlider(
                value: Binding(get: { Float(binding.wrappedValue * 100) },
                               set: { binding.wrappedValue = Double($0) / 100 }),
                title: String(localized: "Form"),
                range: Float(range.lowerBound * 100)...Float(range.upperBound * 100),
                step: 5, neutralValue: 100,
                valueFormatter: { "\(Int($0.rounded()))%" })
            Text("How strongly light follows the estimated shape. Lower is a gentler wash, higher sculpts harder.")
                .font(.caption2).foregroundStyle(AppColors.textTertiary)
        }
    }

    private var affectPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Affect", selection: Binding(
                get: { model.relightMask?.id },
                set: { model.setRelightMask($0) })) {
                Text("Entire Frame").tag(UUID?.none)
                ForEach(model.maskedGrades) { mask in
                    Text(mask.name).tag(Optional(mask.id))
                }
            }
            .font(.subheadline)
            Text(model.maskedGrades.isEmpty
                 ? "To light only part of the picture, draw a window in Masks and choose it here."
                 : "Limits the light to one of this clip's masks — the same window, feather and tracking.")
                .font(.caption2).foregroundStyle(AppColors.textTertiary)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.relightSettings != nil {
                Button("Reset Relight") { model.resetRelight() }
                    .font(.caption.weight(.medium)).frame(minHeight: 36)
                    .disabled(!model.canEditRelight)
            }
            Text("Relight shapes light from an estimate of the scene's depth, not a 3D scan: it reads surfaces and forms convincingly but does not cast exact shadows. Hold the picture — or press \\ — to compare.")
                .font(.caption2).foregroundStyle(AppColors.textSecondary)
            if AppPlatform.isMac || !isCompact {
                Text("Drag a light on the picture to move it. Arrow keys nudge the selected light — Shift for larger steps, Option for finer ones. Delete removes it and ⌘D duplicates it.")
                    .font(.caption2).foregroundStyle(AppColors.textTertiary)
            }
        }
    }

    private func animatedRow(remove: @escaping () -> Void) -> some View {
        HStack(spacing: AppSpacing.small) {
            Text("Animated").font(.caption2).foregroundStyle(AppColors.accent)
            Button("Remove", action: remove)
                .font(.caption2.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(AppColors.textSecondary)
                .frame(minHeight: 32)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - The selected light

/// One light's controls. Every value reads what is on screen at the playhead
/// and writes by the keyframe rule, through the same diamond every other
/// animatable control in the app uses.
private struct LightInspector: View {
    @ObservedObject var model: EditorViewModel
    let light: RelightLight
    @Binding var showsAdvanced: Bool
    @Binding var confirmsDelete: UUID?
    let isCompact: Bool

    /// The light as rendered at the playhead.
    private var shown: RelightLight { model.displayedLight(light.id) ?? light }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(light.name).font(AppTypography.bodyEmphasized).lineLimit(1)
                Spacer()
                if !light.isEnabled {
                    Text("Disabled").font(.caption2.weight(.semibold)).foregroundStyle(AppColors.textSecondary)
                }
            }
            Picker("Type", selection: Binding(get: { light.type },
                                              set: { model.setLightType(light.id, $0) })) {
                ForEach(RelightLightType.allCases) { type in
                    Label(type.title, systemImage: type.symbol).tag(type)
                }
            }
            .pickerStyle(.segmented)

            group(String(localized: "LIGHT")) {
                slider(.relightIntensity, String(localized: "Intensity"), -100...200, neutral: 100,
                       format: { "\(Int($0.rounded()))%" })
                if shown.intensity < 0 {
                    Text("Negative light takes light away — a flag or negative fill.")
                        .font(.caption2).foregroundStyle(AppColors.textTertiary)
                }
                slider(.relightExposure, String(localized: "Exposure"), 0...4, step: 0.05, neutral: 1,
                       format: { String(format: "%.2f EV", locale: .current, $0) })
                slider(.relightSoftness, String(localized: "Softness"), 0...1, scale: 100, neutral: 0.5,
                       format: { "\(Int($0.rounded()))%" })
            }

            group(String(localized: "COLOR")) {
                slider(.relightTemperature, String(localized: "Temperature"), 1500...15000, step: 50, neutral: 6500,
                       format: { "\(Int($0.rounded()))K" })
                temperaturePresets
                slider(.relightTint, String(localized: "Tint"), -100...100, neutral: 0, format: { "\(Int($0.rounded()))" })
                colorFilter
            }

            group(light.type == .directional ? String(localized: "DIRECTION") : String(localized: "PLACEMENT")) {
                switch light.type {
                case .directional:
                    slider(.relightAzimuth, String(localized: "Direction"), 0...360, neutral: 25,
                           format: { "\(Int($0.rounded()))°" })
                    slider(.relightElevation, String(localized: "Elevation"), -80...90, neutral: 35,
                           format: { "\(Int($0.rounded()))°" })
                    Text("Elevation 90° is light from the camera, 0° is pure side light, and below zero it comes from behind the subject.")
                        .font(.caption2).foregroundStyle(AppColors.textTertiary)
                case .point, .spot:
                    slider(.relightPositionX, String(localized: "Position X"), -0.5...1.5, scale: 100, neutral: 0.5,
                           format: { "\(Int($0.rounded()))%" })
                    slider(.relightPositionY, String(localized: "Position Y"), -0.5...1.5, scale: 100, neutral: 0.5,
                           format: { "\(Int($0.rounded()))%" })
                    slider(.relightDistance, String(localized: "Distance"), 0...1, scale: 100, neutral: 0.25,
                           format: { "\(Int($0.rounded()))%" })
                    Text("Near puts the light in front of everything; far puts it behind the subject, as a rim or background light.")
                        .font(.caption2).foregroundStyle(AppColors.textTertiary)
                    slider(.relightRadius, String(localized: "Reach"), 0.05...4, scale: 100, step: 5, neutral: 0.9,
                           format: { "\(Int($0.rounded()))%" })
                    slider(.relightFalloff, String(localized: "Falloff"), 0...1, scale: 100, neutral: 0.5,
                           format: { "\(Int($0.rounded()))%" })
                }
                if light.type == .spot {
                    slider(.relightTargetX, String(localized: "Aim X"), -0.5...1.5, scale: 100, neutral: 0.5,
                           format: { "\(Int($0.rounded()))%" })
                    slider(.relightTargetY, String(localized: "Aim Y"), -0.5...1.5, scale: 100, neutral: 0.45,
                           format: { "\(Int($0.rounded()))%" })
                    slider(.relightConeAngle, String(localized: "Cone"), 3...85, neutral: 26, format: { "\(Int($0.rounded()))°" })
                    slider(.relightFeather, String(localized: "Cone Feather"), 0...1, scale: 100, neutral: 0.5,
                           format: { "\(Int($0.rounded()))%" })
                }
            }

            group(String(localized: "SHADOWS")) {
                Picker("Shadow Response", selection: Binding(
                    get: { shown.shadowResponse > 0.001 },
                    set: { shading in
                        model.setLightNumbers(light.id, [(.relightShadow, shading ? 0.5 : 0)],
                                              label: String(localized: "Shadow Response"), immediate: true)
                    })) {
                    Text("Light Only").tag(false)
                    Text("Light + Shading").tag(true)
                }
                .pickerStyle(.segmented)
                if shown.shadowResponse > 0.001 || model.lightKeyframeState(light.id, .relightShadow) != .off {
                    slider(.relightShadow, String(localized: "Shading"), 0...1, scale: 100, neutral: 0,
                           format: { "\(Int($0.rounded()))%" })
                }
                Text("Light + Shading also darkens the side of a form turned away from this light. It shapes; it does not cast shadows.")
                    .font(.caption2).foregroundStyle(AppColors.textTertiary)
            }

            if !isCompact || showsAdvanced {
                DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                    VStack(alignment: .leading, spacing: 12) {
                        plainSlider(String(localized: "Specular"), \.specular, detail: String(localized: "A restrained sheen on surfaces facing both the light and the camera."))
                        plainSlider(String(localized: "Roughness"), \.roughness, detail: String(localized: "How broad that sheen is. Higher is a matte surface."))
                        plainSlider(String(localized: "Light Wrap"), \.lightWrap, detail: String(localized: "Lets a little light reach round a silhouette edge."))
                    }
                    .padding(.top, 8)
                }
                .font(.subheadline.weight(.semibold))
            } else {
                Button("Advanced…") { showsAdvanced = true }
                    .font(.caption.weight(.semibold)).frame(minHeight: 40)
            }

            HStack(spacing: AppSpacing.small) {
                actionButton(String(localized: "Duplicate"), role: nil) { model.duplicateLight(light.id) }
                    .disabled(!model.canAddLight)
                actionButton(String(localized: "Reset"), role: nil) { model.resetLight(light.id) }
                actionButton(String(localized: "Delete"), role: .destructive) { confirmsDelete = light.id }
            }
        }
        .disabled(!model.canEditRelight)
    }

    // MARK: Pieces

    private func group<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey(title)).font(.caption.weight(.semibold)).tracking(1.2)
                .foregroundStyle(AppColors.textSecondary)
            content()
        }
    }

    private func slider(
        _ property: AnimatableProperty, _ title: String, _ range: ClosedRange<Double>,
        scale: Double = 1, step: Float = 1, neutral: Double, format: @escaping (Float) -> String
    ) -> some View {
        let binding = model.lightBinding(light.id, property)
        let state = model.lightKeyframeState(light.id, property)
        return VStack(spacing: 4) {
            AdjustmentSlider(
                value: Binding(get: { Float(binding.wrappedValue * scale) },
                               set: { binding.wrappedValue = Double($0) / scale }),
                title: title,
                range: Float(range.lowerBound * scale)...Float(range.upperBound * scale),
                step: step, neutralValue: Float(neutral * scale), valueFormatter: format
            ) {
                KeyframeDiamond(state: state, title: title,
                                enabled: model.relightAnimationTime != nil && model.canEditRelight) {
                    model.toggleLightKeyframe(light.id, property)
                }
            }
            if state != .off {
                HStack(spacing: AppSpacing.small) {
                    Text("Animated").font(.caption2).foregroundStyle(AppColors.accent)
                    Button("Remove") { model.removeLightAnimation(light.id, property) }
                        .font(.caption2.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(AppColors.textSecondary)
                        .frame(minHeight: 32)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func plainSlider(_ title: String, _ keyPath: WritableKeyPath<RelightLight, Double>,
                             detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            AdjustmentSlider(
                value: Binding(
                    get: { Float((model.displayedLight(light.id) ?? light)[keyPath: keyPath] * 100) },
                    set: { value in
                        model.updateLight(light.id, label: title) {
                            $0[keyPath: keyPath] = min(max(Double(value) / 100, 0), 1)
                        }
                    }),
                title: title, range: 0...100, step: 1,
                neutralValue: Float(RelightLight(name: "", type: light.type)[keyPath: keyPath] * 100),
                valueFormatter: { "\(Int($0.rounded()))%" })
            Text(LocalizedStringKey(detail)).font(.caption2).foregroundStyle(AppColors.textTertiary)
        }
    }

    private var temperaturePresets: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(RelightColorScience.temperaturePresets) { preset in
                    let rgb = RelightColorScience.temperatureRGB(kelvin: preset.kelvin)
                    let peak = max(rgb.x, max(rgb.y, rgb.z), 1e-5)
                    Button {
                        model.setLightNumbers(light.id, [(.relightTemperature, preset.kelvin)],
                                              label: String(localized: "Light Temperature"), immediate: true)
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color(.sRGB,
                                            red: RelightColorScience.encoded(rgb.x / peak),
                                            green: RelightColorScience.encoded(rgb.y / peak),
                                            blue: RelightColorScience.encoded(rgb.z / peak), opacity: 1))
                                .frame(width: 12, height: 12)
                            Text(preset.title).font(.caption.weight(.medium))
                        }
                        .padding(.horizontal, 10).frame(height: 32)
                        .background(abs(shown.temperature - preset.kelvin) < 25
                                    ? AppColors.accent.opacity(0.18) : AppColors.surfaceRaised, in: Capsule())
                        .foregroundStyle(AppColors.textPrimary)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 1)
        }
        .scrollIndicators(.hidden)
    }

    private var colorFilter: some View {
        let state = model.lightKeyframeState(light.id, .relightColor)
        return VStack(spacing: 4) {
            HStack {
                ColorPicker("Color Filter", selection: Binding(
                    get: {
                        let c = shown.color
                        return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: 1)
                    },
                    set: { color in
                        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
                        model.setLightColor(light.id, RGBAColor(red: Double(min(max(r, 0), 1)),
                                                                green: Double(min(max(g, 0), 1)),
                                                                blue: Double(min(max(b, 0), 1))))
                    }), supportsOpacity: false)
                .font(.subheadline)
                .frame(minHeight: 44)
                KeyframeDiamond(state: state, title: String(localized: "Color Filter"),
                                enabled: model.relightAnimationTime != nil && model.canEditRelight) {
                    model.toggleLightKeyframe(light.id, .relightColor)
                }
            }
            if shown.color != .white {
                HStack {
                    Button("Clear Filter") { model.setLightColor(light.id, .white, immediate: true) }
                        .font(.caption2.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(AppColors.textSecondary)
                        .frame(minHeight: 32)
                    Spacer()
                }
            }
            if state != .off {
                HStack(spacing: AppSpacing.small) {
                    Text("Animated").font(.caption2).foregroundStyle(AppColors.accent)
                    Button("Remove") { model.removeLightAnimation(light.id, .relightColor) }
                        .font(.caption2.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(AppColors.textSecondary)
                        .frame(minHeight: 32)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func actionButton(_ title: String, role: ButtonRole?, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Text(LocalizedStringKey(title))
                .font(AppTypography.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(AppColors.surfaceRaised, in: RoundedRectangle(cornerRadius: AppCornerRadius.control))
                .foregroundStyle(role == .destructive ? AppColors.destructive : AppColors.textPrimary)
        }
        .buttonStyle(.plain)
    }
}
