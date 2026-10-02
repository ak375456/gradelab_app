import Combine
import PhotosUI
import SwiftUI
import UIKit

@MainActor
final class AppCoordinator: ObservableObject {
    enum Screen {
        case home
        case analyzing
        case source
        case editor
        /// The still-image workspace. A separate screen rather than a mode of
        /// the video editor, because it is a different document with a different
        /// shape — no timeline, no transport, no duration.
        case imageEditor
    }

    struct AlertState: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Published private(set) var screen: Screen = .home
    @Published private(set) var projects: [GradeProject] = []
    @Published private(set) var activeProject: GradeProject?
    @Published private(set) var editorModel: EditorViewModel?
    @Published private(set) var imageProjects: [ImageProject] = []
    @Published private(set) var imageEditorModel: ImageEditorViewModel?
    @Published private(set) var analyzingFileName: String?
    /// Which import is running, so the analysing screen names the right medium.
    /// Set alongside `analyzingFileName` by whichever import began.
    @Published private(set) var analyzingMedia: AnalyzingView.Media = .video
    @Published var alert: AlertState?
    /// Why the video library is empty, when it is empty because reading it
    /// failed rather than because nothing has been imported. Home needs the
    /// difference: "No projects yet" is an invitation, and showing it over a
    /// library that could not be read tells the user their work is gone.
    @Published private(set) var projectLoadFailure: String?
    /// The same, for the photo library. Two properties rather than one because
    /// they fail independently — a corrupt photo database must not hide the
    /// video projects that loaded perfectly well.
    @Published private(set) var imageProjectLoadFailure: String?

    private let projectStore: ProjectStore
    private let imageProjectStore = ImageProjectStore()
    private lazy var importService = VideoImportService(projectStore: projectStore)
    private let metadataReader = VideoMetadataReader()
    private let thumbnailGenerator = ThumbnailGenerator()
    private var importTask: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?
    private var imageAutosaveTask: Task<Void, Never>?

    init(projectStore: ProjectStore = ProjectStore()) {
        self.projectStore = projectStore
        // Started at launch, not when a tool needs it: the compositing shaders
        // take real time to compile the first time they are built on a device,
        // and paying that while someone waits for a frame is what made the first
        // Transform after a fresh install stall. See `CompositorWarmup`.
        CompositorWarmup.shared.start()
        Task { await loadProjects() }
        Task { await loadImageProjects() }
    }

    deinit {
        importTask?.cancel()
        autosaveTask?.cancel()
        imageAutosaveTask?.cancel()
    }

    // MARK: - Images

    /// Imports a photograph and opens it straight in the grading workspace.
    ///
    /// There is no source-information step on the way: a still has one thing to
    /// check — whether its colour can be handled — and that is decided during
    /// the import, which either succeeds or explains itself. Anything else would
    /// be a screen between the user and the picture.
    func importImage(from item: MediaImportSource) {
        importTask?.cancel()
        analyzingFileName = nil
        analyzingMedia = .image
        withAnimation(.easeInOut(duration: 0.18)) { screen = .analyzing }
        importTask = Task { [weak self] in
            guard let self else { return }
            do {
                let imported = try await StillImageImportService.load(item, store: self.imageProjectStore)
                try Task.checkCancellation()
                self.analyzingFileName = imported.displayName
                var project = ImageProject(displayName: imported.displayName, asset: imported.asset)
                if let thumbnail = ImageDecoder.thumbnail(url: imported.asset.url),
                   let jpeg = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.82) {
                    let url = try await self.imageProjectStore.thumbnailURL(for: project.id)
                    try jpeg.write(to: url, options: .atomic)
                    project.thumbnailFileName = url.path
                }
                try await self.imageProjectStore.save(project)
                await self.loadImageProjects()
                try Task.checkCancellation()
                self.openImageProject(project)
            } catch is CancellationError {
                self.screen = .home
            } catch {
                self.screen = .home
                self.present(error: error, title: String(localized: "Couldn’t Import Image"))
            }
        }
    }

    func openImageProject(_ project: ImageProject) {
        guard FileManager.default.fileExists(atPath: project.sourceURL.path) else {
            present(error: GradeLabError.imageUnavailable, title: String(localized: "Image Unavailable"))
            return
        }
        let support = project.colorSupport
        guard support.allowsEditor else {
            present(error: GradeLabError.unsupportedExport(
                support.notice ?? String(localized: "This image is outside GradeLab’s validated colour pipeline.")),
                    title: String(localized: "Editor Unavailable"))
            return
        }
        do {
            imageEditorModel = try ImageEditorViewModel(project: project)
            withAnimation(.easeInOut(duration: 0.16)) { screen = .imageEditor }
        } catch {
            present(error: error, title: String(localized: "Couldn’t Open Editor"))
        }
    }

    func closeImageEditor(project: ImageProject) {
        imageEditorModel = nil
        imageAutosaveTask?.cancel()
        withAnimation(.easeInOut(duration: 0.16)) { screen = .home }
        Task {
            do {
                try await imageProjectStore.save(project)
                await loadImageProjects()
            } catch {
                present(error: error, title: String(localized: "Project Not Saved"))
            }
        }
    }

    /// Same debounce as the video editor's: disk writes are coalesced during a
    /// drag and forced when the app leaves the foreground. Rendering never waits
    /// on persistence.
    func persistImageProject(_ project: ImageProject, immediately: Bool) {
        imageAutosaveTask?.cancel()
        imageAutosaveTask = Task { [weak self] in
            guard let self else { return }
            do {
                if !immediately { try await Task.sleep(for: .milliseconds(650)) }
                try Task.checkCancellation()
                try await self.imageProjectStore.save(project)
                try Task.checkCancellation()
                await self.loadImageProjects()
            } catch is CancellationError {
                // A newer grade snapshot superseded this write.
            } catch {
                self.present(error: error, title: String(localized: "Project Not Saved"))
            }
        }
    }

    func deleteImageProject(_ project: ImageProject) {
        Task {
            do {
                try await imageProjectStore.delete(
                    project.id,
                    mediaReferencedElsewhere: try? await projectStore.referencedMediaURLs()
                )
                await loadImageProjects()
            } catch {
                present(error: error, title: String(localized: "Couldn’t Delete Project"))
            }
        }
    }

    /// Removes a video project and GradeLab's imported copy of its media.
    ///
    /// The photo library is asked what it is still using first, because both
    /// libraries import into the same folder. `try?` rather than `try` on
    /// purpose: if that library cannot be read, its references are unknown and
    /// `nil` tells the store to remove the document but leave every file alone.
    func deleteProject(_ project: GradeProject) {
        Task {
            do {
                try await projectStore.delete(
                    project.id,
                    mediaReferencedElsewhere: try? await imageProjectStore.referencedMediaURLs()
                )
                if activeProject?.id == project.id { activeProject = nil }
                await loadProjects()
            } catch {
                present(error: error, title: String(localized: "Couldn’t Delete Project"))
            }
        }
    }

    private func loadImageProjects() async {
        do {
            imageProjects = try await imageProjectStore.loadProjects()
            imageProjectLoadFailure = nil
        } catch {
            // Cleared rather than left stale: the rows would be describing a
            // library the app can no longer read, and the banner Home shows in
            // their place says so.
            imageProjects = []
            imageProjectLoadFailure = reportLoadFailure(
                error, previous: imageProjectLoadFailure, title: String(localized: "Couldn’t Load Photo Projects"))
        }
    }

    func importVideo(from item: MediaImportSource) {
        importVideos(from: [item])
    }

    func importVideos(from items: [MediaImportSource]) {
        guard let item = items.first else { return }
        importTask?.cancel()
        analyzingFileName = nil
        analyzingMedia = .video
        withAnimation(.easeInOut(duration: 0.18)) { screen = .analyzing }

        importTask = Task { [weak self] in
            guard let self else { return }
            var importedURLs: [URL] = []
            do {
                let imported = try await self.importService.importVideo(from: item)
                importedURLs.append(imported.url)
                try Task.checkCancellation()
                self.analyzingFileName = imported.displayName
                let asset = try await self.metadataReader.read(
                    from: imported.url,
                    originalFileName: imported.originalFilename
                )
                try Task.checkCancellation()

                var project = GradeProject(
                    sourceURL: asset.url,
                    displayName: imported.displayName,
                    metadata: asset.metadata,
                    sourceRange: asset.sourceRange,
                    frameDuration: asset.frameDuration
                )
                for (index, item) in items.dropFirst().enumerated() {
                    self.analyzingFileName = "Importing \(index+2) of \(items.count)"
                    let additional = try await self.importService.importVideo(from: item)
                    importedURLs.append(additional.url)
                    let video = try await self.metadataReader.read(from: additional.url, originalFileName: additional.originalFilename)
                    _ = try await ExportSourceInspector.inspect(video, requireExportColorTags: false)
                    let range = try video.sourceRange ?? .init(start: .zero, duration: .seconds(video.metadata.durationSeconds))
                    let media = ProjectMediaAsset(id: UUID(), url: video.url, sourceRange: range, videoMetadata: video.metadata, frameDuration: video.frameDuration)
                    project.addAsset(media)
                    let clip = VideoClip(placement: .init(id: UUID(), trackID: project.timeline.tracks[0].id, timelineStart: project.timeline.duration, duration: range.duration),
                        assetID: media.id, sourceRange: range, embeddedAudio: video.metadata.hasAudio ? EmbeddedAudio() : nil)
                    project.timeline.tracks[0].items.append(.video(clip))
                    try Task.checkCancellation()
                }
                if let thumbnail = try? await self.thumbnailGenerator.makeThumbnail(for: asset.url),
                   let jpeg = thumbnail.jpegData(compressionQuality: 0.82) {
                    let thumbnailURL = try await self.projectStore.thumbnailURL(for: project.id)
                    try jpeg.write(to: thumbnailURL, options: .atomic)
                    project.thumbnailFileName = thumbnailURL.path
                }
                try await self.projectStore.save(project)
                self.activeProject = project
                await self.loadProjects()
                withAnimation(.easeInOut(duration: 0.18)) { self.screen = .source }
            } catch is CancellationError {
                for url in importedURLs { try? FileManager.default.removeItem(at: url) }
                self.screen = .home
            } catch {
                for url in importedURLs { try? FileManager.default.removeItem(at: url) }
                #if DEBUG
                print("Import failed: \(error)")
                #endif
                self.screen = .home
                self.present(error: error, title: String(localized: "Couldn’t Import Video"))
            }
        }
    }

    func showHome() {
        autosaveTask?.cancel()
        imageAutosaveTask?.cancel()
        editorModel?.playback.pause()
        editorModel = nil
        imageEditorModel = nil
        activeProject = nil
        withAnimation(.easeInOut(duration: 0.16)) { screen = .home }
        Task { await loadProjects() }
        Task { await loadImageProjects() }
    }

    func openProject(_ project: GradeProject) {
        guard FileManager.default.fileExists(atPath: project.sourceURL.path) else {
            present(error: GradeLabError.assetUnavailable, title: String(localized: "Source Unavailable"))
            return
        }
        activeProject = project
        withAnimation(.easeInOut(duration: 0.16)) { screen = .source }
    }

    /// Chooses how an Apple Log source is handled: decoded and rendered, or
    /// left as recorded.
    ///
    /// This is source colour management, not a grade. It is kept away from
    /// `GradeSettings` on purpose, so copying a grade or applying a preset can
    /// never carry one clip's handling onto another's footage.
    func setColorMode(_ mode: ProjectColorMode) {
        guard var project = activeProject, project.colorMode != mode else { return }
        project.colorMode = mode
        project.updatedAt = .now
        activeProject = project
        Task { [project] in
            do { try await projectStore.save(project) } catch {
                #if DEBUG
                print("Saving the colour mode failed: \(error)")
                #endif
            }
        }
    }

    func openEditor() {
        guard let project = activeProject else { return }
        guard FileManager.default.fileExists(atPath: project.sourceURL.path) else {
            present(error: GradeLabError.assetUnavailable, title: String(localized: "Source Unavailable"))
            return
        }
        let support = ColorPipelineSupport(metadata: project.metadata)
        guard support.allowsEditor else {
            present(
                error: GradeLabError.unsupportedExport(
                    support.notice ?? String(localized: "This source is outside GradeLab’s validated color pipeline.")
                ),
                title: String(localized: "Editor Unavailable")
            )
            return
        }
        do {
            editorModel = try EditorViewModel(project: project)
            withAnimation(.easeInOut(duration: 0.16)) { screen = .editor }
        } catch {
            present(error: error, title: String(localized: "Couldn’t Open Editor"))
        }
    }

    func closeEditor(project: VideoProject) {
        editorModel?.playback.pause()
        editorModel = nil
        autosaveTask?.cancel()
        activeProject = project
        screen = .source
        Task {
            do {
                try await projectStore.save(project)
                await loadProjects()
            } catch {
                present(error: error, title: String(localized: "Project Not Saved"))
            }
        }
    }

    /// Debounces disk writes during slider drags while preserving immediately when
    /// the app leaves the foreground. Rendering is updated independently and never
    /// waits for project persistence.
    func persistEditorSettings(_ project: VideoProject, immediately: Bool) {
        guard activeProject?.id == project.id else { return }
        activeProject = project
        autosaveTask?.cancel()

        autosaveTask = Task { [weak self] in
            guard let self else { return }
            do {
                if !immediately {
                    try await Task.sleep(for: .milliseconds(650))
                }
                try Task.checkCancellation()
                try await self.projectStore.save(project)
                try Task.checkCancellation()
                await self.loadProjects()
            } catch is CancellationError {
                // A newer grade snapshot superseded this write.
            } catch {
                self.present(error: error, title: String(localized: "Project Not Saved"))
            }
        }
    }

    private func loadProjects() async {
        do {
            projects = try await projectStore.loadProjects()
            projectLoadFailure = nil
        } catch {
            projects = []
            projectLoadFailure = reportLoadFailure(
                error, previous: projectLoadFailure, title: String(localized: "Couldn’t Load Projects"))
        }
    }

    /// Records a library failure and alerts once per distinct failure.
    ///
    /// Every autosave reloads the library, so a database that will not read
    /// fails again every few hundred milliseconds during a slider drag. The
    /// recorded message stays for as long as the failure does, which is what
    /// Home reads; the modal alert is shown only when the message changes, so
    /// the user is told once rather than buried.
    private func reportLoadFailure(_ error: Error, previous: String?, title: String) -> String {
        let message = Self.message(for: error)
        if previous != message { alert = AlertState(title: title, message: message) }
        return message
    }

    private func present(error: Error, title: String) {
        alert = AlertState(title: title, message: Self.message(for: error))
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
