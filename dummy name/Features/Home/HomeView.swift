import PhotosUI
import SwiftUI
import UIKit

struct HomeView: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var selectedImage: PhotosPickerItem?
    @State private var settings = false
    @State private var pendingDeletion: RecentProject?
    @ObservedObject private var store = ProStore.shared
    @State private var paywall = false

    /// The grade this screen is wearing, restored from the last time it was set.
    @State private var grade = HomeScreenGrade.restored()
    @State private var isGradingScreen = false
    /// Persisted, because the mark should invite a tap once in the life of the
    /// install rather than once per launch.
    @AppStorage("home.screenGrade.discovered") private var hasFoundScreenGrade = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xLarge) {
                header
                if isGradingScreen {
                    ScreenGradePanel(grade: $grade, onClose: toggleScreenGrade)
                        .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
                }
                unlockPro
                importHero
                recentProjects
            }
            .padding(.horizontal, AppSpacing.standard)
            .padding(.top, AppSpacing.large)
            .padding(.bottom, AppSpacing.xLarge)
        }
        .scrollIndicators(.hidden)
        .background(grade.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .environment(\.homeScreenGrade, grade)
        // Lets the read-out on each grading slider be tapped for an exact value,
        // the way the same slider behaves in the editor.
        .numericEntryHost()
        .sheet(isPresented: $settings) { EditorSettings() }
        .sheet(isPresented: $paywall) { PaywallView() }
        .onChange(of: selectedItems) { _, newValue in
            guard !newValue.isEmpty else { return }
            coordinator.importVideos(from: newValue)
            selectedItems = []
        }
        .onChange(of: selectedImage) { _, item in
            guard let item else { return }
            coordinator.importImage(from: item)
            selectedImage = nil
        }
        // Catches the grade of someone who set it and then left without closing
        // the panel, which the close handler alone would lose.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { grade.persist() }
        }
    }

    /// Opening the panel is what counts as finding it: the invitation on the
    /// mark stops for good at that point, whether or not anything gets graded.
    private func toggleScreenGrade() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            isGradingScreen.toggle()
        }

        if isGradingScreen {
            hasFoundScreenGrade = true
        } else {
            grade.persist()
        }
    }

    /// The Pro offer, above the fold on the first screen.
    ///
    /// It disappears the moment Pro is owned rather than becoming a receipt: a
    /// paid customer should not keep seeing the shop. The saving is stated as a
    /// percentage off the standard lifetime price, which is a real price, and
    /// no end date is claimed here — the campaign is ended by shipping a build,
    /// not by a countdown, so a date shown now could easily become a lie.
    @ViewBuilder
    private var unlockPro: some View {
        if !store.hasPro && !store.isCheckingAccess {
            Button { paywall = true } label: {
                HStack(spacing: AppSpacing.standard) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(ProStyle.gold)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("Unlock GradeLab Pro")
                                .font(AppTypography.bodyEmphasized)
                                .foregroundStyle(AppColors.textPrimary)
                            if ProConfiguration.foundingCampaignEnabled {
                                Text("SAVE \(ProConfiguration.foundingDiscountPercent)%")
                                    .font(.system(size: 10, weight: .bold)).tracking(0.6)
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(ProStyle.gold, in: Capsule())
                            }
                        }
                        Text(ProConfiguration.foundingCampaignEnabled
                             ? "Founding price for launch week. One purchase, yours forever."
                             : "4K export, custom LUTs, scopes, curves and more.")
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(AppTypography.caption)
                        .foregroundStyle(ProStyle.goldMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AppSpacing.standard)
                .background(ProStyle.gold.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(ProStyle.gold.opacity(0.3), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens GradeLab Pro")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: AppSpacing.compact) {
            GradeLabMark(grade: grade,
                         isOpen: isGradingScreen,
                         isInviting: !hasFoundScreenGrade,
                         action: toggleScreenGrade)
            VStack(alignment: .leading, spacing: 2) {
                Text("GradeLab")
                    .font(AppTypography.display)
                    .foregroundStyle(AppColors.textPrimary)
                Text("Professional color grading on iPhone.")
                    .font(AppTypography.secondary)
                    .foregroundStyle(AppColors.textSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer()
            Button { settings = true } label: { Image(systemName: "gearshape").frame(width: 44, height: 44) }
                .buttonStyle(.plain).accessibilityLabel("App settings")
        }
        // Two buttons and a title live here now that the mark is a control, so
        // the row contains its children instead of collapsing them into one
        // element that would bury both buttons behind the app's name.
        .accessibilityElement(children: .contain)
    }

    private var importHero: some View {
        VStack(alignment: .leading, spacing: AppSpacing.large) {
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                Text("FROM CAMERA TO FINISH")
                    .font(AppTypography.sectionLabel)
                    .tracking(1.15)
                    .foregroundStyle(grade.accent)
                Text("Shape the image.\nKeep the quality.")
                    .font(.system(.title, design: .default, weight: .semibold))
                    .foregroundStyle(AppColors.textPrimary)
                Text("Import a clip or a photograph, inspect its real format, grade on the GPU, and export at its original dimensions.")
                    .font(AppTypography.callout)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: AppSpacing.small) {
                PhotosPicker(selection: $selectedItems, selectionBehavior: .ordered, matching: .videos, preferredItemEncoding: .current) {
                    Label("Import Videos", systemImage: "plus")
                        .font(AppTypography.bodyEmphasized)
                        .foregroundStyle(AppColors.editorBackground)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(grade.accent, in: RoundedRectangle(cornerRadius: AppCornerRadius.control, style: .continuous))
                }
                .accessibilityHint("Opens the system video picker")

                // A photograph goes to the same grading tools, so it is imported
                // from the same place rather than from a separate corner of the app.
                PhotosPicker(selection: $selectedImage, matching: .images, preferredItemEncoding: .current) {
                    Label("Import Photo", systemImage: "photo")
                        .font(AppTypography.bodyEmphasized)
                        .foregroundStyle(AppColors.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(grade.surfaceRaised, in: RoundedRectangle(cornerRadius: AppCornerRadius.control, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: AppCornerRadius.control, style: .continuous)
                                .strokeBorder(AppColors.border, lineWidth: 1)
                        }
                }
                .accessibilityHint("Opens the system photo picker")
            }

            HStack(spacing: AppSpacing.standard) {
                WorkflowStep(number: "01", label: "Analyze")
                WorkflowConnector()
                WorkflowStep(number: "02", label: "Grade")
                WorkflowConnector()
                WorkflowStep(number: "03", label: "Export")
            }
        }
        .padding(AppSpacing.large)
        .background {
            ZStack {
                grade.surface
                TechnicalGrid().opacity(0.28)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.prominent, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppCornerRadius.prominent, style: .continuous)
                .strokeBorder(AppColors.border, lineWidth: 1)
        }
    }

    /// Video and image documents in one list, newest first.
    ///
    /// They are separate documents with separate stores, but to the person
    /// looking at this screen they are simply the things they have worked on, so
    /// they are ordered together by when they were last touched.
    private enum RecentProject: Identifiable {
        case video(GradeProject)
        case image(ImageProject)

        var id: UUID {
            switch self {
            case .video(let project): project.id
            case .image(let project): project.id
            }
        }

        var updatedAt: Date {
            switch self {
            case .video(let project): project.updatedAt
            case .image(let project): project.updatedAt
            }
        }

        var displayName: String {
            switch self {
            case .video(let project): project.displayName
            case .image(let project): project.displayName
            }
        }

        /// What deleting actually removes, said plainly. Both kinds keep the
        /// original in the photo library; what goes is the grade and the copy
        /// GradeLab made when it was imported.
        var deletionMessage: String {
            switch self {
            case .video:
                "The grade and GradeLab’s imported copy of the footage are removed. The clip in your photo library is untouched."
            case .image:
                "The grade and GradeLab’s imported copy of the picture are removed. The photograph in your photo library is untouched."
            }
        }
    }

    private var recents: [RecentProject] {
        (coordinator.projects.map(RecentProject.video)
            + coordinator.imageProjects.map(RecentProject.image))
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Either library failing to load is worth saying out loud here. The two
    /// fail independently, so a broken photo library still shows every video
    /// project that loaded — it only takes the empty state's place, never the
    /// rows'.
    private var libraryFailure: String? {
        coordinator.projectLoadFailure ?? coordinator.imageProjectLoadFailure
    }

    private var recentProjects: some View {
        VStack(alignment: .leading, spacing: AppSpacing.compact) {
            AppSectionHeader("Recent Projects") {
                if !recents.isEmpty {
                    Text("\(recents.count)")
                        .font(AppTypography.numeric)
                        .foregroundStyle(AppColors.textTertiary)
                }
            }

            if let libraryFailure {
                AppEmptyState(
                    title: "Projects couldn’t be loaded",
                    message: "\(libraryFailure)",
                    systemImage: "exclamationmark.triangle",
                    tint: grade.accent
                )
                .frame(maxWidth: .infinity)
                .appSurface(fill: grade.surface)
            }

            if !recents.isEmpty {
                LazyVStack(spacing: AppSpacing.small) {
                    ForEach(recents) { entry in
                        row(for: entry)
                            // One menu for both kinds. A video project used to
                            // have no way out of the library at all, so its
                            // imported copy of the footage stayed on the device
                            // for good.
                            .contextMenu {
                                Button("Delete Project", systemImage: "trash", role: .destructive) {
                                    pendingDeletion = entry
                                }
                            }
                    }
                }
            } else if libraryFailure == nil {
                // Only when the library really is empty. Printing this over a
                // library that failed to read would tell the user their work
                // never existed.
                AppEmptyState(
                    title: "No projects yet",
                    message: "Your imported clips, photographs and non-destructive grades will appear here.",
                    systemImage: "rectangle.stack",
                    tint: grade.accent
                )
                .frame(maxWidth: .infinity)
                .appSurface(fill: grade.surface)
            }
        }
        // Confirmed rather than undoable: deleting frees the imported copy of
        // the media, and an undo that had to hold that copy back would not be
        // freeing the storage the user came here for.
        .confirmationDialog(
            Text("Delete “\(pendingDeletion?.displayName ?? "")”?"),
            isPresented: Binding(get: { pendingDeletion != nil },
                                 set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { entry in
            Button("Delete Project", role: .destructive) { delete(entry) }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { entry in
            Text(entry.deletionMessage)
        }
    }

    @ViewBuilder
    private func row(for entry: RecentProject) -> some View {
        switch entry {
        case .video(let project):
            Button { coordinator.openProject(project) } label: {
                ProjectRow(project: project)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens source information")
        case .image(let project):
            Button { coordinator.openImageProject(project) } label: {
                ImageProjectRow(project: project)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the image grading workspace")
        }
    }

    private func delete(_ entry: RecentProject) {
        switch entry {
        case .video(let project): coordinator.deleteProject(project)
        case .image(let project): coordinator.deleteImageProject(project)
        }
        pendingDeletion = nil
    }
}

private struct WorkflowStep: View {
    let number: String
    let label: String
    @Environment(\.homeScreenGrade) private var grade
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(number).font(AppTypography.caption.monospacedDigit()).foregroundStyle(grade.accent)
            Text(label).font(AppTypography.caption.weight(.medium)).foregroundStyle(AppColors.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct WorkflowConnector: View {
    var body: some View {
        Rectangle().fill(AppColors.separator).frame(maxWidth: .infinity).frame(height: 1).accessibilityHidden(true)
    }
}

private struct TechnicalGrid: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            stride(from: 0.0, through: size.width, by: 28).forEach { x in
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
            }
            stride(from: 0.0, through: size.height, by: 28).forEach { y in
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(AppColors.separator), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}

/// A video project's card.
///
/// Everything on it describes the PROJECT, never the clip it was started from.
/// The two agree only until the first edit: the card used to read its numbers
/// off the primary source, so a project built from two ten-second clips claimed
/// to be ten seconds long, and trimming, retiming or resizing the canvas left it
/// stating figures that were true of a file rather than of the movie.
private struct ProjectRow: View {
    let project: GradeProject
    @Environment(\.homeScreenGrade) private var grade

    /// The movie's length, which is where the last clip ends — not the source's.
    private var durationLabel: String {
        TimecodeFormatter.string(from: project.timeline.duration.seconds)
    }

    /// The canvas, which is what will be exported. A vertical canvas cut from
    /// landscape footage is the case this exists for.
    private var resolutionLabel: String { project.canvas.resolutionLabel }

    /// Nil when the document has no frame rate, and then nothing is shown. The
    /// canvas keeps `frameDuration` optional precisely so an unknown rate is
    /// never quietly printed as 30.
    private var frameRateLabel: String? { project.canvas.frameRateLabel }

    var body: some View {
        HStack(spacing: AppSpacing.compact) {
            thumbnail.frame(width: 92, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(project.displayName).font(AppTypography.bodyEmphasized).foregroundStyle(AppColors.textPrimary).lineLimit(1)
                HStack(spacing: 6) {
                    Text(project.canvas.resolutionClass ?? resolutionLabel)
                    if let frameRateLabel { Text("•"); Text(frameRateLabel) }
                    Text("•"); Text(durationLabel)
                }
                .font(AppTypography.caption).foregroundStyle(AppColors.textSecondary).lineLimit(1)
                Text(project.updatedAt.formatted(.relative(presentation: .named)))
                    .font(AppTypography.caption).foregroundStyle(AppColors.textTertiary)
            }
            Spacer(minLength: AppSpacing.small)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColors.textTertiary).accessibilityHidden(true)
        }
        .padding(AppSpacing.compact)
        .appSurface(fill: grade.surface)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(project.displayName), \(resolutionLabel), \(frameRateLabel ?? "frame rate unknown"), \(durationLabel)")
    }

    @ViewBuilder private var thumbnail: some View {
        if let path = project.thumbnailFileName, let image = UIImage(contentsOfFile: path) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack { grade.surfaceRaised; Image(systemName: "film").foregroundStyle(AppColors.textTertiary) }
        }
    }
}


/// An image project's card.
///
/// It shows what a photograph has — dimensions, megapixels, format — and not
/// what it does not. There is no duration and no frame rate here, because a
/// still has neither and printing a placeholder for them would be a small lie
/// repeated on every row.
private struct ImageProjectRow: View {
    let project: ImageProject
    @Environment(\.homeScreenGrade) private var grade

    private var metadata: ImageMetadata { project.metadata }

    var body: some View {
        HStack(spacing: AppSpacing.compact) {
            thumbnail.frame(width: 92, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: AppCornerRadius.small, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(project.displayName)
                    .font(AppTypography.bodyEmphasized)
                    .foregroundStyle(AppColors.textPrimary).lineLimit(1)
                HStack(spacing: 6) {
                    Text(metadata.resolutionLabel)
                    Text("•"); Text(metadata.megapixelLabel)
                    Text("•"); Text(metadata.formatLabel)
                }
                .font(AppTypography.caption).foregroundStyle(AppColors.textSecondary).lineLimit(1)
                Text(project.updatedAt.formatted(.relative(presentation: .named)))
                    .font(AppTypography.caption).foregroundStyle(AppColors.textTertiary)
            }
            Spacer(minLength: AppSpacing.small)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColors.textTertiary).accessibilityHidden(true)
        }
        .padding(AppSpacing.compact)
        .appSurface(fill: grade.surface)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(project.displayName), photograph, \(metadata.resolutionLabel), \(metadata.formatLabel)")
    }

    @ViewBuilder private var thumbnail: some View {
        if let path = project.thumbnailFileName, let image = UIImage(contentsOfFile: path) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack { grade.surfaceRaised; Image(systemName: "photo").foregroundStyle(AppColors.textTertiary) }
        }
    }
}
