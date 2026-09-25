import SwiftUI
import UniformTypeIdentifiers

// ---------------------------------------------------------------------------
// The Match panel
//
// Reads top to bottom as the job does: what am I matching to, what do the two
// pictures look like, what kind of match is this, go — and then, once there is
// a result, how well did it go, how much of it do I want, and what was it
// allowed to touch.
//
// The part worth defending is the last section. A match that only printed a
// confidence and a strength slider would be an auto-enhance button with better
// manners. Listing what it actually wrote, in the same units and under the same
// names as the controls it wrote them to, is what makes it a colorist's tool:
// the values are checkable, and the next thing the user does is open Light and
// nudge the exposure it chose.
// ---------------------------------------------------------------------------

struct ShotMatchPanel: View {
    @ObservedObject var model: EditorViewModel
    @State private var isChoosingClip = false
    @State private var isImportingImage = false

    private var state: ShotMatchUIState { model.shotMatchState }
    private var match: ShotMatchSettings? { model.shotMatch }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            reference
            thumbnails
            mode
            analyzeButton
            if let match { result(match) }
            components
            footnote
        }
        .disabled(!model.canGrade)
        .task(id: model.gradeSubjectID) { await model.refreshShotMatchThumbnails() }
        .onDisappear { model.releaseShotMatchEngine() }
        .sheet(isPresented: $isChoosingClip) {
            ShotMatchClipPicker(model: model, isPresented: $isChoosingClip)
        }
        .fileImporter(isPresented: $isImportingImage, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url): model.setShotMatchReference(imageURL: url)
            case .failure(let error): model.editError = error.localizedDescription
            }
        }
    }

    // MARK: - Reference

    @ViewBuilder
    private var reference: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reference").font(AppTypography.sectionLabel).foregroundStyle(AppColors.textSecondary)
            HStack(spacing: 8) {
                chooserButton(
                    title: String(localized: "Timeline Clip"), symbol: "film.stack",
                    isEnabled: !model.shotMatchReferenceCandidates.isEmpty
                ) { isChoosingClip = true }
                chooserButton(
                    title: String(localized: "Import Image"), symbol: "photo.badge.plus",
                    isEnabled: true
                ) { isImportingImage = true }
            }
            if let reference = state.reference {
                HStack(spacing: 6) {
                    Image(systemName: reference.isClipAverage ? "film" : "photo")
                        .font(.caption2).foregroundStyle(AppColors.textTertiary)
                    Text(reference.displayName).font(.caption).lineLimit(1)
                    Spacer(minLength: 0)
                }.foregroundStyle(AppColors.textSecondary)
            } else if model.shotMatchReferenceCandidates.isEmpty {
                // A single-clip project has nothing on the timeline to match to,
                // which is worth saying rather than leaving a button that does
                // nothing when tapped.
                Text("This project has only one clip, so there is nothing on the timeline to match to. Import a reference image instead.")
                    .font(.caption2).foregroundStyle(AppColors.textTertiary)
            }
            if case .timelineClip = state.reference?.source {
                Toggle(isOn: Binding(
                    get: { state.analyzesWholeClip },
                    set: { model.shotMatchState.analyzesWholeClip = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Analyze whole clip").font(.caption)
                        // Says what the choice costs, because the wrong one is
                        // not obviously wrong: a single frame is faster and is
                        // right when the reference is one graded still, and
                        // wrong the moment the light changes during the shot.
                        Text(state.analyzesWholeClip
                             ? "Five frames across the shot, averaged."
                             : "The one frame shown below.")
                            .font(.caption2).foregroundStyle(AppColors.textTertiary)
                    }
                }.tint(AppColors.accent)
            }
        }
    }

    private func chooserButton(
        title: String, symbol: String, isEnabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.caption)
                Text(title).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity).frame(height: 40)
            .background(AppColors.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? AppColors.textPrimary : AppColors.textDisabled)
        .disabled(!isEnabled)
    }

    // MARK: - The two pictures

    private var thumbnails: some View {
        HStack(spacing: 10) {
            thumbnail(state.currentThumbnail, caption: String(localized: "CURRENT"))
            thumbnail(state.referenceThumbnail, caption: String(localized: "REFERENCE"))
        }
    }

    private func thumbnail(_ image: UIImage?, caption: String) -> some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(AppColors.surface)
                if let image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: "rectangle.dashed")
                        .font(.title3).foregroundStyle(AppColors.textDisabled)
                }
            }
            .frame(height: 78).frame(maxWidth: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppColors.border, lineWidth: 1))
            Text(caption).font(.system(size: 9, weight: .semibold))
                .foregroundStyle(AppColors.textTertiary)
        }
    }

    // MARK: - Mode

    private var mode: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Mode", selection: Binding(
                get: { state.mode }, set: { model.setShotMatchMode($0) }
            )) {
                ForEach(ShotMatchMode.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Text(state.mode.explanation)
                .font(.caption2).foregroundStyle(AppColors.textTertiary)

            // Offered only when there is something for it to preserve. On a
            // clip with no grade the two behave identically, and a control that
            // makes no difference is worse than no control.
            if match != nil || model.globalSettings.hasCreativeChangeIgnoringMask {
                Picker("Applies", selection: Binding(
                    get: { state.applyMode },
                    set: { model.shotMatchState.applyMode = $0 }
                )) {
                    ForEach(ShotMatchApplyMode.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                Text(state.applyMode.explanation)
                    .font(.caption2).foregroundStyle(AppColors.textTertiary)
            }
        }
    }

    // MARK: - Go

    @ViewBuilder
    private var analyzeButton: some View {
        if let progress = state.progress {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(progress.message).font(.caption).foregroundStyle(AppColors.textSecondary)
                Spacer(minLength: 0)
                // Cancellable, because a five-frame analysis of 4K footage is
                // long enough that someone will change their mind during it.
                Button("Cancel") { model.cancelShotMatch() }
                    .font(.caption.weight(.medium)).buttonStyle(.plain)
                    .foregroundStyle(AppColors.accent)
            }
            .frame(height: 44)
        } else {
            Button {
                model.runShotMatch()
            } label: {
                Text(match == nil
                     ? String(localized: "Analyze & Match")
                     : String(localized: "Reanalyze"))
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(state.reference == nil ? AppColors.surfaceRaised : AppColors.accent,
                                in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(state.reference == nil ? AppColors.textDisabled : .black)
            .disabled(state.reference == nil)
        }
    }

    // MARK: - The result

    @ViewBuilder
    private func result(_ match: ShotMatchSettings) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider().overlay(AppColors.separator)

            HStack(spacing: 6) {
                Text("Match Confidence").font(.caption).foregroundStyle(AppColors.textSecondary)
                Spacer(minLength: 0)
                Text(match.confidence.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(confidenceColor(match.confidence))
            }
            if let advice = match.confidence.advice {
                Text(advice).font(.caption2).foregroundStyle(AppColors.textTertiary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Match Strength").font(.caption).foregroundStyle(AppColors.textSecondary)
                    Spacer(minLength: 0)
                    Text("\(Int((state.strength * 100).rounded()))%")
                        .font(AppTypography.numeric).foregroundStyle(AppColors.textPrimary)
                }
                Slider(
                    value: Binding(
                        get: { Double(state.strength) },
                        set: { model.setShotMatchStrength(Float($0)) }
                    ),
                    in: 0...1,
                    onEditingChanged: { editing in
                        if !editing { model.flushGradeHistory() }
                    }
                ).tint(AppColors.accent)
            }

            if !model.shotMatchIsIntact {
                // Not an error. The user has been grading on top of the match,
                // which is the whole point of it being editable — but Strength
                // rebuilds from the grade that was underneath, so it would
                // discard those edits, and that is worth one line of warning
                // before it happens rather than an apology after.
                Label(
                    String(localized: "Edited since matching. Moving Strength rebuilds from the match and discards those edits."),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption2).foregroundStyle(AppColors.warning)
            }

            changed(match.adjustment.scaled(by: match.strength))

            Button(role: .destructive) {
                model.resetShotMatch()
            } label: {
                Text("Remove Match").font(.caption.weight(.medium))
                    .frame(maxWidth: .infinity).frame(height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(AppColors.destructive)
        }
    }

    private func confidenceColor(_ confidence: ShotMatchConfidence) -> Color {
        switch confidence {
        case .high: AppColors.positive
        case .medium: AppColors.warning
        case .low: AppColors.destructive
        }
    }

    /// What the match wrote, in the units of the controls it wrote to.
    @ViewBuilder
    private func changed(_ adjustment: ShotMatchAdjustment) -> some View {
        let rows = ShotMatchPanel.summary(adjustment)
        VStack(alignment: .leading, spacing: 6) {
            Text("What changed").font(AppTypography.sectionLabel)
                .foregroundStyle(AppColors.textSecondary)
            if rows.isEmpty {
                Text("Nothing. These two pictures already agree.")
                    .font(.caption2).foregroundStyle(AppColors.textTertiary)
            } else {
                ForEach(rows, id: \.name) { row in
                    HStack {
                        Text(row.name).font(.caption).foregroundStyle(AppColors.textSecondary)
                        Spacer(minLength: 8)
                        Text(row.value).font(AppTypography.numeric)
                            .foregroundStyle(AppColors.textPrimary)
                    }
                }
                Text("These are the ordinary controls. Open Light, Color, Wheels or Curves to see them and change them.")
                    .font(.caption2).foregroundStyle(AppColors.textTertiary)
            }
        }
    }

    /// The solved values as a readable list. Static and pure so a test can
    /// assert that a match with a value in it never renders an empty summary.
    static func summary(_ adjustment: ShotMatchAdjustment) -> [(name: String, value: String)] {
        var rows: [(name: String, value: String)] = []
        func add(_ name: String, _ value: Float, _ format: String = "%+.0f") {
            guard abs(value) >= 0.5 else { return }
            rows.append((name, String(format: format, locale: .current, value)))
        }
        if abs(adjustment.exposure) >= 0.005 {
            rows.append((GradeParameter.exposure.title,
                         String(format: "%+.2f", locale: .current, adjustment.exposure)))
        }
        add(GradeParameter.temperature.title, adjustment.temperature)
        add(GradeParameter.tint.title, adjustment.tint)
        add(GradeParameter.contrast.title, adjustment.contrast)
        add(GradeParameter.highlights.title, adjustment.highlights)
        add(GradeParameter.shadows.title, adjustment.shadows)
        add(GradeParameter.whites.title, adjustment.whites)
        add(GradeParameter.blacks.title, adjustment.blacks)
        add(GradeParameter.saturation.title, adjustment.saturation)
        let names = [String(localized: "Shadow color"), String(localized: "Midtone color"),
                     String(localized: "Highlight color")]
        for (index, wheel) in adjustment.wheels.enumerated() where wheel.strength >= 0.5 {
            guard index < names.count else { break }
            rows.append((names[index],
                         String(format: "%.0f%% @ %.0f°", locale: .current,
                                wheel.strength, wheel.hue)))
        }
        if adjustment.toneCurve != nil {
            rows.append((String(localized: "Tone curve"), String(localized: "Master")))
        }
        return rows
    }

    // MARK: - Components

    private var components: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(AppColors.separator)
            Text("Match Components").font(AppTypography.sectionLabel)
                .foregroundStyle(AppColors.textSecondary)
            Text("What the match is allowed to touch. Switch off anything you have already set by hand.")
                .font(.caption2).foregroundStyle(AppColors.textTertiary)
            ForEach(ShotMatchPanel.componentRows, id: \.label) { row in
                Toggle(isOn: Binding(
                    get: { state.components.contains(row.component) },
                    set: { _ in model.toggleShotMatchComponent(row.component) }
                )) {
                    Text(row.label).font(.caption)
                }.tint(AppColors.accent)
            }
        }
    }

    static let componentRows: [(label: String, component: ShotMatchComponents)] = [
        (String(localized: "Exposure"), .exposure),
        (String(localized: "White Balance"), .whiteBalance),
        (String(localized: "Contrast"), .contrast),
        (String(localized: "Tonal Range"), .tonalRange),
        (String(localized: "Saturation"), .saturation),
        (String(localized: "Shadow Color"), .shadowColor),
        (String(localized: "Midtone Color"), .midtoneColor),
        (String(localized: "Highlight Color"), .highlightColor),
        (String(localized: "Tone Curve"), .toneCurve)
    ]

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Both pictures are measured in the same colour space, so an Apple Log clip, an HDR clip, a Rec.709 clip and an imported photograph can be compared honestly.")
                .font(.caption2).foregroundStyle(AppColors.textTertiary)
            Text("Hold the preview to see the shot before the match.")
                .font(.caption2).foregroundStyle(AppColors.textTertiary)
        }
    }
}

// ---------------------------------------------------------------------------

/// Picks a reference clip, and which of its frames to measure.
///
/// A list rather than a timeline strip: what someone is choosing here is a
/// SHOT, and the frame within it is the secondary decision — which is why the
/// scrubber only appears once a clip is chosen, and why the default is to
/// average the whole shot rather than to make a frame the user must get right.
struct ShotMatchClipPicker: View {
    @ObservedObject var model: EditorViewModel
    @Binding var isPresented: Bool
    @State private var selected: VideoClip?
    @State private var seconds: Double = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.shotMatchReferenceCandidates, id: \.id) { clip in
                        Button {
                            selected = clip
                            seconds = clip.placement.timelineStart.seconds
                                + clip.placement.duration.seconds * 0.5
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(name(of: clip)).font(.subheadline)
                                    Text(timecode(clip)).font(.caption2)
                                        .foregroundStyle(AppColors.textTertiary)
                                }
                                Spacer()
                                if selected?.id == clip.id {
                                    Image(systemName: "checkmark").foregroundStyle(AppColors.accent)
                                }
                            }
                        }.buttonStyle(.plain)
                    }
                } header: {
                    Text("Reference clip")
                }

                if let clip = selected, !model.shotMatchState.analyzesWholeClip {
                    Section {
                        Slider(value: $seconds, in: Self.scrubRange(clip))
                            .tint(AppColors.accent)
                    } header: {
                        Text("Frame")
                    } footer: {
                        Text("The frame measured, and the one shown as the reference thumbnail.")
                    }
                }
            }
            .navigationTitle("Choose Reference")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") {
                        if let selected {
                            model.setShotMatchReference(clip: selected, atTimelineSeconds: seconds)
                        }
                        isPresented = false
                    }.disabled(selected == nil)
                }
            }
        }
    }

    private func name(of clip: VideoClip) -> String {
        model.project.assets.first { $0.id == clip.assetID }?
            .url.deletingPathExtension().lastPathComponent
            ?? String(localized: "Clip")
    }

    private func timecode(_ clip: VideoClip) -> String {
        let start = clip.placement.timelineStart.seconds
        let duration = clip.placement.duration.seconds
        return String(format: "%@ · %.1fs", Self.timeLabel(start), duration)
    }

    static func timeLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// The scrubber's travel over a clip.
    ///
    /// Never empty: `Slider` traps on a range whose bounds are equal, and a clip
    /// shorter than one frame — which a trim can legitimately produce — would
    /// otherwise crash the picker rather than offering a scrubber with nothing
    /// to scrub.
    static func scrubRange(_ clip: VideoClip) -> ClosedRange<Double> {
        let start = clip.placement.timelineStart.seconds
        let end = (try? clip.placement.range.end)?.seconds ?? start
        return start...max(end, start + 0.01)
    }
}
