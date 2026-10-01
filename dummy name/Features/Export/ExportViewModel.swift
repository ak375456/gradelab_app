import Combine
import Foundation

@MainActor
final class ExportViewModel: ObservableObject {
    @Published private(set) var state: ExportState = .idle
    @Published private(set) var capabilities: ExportCapabilities?
    @Published private(set) var outputMetadata: VideoMetadata?
    @Published private(set) var isInspectingOutput = false
    @Published private(set) var isCheckingCapabilities = true
    @Published private(set) var isSaving = false
    @Published private(set) var savedToPhotos = false
    @Published var message: String?
    @Published var showsShareSheet = false

    let project: GradeProject
    let settings: GradeSettings
    @Published var configuration = ExportConfiguration.maximumQuality {
        didSet { if oldValue != configuration { checkCapabilities() } }
    }
    @Published var followsCanvas: Bool {
        didSet {
            if followsCanvas {
                configuration.resolution = .original
                configuration.frameRate = .original
            }
        }
    }
    private var capabilityTask: Task<Void, Never>?

    private var exporter: VideoExporter?
    private var operationTask: Task<Void, Never>?
    private var completedURL: URL?
    /// True from the moment Cancel is tapped until the export task has unwound.
    ///
    /// The exporter keeps reporting the frames that were already in flight when
    /// the tap landed, and letting those through would raise the progress view
    /// back over an export the person has already been told is cancelled.
    private var isCancelling = false

    // MARK: - Estimates

    /// How much longer the running export has to go, measured from its own
    /// progress. Nil until enough has happened for the number to mean anything.
    @Published private(set) var timeRemaining: TimeInterval?
    private var timeRemainingTracker = ExportTimeRemaining()
    private var exportStartedAt: Date?

    /// The expected output size for the current settings.
    ///
    /// Recomputed as the pickers change, because that is exactly when someone
    /// is weighing quality against storage.
    var estimate: ExportEstimate? {
        ExportEstimate.make(
            configuration: configuration,
            canvasWidth: project.canvas.width,
            canvasHeight: project.canvas.height,
            fps: outputFrameRate,
            durationSeconds: project.timeline.duration.seconds,
            audioTrackCount: exportedAudioTrackCount
        )
    }

    /// The frame rate the file will actually be written at: the chosen one, or
    /// the project's own grid.
    private var outputFrameRate: Double? {
        if let chosen = configuration.frameRate.value { return chosen }
        if let frame = project.canvas.frameDuration, frame.seconds > 0 { return 1 / frame.seconds }
        return project.metadata.nominalFrameRate
    }

    /// Audio is mixed to one track on the way out, so this is one or none.
    private var exportedAudioTrackCount: Int {
        let hasTimelineAudio = project.timeline.tracks.contains { track in
            track.kind == .audio && !track.items.isEmpty
        }
        return hasTimelineAudio || project.metadata.hasAudio ? 1 : 0
    }

    init(project: GradeProject, settings: GradeSettings) {
        self.project = project
        self.settings = settings
        followsCanvas = project.canvas.usesCanvasExportSettings
    }

    deinit {
        operationTask?.cancel()
        capabilityTask?.cancel()
        exporter?.cancel()
        if let completedURL {
            try? FileManager.default.removeItem(at: completedURL)
        }
    }

    var asset: VideoAsset {
        VideoAsset(id: project.id, url: project.sourceURL, metadata: project.metadata)
    }

    var canStart: Bool {
        !isCheckingCapabilities && capabilities?.canExport == true && state == .idle
    }

    /// What writing this particular file would need from Pro, or nil when a
    /// free account may write it.
    ///
    /// Both halves matter: the export settings, and the grade itself. A grade
    /// can arrive here on the timeline's clips or as the project-level
    /// `settings`, and gating only one of the two would leave the other as a
    /// way around the paywall.
    var proRequirements: [ProFeature] {
        ProAccessPolicy.exportRequirements(
            project, configuration: configuration, settings: settings)
    }

    var proRequirement: ProFeature? { proRequirements.first }

    /// True when the paywall stands between these settings and the file.
    var isLocked: Bool { proRequirement != nil && !ProStore.shared.hasPro }

    var isBusy: Bool {
        switch state {
        case .preparing, .analyzing, .exporting, .finishing: true
        default: false
        }
    }

    var outputURL: URL? {
        if case .completed(let url) = state { return url }
        return completedURL
    }

    func prepare() {
        guard exporter == nil else { return }
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try self.project.validate()
                _ = try TimelineEditing.clips(in: self.project)
                guard self.project.timeline.duration > .zero else { throw TimelineError.invalid(String(localized: "There are no clips to export.")) }
                let context = try MetalContext()
                let exporter = try VideoExporter(context: context)
                self.exporter = exporter
                self.checkCapabilities()
            } catch {
                self.isCheckingCapabilities = false
                self.capabilities = ExportCapabilities(
                    sourceIsSupported: false,
                    encoderIsSupported: false,
                    writerAcceptsVideoSettings: false,
                    writerAcceptsAudioSettings: false,
                    issues: [error.localizedDescription]
                )
            }
        }
    }

    func startExport() {
        // The view opens the paywall before reaching this, so a locked export
        // simply does nothing here. Repeated rather than trusted, because this
        // is the last point before frames are written.
        guard let exporter, canStart, !isLocked else { return }
        let configuration = configuration
        isCancelling = false
        state = .preparing
        outputMetadata = nil
        isInspectingOutput = false
        savedToPhotos = false
        message = nil

        timeRemaining = nil
        timeRemainingTracker.reset()
        exportStartedAt = .now

        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await exporter.export(
                    asset: self.asset,
                    settings: self.settings,
                    configuration: configuration,
                    project: self.project
                ) { [weak self] newState in
                    self?.apply(newState)
                }
                guard !Task.isCancelled, !self.isCancelling else {
                    // It finished between the tap and the unwind. Nobody asked
                    // for this file, so it does not get to sit in the temporary
                    // directory until the app is killed.
                    try? FileManager.default.removeItem(at: url)
                    self.state = .cancelled
                    return
                }
                self.completedURL = url
                self.isInspectingOutput = true
                do {
                    let inspected = try await VideoMetadataReader().read(from: url)
                    self.outputMetadata = inspected.metadata
                } catch {
                    self.message = "Export finished, but its metadata could not be inspected."
                }
                self.isInspectingOutput = false
            } catch {
                self.isInspectingOutput = false
                // A cancelled export can surface as any error the teardown
                // happened to reach first — a rejected frame, a cancelled
                // reader — so what the person asked for decides the state, not
                // whichever failure won the race.
                guard !self.isCancelling, (error as? GradeLabError) != .exportCancelled else {
                    self.state = .cancelled
                    return
                }
                if case .failed = self.state { return }
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Every state update from the exporter comes through here, so the
    /// remaining-time estimate is measured from the same progress the ring is
    /// drawn from rather than from a second clock of its own.
    private func apply(_ newState: ExportState) {
        // Cancelled has already been shown. Frames still draining out of the
        // exporter do not get to put the progress view back.
        guard !isCancelling else { return }
        // Analysis progress is posted from the analysis thread and can land
        // after the export has moved on; it never puts the ring back.
        if case .analyzing = newState {
            switch state {
            case .preparing, .analyzing: break
            default: return
            }
        }
        state = newState
        switch newState {
        case .exporting(let progress):
            guard let exportStartedAt else { return }
            timeRemaining = timeRemainingTracker.update(
                fractionCompleted: progress.fractionCompleted,
                elapsed: Date.now.timeIntervalSince(exportStartedAt)
            )
        case .finishing:
            // Writing the last samples and closing the file is not something
            // the frame progress can predict, so stop claiming a number.
            timeRemaining = nil
        case .completed, .cancelled, .failed, .idle, .preparing, .analyzing:
            timeRemaining = nil
        }
    }

    func cancel() {
        guard isBusy, !isCancelling else { return }
        isCancelling = true
        // The task cancel is what actually stops the export: the frame loop
        // checks for it every iteration and unwinds through its own cleanup.
        // The exporter's cancel only asks AVFoundation to stop, and that now
        // happens on the exporter's own queue, so neither call blocks here.
        operationTask?.cancel()
        exporter?.cancel()
        timeRemaining = nil
        // Said now, not when the last frame finally unwinds. The file is being
        // deleted either way, and waiting on the exporter to confirm is what
        // left a cancelled export sitting on the progress ring.
        state = .cancelled
    }

    private func checkCapabilities() {
        capabilityTask?.cancel()
        capabilities = nil
        isCheckingCapabilities = true
        guard let exporter else { return }
        let selection = configuration
        capabilityTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            let result = await exporter.capabilities(for: self.asset, configuration: selection,
                                                     project: self.project)
            guard !Task.isCancelled, selection == self.configuration else { return }
            self.capabilities = result
            self.isCheckingCapabilities = false
        }
    }

    func resetAfterFailure() {
        guard !isBusy else { return }
        isCancelling = false
        state = .idle
        isInspectingOutput = false
        message = nil
    }

    func saveToPhotos() {
        guard let outputURL, !isSaving, !savedToPhotos else { return }
        isSaving = true
        message = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await PhotoLibrarySaveService().saveVideo(at: outputURL)
                self.savedToPhotos = true
                self.message = "Saved to Photos."
            } catch {
                self.message = error.localizedDescription
            }
            self.isSaving = false
        }
    }
}
