import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct ClipReplacementSheet: View {
    @ObservedObject var model: EditorViewModel
    let clipID: UUID
    let assetFrames: [UUID: [UIImage]]
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAsset: ProjectMediaAsset?
    @State private var timing: ClipReplacementTiming = .keepDuration
    @State private var startOffset = 0.0
    @State private var useAudio = true
    @State private var showsFiles = false
    @State private var showsPhotos = false
    @State private var importsImage = false
    @State private var importSource: MediaImportSource?
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var previewHeight: CGFloat = 210
    @State private var stagedAssets: [ProjectMediaAsset] = []
    @State private var player: AVPlayer?
    @StateObject private var filmstrip = FilmstripStore()

    init(model: EditorViewModel, clipID: UUID, assetFrames: [UUID: [UIImage]],
         initialAsset: ProjectMediaAsset? = nil) {
        self.model = model
        self.clipID = clipID
        self.assetFrames = assetFrames
        _selectedAsset = State(initialValue: initialAsset)
    }

    private var original: VideoClip? { model.project.timeline.videoClip(id: clipID) }
    private var assets: [ProjectMediaAsset] {
        model.project.assets.filter { $0.videoMetadata != nil || $0.stillImage != nil }
    }
    private var sourceStart: TimelineTime? {
        guard let asset = selectedAsset else { return nil }
        return try? asset.sourceRange.start.adding(.seconds(startOffset))
    }
    private var maxStartOffset: Double {
        guard let asset = selectedAsset, let original else { return 0 }
        return max(0, asset.sourceRange.duration.seconds - original.sourceRange.duration.seconds)
    }
    private func plan(for choice: ClipReplacementTiming) throws -> ClipReplacement.Plan? {
        guard let asset = selectedAsset else { return nil }
        return try ClipReplacement.prepare(clipID: clipID, asset: asset, timing: choice,
            sourceStart: sourceStart, useAudio: useAudio, in: model.project)
    }
    private var currentPlan: ClipReplacement.Plan? { try? plan(for: timing) }
    private var validationMessage: String? {
        do { _ = try plan(for: timing); return nil }
        catch { return error.localizedDescription }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    context
                    if let asset = selectedAsset {
                        preview(asset)
                        durationChoices
                        if asset.stillImage == nil && timing == .keepDuration { trimControl }
                        audioControl(asset)
                        editSummary
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 30, weight: .light)).foregroundStyle(AppColors.accent)
                            Text("Choose a replacement").font(.headline)
                            Text("Pick from your media or import a new video or image.")
                                .font(.subheadline).foregroundStyle(AppColors.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 32)
                        .appSurface()
                    }
                    mediaLibrary
                    if let message = errorMessage ?? validationMessage {
                        Label(message, systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(AppColors.warning)
                            .accessibilityIdentifier("replacement.error")
                    }
                }
                .padding(20)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(AppColors.background)
            .navigationTitle("Replace clip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        }
        .tint(AppColors.accent)
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(loading)
        .onGeometryChange(for: CGFloat.self) { proxy in
            min(210, max(110, proxy.size.height - 500))
        } action: { previewHeight = $0 }
        .onAppear { useAudio = original?.embeddedAudio != nil }
        .onDisappear {
            player?.pause()
            model.discardStagedReplacementMedia(stagedAssets)
        }
        .sideFileImporter(isPresented: $showsFiles, allowedContentTypes: [.movie, .image]) { result in
            switch result {
            case .success(let urls): if let url = urls.first { importSource = .file(url) }
            case .failure(let error):
                let cocoa = error as NSError
                if cocoa.domain != NSCocoaErrorDomain || cocoa.code != NSUserCancelledError {
                    errorMessage = error.localizedDescription
                }
            }
        }
        .modifier(PhotoImportPicker(isPresented: $showsPhotos, images: importsImage,
                                    onSelection: { importSource = $0.first }))
        .task(id: importSource) {
            guard let source = importSource else { return }
            loading = true
            defer { loading = false; importSource = nil }
            do {
                let asset = try await model.loadReplacementMedia(source, image: importsImage)
                if Task.isCancelled {
                    model.discardStagedReplacementMedia([asset])
                    return
                }
                stagedAssets.append(asset)
                choose(asset)
            } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
        }
        .task(id: selectedAsset?.id) {
            player?.pause()
            guard let asset = selectedAsset, asset.stillImage == nil else { player = nil; return }
            player = AVPlayer(url: asset.url)
            player?.isMuted = !useAudio
            updatePreviewRange()
            await filmstrip.load(url: asset.url, range: asset.sourceRange)
        }
        .onChange(of: startOffset) { _, _ in updatePreviewRange() }
        .onChange(of: timing) { _, _ in updatePreviewRange() }
        .onChange(of: useAudio) { _, value in player?.isMuted = !value }
    }

    private var context: some View {
        HStack(spacing: 12) {
            Image(systemName: "film.stack").foregroundStyle(AppColors.accent)
                .frame(width: 42, height: 42).background(AppColors.accentMuted, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(original.flatMap { clip in model.project.assets.first { $0.id == clip.assetID } }
                    .map(name) ?? String(localized: "Selected clip"))
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("Your grade, transforms and keyframes carry over.")
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
            }
            Spacer(minLength: 0)
            Text(seconds(original?.placement.duration.seconds ?? 0))
                .font(AppTypography.numeric).foregroundStyle(AppColors.textSecondary)
        }
    }

    private func preview(_ asset: ProjectMediaAsset) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Source preview").font(.caption.weight(.medium)).foregroundStyle(AppColors.textSecondary)
            ZStack {
                Color.black
                if asset.stillImage != nil, let image = ImageImportService.thumbnail(asset.url) {
                    Image(uiImage: UIImage(cgImage: image)).resizable().scaledToFit()
                } else if let player { VideoPlayer(player: player) }
            }
            .frame(height: previewHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack {
                Text(name(asset)).font(.subheadline.weight(.medium)).lineLimit(1)
                Spacer()
                Text(asset.stillImage != nil ? String(localized: "Image") : seconds(asset.sourceRange.duration.seconds))
                    .font(.caption.monospacedDigit()).foregroundStyle(AppColors.textSecondary)
            }
        }
    }

    private var durationChoices: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Duration").font(.subheadline.weight(.semibold))
            timingOption(.keepDuration,
                title: String(localized: "Keep \(seconds(original?.placement.duration.seconds ?? 0))"),
                subtitle: (try? plan(for: .keepDuration))?.holdsLastFrame == true
                    ? String(localized: "Play the video, then hold its last frame. Other clips stay in place.")
                    : String(localized: "Fill the existing slot. Other clips stay in place."))
            if selectedAsset?.stillImage == nil {
                let full = try? plan(for: .useFullClip)
                timingOption(.useFullClip,
                    title: full.map { String(localized: "Use full clip · \(seconds($0.clip.placement.duration.seconds))") }
                        ?? String(localized: "Use full clip"),
                    subtitle: full.map { rippleDescription($0.durationChange.seconds) }
                        ?? String(localized: "Use the whole video at the clip's current speed."))
            }
        }
    }

    private func timingOption(_ choice: ClipReplacementTiming, title: String, subtitle: String) -> some View {
        Button {
            timing = choice
            errorMessage = nil
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: timing == choice ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(timing == choice ? AppColors.accent : AppColors.textTertiary)
                    .font(.system(size: 20)).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(AppColors.textPrimary)
                    Text(subtitle).font(.caption).foregroundStyle(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(timing == choice ? AppColors.accentMuted : AppColors.surface,
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(timing == choice ? AppColors.accent.opacity(0.7) : AppColors.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(timing == choice ? .isSelected : [])
        .accessibilityIdentifier("replacement.\(choice.rawValue)")
    }

    private var trimControl: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Choose the starting frame").font(.subheadline.weight(.medium))
                Spacer()
                Text(seconds(startOffset)).font(.caption.monospacedDigit()).foregroundStyle(AppColors.accent)
            }
            if !filmstrip.frames.isEmpty, let asset = selectedAsset {
                GeometryReader { geometry in
                    HStack(spacing: 1) {
                        ForEach(Array(filmstrip.frames.enumerated()), id: \.offset) { _, image in
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(width: max(1, geometry.size.width / CGFloat(filmstrip.frames.count)), height: 42)
                                .clipped()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .leading) {
                        let total = asset.sourceRange.duration.seconds
                        let span = min(original?.sourceRange.duration.seconds ?? total, total)
                        RoundedRectangle(cornerRadius: 6).strokeBorder(AppColors.accent, lineWidth: 2)
                            .background(AppColors.accent.opacity(0.12))
                            .frame(width: max(2, geometry.size.width * span / total))
                            .offset(x: geometry.size.width * startOffset / total)
                    }
                }
                .frame(height: 42).accessibilityHidden(true)
            }
            if maxStartOffset > 0 {
                Slider(value: $startOffset, in: 0...maxStartOffset,
                       step: selectedAsset?.frameDuration?.seconds ?? 1.0 / 30)
                    .accessibilityLabel("Replacement starting frame")
                    .accessibilityValue(seconds(startOffset))
                    .accessibilityIdentifier("replacement.sourceStart")
            }
            if let plan = currentPlan {
                Text("Uses \(seconds(startOffset))–\(seconds(startOffset + plan.clip.sourceRange.duration.seconds)) of the source.")
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
            }
        }
    }

    @ViewBuilder private func audioControl(_ asset: ProjectMediaAsset) -> some View {
        if asset.videoMetadata?.hasAudio == true {
            Toggle("Use replacement audio", isOn: $useAudio)
                .font(.subheadline).accessibilityIdentifier("replacement.audio")
        } else {
            Label("This replacement has no audio.", systemImage: "speaker.slash")
                .font(.caption).foregroundStyle(AppColors.textSecondary)
        }
    }

    private var editSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let plan = currentPlan {
                HStack(spacing: 10) {
                    Text(seconds(original?.placement.duration.seconds ?? 0))
                        .foregroundStyle(AppColors.textSecondary)
                    Image(systemName: "arrow.right").foregroundStyle(AppColors.textTertiary)
                    Text(seconds(plan.clip.placement.duration.seconds)).foregroundStyle(AppColors.accent)
                    Spacer()
                    Text(plan.durationChange == .zero ? String(localized: "Timing unchanged")
                         : String(localized: "Timing updated"))
                        .font(.caption).foregroundStyle(AppColors.textSecondary)
                }
                .font(AppTypography.numeric)
            }
            if timing == .useFullClip {
                Text("Following clips on this track move with their embedded audio. On the main track, later text and overlays move too. Separate audio stays in place.")
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
            }
            if let plan = currentPlan,
               plan.project.timeline.transitions.count < model.project.timeline.transitions.count {
                let count = model.project.timeline.transitions.count - plan.project.timeline.transitions.count
                Text(count == 1
                     ? String(localized: "One transition will be removed because the new footage has no extra frames at that cut.")
                     : String(localized: "\(count) transitions will be removed because the new footage has no extra frames at those cuts."))
                    .font(.caption).foregroundStyle(AppColors.warning)
            }
            if original?.backgroundRemoval != nil && original?.backgroundRemoval?.mode != .colorKey {
                Text("Redo the cutout on the new footage. The previous cutout is cleared.")
                    .font(.caption).foregroundStyle(AppColors.warning)
            }
        }
        .padding(14).appSurface()
    }

    private var mediaLibrary: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Your media").font(.subheadline.weight(.semibold))
                Spacer()
                Menu {
                    Button("From Files", systemImage: "folder") { showsFiles = true }
                    if !AppPlatform.isMac {
                        Button("Video from Photos", systemImage: "film") { importsImage = false; showsPhotos = true }
                        Button("Image from Photos", systemImage: "photo") { importsImage = true; showsPhotos = true }
                    }
                } label: { Label("Import", systemImage: "plus").font(.subheadline.weight(.medium)).frame(minHeight: 44) }
                .disabled(loading).accessibilityIdentifier("replacement.import")
            }
            if loading { ProgressView("Preparing replacement…").frame(maxWidth: .infinity).padding() }
            ForEach(assets) { asset in
                Button { choose(asset) } label: {
                    HStack(spacing: 12) {
                        Group {
                            if let frame = assetFrames[asset.id]?.first {
                                Image(uiImage: frame).resizable().scaledToFill()
                            } else {
                                Image(systemName: asset.stillImage == nil ? "film" : "photo")
                                    .foregroundStyle(AppColors.textSecondary)
                            }
                        }
                        .frame(width: 58, height: 40).clipped()
                        .background(AppColors.surfaceRaised).clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name(asset)).font(.subheadline).foregroundStyle(AppColors.textPrimary).lineLimit(1)
                            Text(asset.stillImage == nil ? seconds(asset.sourceRange.duration.seconds) : String(localized: "Image"))
                                .font(.caption).foregroundStyle(AppColors.textSecondary)
                        }
                        Spacer()
                        if selectedAsset?.id == asset.id {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(AppColors.accent)
                        }
                    }
                    .padding(10).background(selectedAsset?.id == asset.id ? AppColors.accentMuted : AppColors.surface,
                                            in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain).disabled(loading)
                .accessibilityIdentifier("replacement.asset.\(asset.id)")
            }
        }
    }

    private var footer: some View {
        Button {
            guard let asset = selectedAsset else { return }
            player?.pause()
            if model.replaceClip(clipID, with: asset, timing: timing, sourceStart: sourceStart, useAudio: useAudio) {
                dismiss()
            } else { errorMessage = model.editError; model.editError = nil }
        } label: {
            Label("Replace clip", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity)
        }
        .buttonStyle(.appPrimary)
        .disabled(currentPlan == nil || loading || model.isPreparingTimeline)
        .accessibilityIdentifier("replacement.confirm")
        .padding(16).background(AppColors.surface)
    }

    private func choose(_ asset: ProjectMediaAsset) {
        selectedAsset = asset
        startOffset = 0
        errorMessage = nil
        if asset.stillImage != nil { timing = .keepDuration }
    }

    private func updatePreviewRange() {
        guard let asset = selectedAsset, let player else { return }
        player.pause()
        let range = currentPlan?.clip.sourceRange ?? asset.sourceRange
        player.currentItem?.forwardPlaybackEndTime = (try? range.end.cmTime) ?? .invalid
        player.seek(to: range.start.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func name(_ asset: ProjectMediaAsset) -> String {
        asset.videoMetadata?.fileName ?? asset.url.lastPathComponent
    }

    private func seconds(_ value: Double) -> String {
        String(localized: "\(value.formatted(.number.precision(.fractionLength(0...2))))s")
    }

    private func rippleDescription(_ delta: Double) -> String {
        if abs(delta) < 0.00001 { return String(localized: "Other clips stay in place.") }
        return delta > 0
            ? String(localized: "Following clips move later by \(seconds(delta)).")
            : String(localized: "Following clips move earlier by \(seconds(-delta)).")
    }
}
