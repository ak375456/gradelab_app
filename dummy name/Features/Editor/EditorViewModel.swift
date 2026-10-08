import AVFoundation
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import CoreMedia
import CoreGraphics
import ImageIO
@preconcurrency import Metal

@MainActor
final class EditorViewModel: ObservableObject, GradingModel {
    /// The Color tab's tools. Shared with the still-image editor so both name
    /// the same panels; the alias keeps every existing `EditorViewModel.Panel`
    /// reference reading as it did.
    typealias Panel = GradePanel

    @Published private(set) var project: VideoProject
    @Published private(set) var selectedClipID: UUID?
    /// The timeline can marquee-select several clips. `selectedClipID` remains
    /// the primary selection for inspectors that edit one clip at a time.
    @Published private(set) var selectedClipIDs: Set<UUID> = []
    @Published private(set) var selectedTransitionID: UUID?
    let playback: VideoPlaybackController
    let renderer: MetalVideoRenderer
    let colorSupport: ColorPipelineSupport
    @Published private(set) var isPreparingTimeline = true
    @Published var editError: String?
    @Published private(set) var history = TimelineHistory()
    @Published private(set) var clipboard: TimelineItem?
    @Published private(set) var gradeBaseline: VideoProject?
    private var gradeTask: Task<Void, Never>?
    private var speedTask: Task<Void, Never>?
    private var transitionDurationBaseline: VideoProject?
    private var sequenceTask: Task<Void, Never>?
    private var backgroundAnalysisTask: Task<Void, Never>?
    private var backgroundTrackTask: Task<Void, Never>?
    private var backgroundPreviewSeekInFlight = false
    private var pendingBackgroundPreviewTime: TimelineTime?
    private var backgroundPreviewAnalysisID: UUID?
    private var layerState: LayerRenderState?
    /// The composition currently on the player, so noise reduction can read
    /// neighbouring frames from exactly the asset the playhead is timed
    /// against. Nil until the first sequence is built.
    private var sequenceSource: ExportSourceInfo?
    private var temporalFrameCache: TemporalFrameCache?
    private var temporalFrameCacheToken: ObjectIdentifier?
    /// The widest temporal window this device can hold for this project.
    @Published private(set) var noiseCapability: NoiseReductionCapability?
    /// The last measurement Auto made, for the panel to report.
    @Published private(set) var noiseProfile: NoiseProfile?
    @Published private(set) var isMeasuringNoise = false
    /// What the renderer actually managed on the last frame it drew.
    @Published private(set) var noiseStatus = NoiseReductionStatus.inactive

    // MARK: Relight — editor state only. The lights live on the clip's grade;
    // see RelightEditing.swift for everything that reads and writes them.

    /// The light the Relight inspector and the viewer handles are pointed at.
    @Published var selectedLightID: UUID?
    /// The light under the pointer or the Pencil, for the viewer to highlight.
    @Published var hoveredLightID: UUID?
    /// The scene analysis running now, or nil.
    @Published var relightProgress: RelightAnalysisProgress?
    /// Which source the running analysis is for, so the panel of another clip
    /// does not claim it.
    @Published var relightAnalysisIdentifier: String?
    /// The last thing analysis has to tell the person.
    @Published var relightNotice: String?
    /// Bumped when an analysis finishes or a cache is cleared, so readings of
    /// the depth store refresh.
    @Published var relightDepthRevision = 0
    /// How hard the preview works on depth. A device preference, not part of
    /// the document: export always analyses and draws at High.
    @Published var relightQuality = RelightQuality.loadPreference()
    var relightAnalysisTask: Task<Void, Never>?
    /// Identifies the analysis in flight, so a late report from one that was
    /// cancelled or superseded is ignored.
    var relightAnalysisRun: UUID?
    /// When the composited preview was last repainted for depth that landed.
    var relightCompositeRefresh = Date.distantPast
    /// The assets the renderer was last given depth identities for.
    private var relightSourceAssets: [ProjectMediaAsset]?
    private var audioRouting = TimelineAudioMix()
    private var forceLayerPreview = false
    private var historyLabel = "Color"
    @Published private(set) var isImporting = false
    @Published var selectedTrackID: UUID?

    /// What is being graded, for shared views that reset per-subject UI state.
    var gradeSubjectID: UUID? { selectedClipID }

    /// The clip's own grade, whatever the Color tab happens to be editing.
    ///
    /// Copy Grade, Paste Grade, presets and Reset Grade all use this rather than
    /// `settings`, because a grade is a portable description of colour and a
    /// masked local grade is not: a face window at x = 0.4 means nothing on
    /// another clip.
    var globalSettings: GradeSettings {
        get {
            selectedClipID.flatMap { project.timeline.videoClip(id: $0)?.gradeSettings }
                ?? project.timeline.firstVideoClip?.gradeSettings ?? .neutral
        }
        set {
            guard let selectedClipID else { return }
            let before = project
            if project.timeline.setGrade(newValue, for: selectedClipID) {
                if gradeBaseline == nil { gradeBaseline = before }
                project.updatedAt = .now
                synchronizeRenderer()
                gradeTask?.cancel()
                gradeTask = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
                    self?.flushGradeHistory()
                }
            }
        }
    }

    /// What the Color controls read and write.
    ///
    /// This is the whole of the Global-versus-Mask context switch. Every slider,
    /// curve, band and wheel in the Color tab already goes through `settings`,
    /// so pointing it at the selected mask's local grade makes them edit that
    /// mask — there is no second set of controls to keep in step, and no control
    /// that can forget which context it is in.
    var settings: GradeSettings {
        get {
            guard let mask = selectedMask else { return globalSettings }
            return mask.localGrade
        }
        set {
            guard let id = selectedMaskID else { globalSettings = newValue; return }
            updateMask(id, label: "Mask Color") { $0.localGrade = newValue }
        }
    }
    @Published var selectedPanel: Panel = .light
    /// Which masked local grade the Color controls are editing, or nil for the
    /// clip's own grade. UI state: the masks themselves live in the document,
    /// but which one is being worked on does not.
    @Published private(set) var selectedMaskID: UUID?
    /// Show Mask. The preview draws this mask as a matte instead of a picture.
    /// Editor state only — the export paths cannot reach it.
    @Published var maskMatteID: UUID? { didSet { synchronizeRenderer() } }
    /// The layer whose track matte the preview is showing as a picture, or nil
    /// for the ordinary composition. Editor-only: it reaches the compositor
    /// through `LayerRenderState`, which export builds for itself and never
    /// sets.
    ///
    /// The TARGET, because the mode belongs to the target: the same source cuts
    /// one layer and its inverse cuts another, and the view shows what actually
    /// survives rather than the raw source alpha.
    @Published var inspectedMatteTargetID: UUID? { didSet { synchronizeRenderer() } }
    /// Tints mask coverage over the picture while a window is being placed.
    /// A guide drawn by the editor; never composited into a frame.
    @Published var showsMaskOverlay = false
    /// True while a freehand mask is being tapped or drawn on the preview.
    @Published var isDrawingMask = false
    @Published var backgroundAnalysisProgress: BackgroundRemovalAnalysisProgress?
    @Published var backgroundAnalysisMessage: String?
    /// Where lasso tracking lost the object, in clip-local time. Nil covers
    /// both "never tracked" and "tracked the whole clip".
    @Published private(set) var backgroundTrackLostTime: TimelineTime?
    @Published var backgroundTrackProgress: MaskTrackingProgress?
    @Published var backgroundTrackDirection: MaskTrackingDirection = .both
    @Published var isDrawingBackgroundLasso = false
    @Published var isPickingBackgroundColor = false
    @Published var backgroundBrush: BackgroundRemovalBrush?
    @Published var backgroundBrushSize = 0.04
    @Published var backgroundBrushSoftness = 0.65
    @Published var showsBackgroundMatte = false { didSet { synchronizeRenderer() } }
    @Published var showsRemovedOverlay = false
    @Published var maskTrackingSession: MaskTrackingSession?
    @Published var pendingMaskTracking: MaskTrackingPlan?
    @Published var maskTrackingNotice: MaskTrackingNotice?
    var maskTrackingWorker: Task<MaskTrackingOutcome, Never>?
    /// Which curve the Curves panel is editing. UI state, never persisted.
    @Published var selectedCurve: CurveType = .master
    /// True while the eyedropper is armed and waiting for a tap on the preview.
    @Published var isPickingCurveHue = false
    /// Color Warper editor state. The warp itself lives on the grade; which
    /// plane is showing, which handle is selected and whether the eyedropper is
    /// armed belong to the panel.
    @Published var selectedWarpMode: ColorWarpMode = .hueSaturation
    @Published var selectedWarpPoint: UUID?
    @Published var isPickingWarpColor = false
    /// The same, for a mask's colour qualifier. Separate from the curve picker
    /// because both can be reached from different panels and arming one must
    /// not silently disarm the other's button.
    @Published var isPickingMaskQualifier = false
    @Published var showsOriginal = false {
        didSet { synchronizeRenderer() }
    }
    @Published var showsExport = false

    // MARK: - Shot Match
    //
    // The RESULT of a match lives on the clip, in its ordinary grade — see
    // `ShotMatchEditing.swift` for why. What is here is only the panel: which
    // reference is chosen, which components are allowed, what stage the
    // analysis has reached. None of it is persisted, because all of it is
    // recoverable from the clip's own `shotMatch` record.
    @Published var shotMatchState = ShotMatchUIState()
    var shotMatchTask: Task<Void, Never>?
    /// Built on first use and released when the panel closes. A project that
    /// never opens Match pays nothing for it, and one that does keeps its
    /// pipelines and its cached reference measurement for as long as it is
    /// working — which is what makes matching a run of clips against one
    /// reference analyse that reference once.
    private var shotMatchEngineStorage: ShotMatchEngine?

    func shotMatchEngine() -> ShotMatchEngine? {
        if let shotMatchEngineStorage { return shotMatchEngineStorage }
        // Apple Log has no alternative display transform, so the rendering LUT
        // is prepared here rather than being looked up per frame. A project that
        // is not Apple Log passes nil and never reaches the code that needs it.
        let renderingLUT = project.colorMode.isAppleLog
            ? renderer.metalContext.luts.prepareRenderingLUT(
                named: AppleLogRendering.rec709LUTResourceName)
            : nil
        shotMatchEngineStorage = ShotMatchEngine(
            context: renderer.metalContext, appleLogRenderingLUT: renderingLUT)
        return shotMatchEngineStorage
    }

    /// Drops the engine and everything it has measured. Called when the Match
    /// panel closes and when the editor goes away.
    func releaseShotMatchEngine() {
        shotMatchTask?.cancel()
        shotMatchTask = nil
        let engine = shotMatchEngineStorage
        shotMatchEngineStorage = nil
        shotMatchState.progress = nil
        Task { await engine?.invalidate() }
    }

    private var playbackObservation: AnyCancellable?

    // MARK: - Scopes

    /// Scope state is analysis/UI state, never written into the project file.
    /// Only the two preferences are persisted, to `UserDefaults`.
    @Published private(set) var scopeSettings = ScopeSettings.load()
    private var scopeRendererStorage: ScopeRenderer?

    var scopeAnalyzer: ScopeAnalyzer? { renderer.scopeAnalyzer }

    /// The signal scopes are measuring, which decides the luma coefficients and
    /// what the panel calls the axis.
    var scopeColorSpace: ScopeColorSpace { ScopeColorSpace(project.colorMode) }

    /// Built lazily and only while scopes are on, so a device that cannot make
    /// the pipelines simply shows an explanation instead of failing to open.
    var scopeRenderer: ScopeRenderer? {
        guard scopeSettings.isEnabled, let analyzer = renderer.scopeAnalyzer else { return nil }
        if scopeRendererStorage == nil {
            scopeRendererStorage = ScopeRenderer(
                context: renderer.metalContext, analyzer: analyzer,
                type: scopeSettings.type, intensity: scopeSettings.intensity)
        }
        return scopeRendererStorage
    }

    func setScopesEnabled(_ enabled: Bool) {
        guard scopeSettings.isEnabled != enabled else { return }
        scopeSettings.isEnabled = enabled
        if !enabled { scopeRendererStorage = nil }
        applyScopeSettings()
    }

    func selectScope(_ type: ScopeType) {
        guard scopeSettings.type != type else { return }
        scopeSettings.type = type
        applyScopeSettings()
    }

    func setScopeIntensity(_ intensity: Double) {
        let clamped = min(max(intensity, ScopeSettings.intensityRange.lowerBound),
                          ScopeSettings.intensityRange.upperBound)
        guard scopeSettings.intensity != clamped else { return }
        scopeSettings.intensity = clamped
        applyScopeSettings()
    }

    private func applyScopeSettings() {
        scopeSettings.save()
        renderer.setScopes(scopeSettings)
    }

    // MARK: - Viewer assist

    /// False colour and zebras. A preference like the scope settings beside it,
    /// and for the same reason: it describes how someone is looking at the
    /// picture, not anything the project contains.
    @Published private(set) var viewerAssist = ViewerAssistSettings.load()

    func setViewerAssist(_ mode: ViewerAssist) {
        guard viewerAssist.mode != mode else { return }
        viewerAssist.mode = mode
        applyViewerAssist()
    }

    func setZebraThreshold(_ threshold: Double) {
        let clamped = min(max(threshold, ViewerAssistSettings.thresholdRange.lowerBound),
                          ViewerAssistSettings.thresholdRange.upperBound)
        guard viewerAssist.zebraThreshold != clamped else { return }
        viewerAssist.zebraThreshold = clamped
        applyViewerAssist()
    }

    private func applyViewerAssist() {
        viewerAssist.save()
        renderer.setViewerAssist(viewerAssist)
    }

    init(project: GradeProject) throws {
        var project = project
        // Normalize transitions written by the first transition build. That
        // version allowed odd frame counts, placing centered handles on half
        // frames; repairing them on open prevents old projects from retaining
        // the decoder-stalling boundary condition.
        try TimelineTransitionEditing.reconcile(in: &project)
        try project.validate()
        let clips = try TimelineEditing.clips(in: project)
        let initialSelection = clips.first?.id ?? project.timeline.items.first?.id
        self.project = project
        selectedClipID = initialSelection
        selectedClipIDs = Set(initialSelection.map { [$0] } ?? [])
        selectedTrackID = clips.first?.placement.trackID ?? project.timeline.items.first?.placement.trackID
        colorSupport = ColorPipelineSupport(metadata: project.metadata)
        playback = VideoPlaybackController(
            url: project.sourceURL,
            duration: project.metadata.durationSeconds,
            range: nil,
            colorMode: project.colorMode,
            // Places the last seekable frame before a sequence has been built,
            // so stepping to the end of a freshly opened project already works.
            frameDuration: project.canvas.frameDuration?.seconds
                ?? project.metadata.bestFrameRate.map { 1 / $0 }
        )
        let context = try MetalContext()
        renderer = try MetalVideoRenderer(
            context: context,
            frameProvider: playback.frameProvider,
            metadata: project.metadata,
            colorMode: project.colorMode
        )
        playbackObservation = playback.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        synchronizeRenderer()
        renderer.setScopes(scopeSettings)
        renderer.setViewerAssist(viewerAssist)
        renderer.onDisplayStateChanged = { [weak self] in
            Task { @MainActor in self?.displayStateID &+= 1 }
        }
        renderer.onNoiseStatusChanged = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                var status = self.renderer.noiseReductionStatus
                // The renderer reports what it did; whether it was asked at all
                // is decided here, because only this side knows the project
                // went to the layer compositor instead.
                status.unavailableInComposite = self.noiseStatus.unavailableInComposite
                self.noiseStatus = status
            }
        }
        renderer.preloadLooks()
        rebuildSequence()
    }

    deinit {
        maskTrackingWorker?.cancel()
        backgroundAnalysisTask?.cancel()
        backgroundTrackTask?.cancel()
        sequenceTask?.cancel()
        gradeTask?.cancel()
        previewTask?.cancel()
    }

    var selectedTrack: TimelineTrack? { project.timeline.tracks.first { $0.id == selectedTrackID } ?? project.timeline.tracks.first }
    var trackClips: [VideoClip] { clips.filter { $0.placement.trackID == selectedTrack?.id } }
    func selectTrack(_ id: UUID) {
        selectedTrackID = id
        selectClip(id: project.timeline.items.first(where: { $0.placement.trackID == id })?.id, seek: false)
    }
    func toggleTrack(_ id: UUID, lock: Bool) {
        commit(lock ? "Track lock" : "Track visibility") { project in
            guard let i = project.timeline.tracks.firstIndex(where: { $0.id == id }) else { return self.selectedClipID }
            if lock { project.timeline.tracks[i].isLocked.toggle() }
            else {
                guard !project.timeline.tracks[i].isLocked else { throw TimelineError.invalid(String(localized: "Unlock this track before changing visibility.")) }
                project.timeline.tracks[i].isEnabled.toggle()
            }
            return self.selectedClipID
        }
    }
    func toggleTrackMute(_ id: UUID) {
        commit("Track mute") { project in
            guard let index = project.timeline.tracks.firstIndex(where: { $0.id == id }) else {
                return self.selectedClipID
            }
            guard !project.timeline.tracks[index].isLocked else {
                throw TimelineError.invalid(String(localized: "Unlock this track before changing its sound."))
            }
            let mute = !project.timeline.tracks[index].isAudioMuted
            for itemIndex in project.timeline.tracks[index].items.indices {
                switch project.timeline.tracks[index].items[itemIndex] {
                case .audio(var clip):
                    clip.isMuted = mute
                    project.timeline.tracks[index].items[itemIndex] = .audio(clip)
                case .video(var clip):
                    clip.embeddedAudio?.isMuted = mute
                    project.timeline.tracks[index].items[itemIndex] = .video(clip)
                case .text, .shape: break
                }
            }
            return self.selectedClipID
        }
    }
    /// Row height and waveform size change nothing the compositor reads, so
    /// like a rename they must not tear down and rebuild the player. They do go
    /// through `commit`, because they live in the document: that is what makes
    /// a row someone set to compact still compact after the app is closed.
    func setTrackHeight(_ id: UUID, _ choice: TimelineTrackHeightChoice) {
        guard project.timeline.tracks.first(where: { $0.id == id })?.resolvedHeight != choice else { return }
        commit("Track height", rebuildsSequence: false) { project in
            guard let index = project.timeline.tracks.firstIndex(where: { $0.id == id }) else { return self.selectedClipID }
            project.timeline.tracks[index].heightChoice = choice
            return self.selectedClipID
        }
    }

    func setWaveformSize(_ id: UUID, _ size: TimelineWaveformSize) {
        guard project.timeline.tracks.first(where: { $0.id == id })?.resolvedWaveformSize != size else { return }
        commit("Waveform size", rebuildsSequence: false) { project in
            guard let index = project.timeline.tracks.firstIndex(where: { $0.id == id }) else { return self.selectedClipID }
            project.timeline.tracks[index].waveformSize = size
            return self.selectedClipID
        }
    }

    func reorderTrack(_ id: UUID, direction: Int) {
        commit("Layer order") { project in
            guard let i = project.timeline.tracks.firstIndex(where: { $0.id == id }), project.timeline.tracks.indices.contains(i+direction) else { return self.selectedClipID }
            guard !project.timeline.tracks[i].isLocked, !project.timeline.tracks[i+direction].isLocked else { throw TimelineError.invalid(String(localized: "Unlock both tracks before reordering.")) }
            project.timeline.tracks.swapAt(i, i+direction)
            return self.selectedClipID
        }
    }
    func reorderLayer(_ id: UUID, to target: Int) {
        commit("Layer order") { project in
            guard let origin = project.timeline.tracks.firstIndex(where: { $0.id == id }),
                  project.timeline.tracks.indices.contains(target) else { return self.selectedClipID }
            guard project.timeline.tracks[min(origin, target)...max(origin, target)].allSatisfy({ !$0.isLocked }) else { throw TimelineError.invalid(String(localized: "Unlock the affected layers before reordering.")) }
            let track = project.timeline.tracks.remove(at: origin)
            project.timeline.tracks.insert(track, at: target)
            return self.selectedClipID
        }
    }

    func moveClipToLayer(_ id: UUID, target: TimelineLayerDropTarget, seconds: Double) {
        commit("Move to layer") { project in
            let time = try TimelineTime.seconds(seconds)
            switch target {
            case .track(let trackID):
                try TimelineEditing.moveToLayer(id, destinationTrackID: trackID,
                                                at: time, in: &project)
            case .newTrack(_, let index):
                try TimelineEditing.moveToLayer(id, destinationTrackID: nil,
                                                newTrackIndex: index,
                                                at: time, in: &project)
            }
            self.selectedTrackID = project.timeline.item(id: id)?.placement.trackID
            return id
        }
    }
    func addMedia(_ item: MediaImportSource, overlay: Bool) async {
        guard !isImporting else { return }
        isImporting = true; defer { isImporting = false }
        do {
            let imported = try await VideoImportService(projectStore: ProjectStore()).importVideo(from: item)
            let asset = try await VideoMetadataReader().read(from: imported.url, originalFileName: imported.originalFilename)
            _ = try await ExportSourceInspector.inspect(asset, requireExportColorTags: false)
            try Task.checkCancellation()
            commit(overlay ? "Add overlay" : "Add video") { project in
                let main = project.timeline.tracks.firstIndex { $0.kind == .mainVideo }
                guard overlay || main.map({ !project.timeline.tracks[$0].isLocked }) == true else { throw TimelineError.invalid(String(localized: "Unlock the main track before adding media.")) }
                let range = try asset.sourceRange ?? .init(start: .zero, duration: .seconds(asset.metadata.durationSeconds))
                let media = ProjectMediaAsset(id: UUID(), url: asset.url, sourceRange: range, videoMetadata: asset.metadata, frameDuration: asset.frameDuration)
                project.addAsset(media)
                let trackIndex: Int
                if overlay {
                    project.timeline.tracks.insert(.init(id: UUID(), name: "Overlay \(project.timeline.tracks.count)", kind: .videoOverlay), at: 0)
                    trackIndex = 0
                } else { trackIndex = main! }
                let track = project.timeline.tracks[trackIndex]
                let existing = try TimelineEditing.clips(in: project).filter { $0.placement.trackID == track.id }
                let start: TimelineTime
                if overlay { start = try TimelineEditing.snapped(.seconds(self.timelineTime), frame: project.canvas.frameDuration) }
                else if let selected = self.selectedClip, selected.placement.trackID == track.id {
                    start = try selected.placement.range.end
                    for var next in existing where next.placement.timelineStart >= start {
                        next.placement.timelineStart = try next.placement.timelineStart.adding(range.duration)
                        try TimelineEditing.replace(next.id, with: [next], in: &project)
                    }
                } else { start = try existing.last?.placement.range.end ?? .zero }
                let clip = VideoClip(placement: .init(id: UUID(), trackID: track.id, timelineStart: start, duration: range.duration),
                    assetID: media.id, sourceRange: range, embeddedAudio: asset.metadata.hasAudio ? EmbeddedAudio() : nil)
                project.timeline.tracks[trackIndex].items.append(.video(clip))
                self.selectedTrackID = track.id
                return clip.id
            }
        } catch { editError = error.localizedDescription }
    }
    func changeVisual(_ label: String = "Transform", immediate: Bool = false, _ edit: (inout VideoClip) -> Void) {
        guard let id = selectedClipID else { return }
        do {
            var candidate = project
            var clip = try TimelineEditing.editable(id, in: candidate)
            edit(&clip)
            try TimelineEditing.replace(id, with: [clip], in: &candidate)
            _ = try TimelineEditing.clips(in: candidate)
            guard candidate.timeline != project.timeline else { return }
            if gradeBaseline == nil { gradeBaseline = project; historyLabel = label }
            project = candidate; project.updatedAt = .now
            synchronizeRenderer()
            gradeTask?.cancel()
            if immediate { flushGradeHistory(); return }
            gradeTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
                self?.flushGradeHistory()
            }
        } catch { editError = error.localizedDescription }
    }
    func addImage(_ item: MediaImportSource) async {
        guard !isImporting else { return }
        isImporting = true; defer { isImporting = false }
        do {
            let asset = try await ImageImportService.load(item)
            try Task.checkCancellation()
            commit("Add image overlay") { project in
                project.addAsset(asset)
                let trackID = UUID()
                let start = try TimelineEditing.snapped(.seconds(self.timelineTime), frame: project.canvas.frameDuration)
                let duration = try TimelineEditing.snapped(.seconds(3), frame: project.canvas.frameDuration)
                let clip = VideoClip(placement: .init(id: UUID(), trackID: trackID, timelineStart: start, duration: duration),
                    assetID: asset.id, sourceRange: .init(start: .zero, duration: duration))
                project.timeline.tracks.insert(.init(id: trackID, name: "Image overlay", kind: .videoOverlay, items: [.video(clip)]), at: 0)
                self.selectedTrackID = trackID
                return clip.id
            }
        } catch { editError = error.localizedDescription }
    }
    func beginTransformEditing() {
        flushGradeHistory(); forceLayerPreview = true
        if layerState == nil { rebuildSequence() }
    }

    func beginLayerMaskEditing() {
        flushGradeHistory(); forceLayerPreview = true
        if layerState == nil { rebuildSequence() }
    }

    /// Track matte only exists in the compositor, so opening the tool forces the
    /// composited preview exactly as the Transform and Mask tools do.
    func beginTrackMatteEditing() {
        flushGradeHistory(); forceLayerPreview = true
        if layerState == nil { rebuildSequence() }
    }

    func beginBackgroundRemovalEditing() {
        flushGradeHistory(); forceLayerPreview = true
        if layerState == nil { rebuildSequence() }
    }

    var selectedBackgroundRemoval: BackgroundRemovalSettings? {
        selectedClip?.backgroundRemoval?.clamped
    }

    func backgroundRemovalBinding<T>(_ keyPath: WritableKeyPath<BackgroundRemovalSettings, T>) -> Binding<T> {
        Binding(
            get: { [weak self] in
                (self?.selectedBackgroundRemoval ?? .automatic)[keyPath: keyPath]
            },
            set: { [weak self] value in
                self?.changeVisual("Remove Background") { clip in
                    var settings = clip.backgroundRemoval ?? .automatic
                    settings[keyPath: keyPath] = value
                    settings.isEnabled = true
                    clip.backgroundRemoval = settings.clamped
                }
            })
    }

    func startAutomaticBackgroundRemoval() {
        changeVisual("Auto Background Removal", immediate: true) { clip in
            var settings = clip.backgroundRemoval ?? .automatic
            settings.beginAnalysis(mode: .automatic)
            clip.backgroundRemoval = settings
        }
        runBackgroundAnalysis()
    }

    func armBackgroundLasso() {
        backgroundAnalysisTask?.cancel(); backgroundAnalysisTask = nil
        backgroundAnalysisProgress = nil
        backgroundBrush = nil
        isPickingBackgroundColor = false
        isDrawingBackgroundLasso = true
        backgroundAnalysisMessage = String(localized: "Draw a closed outline around the object you want to keep.")
    }

    /// Adopts a freshly drawn outline. There is no analysis pass behind this:
    /// the cutout is on screen by the next rendered frame, and Track Object is
    /// then a separate, explicit step.
    func commitBackgroundLasso(_ points: [MaskPoint]) {
        guard isDrawingBackgroundLasso else { return }
        isDrawingBackgroundLasso = false
        let authored = BackgroundLassoSelection.authored(points)
        guard authored.count >= 3 else {
            backgroundAnalysisMessage = String(localized: "That outline was too small. Draw all the way around the object.")
            return
        }
        let clip = selectedClip
        let sourceTime = clip.flatMap { try? $0.sourceTime(at: playheadTime) }
        let localTime = clip?.localTime(for: playheadTime)
        backgroundTrackLostTime = nil
        changeVisual("Lasso Selection", immediate: true) { clip in
            var settings = clip.backgroundRemoval ?? .automatic
            settings.adopt(.init(points: authored, sourceTime: sourceTime, localTime: localTime))
            clip.backgroundRemoval = settings
        }
        backgroundAnalysisMessage = String(localized: "Outline applied to this frame. Use Track Object to follow it through the clip.")
    }

    func clearBackgroundLasso() {
        backgroundTrackTask?.cancel(); backgroundTrackTask = nil
        backgroundTrackProgress = nil
        backgroundTrackLostTime = nil
        changeVisual("Clear Lasso", immediate: true) { $0.backgroundRemoval?.lasso = nil }
        armBackgroundLasso()
    }

    // MARK: - Lasso tracking

    var canTrackBackgroundLasso: Bool {
        guard let clip = selectedClip, let settings = clip.resolvedBackgroundRemoval,
              settings.mode == .lasso, settings.lasso?.isDrawn == true,
              let asset = project.assets.first(where: { $0.id == clip.assetID }) else { return false }
        return asset.stillImage == nil
    }

    /// Follows the outlined object through the clip and stores where it sits
    /// on each frame. Only the motion is written to the document; the outline
    /// the user drew is never rewritten by the tracker.
    func trackBackgroundLasso() {
        guard let clip = selectedClip, let settings = clip.resolvedBackgroundRemoval,
              settings.mode == .lasso, let lasso = settings.lasso, lasso.isDrawn,
              let asset = project.assets.first(where: { $0.id == clip.assetID }),
              asset.stillImage == nil else {
            backgroundAnalysisMessage = String(localized: "Draw a lasso around the object before tracking it.")
            return
        }
        backgroundTrackTask?.cancel()
        isDrawingBackgroundLasso = false
        backgroundBrush = nil
        let request = BackgroundLassoTrackRequest(url: asset.url, clip: clip, selection: lasso,
                                                  direction: backgroundTrackDirection)
        backgroundAnalysisMessage = nil
        backgroundTrackLostTime = nil
        backgroundTrackProgress = .init(fraction: 0, frames: 0,
                                        direction: backgroundTrackDirection, preparing: true)
        playback.pause()
        backgroundTrackTask = Task { [weak self] in
            let result = await BackgroundLassoTracker.track(request) { update in
                Task { @MainActor [weak self] in
                    guard let self, self.selectedClipID == request.clip.id else { return }
                    self.backgroundTrackProgress = update
                }
            }
            guard let self, !Task.isCancelled, self.selectedClipID == request.clip.id else { return }
            self.backgroundTrackProgress = nil
            if let message = result.message, result.samples.count < 2 {
                self.backgroundAnalysisMessage = message
                return
            }
            guard result.samples.count > 1 else {
                self.backgroundAnalysisMessage = String(localized: "Tracking did not measure any movement. The outline still applies to the whole clip.")
                return
            }
            self.changeVisual("Track Lasso", immediate: true) { clip in
                clip.backgroundRemoval?.lasso?.motion = result.samples
            }
            self.backgroundTrackLostTime = result.lostLocalTime
            if let lost = result.lostLocalTime {
                self.backgroundAnalysisMessage = String(
                    localized: "Tracked \(result.frames) frames. The object was lost at \(TimecodeFormatter.string(from: lost.seconds, alwaysShowHours: true)); the outline holds its last position after that.")
            } else if let message = result.message {
                self.backgroundAnalysisMessage = message
            } else {
                self.backgroundAnalysisMessage = String(localized: "Tracked \(result.frames) frames. The cutout now follows the object.")
            }
        }
    }

    func cancelBackgroundLassoTracking() {
        backgroundTrackTask?.cancel(); backgroundTrackTask = nil
        backgroundTrackProgress = nil
        backgroundAnalysisMessage = String(localized: "Tracking canceled. The outline still applies to this frame.")
    }

    func clearBackgroundLassoTracking() {
        backgroundTrackTask?.cancel(); backgroundTrackTask = nil
        backgroundTrackProgress = nil
        backgroundTrackLostTime = nil
        guard selectedBackgroundRemoval?.lasso?.isTracked == true else {
            backgroundAnalysisMessage = String(localized: "This outline has not been tracked.")
            return
        }
        changeVisual("Clear Lasso Tracking", immediate: true) {
            $0.backgroundRemoval?.lasso?.motion = []
        }
        backgroundAnalysisMessage = String(localized: "Tracking cleared. The outline stays where you drew it.")
    }

    func useColorBackgroundRemoval() {
        backgroundAnalysisTask?.cancel()
        backgroundAnalysisProgress = nil
        changeVisual("Color Background Removal", immediate: true) { clip in
            var settings = clip.backgroundRemoval ?? .automatic
            settings.mode = .colorKey; settings.isEnabled = true
            clip.backgroundRemoval = settings
        }
    }

    func armBackgroundColorPicker() {
        useColorBackgroundRemoval()
        backgroundBrush = nil
        isDrawingBackgroundLasso = false
        isPickingBackgroundColor = true
        backgroundAnalysisMessage = String(localized: "Tap the background color to remove.")
    }

    func pickBackgroundColor(atSourcePoint point: CGPoint) {
        guard isPickingBackgroundColor, let clip = selectedClip,
              let asset = project.assets.first(where: { $0.id == clip.assetID }) else { return }
        isPickingBackgroundColor = false
        let sourceTime = (try? clip.sourceTime(at: playheadTime)) ?? clip.sourceRange.start
        Task { [weak self] in
            do {
                let color = try await Self.sourceColor(asset: asset, time: sourceTime, point: point)
                guard let self else { return }
                self.changeVisual("Pick Background Color", immediate: true) { edited in
                    var settings = edited.backgroundRemoval ?? .automatic
                    settings.mode = .colorKey; settings.isEnabled = true
                    settings.colorKey.color = .init(red: color.x, green: color.y, blue: color.z)
                    edited.backgroundRemoval = settings
                }
                self.backgroundAnalysisMessage = nil
            } catch {
                self?.editError = String(localized: "That color could not be sampled. Try another point.")
            }
        }
    }

    func addBackgroundStroke(_ points: [MaskPoint]) {
        guard let kind = backgroundBrush, !points.isEmpty else { return }
        let local = selectedClip?.localTime(for: playheadTime)
        changeVisual(kind == .add ? "Add Cutout Detail" : "Remove Cutout Detail", immediate: true) { clip in
            var settings = clip.backgroundRemoval ?? .automatic
            settings.isEnabled = true
            settings.strokes.append(.init(kind: kind, points: points,
                radius: self.backgroundBrushSize, softness: self.backgroundBrushSoftness,
                localTime: local))
            clip.backgroundRemoval = settings.clamped
        }
    }

    func resetBackgroundRefinement() {
        guard selectedBackgroundRemoval?.strokes.isEmpty == false else {
            backgroundAnalysisMessage = String(localized: "There are no refinement strokes to reset.")
            return
        }
        changeVisual("Reset Background Refinement", immediate: true) { clip in
            clip.backgroundRemoval?.resetRefinement()
        }
        backgroundAnalysisMessage = String(localized: "All Add and Remove strokes were reset.")
    }

    func removeBackgroundRemoval() {
        backgroundAnalysisTask?.cancel()
        backgroundTrackTask?.cancel(); backgroundTrackProgress = nil; backgroundTrackLostTime = nil
        backgroundAnalysisProgress = nil; backgroundAnalysisMessage = nil
        isDrawingBackgroundLasso = false; isPickingBackgroundColor = false; backgroundBrush = nil
        changeVisual("Remove Background Removal", immediate: true) { $0.backgroundRemoval = nil }
    }

    func cancelBackgroundAnalysis() {
        backgroundAnalysisTask?.cancel(); backgroundAnalysisTask = nil
        backgroundPreviewAnalysisID = nil; pendingBackgroundPreviewTime = nil
        backgroundAnalysisProgress = nil
        backgroundAnalysisMessage = String(localized: "Analysis canceled. Already analyzed frames remain available.")
    }

    private func runBackgroundAnalysis() {
        backgroundAnalysisTask?.cancel()
        guard let clip = selectedClip, let settings = clip.resolvedBackgroundRemoval,
              let asset = project.assets.first(where: { $0.id == clip.assetID }) else { return }
        let request = BackgroundRemovalAnalysisRequest(projectID: project.id, clip: clip,
                                                       asset: asset, settings: settings)
        backgroundAnalysisMessage = nil
        backgroundAnalysisProgress = .init(fraction: 0, frames: 0, preparing: true)
        backgroundPreviewAnalysisID = settings.analysisID
        pendingBackgroundPreviewTime = nil
        backgroundPreviewSeekInFlight = false
        playback.pause()
        backgroundAnalysisTask = Task { [weak self] in
            do {
                let summary = try await BackgroundRemovalAnalyzer.analyze(request) { update in
                    Task { @MainActor [weak self] in
                        guard let self, self.selectedClipID == request.clip.id else { return }
                        self.backgroundAnalysisProgress = update
                        if let sourceTime = update.currentSourceTime {
                            self.queueBackgroundAnalysisPreview(sourceTime, clip: request.clip,
                                                                analysisID: request.settings.analysisID)
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                self?.backgroundAnalysisProgress = nil
                self?.backgroundAnalysisMessage = String(localized: "Background ready across \(summary.frames) frames.")
            } catch is CancellationError {
                return
            } catch {
                self?.backgroundAnalysisProgress = nil
                self?.backgroundAnalysisMessage = error.localizedDescription
            }
        }
    }

    private func queueBackgroundAnalysisPreview(_ sourceTime: TimelineTime, clip: VideoClip,
                                                analysisID: UUID) {
        guard backgroundPreviewAnalysisID == analysisID else { return }
        pendingBackgroundPreviewTime = sourceTime
        guard !backgroundPreviewSeekInFlight else { return }
        presentNextBackgroundAnalysisPreview(clip: clip, analysisID: analysisID)
    }

    private func presentNextBackgroundAnalysisPreview(clip: VideoClip, analysisID: UUID) {
        guard backgroundPreviewAnalysisID == analysisID,
              let sourceTime = pendingBackgroundPreviewTime else {
            backgroundPreviewSeekInFlight = false
            return
        }
        pendingBackgroundPreviewTime = nil
        do {
            let sourceOffset = try sourceTime.subtracting(clip.sourceRange.start)
            let timelineOffset = try TimelineTime(CMTimeMultiplyByFloat64(
                sourceOffset.cmTime, multiplier: 1 / clip.speed))
            let unclamped = try clip.placement.timelineStart.adding(timelineOffset)
            let target = min(unclamped, try clip.placement.range.end)
            backgroundPreviewSeekInFlight = true
            playback.seekPrecisely(to: target.cmTime) { [weak self] in
                guard let self, self.backgroundPreviewAnalysisID == analysisID else { return }
                self.backgroundPreviewSeekInFlight = false
                self.presentNextBackgroundAnalysisPreview(clip: clip, analysisID: analysisID)
            }
        } catch {
            backgroundPreviewSeekInFlight = false
        }
    }

    /// Parks the playhead on the frame where tracking lost the object, so the
    /// fix is to redraw there rather than to start the whole clip again.
    func goToBackgroundTrackLostFrame() {
        guard let local = backgroundTrackLostTime, let clip = selectedClip else { return }
        do {
            let visibleStart = clip.animation?.startOffset ?? .zero
            let offset = try local.subtracting(visibleStart)
            let target = min(try clip.placement.range.end,
                             try clip.placement.timelineStart.adding(offset))
            playback.pause()
            playback.seekPrecisely(to: target.cmTime)
            armBackgroundLasso()
        } catch { editError = error.localizedDescription }
    }

    private nonisolated static func sourceColor(asset: ProjectMediaAsset, time: TimelineTime,
                                                point: CGPoint) async throws -> SIMD3<Double> {
        let image: CGImage
        if asset.stillImage != nil {
            guard let source = CGImageSourceCreateWithURL(asset.url as CFURL, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true] as CFDictionary) else {
                throw BackgroundRemovalAnalysisError.message("The image could not be decoded.")
            }
            image = decoded
        } else {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: asset.url))
            generator.appliesPreferredTrackTransform = false
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            image = try await generator.image(at: time.cmTime).image
        }
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw BackgroundRemovalAnalysisError.message("The color sampler could not start.")
        }
        let x = min(max(point.x, 0), 1), y = min(max(point.y, 0), 1)
        context.interpolationQuality = .none
        context.translateBy(x: -x * CGFloat(image.width), y: -(1 - y) * CGFloat(image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return SIMD3(Double(bytes[0]) / 255, Double(bytes[1]) / 255, Double(bytes[2]) / 255)
    }

    var maskOverlayUsesCanvas: Bool { layerState != nil }

    var evaluatedSelectedClip: VideoClip? {
        guard let clip = selectedClip, let local = clip.localTime(for: playheadTime) else { return selectedClip }
        return clip.evaluated(atLocal: local)
    }

    var selectedLayerMask: LayerMask { evaluatedSelectedClip?.resolvedLayerMask ?? .disabled }

    var displayedGradeMask: GradeMask {
        (evaluatedSelectedClip?.gradeSettings.advanced ?? .neutral).resolvedMask
    }

    func layerMaskBinding<T>(_ keyPath: WritableKeyPath<LayerMask, T>) -> Binding<T> {
        Binding(
            get: { [weak self] in self?.selectedLayerMask[keyPath: keyPath] ?? LayerMask.disabled[keyPath: keyPath] },
            set: { [weak self] value in
                self?.changeVisual("Layer Mask") { clip in
                    var mask = clip.resolvedLayerMask
                    mask[keyPath: keyPath] = value
                    clip.layerMask = mask == .disabled ? nil : mask
                }
            }
        )
    }

    func resetLayerMask() {
        changeVisual("Reset Layer Mask", immediate: true) { clip in
            clip.layerMask = nil
            if var animation = clip.animation {
                [.layerMaskPositionX, .layerMaskPositionY, .layerMaskWidth,
                 .layerMaskHeight, .layerMaskRotation, .layerMaskFeather]
                    .forEach { animation.removeAnimation(of: $0) }
                clip.animation = animation.isEmpty ? nil : animation
            }
        }
    }

    func addLayerMask(_ shape: LayerMaskShape) {
        changeVisual("Add Layer Mask", immediate: true) { clip in
            var mask = clip.resolvedLayerMask
            mask.shape = shape
            mask.isEnabled = true
            clip.layerMask = mask
        }
    }

    /// A structural mask can only reveal something when an enabled visual
    /// track beneath the selected clip is active at the playhead.
    var hasVisibleLayerBelowSelection: Bool {
        guard let clip = selectedClip,
              let selectedIndex = project.timeline.tracks.firstIndex(where: { $0.id == clip.placement.trackID }),
              let time = try? TimelineTime.seconds(timelineTime) else { return false }
        return project.timeline.tracks.dropFirst(selectedIndex + 1).contains { track in
            guard track.isEnabled else { return false }
            let clips = track.items.compactMap { item -> VideoClip? in
                if case .video(let clip) = item, clip.placement.isEnabled { return clip }
                return nil
            }
            return TimelineEditing.activeClip(in: clips, at: time.cmTime) != nil
        }
    }
    func setCanvas(width: Int, height: Int) {
        guard (64...4096).contains(width), (64...4096).contains(height), width % 2 == 0, height % 2 == 0 else {
            editError = String(localized: "Use even canvas dimensions between 64 and 4096 pixels."); return
        }
        commit("Canvas") { project in project.canvas.width = width; project.canvas.height = height; return self.selectedClipID }
    }

    func setCanvasFrameDuration(_ duration: TimelineTime?) {
        guard let duration, duration > .zero else {
            editError = String(localized: "Choose a valid canvas frame rate."); return
        }
        commit("Canvas Frame Rate") { project in
            project.canvas.frameDuration = duration
            return self.selectedClipID
        }
    }

    func setExportFollowsCanvas(_ enabled: Bool) {
        guard project.canvas.usesCanvasExportSettings != enabled else { return }
        commit("Export Follows Canvas", rebuildsSequence: false) { project in
            project.canvas.usesCanvasExportSettings = enabled
            return self.selectedClipID
        }
    }

    /// The colour the canvas is filled with wherever no clip covers it.
    ///
    /// Part of the document, not a viewing preference: it is what the exported
    /// frame contains behind a scaled-down or repositioned clip, which is
    /// exactly why it is worth being able to change.
    func setCanvasBackground(_ color: RGBAColor) {
        guard project.canvas.background != color else { return }
        var probe = project
        probe.canvas.background = color
        // Only the first step away from black — or back to it — changes which
        // compositor the sequence needs. Every other change is a value the live
        // one already reads each frame, so the composition is left alone rather
        // than rebuilt under a colour picker the user is still dragging.
        let switchesCompositor = probe.needsLayerCompositor != project.needsLayerCompositor
        commit("Canvas Background", rebuildsSequence: switchesCompositor) { project in
            project.canvas.background = color
            return self.selectedClipID
        }
    }
    func stepFrames(_ count: Int) {
        guard !isPreparingTimeline, let cadence = project.canvas.frameDuration else { return }
        playback.pause()
        do {
            let current = try TimelineEditing.snapped(.seconds(timelineTime), frame: cadence)
            let offset = try TimelineTime(CMTimeMultiply(cadence.cmTime, multiplier: Int32(clamping: count)))
            let target = min(project.timeline.duration, max(.zero, try current.adding(offset)))
            playback.seekPrecisely(to: target.cmTime)
        } catch { editError = error.localizedDescription }
    }
    func toggleMarker() {
        commit("Marker") { project in
            let time = try TimelineEditing.snapped(.seconds(self.timelineTime), frame: project.canvas.frameDuration)
            if let index = project.timeline.markers.firstIndex(where: { abs($0.time.seconds-time.seconds) < (project.canvas.frameDuration?.seconds ?? 0.01)/2 }) {
                project.timeline.markers.remove(at: index)
            } else { project.timeline.markers.append(.init(id: UUID(), time: time)) }
            return self.selectedClipID
        }
    }
    func deleteMarker(_ id: UUID) {
        commit("Delete marker") { project in project.timeline.markers.removeAll { $0.id == id }; return self.selectedClipID }
    }

    var clips: [VideoClip] { (try? TimelineEditing.clips(in: project)) ?? [] }
    var selectedTransition: TimelineTransition? {
        selectedTransitionID.flatMap { id in project.timeline.transitions.first { $0.id == id } }
    }
    var transitionAtPlayhead: TimelineTransition? {
        guard let time = try? TimelineTime.seconds(timelineTime) else { return nil }
        return TimelineTransitionEditing.transition(in: project, at: time)
    }
    var canUseTransitions: Bool {
        !isPreparingTimeline &&
            project.assets.contains { $0.videoMetadata != nil && $0.stillImage == nil }
    }

    func prepareTransitionPanel() {
        playback.pause()
        selectedTransitionID = transitionAtPlayhead?.id
        if let transition = selectedTransition,
           let outgoing = project.timeline.videoClip(id: transition.outgoingClipID) {
            selectedTrackID = outgoing.placement.trackID
        }
    }

    func selectTransition(_ id: UUID?) {
        selectedTransitionID = id
        guard let transition = selectedTransition else { return }
        selectedClipID = nil
        selectedClipIDs = []
        if let outgoing = project.timeline.videoClip(id: transition.outgoingClipID) {
            selectedTrackID = outgoing.placement.trackID
        }
        playback.pause()
        playback.seekPrecisely(to: transition.editTime.cmTime)
    }

    func applyTransition(_ type: TimelineTransitionType) {
        guard canUseTransitions, let time = try? TimelineTime.seconds(timelineTime) else { return }
        var insertedID: UUID?
        commit("Add Transition") { project in
            insertedID = try TimelineTransitionEditing.apply(type, at: time,
                preferredTrackID: self.selectedTrackID, in: &project)
            return self.selectedClipID
        }
        if let insertedID { selectedTransitionID = insertedID }
    }

    func removeSelectedTransition() {
        guard let id = selectedTransitionID ?? transitionAtPlayhead?.id else { return }
        commit("Remove Transition") { project in
            TimelineTransitionEditing.remove(id, in: &project)
            return self.selectedClipID
        }
        selectedTransitionID = nil
    }

    var selectedTransitionMaximumDuration: Double {
        guard let transition = selectedTransition,
              let outgoing = project.timeline.videoClip(id: transition.outgoingClipID),
              let incoming = project.timeline.videoClip(id: transition.incomingClipID) else { return TimelineTransitionEditing.maximumSeconds }
        return (try? TimelineTransitionEditing.maximumDuration(for: outgoing, incoming: incoming, in: project).seconds)
            ?? TimelineTransitionEditing.maximumSeconds
    }
    var selectedTransitionMinimumDuration: Double {
        (try? TimelineTransitionEditing.minimumDuration(in: project).seconds)
            ?? TimelineTransitionEditing.minimumSeconds
    }

    func beginTransitionDurationEditing() {
        flushGradeHistory()
        if transitionDurationBaseline == nil { transitionDurationBaseline = project }
    }

    func setTransitionDuration(_ seconds: Double) {
        guard let id = selectedTransitionID else { return }
        if transitionDurationBaseline == nil { transitionDurationBaseline = project }
        do {
            var candidate = project
            try TimelineTransitionEditing.setDuration(id, seconds: seconds, in: &candidate)
            guard candidate.timeline != project.timeline else { return }
            project = candidate
            project.updatedAt = .now
            synchronizeRenderer()
        } catch { editError = error.localizedDescription }
    }

    func endTransitionDurationEditing() {
        guard let before = transitionDurationBaseline else { return }
        transitionDurationBaseline = nil
        guard before.timeline != project.timeline else { return }
        history.record("Transition Duration", before: before, after: project)
        rebuildSequence()
    }
    var selectedClip: VideoClip? { selectedClipID.flatMap { project.timeline.videoClip(id: $0) } }
    var selectedItem: TimelineItem? { selectedClipID.flatMap { project.timeline.item(id: $0) } }
    var selectedAudio: AudioClip? { selectedClipID.flatMap { project.timeline.audioClip(id: $0) } }
    var selectedItems: [TimelineItem] {
        project.timeline.items.filter { selectedClipIDs.contains($0.id) }
    }
    var selectedTextCount: Int {
        selectedItems.reduce(into: 0) { count, item in if case .text = item { count += 1 } }
    }
    var selectionContainsOnlyText: Bool {
        !selectedItems.isEmpty && selectedItems.allSatisfy { if case .text = $0 { true } else { false } }
    }
    /// Whether the selected layers edit through one path, and so can be dragged
    /// on the canvas as a block. Titles and shapes have separate edit paths, so a
    /// selection holding both is shown but not moved together.
    var selectionMovesAsAGroup: Bool {
        selectedClipIDs.count > 1 && (selectionContainsOnlyText || selectionContainsOnlyShapes)
    }
    var selectedShapeCount: Int {
        selectedItems.reduce(into: 0) { count, item in if case .shape = item { count += 1 } }
    }
    var selectionContainsOnlyShapes: Bool {
        !selectedItems.isEmpty && selectedItems.allSatisfy { if case .shape = $0 { true } else { false } }
    }
    var hasMedia: Bool { project.timeline.duration > .zero }
    var canEditSelection: Bool {
        let items = selectedItems
        guard !items.isEmpty else { return false }
        return !isPreparingTimeline && items.allSatisfy { item in
            !item.placement.isLocked &&
                project.timeline.tracks.first(where: { $0.id == item.placement.trackID })?.isLocked == false
        }
    }
    var audioSettings: EmbeddedAudio? {
        if let audio = selectedAudio {
            return .init(volume: audio.volume, isMuted: audio.isMuted,
                         fadeIn: audio.fadeIn, fadeOut: audio.fadeOut)
        }
        return selectedClip?.embeddedAudio
    }

    /// How long the selected clip's sound runs, which is what bounds a fade.
    var audioClipDuration: Double {
        selectedAudio?.placement.duration.seconds ?? selectedClip?.placement.duration.seconds ?? 0
    }

    /// The longest fade this clip can take. A fade longer than the clip is not a
    /// fade, and two that overlap fight each other, so the slider stops at half
    /// the clip and the resolver enforces the same rule on anything stored.
    var audioFadeLimit: Double {
        max(0, min(AudioFade.maximum, audioClipDuration / 2))
    }
    func beginAudioEditing() {
        flushGradeHistory(); forceLayerPreview = true
        if layerState == nil { rebuildSequence() }
    }
    func changeAudio(volume: Double? = nil, muted: Bool? = nil,
                     fadeIn: Double? = nil, fadeOut: Double? = nil) {
        guard canEditSelection, let id = selectedClipID else { return }
        let limit = audioFadeLimit
        // Zero is stored as "no fade" rather than as a fade of length zero, so a
        // clip that has never been faded keeps writing nothing to the document.
        func fade(_ value: Double) -> Double? {
            let clamped = min(max(value, 0), limit)
            return clamped > 0.0005 ? clamped : nil
        }
        do {
            var candidate = project
            if var clip = selectedAudio {
                if let volume { clip.volume = min(1, max(0, volume)) }
                if let muted { clip.isMuted = muted }
                if let fadeIn { clip.fadeIn = fade(fadeIn) }
                if let fadeOut { clip.fadeOut = fade(fadeOut) }
                try AudioEditing.replace(id, with: [clip], in: &candidate)
            } else if var clip = selectedClip, var linked = clip.embeddedAudio {
                if let volume { linked.volume = min(1, max(0, volume)) }
                if let muted { linked.isMuted = muted }
                if let fadeIn { linked.fadeIn = fade(fadeIn) }
                if let fadeOut { linked.fadeOut = fade(fadeOut) }
                clip.embeddedAudio = linked
                try TimelineEditing.replace(id, with: [clip], in: &candidate)
            } else { return }
            guard candidate != project else { return }
            if gradeBaseline == nil {
                gradeBaseline = project
                historyLabel = fadeIn != nil || fadeOut != nil ? "Audio fade" : "Audio level"
            }
            project = candidate; project.updatedAt = .now
            playback.player.currentItem?.audioMix = audioRouting.makeMix(project)
            gradeTask?.cancel()
            gradeTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
                self?.flushGradeHistory()
            }
        } catch { editError = error.localizedDescription }
    }
    func separateAudio() {
        guard let id = selectedClipID else { return }
        commit("Separate audio") { try AudioEditing.separate(id, in: &$0) }
    }
    func addAudio(_ url: URL) async {
        guard !isImporting else { return }
        isImporting = true; defer { isImporting = false }
        do {
            let media = try await AudioImportService.load(url)
            try Task.checkCancellation()
            commit("Add audio") { project in
                project.addAsset(media)
                let trackID = UUID()
                let start = try TimelineEditing.snapped(.seconds(self.timelineTime), frame: project.canvas.frameDuration)
                let clip = AudioClip(placement: .init(id: UUID(), trackID: trackID, timelineStart: start,
                    duration: media.sourceRange.duration), assetID: media.id, sourceRange: media.sourceRange)
                project.timeline.tracks.append(.init(id: trackID, name: media.audioName ?? "Audio", kind: .audio, items: [.audio(clip)]))
                return clip.id
            }
        } catch { editError = error.localizedDescription }
    }
    // MARK: - Importing into the bin

    /// What a chosen file turns out to be.
    ///
    /// Read from the file rather than asked of the user, so one Import button
    /// and one drop target can serve video, stills and audio. Someone dragging
    /// a folder of rushes in should not have to sort them first.
    enum ImportedMediaKind {
        case video, image, audio

        init?(_ url: URL) {
            guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
            // Order matters: some container types conform to more than one of
            // these, and a movie that also reports as audio is still a movie.
            if type.conforms(to: .movie) || type.conforms(to: .video) { self = .video }
            else if type.conforms(to: .image) { self = .image }
            else if type.conforms(to: .audio) { self = .audio }
            else { return nil }
        }
    }

    /// Imports files into the project's media list **without** putting anything
    /// on the timeline.
    ///
    /// That separation is the point of having a bin. Import answers "what am I
    /// working with", placing answers "where does it go", and running them
    /// together meant every import also edited the sequence — so bringing in
    /// six takes to choose between them left six clips to delete again.
    @discardableResult
    func importIntoBin(_ urls: [URL]) async -> [UUID] {
        guard !isImporting, !urls.isEmpty else { return [] }
        isImporting = true
        defer { isImporting = false }
        var imported: [ProjectMediaAsset] = []
        for url in urls {
            do {
                imported.append(try await importedAsset(for: url))
                try Task.checkCancellation()
            } catch is CancellationError {
                return []
            } catch {
                editError = error.localizedDescription
                break
            }
        }
        guard !imported.isEmpty else { return [] }
        // One history entry for the whole drop, so undo takes back the gesture
        // the user made rather than one file of it.
        // The count branch is only ever reached with two or more, so a single
        // plural form is correct in every shipped language.
        let label = imported.count == 1
            ? String(localized: "Import media")
            : String(localized: "Import \(imported.count) files")
        commit(label) { project in
            for asset in imported { project.addAsset(asset) }
            return nil
        }
        return imported.map(\.id)
    }

    /// Files dropped straight onto the picture: imported into the bin first,
    /// because that is where media lives, then placed so the drop does what it
    /// looked like it would do.
    func importAndPlaceOnCanvas(_ urls: [URL]) async {
        for id in await importIntoBin(urls) { placeAsset(id, as: .overlay) }
    }

    private func importedAsset(for url: URL) async throws -> ProjectMediaAsset {
        switch ImportedMediaKind(url) {
        case .video:
            let imported = try await VideoImportService(projectStore: ProjectStore()).importVideo(from: url)
            let asset = try await VideoMetadataReader().read(from: imported.url,
                                                            originalFileName: imported.originalFilename)
            _ = try await ExportSourceInspector.inspect(asset, requireExportColorTags: false)
            let range = try asset.sourceRange ?? .init(start: .zero,
                                                       duration: .seconds(asset.metadata.durationSeconds))
            return ProjectMediaAsset(id: UUID(), url: asset.url, sourceRange: range,
                                     videoMetadata: asset.metadata, frameDuration: asset.frameDuration)
        case .image:
            return try await ImageImportService.load(.file(url))
        case .audio:
            return try await AudioImportService.load(url)
        case nil:
            throw TimelineError.invalid(
                String(localized: "\(url.lastPathComponent) is not a video, image or audio file."))
        }
    }

    var canReplaceClip: Bool {
        selectedClipIDs.count == 1 && selectedClip != nil && canEditSelection && !isImporting
    }

    /// Stage media without editing the document. Cancelling the replacement
    /// leaves the timeline and its history untouched.
    func loadReplacementMedia(_ source: MediaImportSource, image: Bool) async throws -> ProjectMediaAsset {
        guard !isImporting else {
            throw TimelineError.invalid(String(localized: "Wait for the current import to finish."))
        }
        isImporting = true
        defer { isImporting = false }
        if case .file(let url) = source { return try await importedAsset(for: url) }
        if image { return try await ImageImportService.load(source) }
        let imported = try await VideoImportService(projectStore: ProjectStore()).importVideo(from: source)
        let video = try await VideoMetadataReader().read(from: imported.url, originalFileName: imported.originalFilename)
        _ = try await ExportSourceInspector.inspect(video, requireExportColorTags: false)
        try Task.checkCancellation()
        return try .init(id: UUID(), url: video.url,
                         sourceRange: video.sourceRange ?? .init(start: .zero, duration: .seconds(video.metadata.durationSeconds)),
                         videoMetadata: video.metadata, frameDuration: video.frameDuration)
    }

    @discardableResult
    func replaceClip(_ id: UUID, with asset: ProjectMediaAsset, timing: ClipReplacementTiming,
                     sourceStart: TimelineTime?, useAudio: Bool) -> Bool {
        // Recompute against the current document: a preview must never overwrite
        // an intervening edit with a stale snapshot.
        var succeeded = false
        commit(String(localized: "Replace clip"), seekToSelection: true) { project in
            let plan = try ClipReplacement.prepare(clipID: id, asset: asset, timing: timing,
                sourceStart: sourceStart, useAudio: useAudio, in: project)
            project = plan.project
            succeeded = true
            return id
        }
        return succeeded
    }

    /// Only media staged by this sheet is eligible. Keep files referenced by
    /// either the document or undo/redo, so cancellation can release unused
    /// imports without stranding a committed replacement.
    func discardStagedReplacementMedia(_ staged: [ProjectMediaAsset]) {
        let documents = [project] + (history.undoEntries + history.redoEntries).flatMap { [$0.before, $0.after] }
        let referenced = Set(documents.flatMap(\.assets).map { $0.url.standardizedFileURL })
        let imports = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("GradeLab/Imports", isDirectory: true).standardizedFileURL
        for asset in staged {
            let url = asset.url.standardizedFileURL
            guard !referenced.contains(url), url.deletingLastPathComponent() == imports else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Where a bin placement should land, so the caller says what it means
    /// rather than passing two booleans that can disagree.
    enum MediaPlacement: Equatable {
        /// Append to the main video track, after whatever is already there.
        case mainTrack
        /// A layer of its own. `at` is a time the caller chose — where a drop
        /// on the timeline let go — or nil for the playhead.
        case overlay(at: Double?)

        static var overlay: MediaPlacement { .overlay(at: nil) }

        var startTime: Double? {
            if case .overlay(let time) = self { time } else { nil }
        }
    }

    /// Puts media the project already holds back on the timeline.
    ///
    /// The media bin hands over an asset that has already been imported,
    /// validated and copied into project storage, so nothing here re-reads the
    /// original file and nothing is copied a second time. The same source can
    /// therefore appear on the timeline as many times as the edit wants, which
    /// is the whole point of having a bin rather than re-importing.
    func placeAsset(_ assetID: UUID, as placement: MediaPlacement) {
        commit(placement == .mainTrack ? String(localized: "Add video") : String(localized: "Add overlay"),
               seekToSelection: true) { project in
            guard let media = project.assets.first(where: { $0.id == assetID }) else {
                throw TimelineError.invalid(String(localized: "That media is no longer part of this project."))
            }
            // A still has no length of its own, so it gets the same default the
            // image import uses. Everything else plays for as long as it lasts.
            let duration: TimelineTime
            if media.stillImage == nil {
                duration = media.sourceRange.duration
            } else {
                duration = try TimelineEditing.snapped(.seconds(3), frame: project.canvas.frameDuration)
            }

            if media.audioName != nil {
                let trackID = UUID()
                let start = try TimelineEditing.snapped(.seconds(placement.startTime ?? self.timelineTime),
                                                        frame: project.canvas.frameDuration)
                let clip = AudioClip(placement: .init(id: UUID(), trackID: trackID, timelineStart: start,
                                                      duration: duration),
                                     assetID: media.id, sourceRange: media.sourceRange)
                project.timeline.tracks.append(.init(id: trackID, name: media.audioName ?? "Audio",
                                                     kind: .audio, items: [.audio(clip)]))
                self.selectedTrackID = trackID
                return clip.id
            }

            let sourceRange = media.stillImage == nil
                ? media.sourceRange
                : TimelineRange(start: .zero, duration: duration)
            let hasAudio = media.videoMetadata?.hasAudio == true

            switch placement {
            case .mainTrack:
                guard let index = project.timeline.tracks.firstIndex(where: { $0.kind == .mainVideo }) else {
                    throw TimelineError.invalid(String(localized: "This project has no main video track."))
                }
                guard !project.timeline.tracks[index].isLocked else {
                    throw TimelineError.invalid(String(localized: "Unlock the main track before adding media."))
                }
                let track = project.timeline.tracks[index]
                let existing = try TimelineEditing.clips(in: project).filter { $0.placement.trackID == track.id }
                let start = try existing.last?.placement.range.end ?? .zero
                let clip = VideoClip(placement: .init(id: UUID(), trackID: track.id, timelineStart: start,
                                                      duration: duration),
                                     assetID: media.id, sourceRange: sourceRange,
                                     embeddedAudio: hasAudio ? EmbeddedAudio() : nil)
                project.timeline.tracks[index].items.append(.video(clip))
                self.selectedTrackID = track.id
                return clip.id

            case .overlay:
                let trackID = UUID()
                let start = try TimelineEditing.snapped(.seconds(placement.startTime ?? self.timelineTime),
                                                        frame: project.canvas.frameDuration)
                let clip = VideoClip(placement: .init(id: UUID(), trackID: trackID, timelineStart: start,
                                                      duration: duration),
                                     assetID: media.id, sourceRange: sourceRange,
                                     embeddedAudio: hasAudio ? EmbeddedAudio() : nil)
                project.timeline.tracks.insert(
                    .init(id: trackID, name: "Overlay \(project.timeline.tracks.count)",
                          kind: .videoOverlay, items: [.video(clip)]), at: 0)
                self.selectedTrackID = trackID
                return clip.id
            }
        }
    }

    /// How many clips currently use an asset, so the bin can show what is in
    /// the edit and what was imported and never used.
    /// Every asset's clip count in one pass, for the bin to read.
    var assetUsageCounts: [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for track in project.timeline.tracks {
            for item in track.items {
                if let id = item.assetID { counts[id, default: 0] += 1 }
            }
        }
        return counts
    }

    func usageCount(of assetID: UUID) -> Int {
        project.timeline.tracks.flatMap(\.items).count { $0.assetID == assetID }
    }

    func addText() {
        commit("Add text", seekToSelection: true) { project in
            let trackID = UUID()
            let frame = try project.canvas.frameDuration ?? .seconds(1.0/30)
            let end = project.timeline.duration
            let start = max(.zero, min(try TimelineEditing.snapped(.seconds(self.timelineTime), frame: frame), try max(.zero, end.subtracting(frame))))
            let remaining = try end.subtracting(start)
            let duration = remaining > .zero ? min(try .seconds(3), remaining) : try .seconds(3)
            var clip = TextClip(placement: .init(id: UUID(), trackID: trackID, timelineStart: start, duration: duration), text: "Text")
            clip.style.fontSize = max(32, Double(project.canvas.width)*0.08)
            project.timeline.tracks.insert(.init(id: trackID, name: "Text", kind: .text, items: [.text(clip)]), at: 0)
            return clip.id
        }
    }

    // MARK: - Shapes
    //
    // A shape layer is a drawn overlay exactly as a title is: the same placement
    // rules, the same track behaviour, and — because `ShapeClip` is an
    // `AnimatableClip` — the same keyframes, read and written through the same
    // routing below. Nothing here is shape-specific except what a shape IS.

    func addShape(_ kind: ShapeKind = .rectangle) {
        commit("Add shape", seekToSelection: true) { project in
            let trackID = UUID()
            let frame = try project.canvas.frameDuration ?? .seconds(1.0/30)
            let end = project.timeline.duration
            let start = max(.zero, min(try TimelineEditing.snapped(.seconds(self.timelineTime), frame: frame),
                                       try max(.zero, end.subtracting(frame))))
            let remaining = try end.subtracting(start)
            let duration = remaining > .zero ? min(try .seconds(3), remaining) : try .seconds(3)
            var clip = ShapeClip(placement: .init(id: UUID(), trackID: trackID,
                                                  timelineStart: start, duration: duration), kind: kind)
            // Sized against the canvas the shape is AUTHORED in — the same
            // reduced preview surface its stroke and corner radius are measured
            // in — so a new shape covers the same fraction of frame whatever the
            // project's resolution.
            let size = ShapeClip.defaultSize(for: kind, canvas: SequenceComposition.previewRenderSize(
                width: project.canvas.width, height: project.canvas.height))
            clip.width = size.width
            clip.height = size.height
            if kind == .rectangle { clip.cornerRadius = 0 }
            project.timeline.tracks.insert(
                .init(id: trackID, name: TimelineTrack.defaultName(for: .shape),
                      kind: .shape, items: [.shape(clip)]), at: 0)
            return clip.id
        }
    }

    var selectedShape: ShapeClip? { if case .shape(let clip) = selectedItem { return clip }; return nil }

    /// The shape as actually rendered at the playhead, for the canvas handles.
    var evaluatedShape: ShapeClip? {
        guard let clip = selectedShape else { return nil }
        guard let local = clip.localTime(for: playheadTime) else { return clip }
        return clip.evaluated(atLocal: local)
    }

    /// Every visible shape layer at the playhead, evaluated at that frame.
    var visibleEvaluatedShapes: [ShapeClip] {
        let time = playheadTime
        return project.timeline.items.compactMap { item in
            guard case .shape(let clip) = item,
                  clip.placement.timelineStart <= time,
                  let end = try? clip.placement.range.end,
                  end > time else { return nil }
            guard let local = clip.localTime(for: time) else { return clip }
            return clip.evaluated(atLocal: local)
        }
    }

    /// The selected clip when it is a picture on a layer of its own — an image
    /// or video overlay — evaluated at the playhead.
    ///
    /// Main-track clips are excluded on purpose. That track is the background
    /// the rest of the frame sits on, and putting drag handles on it would mean
    /// a stray drag across the picture moved the whole programme. It still
    /// transforms from the Transform tool, as before.
    var evaluatedMediaOverlay: VideoClip? {
        guard let clip = selectedClip, isOverlayTrack(clip.placement.trackID) else { return nil }
        guard let local = clip.localTime(for: playheadTime) else { return clip }
        return clip.evaluated(atLocal: local)
    }

    /// Every visible picture overlay at the playhead, so a title lines up on an
    /// image's edge exactly as it does on another title's.
    var visibleEvaluatedMediaOverlays: [VideoClip] {
        let time = playheadTime
        return project.timeline.items.compactMap { item in
            guard case .video(let clip) = item,
                  isOverlayTrack(clip.placement.trackID),
                  clip.placement.isEnabled,
                  clip.placement.timelineStart <= time,
                  let end = try? clip.placement.range.end,
                  end > time else { return nil }
            guard let local = clip.localTime(for: time) else { return clip }
            return clip.evaluated(atLocal: local)
        }
    }

    private func isOverlayTrack(_ id: UUID) -> Bool {
        project.timeline.tracks.first { $0.id == id }?.kind == .videoOverlay
    }

    /// The size a clip's picture draws at before its own transform, which is
    /// what the canvas handles measure against.
    func displaySize(of clip: VideoClip) -> CGSize? {
        guard let asset = project.assets.first(where: { $0.id == clip.assetID }) else { return nil }
        if let still = asset.stillImage { return CGSize(width: still.width, height: still.height) }
        guard let metadata = asset.videoMetadata else { return nil }
        return CGSize(width: metadata.displayWidth, height: metadata.displayHeight)
    }

    /// The shape counterpart of `editText`, with the same undo grouping.
    func editShape(_ label: String = "Shape", immediate: Bool = false, _ edit: (inout ShapeClip) -> Void) {
        guard canEditSelection, selectionContainsOnlyShapes else { return }
        do {
            var candidate = project
            for item in selectedItems {
                guard case .shape(var clip) = item else { continue }
                edit(&clip)
                try OverlayEditing.replace(clip.id, with: clip, in: &candidate)
            }
            try candidate.validate()
            guard candidate != project else { return }
            if gradeBaseline == nil { gradeBaseline = project; historyLabel = label }
            project = candidate; project.updatedAt = .now
            synchronizeRenderer()
            gradeTask?.cancel()
            if immediate { flushGradeHistory(); return }
            gradeTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
                self?.flushGradeHistory()
            }
        } catch { editError = error.localizedDescription }
    }

    func setShapeDuration(_ seconds: Double) {
        guard let clip = selectedShape else { return }
        editTiming(id: clip.id, operation: .trimEnd, seconds: clip.placement.timelineStart.seconds + seconds)
    }
    func detectBeats() async {
        guard let audio = selectedAudio, let media = project.assets.first(where: { $0.id == audio.assetID }) else { return }
        do {
            let times = try await AudioBeatStore.shared.beats(for: media)
            let offset = audio.placement.timelineStart.seconds - audio.sourceRange.start.seconds
            commit("Audio beats") { project in
                let existing = Set(project.timeline.markers.map { Int(($0.time.seconds * 1000).rounded()) })
                for time in times {
                    let timelineSeconds = time.seconds + offset
                    guard timelineSeconds >= 0, timelineSeconds <= project.timeline.duration.seconds,
                          !existing.contains(Int((timelineSeconds * 1000).rounded())) else { continue }
                    project.timeline.markers.append(.init(id: UUID(), time: try .seconds(timelineSeconds), label: "Beat"))
                }
                return self.selectedClipID
            }
        } catch { editError = error.localizedDescription }
    }
    var selectedText: TextClip? { if case .text(let clip) = selectedItem { return clip }; return nil }
    /// Every visible text layer at the playhead, evaluated at that frame. The
    /// canvas uses these bounds as alignment targets for the selected title.
    var visibleEvaluatedTexts: [TextClip] {
        let time = playheadTime
        return project.timeline.items.compactMap { item in
            guard case .text(let clip) = item,
                  clip.placement.timelineStart <= time,
                  let end = try? clip.placement.range.end,
                  end > time else { return nil }
            guard let local = clip.localTime(for: time) else { return clip }
            return clip.evaluated(atLocal: local)
        }
    }
    /// `immediate` closes the undo entry at once, for discrete actions such as adding a
    /// keyframe. Continuous edits leave it open so a whole drag coalesces into one entry.
    func editText(_ label: String = "Text", immediate: Bool = false, _ edit: (inout TextClip) -> Void) {
        guard canEditSelection, selectionContainsOnlyText else { return }
        do {
            var candidate = project
            for item in selectedItems {
                guard case .text(var clip) = item else { continue }
                edit(&clip)
                FontRegistry.shared.normalize(&clip.style)
                try OverlayEditing.replace(clip.id, with: clip, in: &candidate)
            }
            try candidate.validate()
            guard candidate != project else { return }
            if gradeBaseline == nil { gradeBaseline = project; historyLabel = label }
            project = candidate; project.updatedAt = .now
            // Styling changes use the live composition snapshot. No player replacement.
            synchronizeRenderer()
            gradeTask?.cancel()
            if immediate { flushGradeHistory(); return }
            gradeTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
                self?.flushGradeHistory()
            }
        } catch { editError = error.localizedDescription }
    }
    // MARK: - Keyframes
    //
    // One implementation routed to whichever animatable clip is selected. The rules
    // themselves live on `AnimatableClip` so text, video and image share them exactly.

    /// The diamond's three states, declared with the keyframe engine so the
    /// grading controls and the still-image editor can name them too.
    typealias KeyframeState = AnimationKeyframeState

    /// Playhead snapped to the project frame grid, as an exact rational time.
    /// Keyframe identity is always decided with this, never a floating-point tolerance.
    var playheadTime: TimelineTime {
        guard let raw = try? TimelineTime.seconds(timelineTime) else { return .zero }
        return (try? TimelineEditing.snapped(raw, frame: project.canvas.frameDuration)) ?? raw
    }

    /// Read-only view of the clip the keyframe controls act on.
    var animationSelection: AnimationSnapshot? {
        if let clip = selectedText { return AnimationSnapshot(clip) }
        if let clip = selectedShape { return AnimationSnapshot(clip) }
        if let clip = selectedClip { return AnimationSnapshot(clip) }
        return nil
    }

    /// Clip-local animation time of the playhead, or nil when the playhead is outside the
    /// selected clip. Nil is what disables the keyframe controls.
    var animationTime: TimelineTime? { animationSelection?.localTimeInside(playheadTime) }
    var isPlayheadInsideSelection: Bool { animationTime != nil }
    /// True when anything on the selection animates, masks included — a clip
    /// whose only animation is a mask's local exposure is still animated, and
    /// "Remove all" has to be offered for it.
    var selectionIsAnimated: Bool {
        (animationSelection?.isAnimated ?? false)
            || (selectedClip?.resolvedMaskedGrades.contains(where: \.isAnimated) ?? false)
    }

    /// The text clip as actually rendered at the playhead, for the canvas handles.
    var evaluatedText: TextClip? {
        guard let clip = selectedText else { return nil }
        guard let local = clip.localTime(for: playheadTime) else { return clip }
        return clip.evaluated(atLocal: local)
    }

    func goToSelectedClip() {
        guard let item = selectedItem, !isPreparingTimeline else { return }
        playback.pause()
        playback.seekPrecisely(to: item.placement.timelineStart.cmTime)
    }

    func supportsAnimation(_ property: AnimatableProperty) -> Bool {
        animationSelection?.supports(property) ?? false
    }

    /// Where a keyframe for this property goes: the selected masked local grade,
    /// or the clip itself.
    ///
    /// The Color controls already switch context through `settings`, so their
    /// keyframes switch with them — moving Exposure while a mask is selected
    /// animates that mask's Exposure and leaves the clip's alone. Only grading
    /// properties are redirected; mask GEOMETRY has its own panel and addresses
    /// its layer by id.
    var gradeKeyframeMaskID: UUID? { selectedMaskID }

    /// See the protocol: the Colour controls follow `selectedMaskID`, so this is
    /// the same question `settings` already answers when it decides which grade
    /// to read and write.
    var isEditingMaskGrade: Bool { selectedMaskID != nil }

    private func maskContext(for property: AnimatableProperty) -> UUID? {
        property.isGradeProperty ? gradeKeyframeMaskID : nil
    }

    func keyframeState(_ property: AnimatableProperty) -> KeyframeState {
        if let id = maskContext(for: property) { return maskKeyframeState(id, property) }
        guard let selection = animationSelection, let track = selection.animation?.track(property) else { return .off }
        guard let local = animationTime else { return .animated }
        return track.index(at: local) != nil ? .onKeyframe : .animated
    }

    /// The keyframe sitting on an exact frame, whichever context owns it. The
    /// lane's interpolation menu and delete action read this.
    func keyframe(_ property: AnimatableProperty, atLocal local: TimelineTime) -> Keyframe? {
        if let id = maskContext(for: property) {
            return maskedGrades.first { $0.id == id }?.animation?.track(property)?.keyframe(at: local)
        }
        return animationSelection?.animation?.track(property)?.keyframe(at: local)
    }

    /// Routes one authoring operation to whichever clip type is selected.
    private func applyAnimation(_ edit: AnimationEdit, label: String, immediate: Bool) {
        guard canEditSelection else { return }
        if selectedText != nil { editText(label, immediate: immediate) { $0.apply(edit) } }
        else if selectedShape != nil { editShape(label, immediate: immediate) { $0.apply(edit) } }
        else if selectedClip != nil { changeVisual(label, immediate: immediate) { $0.apply(edit) } }
    }

    func toggleKeyframe(_ property: AnimatableProperty) {
        if let id = maskContext(for: property) { toggleMaskKeyframe(id, property); return }
        guard let local = animationTime else { return }
        playback.pause()
        let adding = keyframeState(property) != .onKeyframe
        applyAnimation(.toggleKeyframe(property, atLocal: local),
                       label: adding ? "Add Keyframe" : "Remove Keyframe", immediate: true)
    }

    /// The single write path for animatable values.
    /// Unanimated -> base value. Animated -> keyframe at the playhead, seeded from the
    /// evaluated value rather than a stale base value.
    func setAnimatableValue(_ property: AnimatableProperty, _ value: KeyframeValue, immediate: Bool = false) {
        if let id = maskContext(for: property) {
            setMaskKeyframeValue(id, property, value, immediate: immediate); return
        }
        guard let selection = animationSelection else { return }
        // Position is WHERE a layer sits, so writing one value to several layers
        // would pile them all on the same spot - four lines of a title collapsing
        // into one the moment Position Y moved. Every other property means the
        // same thing on each layer ("make these all 40pt") and stays absolute.
        if movesSelectionTogether(property), case .number(let target) = value,
           let current = animatableValue(property)?.number {
            offsetSelection(property, by: target-current, label: property.title, immediate: immediate)
            return
        }
        let animated = selection.animation?.track(property) != nil
        if animated && animationTime == nil {
            editError = String(localized: "Move the playhead inside the clip to change an animated value.")
            return
        }
        if animated { playback.pause() }
        applyAnimation(.setValue(property, value, atLocal: animationTime), label: property.title, immediate: immediate)
    }

    /// Whether a change to this property has to move the selection as a block
    /// rather than write the same number to every layer in it.
    private func movesSelectionTogether(_ property: AnimatableProperty) -> Bool {
        selectedClipIDs.count > 1 && (property == .positionX || property == .positionY)
    }

    /// Moves every selected layer by the same amount, so each keeps its own
    /// place. The group drag on the canvas, a position slider with more than one
    /// layer selected, and `alignSelection` all write through here.
    func offsetSelection(_ property: AnimatableProperty, by delta: Double, label: String, immediate: Bool = false) {
        guard canEditSelection, delta != 0 else { return }
        if animationSelection?.animation?.track(property) != nil {
            guard animationTime != nil else {
                editError = String(localized: "Move the playhead inside the clip to change an animated value.")
                return
            }
            playback.pause()
        }
        applyAnimation(.offsetValue(property, by: delta, atComposition: playheadTime),
                       label: label, immediate: immediate)
    }

    /// The size drawn layers are authored against - the same reduced preview
    /// surface the canvas handles and the compositor measure in.
    var previewCanvasSize: CGSize {
        SequenceComposition.previewRenderSize(width: project.canvas.width, height: project.canvas.height)
    }

    /// Every selected drawn layer as canvas geometry, evaluated at the playhead,
    /// so the outlines and the alignment controls measure the same shapes.
    func selectedOverlays(canvas: CGSize) -> [CanvasOverlay] {
        let time = playheadTime
        return selectedItems.compactMap { item in
            switch item {
            case .text(let clip): CanvasOverlay(clip.evaluated(at: time), canvas: canvas)
            case .shape(let clip): CanvasOverlay(clip.evaluated(at: time), canvas: canvas)
            case .video(let clip):
                isOverlayTrack(clip.placement.trackID) ? displaySize(of: clip).map {
                    CanvasOverlay(clip.evaluated(at: time), displaySize: $0, canvas: canvas)
                } : nil
            case .audio: nil
            }
        }
    }

    /// Alignment moves everything it measures, so it needs one edit path for the
    /// whole selection - the same condition a group drag has. A mixed selection
    /// would otherwise measure four layers and move one.
    var canAlignSelection: Bool {
        canEditSelection && (selectedClipIDs.count == 1 || selectionMovesAsAGroup)
    }

    /// Places the selection against the canvas as ONE block.
    ///
    /// Every selected layer moves by the same amount, so a four-line title keeps
    /// its spacing and its ragged edges. Centring each line on its own instead
    /// would be identical for one layer and would stack all four vertically.
    func alignSelection(_ alignment: CanvasAlignment) {
        guard canAlignSelection else { return }
        let canvas = previewCanvasSize
        var union: CGRect?
        for overlay in selectedOverlays(canvas: canvas) {
            let bounds = overlay.screenBounds(canvas: canvas)
            union = union.map { $0.union(bounds) } ?? bounds
        }
        guard let union, canvas.width > 0, canvas.height > 0 else { return }
        // `positionX`/`positionY` are the LAST translation in the placement
        // matrix, so screen bounds follow them one for one whatever the anchor,
        // scale and rotation are. That makes the offset an exact solve.
        let delta: Double = switch alignment {
        case .left: Double(-union.minX)/Double(canvas.width)
        case .centerHorizontally: Double(canvas.width/2-union.midX)/Double(canvas.width)
        case .right: Double(canvas.width-union.maxX)/Double(canvas.width)
        case .top: Double(-union.minY)/Double(canvas.height)
        case .centerVertically: Double(canvas.height/2-union.midY)/Double(canvas.height)
        case .bottom: Double(canvas.height-union.maxY)/Double(canvas.height)
        }
        offsetSelection(alignment.isHorizontal ? .positionX : .positionY,
                        by: delta, label: alignment.title, immediate: true)
    }

    /// Evaluated value at the playhead: what a control should show and start editing from.
    func animatableValue(_ property: AnimatableProperty) -> KeyframeValue? {
        if let id = maskContext(for: property) {
            return displayedMask(id)?.baseKeyframeValue(of: property)
        }
        guard let selection = animationSelection, let local = selection.localTime(for: playheadTime) else { return nil }
        return selection.evaluatedValue(property, local)
    }

    func animatableNumber(_ property: AnimatableProperty) -> Binding<Double> {
        Binding(get: { [weak self] in self?.animatableValue(property)?.number ?? 0 },
                set: { [weak self] in self?.setAnimatableValue(property, .number($0)) })
    }
    func animatableColor(_ property: AnimatableProperty) -> Binding<RGBAColor> {
        Binding(get: { [weak self] in self?.animatableValue(property)?.color ?? .white },
                set: { [weak self] in self?.setAnimatableValue(property, .color($0)) })
    }

    func visibleKeyframes(_ property: AnimatableProperty) -> [(local: TimelineTime, timeline: TimelineTime)] {
        if let id = maskContext(for: property) { return maskVisibleKeyframes(id, property) }
        return animationSelection?.visibleKeyframes(property) ?? []
    }

    func keyframeNeighbour(_ property: AnimatableProperty, forward: Bool) -> TimelineTime? {
        let times = visibleKeyframes(property).map(\.timeline)
        let now = playheadTime
        return forward ? times.first { $0 > now } : times.last { $0 < now }
    }

    func seekToKeyframe(_ property: AnimatableProperty, forward: Bool) {
        guard let target = keyframeNeighbour(property, forward: forward), !isPreparingTimeline else { return }
        playback.pause()
        playback.seekPrecisely(to: target.cmTime)
    }

    func setKeyframeInterpolation(_ mode: KeyframeInterpolation, property: AnimatableProperty, atLocal local: TimelineTime) {
        if let id = maskContext(for: property) {
            updateMask(id, label: "Interpolation", immediate: true) {
                $0.animation?.update(property) { $0.setInterpolation(mode, at: local) }
            }
            return
        }
        applyAnimation(.setInterpolation(mode, property, atLocal: local), label: "Interpolation", immediate: true)
    }

    /// Retiming. `committing` closes the undo entry so a whole drag is one action.
    func moveKeyframe(_ property: AnimatableProperty, from: TimelineTime, to requested: TimelineTime, committing: Bool) {
        guard let selection = animationSelection else { return }
        let frame = project.canvas.frameDuration ?? (try? .seconds(1.0/30)) ?? .zero
        let snapped = (try? TimelineEditing.snapped(requested, frame: project.canvas.frameDuration)) ?? requested
        // Never leave the clip's own range.
        let lower = selection.animation?.startOffset ?? .zero
        let upper = (try? lower.adding(selection.placement.duration).subtracting(frame)) ?? lower
        let bounded = min(max(snapped, lower), upper)
        if let id = maskContext(for: property) {
            updateMask(id, label: "Move Keyframe", immediate: committing) {
                $0.animation?.update(property) { $0.move(from: from, to: bounded, minimumSpacing: frame) }
            }
            return
        }
        applyAnimation(.moveKeyframe(property, from: from, to: bounded, spacing: frame),
                       label: "Move Keyframe", immediate: committing)
    }

    func removeKeyframe(_ property: AnimatableProperty, atLocal local: TimelineTime) {
        if let id = maskContext(for: property) {
            removeMaskKeyframe(id, property, atLocal: local); return
        }
        applyAnimation(.removeKeyframe(property, atLocal: local), label: "Remove Keyframe", immediate: true)
    }

    /// Stops animating a property but keeps what is currently on screen.
    func removeAnimation(of property: AnimatableProperty) {
        if let id = maskContext(for: property) { removeMaskAnimation(id, property); return }
        applyAnimation(.removeAnimation(property, atLocal: animationSelection?.localTime(for: playheadTime)),
                       label: "Remove Animation", immediate: true)
    }

    /// Restores the documented default AND removes the property's animation.
    func resetProperty(_ property: AnimatableProperty) {
        if let id = maskContext(for: property) { resetMaskProperty(id, property); return }
        applyAnimation(.resetProperty(property), label: "Reset \(property.title)", immediate: true)
    }

    /// Broad action: the UI confirms before calling this.
    ///
    /// Reaches the masked local grades too, in the same undo entry. A clip that
    /// reports no animation afterwards has to actually have none, or the picture
    /// would still change during playback.
    func removeAllAnimation() {
        guard selectionIsAnimated, canEditSelection else { return }
        let local = animationSelection?.localTime(for: playheadTime)
        // What is on screen right now, gathered before anything is removed, so
        // every property keeps the value the user can see.
        let clipHeld: [(AnimatableProperty, KeyframeValue)] = selectedClip.map { clip in
            guard let local, let animation = clip.animation else { return [] }
            return animation.animatedProperties.compactMap { property in
                clip.evaluatedValue(of: property, atLocal: local).map { (property, $0) }
            }
        } ?? []
        // Lights carry their own tracks, as masks do; each keeps what is on
        // screen.
        let relightHeld = local.flatMap { time in
            selectedClip?.resolvedRelight.flatMap { $0.isAnimated ? $0.evaluated(atLocal: time) : nil }
        }
        let maskHeld: [UUID: [(AnimatableProperty, KeyframeValue)]] = maskedGrades.reduce(into: [:]) { result, layer in
            guard let local, let animation = layer.animation, !animation.isEmpty else { return }
            let evaluated = layer.evaluated(atLocal: local)
            result[layer.id] = animation.animatedProperties.compactMap { property in
                evaluated.baseKeyframeValue(of: property).map { (property, $0) }
            }
        }
        changeVisual("Remove All Animation", immediate: true) { clip in
            clip.animation = nil
            for (property, value) in clipHeld { clip.setBaseValue(value, of: property) }
            if var flattened = relightHeld, var advanced = clip.gradeSettings.advanced, advanced.relight != nil {
                flattened.animation = nil
                for index in flattened.lights.indices { flattened.lights[index].animation = nil }
                advanced.relight = flattened
                clip.gradeSettings.advanced = advanced
            }
            guard var masks = clip.maskedGrades else { return }
            for index in masks.indices {
                masks[index].animation = nil
                for (property, value) in maskHeld[masks[index].id] ?? [] {
                    masks[index].setBaseKeyframeValue(value, of: property)
                }
            }
            clip.maskedGrades = masks
        }
    }

    /// Timeline positions of the selected clip's keyframes, for the timeline indicators.
    var selectedClipKeyframeTimes: [Double] { animationSelection?.keyframeSeconds ?? [] }

    // MARK: - Text animation presets
    //
    // Presets are authored state, not keyframes. Nothing here writes to
    // `ClipAnimation`, and `removeAllAnimation` still clears only the manual
    // keyframes — the two features stay separable, which is the whole point of
    // keeping a preset a preset.

    /// What the Animation panel shows. Defaults for a title that has never been
    /// animated, so the panel never has to unwrap.
    var textAnimationSettings: TextAnimationSettings { selectedText?.textAnimation ?? .init() }

    /// True when the selected title carries any preset, for the tab's dot.
    var hasTextAnimation: Bool { selectedText?.textAnimation?.isEmpty == false }

    /// One write path, so every animation control is an ordinary undo step and a
    /// slider drag coalesces into one entry exactly as the grading sliders do.
    func editTextAnimation(_ label: String, immediate: Bool = true,
                           _ edit: @escaping (inout TextAnimationSettings) -> Void) {
        editText(label, immediate: immediate) { clip in
            var settings = clip.textAnimation ?? .init()
            edit(&settings)
            clip.textAnimation = settings.isEmpty ? nil : settings
        }
    }

    func setTextAnimation(_ preset: TextAnimationPreset?, for slot: TextAnimationSlot) {
        editTextAnimation(String(localized: "Text Animation")) { $0.setPreset(preset, for: slot) }
        if preset != nil { previewTextAnimation(slot) }
    }

    func setTextAnimationDuration(_ seconds: Double, for slot: TextAnimationSlot, immediate: Bool = false) {
        guard let time = try? TimelineTime.seconds(seconds) else { return }
        editTextAnimation(String(localized: "Animation Duration"), immediate: immediate) {
            $0.setDuration(time, for: slot)
        }
    }

    func setTextAnimationStrength(_ strength: Double, immediate: Bool = false) {
        editTextAnimation(String(localized: "Animation Strength"), immediate: immediate) {
            $0.strength = min(max(strength, 0), 1)
        }
    }

    func setTextAnimationLoopSpeed(_ speed: Double, immediate: Bool = false) {
        editTextAnimation(String(localized: "Animation Speed"), immediate: immediate) {
            $0.loopSpeed = min(max(speed, 0.25), 3)
        }
    }

    /// Clears the three preset slots and nothing else. Manual keyframes on
    /// position, scale, colour and the rest survive untouched.
    func removeAllTextAnimation() {
        editText(String(localized: "Remove Text Animation"), immediate: true) { $0.textAnimation = nil }
    }

    /// The longest an In or Out may be on this title: never more than the clip.
    var textAnimationDurationLimit: Double {
        guard let clip = selectedText else { return TextAnimationSettings.maximumDuration }
        return max(TextAnimationSettings.minimumDuration,
                   min(TextAnimationSettings.maximumDuration, clip.placement.duration.seconds))
    }

    /// Plays the part of the title the user is actually tuning, so picking a
    /// preset or nudging its duration shows the result without hunting for the
    /// right frame first.
    func previewTextAnimation(_ slot: TextAnimationSlot) {
        guard let clip = selectedText, !isPreparingTimeline else { return }
        let settings = clip.textAnimation ?? .init()
        let duration = clip.placement.duration.seconds
        let start = clip.placement.timelineStart.seconds
        let window = TextAnimator.windows(settings, duration: duration)
        let from: Double, to: Double
        switch slot {
        case .incoming:
            from = start
            to = start + max(window.incoming, 0.25)
        case .outgoing:
            to = start + duration
            from = max(start, to - max(window.outgoing, 0.25))
        case .loop:
            // Start where the loop actually takes over, and run a couple of its
            // own cycles rather than a fixed wall-clock slice.
            from = min(start + window.incoming, start + duration)
            to = min(from + 4 / max(settings.loopSpeed, 0.25), start + duration)
        }
        textAnimationPreview?.cancel()
        playback.pause()
        playback.seekPrecisely(to: from)
        textAnimationPreview = Task { @MainActor [weak self] in
            guard let self else { return }
            self.playback.play()
            try? await Task.sleep(for: .seconds(max(0.25, to-from)))
            guard !Task.isCancelled else { return }
            self.playback.pause()
            self.playback.seekPrecisely(to: to)
        }
    }

    func setTextDuration(_ seconds: Double) {
        guard let clip = selectedText else { return }
        editTiming(id: clip.id, operation: .trimEnd, seconds: clip.placement.timelineStart.seconds + seconds)
    }
    func applyTextPreset(_ preset: TextStylePreset) {
        editText { clip in
            clip.style.isBold = preset.style.isBold
            clip.color = preset.color; clip.strokeColor = preset.strokeColor
            clip.strokeWidth = preset.strokeWidth; clip.backgroundColor = preset.backgroundColor; clip.backgroundOpacity = preset.backgroundOpacity
            clip.gradient = preset.gradient
        }
    }
    var canUndo: Bool { gradeBaseline != nil || !history.undoEntries.isEmpty }
    var canRedo: Bool { gradeBaseline == nil && !history.redoEntries.isEmpty }

    func flushGradeHistory() {
        gradeTask?.cancel(); gradeTask = nil
        if let before = gradeBaseline { history.record(historyLabel, before: before, after: project) }
        gradeBaseline = nil
        historyLabel = "Color"
    }

    /// A document write from a control that is being dragged.
    ///
    /// The path `globalSettings` already takes for every colour slider — write
    /// the project, refresh the preview, and let the pending history flush turn
    /// the whole gesture into one undo entry — made available to a continuous
    /// control that lives in another file. `project` and `gradeBaseline` are
    /// `private(set)` on purpose, so this is the door rather than a widening of
    /// their access.
    ///
    /// - Returns: whether anything actually changed.
    @discardableResult
    func applyCoalescedGradeEdit(label: String, _ edit: (inout VideoProject) -> Bool) -> Bool {
        let before = project
        var updated = project
        guard edit(&updated) else { return false }
        if gradeBaseline == nil { gradeBaseline = before }
        updated.updatedAt = .now
        project = updated
        synchronizeRenderer()
        scheduleGradeHistoryFlush(label: label)
        return true
    }

    /// Closes the open coalesced edit a moment after the last write, under a
    /// name of the caller's choosing.
    ///
    /// The same mechanism the colour sliders use, lifted out so a continuous
    /// control outside this file — Match Strength — can produce one undo entry
    /// per gesture rather than one per frame of the drag, and can have that
    /// entry say what it was.
    func scheduleGradeHistoryFlush(label: String) {
        historyLabel = label
        gradeTask?.cancel()
        gradeTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            self?.flushGradeHistory()
        }
    }

    /// Renaming a layer changes nothing the compositor reads, so it must not tear down and
    /// rebuild the player the way a structural edit does.
    func renameTrack(_ id: UUID, to proposed: String) {
        guard let track = project.timeline.tracks.first(where: { $0.id == id }) else { return }
        let name = TimelineTrack.sanitizedName(proposed, kind: track.kind)
        guard name != track.name else { return }
        commit("Rename Layer", rebuildsSequence: false) { project in
            guard let index = project.timeline.tracks.firstIndex(where: { $0.id == id }) else { return self.selectedClipID }
            project.timeline.tracks[index].name = name
            return self.selectedClipID
        }
    }

    func commit(_ name: String, seekToSelection: Bool = false, rebuildsSequence: Bool = true,
                edit: (inout VideoProject) throws -> UUID?) {
        flushGradeHistory()
        do {
            let before = project
            var after = before
            let selection = try edit(&after)
            try TimelineTransitionEditing.reconcile(in: &after)
            // Track matte relationships are repaired on every mutation, not only
            // when one is edited: deleting the layer a matte points at has to
            // clear the relationship in the SAME undo step that removed it.
            after.timeline.reconcileTrackMattes()
            _ = try TimelineEditing.clips(in: after)
            guard before.timeline != after.timeline || before.canvas != after.canvas
                    || before.assets != after.assets else {
                selectedClipID = selection
                selectedClipIDs = Set(selection.map { [$0] } ?? [])
                return
            }
            after.updatedAt = .now
            history.record(name, before: before, after: after)
            project = after; selectedClipID = selection
            selectedClipIDs = Set(selection.map { [$0] } ?? [])
            if let selection, let item = after.timeline.item(id: selection) { selectedTrackID = item.placement.trackID }
            if rebuildsSequence,
               before.timeline.tracks != after.timeline.tracks ||
               before.timeline.transitions != after.timeline.transitions ||
               before.canvas != after.canvas || before.assets != after.assets {
                rebuildSequence(at: seekToSelection ? selectedItem?.placement.timelineStart.seconds : nil)
            } else {
                synchronizeRenderer()
            }
        } catch { editError = error.localizedDescription }
    }

    /// A tracking pass is one normal, validated history operation. Resolve by
    /// captured clip/mask ID so changing selection cannot redirect the result.
    func commitMaskTracking(_ plan: MaskTrackingPlan, animation: ClipAnimation) -> Bool {
        let previousError = editError
        editError = nil
        commit(plan.request.direction.title, rebuildsSequence: false) { project in
            var clip = try TimelineEditing.editable(plan.request.clip.id, in: project)
            var masks = clip.resolvedMaskedGrades
            guard let index = masks.firstIndex(where: { $0.id == plan.original.id }) else {
                throw MaskTrackingError.message(String(localized: "The tracked mask was removed."))
            }
            var combined = masks[index].animation ?? ClipAnimation()
            combined.tracks.removeAll { MaskTrackingMotion.properties.contains($0.property) }
            combined.tracks += animation.tracks.filter { MaskTrackingMotion.properties.contains($0.property) }
            masks[index].animation = combined
            // A head extension can expose negative animation-local time. The
            // generic engine holds the first key there; new keys must remain
            // nonnegative. Rebase the shared window and every track together.
            if plan.request.visibleStart < .zero {
                let shift = try TimelineTime.zero.subtracting(plan.request.visibleStart)
                var window = clip.animation ?? ClipAnimation()
                window.startOffset = try window.startOffset.adding(shift)
                window.tracks = window.tracks.map { track in
                    var moved = track; moved.shift(by: shift); return moved
                }
                clip.animation = window
                for i in masks.indices {
                    guard var animation = masks[i].animation else { continue }
                    animation.tracks = animation.tracks.map { track in
                        var moved = track; moved.shift(by: shift); return moved
                    }
                    masks[i].animation = animation
                }
            }
            clip.maskedGrades = masks
            try TimelineEditing.replace(clip.id, with: [clip], in: &project)
            return self.selectedClipID
        }
        let succeeded = editError == nil
        if succeeded { editError = previousError }
        return succeeded
    }

    var canSplit: Bool {
        guard selectedClipIDs.count == 1, !isPreparingTimeline,
              let time = try? TimelineTime.seconds(timelineTime) else { return false }
        if selectedTrack?.kind == .audio { return AudioEditing.splitTarget(in: project, at: time, trackID: selectedTrackID) != nil }
        if selectedTrack?.kind == .text || selectedTrack?.kind == .shape {
            return OverlayEditing.splitTarget(in: project, at: time, trackID: selectedTrackID) != nil
        }
        return TimelineEditing.splitTarget(in: project, at: time, trackID: selectedTrack?.id) != nil
    }
    func split() {
        if selectedTrack?.kind == .text || selectedTrack?.kind == .shape {
            guard let time = try? TimelineTime.seconds(timelineTime),
                  let id = OverlayEditing.splitTarget(in: project, at: time, trackID: selectedTrackID) else { return }
            commit(selectedTrack?.kind == .shape ? "Split shape" : "Split text") {
                try OverlayEditing.split(id, at: time, in: &$0)
            }
            return
        }
        if selectedTrack?.kind == .audio {
            guard let time = try? TimelineTime.seconds(timelineTime), let id = AudioEditing.splitTarget(in: project, at: time, trackID: selectedTrackID) else { return }
            commit("Split audio") { try AudioEditing.split(id, at: time, in: &$0) }
            return
        }
        guard let time = try? TimelineTime.seconds(timelineTime),
              let id = TimelineEditing.splitTarget(in: project, at: time, trackID: selectedTrack?.id) else { return }
        commit("Split") { try TimelineEditing.split(id, at: TimelineTime.seconds(self.timelineTime), in: &$0) }
    }
    func copyClip() { if selectedClipIDs.count == 1, let selectedItem { clipboard = selectedItem } }
    func deleteClip(cutting: Bool = false) {
        guard let id = selectedClipID else { return }
        let copy = selectedItem
        let targets = cutting ? Set([id]) : selectedClipIDs
        commit(cutting ? "Cut" : "Delete") {
            for target in targets where $0.timeline.item(id: target) != nil {
                if $0.timeline.audioClip(id: target) != nil { try AudioEditing.replace(target, with: [], in: &$0) }
                else if $0.timeline.item(id: target)?.isDrawnOverlay == true { try OverlayEditing.delete(target, in: &$0) }
                else { try TimelineEditing.deleteClosingGaps(target, in: &$0) }
            }
            return nil
        }
        if cutting, project.timeline.item(id: id) == nil { clipboard = copy }
    }
    func pasteClip() {
        guard let clipboard else { return }
        commit("Paste") { project in
            switch clipboard {
            case .video(let clip): return try TimelineEditing.paste(clip, at: .seconds(self.timelineTime), in: &project)
            case .audio(let clip): return try AudioEditing.paste(clip, at: .seconds(self.timelineTime), trackID: self.selectedTrackID, in: &project)
            case .text(let clip): return try OverlayEditing.paste(clip, at: .seconds(self.timelineTime), in: &project)
            case .shape(let clip): return try OverlayEditing.paste(clip, at: .seconds(self.timelineTime), in: &project)
            }
        }
    }
    /// Playback speed of the selected video clip, or 1 when nothing is selected.
    var selectedSpeed: Double {
        selectedClip?.speed ?? ClipSpeed.normal
    }

    /// Whether a speed change is currently possible: video clips only, and not
    /// while the clip or its track is locked.
    var canChangeSpeed: Bool {
        selectedClip != nil && canEditSelection
    }

    /// Applies a speed change.
    ///
    /// `live` is for slider dragging: the timeline updates immediately so the
    /// clip resizes under the finger, but the expensive parts — recording undo
    /// history and rebuilding the AVComposition — are deferred until the drag
    /// settles. Doing those on every tick would spam undo and tear the player
    /// down dozens of times per drag.
    func setSpeed(_ speed: Double, live: Bool = false) {
        guard let id = selectedClipID, canChangeSpeed else { return }
        do {
            var candidate = project
            try TimelineEditing.setSpeed(id, to: speed, in: &candidate)
            try TimelineTransitionEditing.reconcile(in: &candidate)
            guard candidate.timeline != project.timeline else { return }
            if gradeBaseline == nil { gradeBaseline = project; historyLabel = "Speed" }
            project = candidate
            project.updatedAt = .now
            speedTask?.cancel()
            guard live else { settleSpeedEdit(); return }
            speedTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(320)) } catch { return }
                self?.settleSpeedEdit()
            }
        } catch {
            editError = error.localizedDescription
        }
    }

    /// The door every ramp edit comes through.
    ///
    /// Exactly what `setSpeed` does, made available to the ramp editing that
    /// lives in `SpeedRampEditing.swift`: write the project now so the timeline
    /// and the curve move under the finger, and defer the two expensive parts —
    /// the undo entry and the composition rebuild — until the gesture settles.
    /// `project`, `gradeBaseline` and the debounce task are all private on
    /// purpose, so this is the door rather than a widening of their access.
    ///
    /// - Parameter live: true while a drag is in flight. One drag becomes one
    ///   undo entry, not one per frame of it.
    @discardableResult
    func applyRetimingEdit(label: String, live: Bool,
                           _ edit: (inout VideoProject) throws -> Void) -> Bool {
        guard let _ = selectedClipID, canChangeSpeed else { return false }
        do {
            var candidate = project
            try edit(&candidate)
            try TimelineTransitionEditing.reconcile(in: &candidate)
            guard candidate.timeline != project.timeline else { return false }
            if gradeBaseline == nil { gradeBaseline = project; historyLabel = label }
            project = candidate
            project.updatedAt = .now
            speedTask?.cancel()
            guard live else { settleSpeedEdit(); return true }
            speedTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(320)) } catch { return }
                self?.settleSpeedEdit()
            }
            return true
        } catch {
            editError = error.localizedDescription
            return false
        }
    }

    /// Applies any speed change still waiting on the debounce.
    ///
    /// The model updates on every slider tick but the composition rebuild is
    /// deferred. If that deferred work is skipped — leaving the tool, closing
    /// the panel — the player keeps a composition whose duration no longer
    /// matches the timeline, and the clip stops playing. Calling this whenever
    /// the panel goes away closes that window.
    func settlePendingSpeedEdit() {
        guard speedTask != nil else { return }
        settleSpeedEdit()
    }

    /// Records the undo entry and rebuilds the composition once the drag stops.
    private func settleSpeedEdit() {
        speedTask?.cancel(); speedTask = nil
        flushGradeHistory()
        rebuildSequence()
    }

    var smoothsMotion: Bool { selectedClip?.smoothsMotion ?? false }

    /// Available in both colour modes. An HDR project composites through the
    /// half-float working-space path, where the two frames are mixed in linear
    /// light before grading, so nothing is clipped at diffuse white.
    var canSmoothMotion: Bool {
        canChangeSpeed && (selectedClip?.isRetimed ?? false)
    }

    var smoothingUnavailableReason: String? {
        guard canChangeSpeed else { return nil }
        if selectedClip?.isRetimed == false {
            return String(localized: "Change the speed first. At normal speed every frame already lands on a source frame, so there is nothing to blend.")
        }
        return nil
    }

    func setSmoothsMotion(_ smooths: Bool) {
        guard let id = selectedClipID, canSmoothMotion || !smooths else { return }
        commit(smooths ? "Smooth motion" : "Sharp frames") { project in
            var clip = try TimelineEditing.editable(id, in: project)
            clip.smoothsMotion = smooths
            try TimelineEditing.replace(id, with: [clip], in: &project)
            return id
        }
    }

    func duplicateClip() {
        guard let item = selectedItem else { return }
        commit("Duplicate") { project in
            switch item {
            case .video(let clip): return try TimelineEditing.paste(clip, at: clip.placement.range.end, in: &project)
            case .audio(let clip): return try AudioEditing.paste(clip, at: clip.placement.range.end, trackID: clip.placement.trackID, in: &project)
            case .text(let clip): return try OverlayEditing.paste(clip, at: clip.placement.range.end, in: &project)
            case .shape(let clip): return try OverlayEditing.paste(clip, at: clip.placement.range.end, in: &project)
            }
        }
    }
    /// Trims every selected clip by the same amount, in one undo step.
    ///
    /// `delta` is travel, not a destination: each clip applies it to its own
    /// edge, so clips of different lengths keep their difference instead of
    /// being flattened to a shared time. The drag has already clamped it to
    /// what the most restricted clip can give, and this re-clamps per clip
    /// anyway — a keyframe-accurate limit is the editing layer's to enforce,
    /// not the gesture's.
    func trimClips(_ ids: Set<UUID>, operation: TimelineGestureEdit, delta: Double) {
        guard operation != .move, delta != 0, !ids.isEmpty else { return }
        commit(operation.rawValue) { project in
            // The id list is fixed up front so nothing is missed or visited
            // twice, but each edge is read back from the project as it is
            // reached. That matters on the main row: trimming one clip there
            // repacks the row and carries the next one along with it, so a
            // position captured beforehand would be stale by the time it is
            // used and the second clip would come out unchanged.
            for id in project.timeline.items.map(\.id) where ids.contains(id) {
                guard let item = project.timeline.item(id: id) else { continue }
                let edge = operation == .trimEnd
                    ? ((try? item.placement.range.end.seconds) ?? 0)
                    : item.placement.timelineStart.seconds
                let target = try TimelineTime.seconds(max(0, edge + delta))
                if project.timeline.audioClip(id: id) != nil {
                    try AudioEditing.edit(id, operation: operation, to: target, clamping: true, in: &project)
                } else if item.isDrawnOverlay {
                    try OverlayEditing.edit(id, operation: operation, to: target, in: &project)
                } else {
                    try TimelineEditing.trimClosingGaps(
                        id, edge: operation == .trimStart ? .left : .right, to: target, in: &project)
                }
            }
            return self.selectedClipID
        }
    }

    func editTiming(id: UUID, operation: TimelineGestureEdit, seconds: Double) {
        commit(operation.rawValue) { project in
            let time = try TimelineTime.seconds(seconds)
            if project.timeline.audioClip(id: id) != nil {
                try AudioEditing.edit(id, operation: operation, to: time, clamping: true, in: &project)
                return id
            }
            if project.timeline.item(id: id)?.isDrawnOverlay == true {
                try OverlayEditing.edit(id, operation: operation, to: time, in: &project)
                return id
            }
            switch operation {
            case .move: try TimelineEditing.insertMove(id, to: time, in: &project)
            case .trimStart: try TimelineEditing.trimClosingGaps(id, edge: .left, to: time, in: &project)
            case .trimEnd: try TimelineEditing.trimClosingGaps(id, edge: .right, to: time, in: &project)
            }
            return id
        }
    }
    func undo() {
        flushGradeHistory()
        guard let snapshot = history.undo() else { return }
        restore(snapshot)
    }
    func redo() {
        flushGradeHistory()
        guard let snapshot = history.redo() else { return }
        restore(snapshot)
    }

    /// Adopts a history snapshot and carries the selection over to it.
    ///
    /// The whole selection survives, minus whatever the snapshot no longer
    /// contains. Rebuilding it from the primary clip alone - which is what this
    /// used to do - silently threw away the other layers immediately after a
    /// group edit, so the undo of a change to four titles left one selected.
    private func restore(_ snapshot: VideoProject) {
        project = snapshot; project.updatedAt = .now
        if selectedTransitionID.flatMap({ id in project.timeline.transitions.first { $0.id == id } }) == nil {
            selectedTransitionID = nil
        }
        let surviving = Set(project.timeline.items.lazy.map(\.id).filter(selectedClipIDs.contains))
        if selectedItem == nil {
            // A stable timeline order chooses the replacement, never a Set's.
            selectedClipID = project.timeline.items.first { surviving.contains($0.id) }?.id
                ?? project.timeline.items.first?.id
        }
        selectedClipIDs = surviving.isEmpty ? Set(selectedClipID.map { [$0] } ?? []) : surviving
        selectedTrackID = selectedItem?.placement.trackID
        rebuildSequence()
    }

    /// The auto-stop for an animation preview. Cancelled whenever another
    /// preview starts, so tapping through the tiles does not leave a queue of
    /// pauses fighting each other.
    private var textAnimationPreview: Task<Void, Never>?

    private var previewSuspendedForExport = false

    func suspendPreviewForExport() {
        guard !previewSuspendedForExport else { return }
        previewSuspendedForExport = true
        stopMaskTracking()
        sequenceTask?.cancel()
        sequenceTask = nil
        isPreparingTimeline = false
        playback.releaseSequenceResources()
        layerState = nil
    }

    func resumePreviewAfterExport() {
        guard previewSuspendedForExport else { return }
        previewSuspendedForExport = false
        rebuildSequence(at: playback.currentTime)
    }

    private func rebuildSequence(at requestedTime: Double? = nil) {
        guard !previewSuspendedForExport else { return }
        sequenceTask?.cancel()
        playback.pause()
        let snapshot = project, time = requestedTime ?? timelineTime
        synchronizeRenderer()
        guard hasMedia else { playback.clearSequence(); isPreparingTimeline = false; return }
        isPreparingTimeline = true
        // Read here, on the main actor, so the catch below can tell a build the
        // document required from one a tool merely asked for.
        let forceLayers = forceLayerPreview
        sequenceTask = Task { [weak self] in
            do {
                let sequence = try await forceLayers ? SequenceComposition.buildLayers(project: snapshot, forExport: false) : SequenceComposition.build(project: snapshot, forExport: false)
                guard !Task.isCancelled, let self else { return }
                self.layerState = sequence.layerState
                self.sequenceSource = sequence.source
                self.audioRouting = sequence.audioRouting
                self.layerState?.update(self.project, bypass: self.showsOriginal,
                                        inspectingMatteOn: self.inspectedMatteTargetID,
                                        inspectingBackgroundOn: self.showsBackgroundMatte ? self.selectedClipID : nil,
                                        showsTransparencyGrid: !self.showsOriginal && !self.showsBackgroundMatte
                                            && self.selectedBackgroundRemoval?.isEnabled == true)
                // The composited frame's real size, which is smaller than the
                // canvas when preview is downscaled for performance.
                self.renderer.setComposited(
                    sequence.layerState != nil,
                    canvas: CGSize(width: sequence.source.encodedWidth, height: sequence.source.encodedHeight))
                self.playback.replaceSequence(sequence, at: time)
                self.isPreparingTimeline = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                // The forced layer preview is what a tool asks for, not something
                // the document requires, so a failure has to release it. Left set,
                // every later rebuild took the same failing path and the preview
                // never came back.
                let wasForced = forceLayers && !snapshot.needsLayerCompositor
                self.forceLayerPreview = false
                if wasForced {
                    // The project plays perfectly well without the compositor, so
                    // rebuild the way it would have built on its own rather than
                    // leaving the user with no picture. Keeping the previous
                    // sequence instead would be worse: it describes a project
                    // this one no longer is, and grading against a stale frame is
                    // harder to notice than having none.
                    self.rebuildSequence(at: time)
                } else {
                    self.playback.clearSequence()
                    self.sequenceSource = nil
                    self.temporalFrameCache = nil
                    self.renderer.setTemporalFrames(nil, capability: self.noiseCapability)
                    self.isPreparingTimeline = false
                }
                self.editError = error.localizedDescription
            }
        }
    }

    /// True when any finishing effect is doing something on the selected clip.
    var hasFilmEffects: Bool {
        !(settings.advanced?.resolvedEffects.isNeutral ?? true)
    }

    func resetFilmEffects() {
        advancedBinding(\.effects).wrappedValue = nil
    }

    var visibleParameters: [GradeParameter] {
        selectedPanel == .light ? GradeParameter.light : GradeParameter.color
    }

    var canGrade: Bool {
        guard let selectedClipID, let clip = project.timeline.videoClip(id: selectedClipID) else { return false }
        return colorSupport.allowsGrading && !clip.placement.isLocked &&
            project.timeline.tracks.first(where: { $0.id == clip.placement.trackID })?.isLocked == false
    }

    var timelineTime: Double {
        max(0, min(project.timeline.duration.seconds, playback.maximumSeekTime, playback.currentTime))
    }

    func selectClip(_ selected: Bool) {
        selectClip(id: selected ? project.timeline.firstVideoClip?.id : nil)
    }

    func selectClip(id: UUID?, seek: Bool = true) {
        selectedTransitionID = nil
        flushGradeHistory()
        // Masks belong to a clip, so the context cannot outlive the selection.
        selectedMaskID = nil
        maskMatteID = nil
        // The matte view belongs to the layer it was opened on.
        inspectedMatteTargetID = nil
        isDrawingMask = false
        if !availablePanels.contains(selectedPanel) { selectedPanel = .light }
        selectedClipID = id
        selectedClipIDs = Set(id.map { [$0] } ?? [])
        if let clip = selectedItem { selectedTrackID = clip.placement.trackID }
        if let clip = selectedItem, seek, !isPreparingTimeline,
           timelineTime < clip.placement.timelineStart.seconds || timelineTime >= ((try? clip.placement.range.end.seconds) ?? 0) {
            playback.seekPrecisely(to: clip.placement.timelineStart.cmTime)
        }
    }

    /// Makes a marquee selection without seeking away from the frame being
    /// inspected. A stable timeline order chooses the primary inspector item.
    func selectClips(_ ids: Set<UUID>) {
        selectedTransitionID = nil
        flushGradeHistory()
        selectedMaskID = nil
        maskMatteID = nil
        isDrawingMask = false
        let valid = Set(project.timeline.items.lazy.map(\.id).filter(ids.contains))
        selectedClipIDs = valid
        if let selectedClipID, valid.contains(selectedClipID) {
            self.selectedClipID = selectedClipID
        } else {
            selectedClipID = project.timeline.items.first(where: { valid.contains($0.id) })?.id
        }
        selectedTrackID = selectedItem?.placement.trackID
    }

    func seekTimeline(to seconds: Double, finishing: Bool) {
        guard !isPreparingTimeline,
              let time = try? TimelineTime.seconds(min(project.timeline.duration.seconds, max(0, seconds))) else { return }
        if finishing { playback.endSeeking(at: time.cmTime) }
        else { playback.seekInteractively(to: time.seconds) }
    }

    // MARK: - Animatable grading values
    //
    // Every numeric grading control writes through here, and the rule is the
    // one the rest of the app already has: not animated, change the authored
    // value; animated, write the keyframe at the playhead. Nothing in the Color
    // tab decides this for itself.

    func gradeBinding(_ property: AnimatableProperty) -> Binding<Float> {
        Binding(
            get: { [weak self] in
                guard let self else { return 0 }
                // The evaluated value at the playhead, so a slider on an
                // animated parameter reads what the picture is showing rather
                // than the authored base. Falls back to the authored value when
                // there is no selection to evaluate against.
                let evaluated = animatableValue(property)?.number ?? settings.gradeNumber(property)
                return Float(evaluated ?? 0)
            },
            set: { [weak self] value in
                self?.setAnimatableValue(property, .number(Double(value)))
            }
        )
    }

    func canEditGradeValue(_ property: AnimatableProperty) -> Bool {
        keyframeState(property) == .off || isPlayheadInsideSelection
    }

    /// Identifies the thing the Color tab's keyframe controls are pointed at, so
    /// a lane can drop its selection when the context changes under it.
    var gradeAnimationContextID: UUID? { selectedMaskID ?? selectedClipID }

    /// True when a tool holds animation, for the small dot on its panel button.
    ///
    /// Asked once per panel button on every body pass, so it walks the tracks
    /// rather than building an array of the animated properties first.
    func panelHasAnimation(_ panel: GradePanel) -> Bool {
        // Light keyframes live on the lights, the way mask keyframes live on
        // the masks, so the tool is asked rather than the clip's tracks.
        if panel == .relight { return selectedMaskID == nil && (selectedClip?.hasRelightAnimation ?? false) }
        return gradeAnimationTracks?.contains {
            !$0.isEmpty && $0.property.gradeSlot?.panel == panel
        } ?? false
    }

    /// The animation the Color tab's keyframe controls are reading and writing:
    /// the selected mask's, or the clip's own.
    private var gradeAnimationTracks: [AnimationTrack]? {
        guard let id = selectedMaskID else { return selectedClip?.animation?.tracks }
        return maskedGrades.first { $0.id == id }?.animation?.tracks
    }

    /// The grading properties animating in that context.
    var animatedGradeProperties: [AnimatableProperty] {
        gradeAnimationTracks?.filter { !$0.isEmpty && $0.property.isGradeProperty }.map(\.property) ?? []
    }

    /// True when this clip's colour changes over time anywhere — globally or
    /// inside a mask. Used by Reset Grade, which must not leave animation behind
    /// that a supposedly reset clip would then play.
    var selectionHasGradeAnimation: Bool { selectedClip?.hasGradeAnimation ?? false }

    // MARK: - Curves

    /// The curves the panel edits: the shape at the playhead when a curve is
    /// animated, and otherwise the stored set, or the legacy three-slider data
    /// converted into one. Reading it never writes, so a project that is only
    /// being looked at keeps whichever form it was saved in.
    var curves: AdvancedCurves {
        var resolved = (settings.advanced ?? .neutral).resolvedCurves
        for track in gradeAnimationTracks ?? [] {
            guard !track.isEmpty, case .curve(let type) = track.property.gradeSlot,
                  let curve = animatableValue(track.property)?.curve else { continue }
            resolved[type] = curve
        }
        return resolved
    }

    /// Applies an edit to one curve.
    ///
    /// Writing through `settings` is what gives curves live preview, undo and
    /// autosave for free - it is the same path every other grading control
    /// takes. Legacy tone-curve data is cleared in the same write, so the two
    /// representations can never both be live.
    ///
    /// An animated curve writes a whole-curve keyframe at the playhead instead,
    /// through the same engine every other animated value uses. Control points
    /// are never keyframed individually: a curve animates as one shape.
    func editCurve(_ type: CurveType, _ edit: (inout AdvancedCurve) -> Void) {
        guard canGrade else { return }
        var curve = curves[type]
        edit(&curve)
        curve.type = type
        if let property = AnimatableProperty.curve(type), keyframeState(property) != .off {
            setAnimatableValue(property, .curve(curve))
            return
        }
        var updated = curves
        updated[type] = curve
        var advanced = settings.advanced ?? .neutral
        advanced.normalizeCollections()
        advanced.advancedCurves = updated.isNeutral ? nil : updated
        advanced.curves = AdvancedGrade.neutral.curves
        settings.advanced = advanced == .neutral ? nil : advanced
    }

    func resetCurve(_ type: CurveType) {
        guard canGrade, !curves[type].isNeutral else { return }
        editCurve(type) { $0.reset() }
        flushGradeHistory()
    }

    /// Whether any curve is doing something, for the panel's Reset affordance.
    var hasCurveEdits: Bool { !curves.isNeutral }

    /// Opens an interaction that should land in undo as a single action.
    ///
    /// The grade path already coalesces rapid changes, but it does so on a
    /// timer. Holding it open explicitly means a drag that pauses mid-gesture
    /// still commits once when the finger lifts rather than twice.
    func beginCurveEdit(_ label: String = "Curves") {
        guard canGrade else { return }
        gradeTask?.cancel()
        gradeTask = nil
        if gradeBaseline == nil { gradeBaseline = project }
        historyLabel = label
    }

    /// Closes it. One undo entry, restoring the whole curve state.
    func endCurveEdit() {
        flushGradeHistory()
    }

    // MARK: - Eyedropper

    /// Samples the graded frame under `point` - 0...1 from the preview's
    /// top-left - and builds a three-point selection around that hue.
    ///
    /// The colour comes from the render pipeline, not from a snapshot of the
    /// view, so it is the picture's own colour rather than whatever the
    /// compositing layers and the display did to it on the way to the screen.
    @discardableResult
    func pickCurveHue(atViewPoint point: CGPoint) -> Bool {
        guard isPickingCurveHue, selectedCurve.isCyclic, canGrade else { return false }
        guard let colour = renderer.sampleGradedColor(atViewPoint: point) else { return false }
        // A near-neutral pixel has no hue worth selecting; say so rather than
        // dropping a selection on whichever channel happened to win.
        guard let hue = CurveHuePicker.hue(of: colour) else {
            editError = CurveHuePicker.neutralMessage
            isPickingCurveHue = false
            return false
        }

        let type = selectedCurve
        beginCurveEdit("Pick colour")
        var picked: UUID?
        editCurve(type) { picked = $0.selectHue(hue) }
        endCurveEdit()
        selectedCurvePoint = picked
        isPickingCurveHue = false
        return true
    }


    // MARK: - Color Warper eyedropper

    /// Samples the picture under `point` and lands on the mesh handle for that
    /// colour, placing one if there is none there yet.
    ///
    /// The sample is taken with the warper BYPASSED. Picking off the finished
    /// picture would hand the warper a colour it had already moved, so the
    /// handle would appear in the wrong place and each successive pick would
    /// chase the last one. Everything else in the grade still applies, so this
    /// is the colour the warper actually receives.
    @discardableResult
    func pickWarpColor(atViewPoint point: CGPoint) -> Bool {
        guard isPickingWarpColor, canGrade else { return false }
        guard let colour = renderer.sampleGradedColor(atViewPoint: point, warpBypass: true) else {
            return false
        }
        let mode = selectedWarpMode
        guard let position = ColorWarpPicker.position(of: colour, in: mode) else {
            editError = ColorWarpPicker.neutralMessage
            isPickingWarpColor = false
            return false
        }
        beginCurveEdit(String(localized: "Pick color"))
        let picked = addColorWarpPoint(x: position.x, y: position.y, mode: mode)
        endCurveEdit()
        selectedWarpPoint = picked
        isPickingWarpColor = false
        return true
    }

    /// The point the curve editor has selected, so a readout and a delete
    /// action have something to refer to. UI state.
    @Published var selectedCurvePoint: UUID?

    func advancedBinding<T>(_ keyPath: WritableKeyPath<AdvancedGrade, T>) -> Binding<T> {
        Binding(get: { (self.settings.advanced ?? .neutral)[keyPath: keyPath] }, set: { value in
            var advanced = self.settings.advanced ?? .neutral
            advanced.normalizeCollections()
            advanced[keyPath: keyPath] = value
            self.settings.advanced = advanced == .neutral ? nil : advanced
        })
    }

    private var renderer_context: MetalContext { renderer.metalContext }

    /// Thumbnails for the look strip, keyed by look id. `nil` for the "None"
    /// entry is stored under `Self.originalPreviewKey`.
    @Published private(set) var lookPreviews: [String: UIImage] = [:]
    static let originalPreviewKey = LookPreviewKey.original
    private var previewTask: Task<Void, Never>?
    private var previewRenderer: LookPreviewRenderer?
    /// Identifies the frame and look set the current thumbnails were built from.
    private var lookPreviewToken = ""


    /// Builds the look strip's thumbnails from a frame at the current playhead.
    ///
    /// Each thumbnail is published as it finishes rather than all at once,
    /// because loading a large LUT takes real time — a 64-point cube is several
    /// megabytes of text — and a strip that fills in progressively is far better
    /// than one that stays empty until the slowest look is ready.
    func refreshLookPreviews(force: Bool = false) {
        let looks = availableLooks
        // Opening the picker used to rebuild the whole strip every time, which on
        // a first visit means parsing every .cube file — a 65-point cube is a
        // quarter of a million lines of text. The set of thumbnails only goes
        // stale when the looks change, the clip changes, or the playhead has
        // moved somewhere else in the timeline, so anything else reuses what is
        // already on screen.
        let token = "\(selectedClipID?.uuidString ?? "-")|\(looks.count)|\(Int(timelineTime * 2))"
        if !force, token == lookPreviewToken, lookPreviews.count > looks.count { return }
        previewTask?.cancel()
        lookPreviewToken = token
        let url = project.sourceURL
        let seconds = timelineTime
        let renderer: LookPreviewRenderer
        do {
            if previewRenderer == nil { previewRenderer = try LookPreviewRenderer(context: renderer_context) }
            guard let existing = previewRenderer else { return }
            renderer = existing
        } catch {
            return
        }
        let videoRenderer = self.renderer

        // `EditorViewModel` is main-actor isolated, so a plain `Task` here would
        // inherit the main actor even at utility priority. Parsing the bundled
        // LUT pack there freezes the whole editor for several seconds on the
        // first visit. Detaching keeps file parsing, texture creation and GPU
        // waits off the UI thread; only the finished thumbnail assignment hops
        // back to the main actor.
        let owner = self
        // Looks whose thumbnail is already on screen. Re-rendering those was
        // most of the work on a refresh, and the result was identical.
        let alreadyRendered = Set(lookPreviews.keys)
        previewTask = Task.detached(priority: .utility) {
            let source: MTLTexture
            // The frame the preview is already showing, when it is usable.
            // Falling back to the file costs a second decode of a 4K picture.
            if let onScreen = videoRenderer.lookPreviewSource() {
                source = onScreen
            } else {
                let frame = await Self.previewFrame(for: url, at: seconds)
                guard !Task.isCancelled, let uploaded = renderer.makeSourceTexture(from: frame) else { return }
                source = uploaded
            }
            if force || !alreadyRendered.contains(Self.originalPreviewKey),
               let original = renderer.render(look: nil, source: source), !Task.isCancelled {
                await owner.storeLookPreview(original, for: Self.originalPreviewKey)
            }
            let pending = force ? looks : looks.filter { !alreadyRendered.contains($0.id) }

            // Published in small groups rather than one thumbnail at a time.
            // Each store is a main-actor hop *and* a @Published change that
            // re-renders the whole strip, so doing it per look meant thirty-odd
            // strip rebuilds competing with the scroll the user was performing.
            // The group is kept small so the strip still fills in progressively.
            //
            // Parsing is deliberately NOT spread across cores. It was measured:
            // six-wide batches came out about 1.75x SLOWER than straight
            // sequential parsing, because several multi-megabyte value arrays
            // being built at once contend on allocation, and each batch can only
            // move as fast as its slowest member. Sequential is both quicker and
            // simpler here.
            let groupSize = 4
            var index = 0
            while index < pending.count {
                if Task.isCancelled { return }
                let batch = pending[index..<min(index + groupSize, pending.count)]
                index += groupSize
                var rendered: [(String, UIImage)] = []
                rendered.reserveCapacity(batch.count)
                for look in batch {
                    if Task.isCancelled { return }
                    guard let image = renderer.render(look: look, source: source) else { continue }
                    rendered.append((look.id, image))
                }
                if Task.isCancelled { return }
                await owner.storeLookPreviews(rendered)
            }
        }
    }

    private func storeLookPreview(_ image: UIImage, for key: String) {
        lookPreviews[key] = image
    }

    /// One published change for a whole batch, so the strip does not re-render
    /// itself once per thumbnail.
    private func storeLookPreviews(_ images: [(String, UIImage)]) {
        guard !images.isEmpty else { return }
        for (key, image) in images { lookPreviews[key] = image }
    }

    /// A frame at the playhead, falling back to a reference chart when the clip
    /// cannot be read — so the strip is never a row of blank squares.
    private static func previewFrame(for url: URL, at seconds: Double) async -> UIImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        do {
            let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
            return UIImage(cgImage: try await generator.image(at: time).image)
        } catch {
            return LookReferenceImage.make()
        }
    }

    /// What the preview is actually showing, refreshed as the display's EDR
    /// headroom changes. Four separate things get conflated easily, so they are
    /// reported separately: the source's HDR metadata, the project's colour
    /// mode, what this display can present, and what export will produce.
    struct PreviewStatus: Equatable {
        var projectMode: ProjectColorMode
        /// True only when the preview is genuinely being presented in EDR.
        var showingHDR: Bool
        var headroom: Double

        /// The badge shown over the preview. An SDR fallback is labelled as
        /// such: it must never be mistaken for HDR brightness.
        var badge: String {
            guard projectMode.isHDR else { return "SDR" }
            return showingHDR ? "HDR" : "HDR · SDR PREVIEW"
        }

        var detail: String? {
            if projectMode == .appleLog {
                return String(localized: "Apple Log is decoded with Apple's published transfer function into scene light, graded there, and rendered to Rec.709 with Apple's own display transform. The preview is that rendered result — the same picture the export produces — which is why it does not look flat.")
            }
            if projectMode == .appleLog2 {
                return String(localized: "Apple Log 2 uses the same transfer function as Apple Log on wider primaries, so it is decoded to scene light, converted from Apple Wide Gamut to BT.2020, and rendered to Rec.709 with Apple's own display transform. The preview is that rendered result — the same picture the export produces — which is why it does not look flat.")
            }
            guard projectMode.isHDR else { return nil }
            if showingHDR {
                return String(
                    format: String(localized: "HDR preview · %.1f× display headroom. The system applies HLG display tone mapping, the same as Photos."),
                    locale: .current,
                    headroom
                )
            }
            return String(localized: "This display has little HDR headroom, so the system is tone-mapping the HDR preview down to what the screen can show. It does not represent HDR highlight brightness. HDR export is unaffected.")
        }
    }

    /// Bumped when the renderer reports an EDR state change; exists so SwiftUI
    /// re-evaluates the badge rather than showing a stale value.
    @Published private(set) var displayStateID: UInt = 0

    var previewStatus: PreviewStatus {
        let state = renderer.previewState
        return PreviewStatus(
            projectMode: project.colorMode,
            showingHDR: state.isHDR,
            headroom: state.headroom
        )
    }

    /// Every look the picker can offer, refreshed after an import or removal.
    /// Held rather than recomputed so a view body never hits the filesystem.
    @Published private(set) var availableLooks: [LUTAsset] = LUTAsset.allLooks

    /// Copies `.cube` files picked from Files into the app.
    ///
    /// Each file is validated before it is stored, so a LUT that cannot be
    /// applied is refused here with a reason rather than appearing in the picker
    /// and doing nothing. Valid files still import when a sibling fails.
    func importLooks(from urls: [URL]) {
        var failures: [String] = []
        var lastImported: LUTAsset?
        for url in urls {
            do {
                lastImported = try LUTStore.importLook(from: url)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        availableLooks = LUTAsset.allLooks
        refreshLookPreviews(force: true)
        if let lastImported {
            renderer.forgetLook(lastImported.id)
            selectLook(lastImported)
        }
        if !failures.isEmpty {
            editError = failures.joined(separator: "\n\n")
        }
    }

    /// Deletes an imported look. Built-in looks cannot be removed.
    func removeLook(_ asset: LUTAsset) {
        guard asset.origin == .device else { return }
        do {
            try LUTStore.remove(asset)
        } catch {
            editError = error.localizedDescription
            return
        }
        renderer.forgetLook(asset.id)
        lookPreviews[asset.id] = nil
        availableLooks = LUTAsset.allLooks
        // Any clip still pointing at the deleted file has to fall back to none,
        // otherwise it would keep an identifier that can never resolve again.
        if settings.advanced?.lut == asset.id {
            selectLook(nil)
        }
    }

    /// The look applied to the selected clip, or nil for none.
    var selectedLook: LUTAsset? {
        guard let identifier = settings.advanced?.lut else { return nil }
        return availableLooks.first { $0.id == identifier }
    }

    /// Selecting a look loads its texture before the grade is committed, so the
    /// first repainted frame already shows it rather than flashing ungraded.
    func selectLook(_ asset: LUTAsset?) {
        guard canGrade else { return }
        var advanced = settings.advanced ?? .neutral
        advanced.normalizeCollections()
        if let asset {
            prepareLookForRendering(asset.id)
            advanced.lut = asset.id
            if advanced.lutIntensity == nil { advanced.lutIntensity = 100 }
        } else {
            advanced.lut = nil
            advanced.lutIntensity = nil
        }
        settings.advanced = advanced == .neutral ? nil : advanced
    }

    /// Direct playback and composited playback use separate Metal contexts.
    /// Prepare both, then repaint the paused composition once its LUT is ready.
    private func prepareLookForRendering(_ identifier: String) {
        renderer.prepareLook(identifier)
        guard layerState != nil else { return }
        Task { [weak self] in
            guard await CompositorResources.prepareLooks([identifier]),
                  let self,
                  self.settings.advanced?.lut == identifier else { return }
            self.synchronizeRenderer()
        }
    }

    /// Returns one tool's BASE values to neutral.
    ///
    /// Animation is deliberately left alone: a reset is about the values, and
    /// throwing away keyframes the user spent time on because they reset a panel
    /// would be a much larger action than the button says. When animation is
    /// still driving what is on screen the panel says so, so the reset never
    /// looks like it silently failed. "Remove animation" is the explicit action,
    /// per property, in each parameter's Animation menu.
    func resetPanel() {
        let stillAnimated = panelHasAnimation(selectedPanel)
        defer { if stillAnimated { showStatus(String(localized: "Base values reset. Animation kept.")) } }
        var advanced = settings.advanced ?? .neutral
        switch selectedPanel {
        case .light: GradeParameter.light.forEach { settings.reset($0) }
        case .color: GradeParameter.color.forEach { settings.reset($0) }
        case .curves:
            advanced.curves = AdvancedGrade.neutral.curves
            advanced.advancedCurves = nil
            selectedCurvePoint = nil
            isPickingCurveHue = false
        case .hsl: advanced.hsl = AdvancedGrade.neutral.hsl
        case .warper:
            // Points only. The density and the luminance choice are how this
            // person works rather than part of the grade, so Reset leaves them.
            if var warp = advanced.colorWarp {
                warp.reset()
                advanced.colorWarp = warp == ColorWarp() ? nil : warp
            }
            selectedWarpPoint = nil
            isPickingWarpColor = false
        case .wheels: advanced.wheels = AdvancedGrade.neutral.wheels
        case .mask:
            changeVisual("Reset Local Mask", immediate: true) { clip in
                var grade = clip.gradeSettings.advanced ?? .neutral
                grade.mask = nil
                clip.gradeSettings.advanced = grade == .neutral ? nil : grade
                if var animation = clip.animation {
                    [.localMaskPositionX, .localMaskPositionY, .localMaskWidth,
                     .localMaskHeight, .localMaskRotation, .localMaskFeather,
                     .localMaskOpacity].forEach { animation.removeAnimation(of: $0) }
                    clip.animation = animation.isEmpty ? nil : animation
                }
            }
            return
        case .vignette:
            advanced.vignette = 0; advanced.vignetteMidpoint = 50; advanced.vignetteFeather = 70
        case .effects:
            advanced.effects = nil
        case .noise:
            advanced.noiseReduction = nil
        case .relight:
            // The lights and their keyframes. The depth cache stays: it is
            // the scene, not the lighting, and a new light can use it at once.
            advanced.relight = nil
            selectedLightID = nil
        case .lut:
            advanced.lut = nil; advanced.lutIntensity = nil
        case .masks:
            // Returns the selected mask's own grade to neutral and keeps its
            // geometry. Deleting the window is a separate, explicit action.
            if let id = selectedMaskID { resetMaskGrade(id) }
            return
        case .match:
            // Removes the match and restores the grade that was underneath it,
            // which is the same thing the panel's own button does. It does NOT
            // clear the chosen reference: the reset is of a result, and having
            // to find the reference again to try different components would be
            // the tool forgetting what it was pointed at.
            resetShotMatch()
            return
        }
        settings.advanced = advanced == .neutral ? nil : advanced
    }

    func binding(for parameter: GradeParameter) -> Binding<Float> {
        Binding(
            get: { [weak self] in
                self?.settings[keyPath: parameter.keyPath] ?? parameter.neutralValue
            },
            set: { [weak self] newValue in
                guard let self, self.canGrade else { return }
                var updated = self.settings
                updated[keyPath: parameter.keyPath] = min(max(newValue, parameter.range.lowerBound), parameter.range.upperBound)
                self.settings = updated
            }
        )
    }

    func resetAll() {
        guard canGrade, settings != .neutral else { return }
        settings.resetAll()
    }

    /// The selected clip's masked local grades, authored values.
    var maskedGrades: [MaskedGradeLayer] { selectedClip?.resolvedMaskedGrades ?? [] }

    /// Points the Color controls at one mask, or back at the clip's own grade.
    ///
    /// Switching context closes the open undo entry first, so a slider moved in
    /// one context and a slider moved in the other never land in the same step.
    func selectMask(_ id: UUID?) {
        guard selectedMaskID != id else { return }
        flushGradeHistory()
        selectedMaskID = id
        // Vignette, Effects, the Look, Noise and the legacy Local window have no
        // local equivalent, so they are not offered while a mask is selected.
        // Leaving the tab on one of them would show controls that silently did
        // nothing. Noise reduction is the clearest case: it restores the source
        // signal before any grade runs, so confining it to a window would mean
        // denoising part of a frame and leaving the rest, with a seam between.
        if !availablePanels.contains(selectedPanel) { selectedPanel = .light }
        // A matte belongs to the mask being worked on.
        if id == nil { maskMatteID = nil } else if maskMatteID != nil { maskMatteID = id }
        synchronizeRenderer()
    }

    // MARK: - Grade presets

    /// The saved grades, as "My Presets" shows them.
    ///
    /// Application-level rather than project-level: presets have to outlive the
    /// project they were made in, so the library reads them from Application
    /// Support rather than from the document.
    let presets = GradePresetLibrary()

    /// Wide enough to judge a look by, small enough that a hundred of them cost
    /// nothing. Never a full frame.
    static let presetThumbnailEdge = 400

    /// A small, fully graded still of the current frame.
    ///
    /// It goes through the same kernel the preview does, so the tile shows what
    /// the preset actually does rather than an approximation of it.
    func makePresetThumbnail() async -> UIImage? {
        let preview: LookPreviewRenderer
        do {
            if previewRenderer == nil { previewRenderer = try LookPreviewRenderer(context: renderer_context) }
            guard let existing = previewRenderer else { return nil }
            preview = existing
        } catch {
            return nil
        }
        let edge = Self.presetThumbnailEdge
        let source: MTLTexture
        if let onScreen = renderer.lookPreviewSource(maximumEdge: edge) {
            source = onScreen
        } else {
            // The composited and HDR paths cannot hand back a plain SDR frame,
            // so the picture is decoded from the file instead.
            let frame = await Self.previewFrame(for: project.sourceURL, at: timelineTime)
            guard let uploaded = preview.makeSourceTexture(from: frame, maximumEdge: edge) else { return nil }
            source = uploaded
        }
        return preview.render(settings: settings, source: source)
    }

    /// The name the save sheet offers by default.
    func suggestedPresetName() -> String { presets.suggestedName() }

    /// Saves the selected clip's whole grading state under `name`.
    ///
    /// The grade is read before the thumbnail is rendered, so the record and the
    /// picture describe the same moment even if a slider moves meanwhile. The
    /// sheet has already rendered one for its own preview and passes it in, so
    /// the same frame is not graded twice.
    @discardableResult
    func saveGradeAsPreset(name: String, isFavorite: Bool, thumbnail existing: UIImage? = nil) async -> Bool {
        // The global grade only. A preset carries colour between clips; mask
        // geometry does not travel, so including it would produce a preset that
        // looks different on every clip it is applied to.
        let snapshot = globalSettings
        let thumbnail: UIImage?
        if let existing { thumbnail = existing } else { thumbnail = await makePresetThumbnail() }
        do {
            try presets.add(name: name, gradeSettings: snapshot, isFavorite: isFavorite, thumbnail: thumbnail)
            return true
        } catch {
            editError = error.localizedDescription
            return false
        }
    }

    /// Replaces a saved preset's grade with the clip's current one. Clips the
    /// preset was already applied to keep the grade they were given.
    func updatePreset(_ id: UUID) async {
        let snapshot = globalSettings
        let thumbnail = await makePresetThumbnail()
        do {
            try presets.update(id, gradeSettings: snapshot, thumbnail: thumbnail)
        } catch {
            editError = error.localizedDescription
        }
    }

    /// Applies a preset to the selected clip, replacing its grading state
    /// entirely — merging would make the result depend on what was there
    /// before, which is exactly what a preset is supposed to remove.
    ///
    /// Nothing is re-encoded and no media is touched: this writes the same
    /// value the sliders write, so it lands in undo as one action and the clip
    /// stays free to edit afterwards.
    func applyPreset(_ preset: GradePreset) {
        replaceGrade(with: preset.gradeSettings, label: "Apply Preset", subject: "“\(preset.name)”")
    }

    // MARK: - Grade clipboard

    /// One copied grade, shared across the session. Not part of the document:
    /// see `GradeClipboard`.
    let gradeClipboard = GradeClipboard.shared

    /// A short line shown over the preview and then dropped, for actions that
    /// would otherwise leave no visible trace. Never an error — those go
    /// through `editError` and its alert.
    @Published private(set) var statusMessage: String?
    private var statusTask: Task<Void, Never>?

    func showStatus(_ message: String) {
        statusTask?.cancel()
        statusMessage = message
        statusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.statusMessage = nil
        }
    }

    /// True when there is a grade to copy: a video clip that can be graded.
    var canCopyGrade: Bool { canGrade }

    /// True when a paste would do something: a gradeable clip, and a grade on
    /// the clipboard to put on it.
    var canPasteGrade: Bool { canGrade && gradeClipboard.hasGrade }

    /// True when the selected clip has anything to reset.
    /// Masks are deliberately not counted: Reset Grade returns the clip's own
    /// colour to neutral and leaves its windows alone, so offering it when only
    /// masks exist would promise something it does not do.
    var canResetGrade: Bool { canGrade && (globalSettings != .neutral || selectionHasGradeAnimation) }

    /// Against the clip's own grade, never the selected mask's — a paste
    /// replaces `globalSettings`, so that is the work it would throw away.
    /// `settings` points at the mask while one is being edited, which is why
    /// the shared default is not the right test here.
    var pasteWouldOverwriteGrade: Bool {
        canPasteGrade && globalSettings.hasCreativeChangeIgnoringMask
    }

    /// Copies the selected clip's complete grading state.
    ///
    /// Reads the model only — no textures, no cached GPU state, nothing the
    /// renderer built. The clipboard holds a value, so the copy is independent
    /// of the clip from the moment it is made.
    func copyGrade() {
        guard canCopyGrade else { return }
        // Deliberately the global grade, never the selected mask's: masks are
        // spatial structure that belongs to this picture.
        gradeClipboard.copy(globalSettings, from: project.displayName)
        CurveHaptics.add()
        showStatus(String(localized: "Grade copied"))
    }

    /// Puts the copied grade on the selected clip.
    ///
    /// `.replace` is what pasting has always meant: the clip's grading state
    /// becomes the copied one outright. `.addOnTop` keeps the grade the clip
    /// already carries and lays the copied one over it — see
    /// `GradeSettings.stacked(onto:)` for what that means control by control.
    /// Which of the two happens is the user's answer to a question the UI asks,
    /// never a guess made here.
    func pasteGrade(_ mode: GradePasteMode) {
        guard canPasteGrade, let grade = gradeClipboard.grade else { return }
        // Confirmed even when nothing changed -- pasting onto a clip that
        // already carries that grade succeeded, and silence would read as a
        // broken button.
        switch mode {
        case .replace:
            replaceGrade(with: grade, label: "Paste Grade", subject: "The copied grade")
            showStatus(String(localized: "Grade pasted"))
        case .addOnTop:
            replaceGrade(with: grade.stacked(onto: globalSettings),
                         label: "Add Grade", subject: "The copied grade")
            showStatus(String(localized: "Grade added"))
        }
        CurveHaptics.add()
    }

    /// Returns the selected clip to the neutral grade, in one undoable step.
    ///
    /// Everything the grade covers goes back to its default — light, colour,
    /// every curve, HSL, wheels, vignette, the look and the finishing effects —
    /// because that is what `GradeSettings.neutral` is.
    ///
    /// Grading ANIMATION goes with it. A neutral base with keyframes still on it
    /// would play a grade the moment the playhead moved, which is not what a
    /// reset clip means. Mask windows and their geometry animation are left
    /// alone: those are structure, and deleting them is a separate action.
    func resetGrade() {
        guard canResetGrade else { return }
        guard replaceGrade(with: .neutral, label: "Reset Grade", subject: "This grade",
                           clearsGradeAnimation: true) else { return }
        CurveHaptics.reset()
        showStatus(String(localized: "Grade reset"))
    }

    /// Strips every grading track from the clip and its masks, leaving geometry
    /// animation untouched. Folded into whichever undo entry is open.
    private func clearGradeAnimation() {
        changeVisual("Reset Grade", immediate: false) { clip in
            if var animation = clip.animation {
                AnimatableProperty.gradeProperties.forEach { animation.removeAnimation(of: $0) }
                clip.animation = animation.isEmpty ? nil : animation
            }
            guard var masks = clip.maskedGrades else { return }
            for index in masks.indices {
                guard var animation = masks[index].animation else { continue }
                AnimatableProperty.gradeProperties.forEach { animation.removeAnimation(of: $0) }
                masks[index].animation = animation.isEmpty ? nil : animation
            }
            clip.maskedGrades = masks
        }
    }

    /// The one path that swaps a clip's whole grading state.
    ///
    /// Applying a preset, pasting and resetting are the same operation with
    /// different sources, so they share this: replace outright rather than
    /// merge, land in undo as a single action, and let the renderer rebuild
    /// whatever GPU data the new state needs the way it does for a slider.
    ///
    /// - Returns: whether anything actually changed.
    @discardableResult
    private func replaceGrade(
        with grade: GradeSettings, label: String, subject: String,
        clearsGradeAnimation: Bool = false
    ) -> Bool {
        guard canGrade else { return false }
        flushGradeHistory()
        var applied = grade
        if let identifier = applied.advanced?.lut {
            if availableLooks.contains(where: { $0.id == identifier }) {
                // Load the texture first so the first repainted frame already
                // carries the look rather than flashing without it.
                prepareLookForRendering(identifier)
            } else {
                // Applying the rest is more useful than refusing outright, but
                // it has to be said plainly, and no other look is put in its
                // place.
                applied = applied.withoutLook
                editError = String(localized: """
                    \(subject) uses a LUT that is no longer available.

                    Everything else has been applied. No other look was substituted.
                    """)
            }
        }
        guard applied != globalSettings || (clearsGradeAnimation && selectionHasGradeAnimation) else { return false }
        historyLabel = label
        // The ordinary grade write: live preview, autosave and undo all behave
        // exactly as they do for a slider, and the whole change closes into one
        // history entry rather than one per property. Masks are untouched —
        // resetting or replacing a grade is not a reason to delete windows.
        globalSettings = applied
        if clearsGradeAnimation {
            // Same open undo entry: `globalSettings` has already taken the
            // baseline, so this folds into it rather than adding a second step.
            clearGradeAnimation()
        } else if selectionHasGradeAnimation {
            // A preset and a paste replace the BASE grade and keep the
            // animation, which is the only reading that lets the two stay
            // separate ideas. Said out loud, because the picture may not change
            // where the playhead happens to be.
            showStatus(String(localized: "Base grade replaced. Animation kept."))
        }
        flushGradeHistory()
        return true
    }

    func setOriginalVisible(_ visible: Bool) {
        showsOriginal = visible
    }

    func handleScenePhase(active: Bool) {
        playback.handleScenePhase(active: active)
    }

    /// Not private: the masked-grade editing extension pushes mask changes
    /// through the same one path everything else uses.
    func synchronizeRenderer() {
        layerState?.update(project, bypass: showsOriginal, inspectingMatteOn: inspectedMatteTargetID,
                           inspectingBackgroundOn: showsBackgroundMatte ? selectedClipID : nil,
                           showsTransparencyGrid: !showsOriginal && !showsBackgroundMatte
                               && selectedBackgroundRemoval?.isEnabled == true)
        if layerState != nil { playback.refreshCompositionFrame() }
        renderer.updateSequence(clips)
        renderer.update(
            settings: globalSettings,
            masks: maskedGrades,
            bypass: showsOriginal || !colorSupport.allowsGrading
        )
        renderer.setMaskMatte(maskMatte)
        synchronizeNoiseReduction()
        synchronizeRelightSources()
    }

    /// Hands the renderer each asset's depth identity and orientation, when
    /// the assets have changed — not on every slider tick.
    private func synchronizeRelightSources() {
        guard relightSourceAssets != project.assets else { return }
        relightSourceAssets = project.assets
        renderer.setRelightSources(RelightSourceInfo.table(for: project))
    }

    /// Records which analysis a clip's lights were set up against.
    ///
    /// Written without an undo entry: it describes the cache the lights were
    /// placed on, not an edit anyone made, and undoing it would undo nothing
    /// a person could see.
    func recordRelightAnalysis(_ reference: RelightAnalysisReference, on clipID: UUID) {
        guard var grade = project.timeline.videoClip(id: clipID)?.gradeSettings,
              var advanced = grade.advanced, var relight = advanced.relight,
              relight.analysis != reference else { return }
        relight.analysis = reference
        advanced.relight = relight
        grade.advanced = advanced
        if project.timeline.setGrade(grade, for: clipID) { project.updatedAt = .now }
    }
}

// ---------------------------------------------------------------------------
// Noise Reduction
//
// The engine itself lives in Core and is shared with the exporter. What belongs
// here is only the editor's half of it: deciding when the neighbouring frames
// need decoding at all, telling the panel what the renderer actually managed,
// and running the one-off measurement behind Auto.
// ---------------------------------------------------------------------------

extension EditorViewModel {

    /// Starts or stops the supply of neighbouring frames, and keeps the
    /// device's ceiling up to date.
    ///
    /// Called from `synchronizeRenderer`, so it follows every grade change, and
    /// it is cheap when nothing has changed: a project with no noise reduction
    /// reaches the first guard and returns.
    func synchronizeNoiseReduction() {
        let settings = project.timeline.tracks
            .flatMap(\.items)
            .compactMap { item -> NoiseReduction? in
                guard case .video(let clip) = item else { return nil }
                return clip.gradeSettings.advanced?.resolvedNoiseReduction
            }
        let wantsTemporal = settings.contains { $0.temporalIsActive }
        // The layer compositor grades inside the composition, one transformed
        // and blended layer at a time, and the engine is not wired into it. A
        // project that needs the compositor therefore renders and exports
        // without noise reduction — consistently, in both — and the panel says
        // so rather than leaving someone to wonder why the sliders do nothing.
        let direct = layerState == nil
        if !settings.isEmpty {
            noiseStatus.unavailableInComposite = !direct
        } else if noiseStatus.unavailableInComposite {
            noiseStatus.unavailableInComposite = false
        }
        guard wantsTemporal, direct, let source = sequenceSource else {
            if temporalFrameCache != nil {
                temporalFrameCache = nil
                renderer.setTemporalFrames(nil, capability: noiseCapability)
            }
            return
        }
        let capability = NoiseReductionCapability.resolve(
            width: source.encodedWidth, height: source.encodedHeight)
        if noiseCapability != capability { noiseCapability = capability }
        guard capability.supportsTemporal else {
            temporalFrameCache = nil
            renderer.setTemporalFrames(nil, capability: capability)
            return
        }
        // One cache per composition. Rebuilt when the composition is, which is
        // what keeps its timestamps and the playhead's describing the same
        // thing.
        if temporalFrameCache == nil || temporalFrameCacheToken != ObjectIdentifier(source.asset) {
            temporalFrameCacheToken = ObjectIdentifier(source.asset)
            let cache = TemporalFrameCache(
                asset: source.asset, track: source.videoTrack,
                // The SOURCE's cadence when it is known, because the ring's
                // spacing is the rate the frames were shot at and this
                // arithmetic counts frames in it. The canvas rate is the
                // fallback, and for a single-clip project the two are the same
                // number anyway.
                frameDuration: Self.temporalFrameDuration(for: source, project: project),
                // The composition's own render size, which is what a paused
                // preview draws. The renderer compares it with the frame in
                // hand and stands the temporal stage down when they differ,
                // rather than decoding frames of the wrong size.
                frameSize: (source.encodedWidth, source.encodedHeight),
                // The player's own output settings, so a neighbour is decoded
                // into exactly the surface the frame on screen arrived in.
                outputSettings: VideoPlaybackController.outputSettings(for: source.colorMode))
            temporalFrameCache = cache
            renderer.setTemporalFrames(cache, capability: capability)
        } else {
            renderer.setTemporalFrames(temporalFrameCache, capability: capability)
        }
    }

    /// The frame spacing the neighbour ring should count in.
    static func temporalFrameDuration(for source: ExportSourceInfo, project: VideoProject) -> CMTime {
        if let rate = source.nominalFrameRate, rate > 1, rate < 1000 {
            return CMTime(seconds: 1 / rate, preferredTimescale: 600)
        }
        return project.canvas.frameDuration?.cmTime ?? CMTime(value: 1, timescale: 30)
    }

    /// Measures the frame on screen and writes a suggested starting point.
    ///
    /// The measurement runs off the main actor and takes a moment on a 4K
    /// frame. The result is written through the ordinary grade path, so it is a
    /// single undo entry and every value it writes stays editable — which is
    /// what makes this a suggestion rather than a mode.
    func measureNoiseAndSuggest() {
        guard canGrade, !isMeasuringNoise else { return }
        guard let frame = playback.frameProvider.latestFrame else {
            editError = String(localized: "There is no decoded frame to measure yet.")
            return
        }
        // Refused rather than answered on a reduced frame. The preview renders
        // smaller while the transport is running, and the first thing a
        // downscale does is average noise away — so measuring then reports a
        // clean picture of a noisy one and suggests a setting far too weak for
        // the footage. A measurement that is quietly wrong is worse than one
        // that asks for a pause.
        if let source = sequenceSource,
           CVPixelBufferGetWidth(frame) != source.encodedWidth
            || CVPixelBufferGetHeight(frame) != source.encodedHeight {
            editError = String(localized: "Pause the preview before measuring. While it plays the picture is rendered smaller, and a smaller picture carries less noise than the real one.")
            return
        }
        let mode = project.colorMode
        let capability = noiseCapability
            ?? NoiseReductionCapability.resolve(
                width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
        isMeasuringNoise = true
        let context = renderer.metalContext
        Task { [weak self] in
            let profile = await Task.detached(priority: .userInitiated) { () -> NoiseProfile? in
                guard let stage = NoiseReductionStage(
                    context: context, isLog2: mode == .appleLog2) else { return nil }
                defer { stage.releaseResources() }
                return stage.measure(pixelBuffer: frame, colorMode: mode)
            }.value
            guard let self else { return }
            self.isMeasuringNoise = false
            guard let profile else {
                self.editError = String(localized: "The frame could not be measured on this device.")
                return
            }
            self.noiseProfile = profile
            self.noiseCapability = capability
            self.editNoiseReduction { $0 = profile.suggestion(for: $0, capability: capability) }
            self.flushGradeHistory()
        }
    }
}
