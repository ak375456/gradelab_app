import Combine
import CoreGraphics
import Foundation
import SwiftUI
@preconcurrency import Metal

/// The still-image grading workspace.
///
/// It is the second `GradingModel` in the app, not a second grading engine. It
/// owns a project, a decoded preview and the same `MetalVideoRenderer` the video
/// editor uses; every grading control it exposes writes into the same
/// `GradeSettings` a video clip carries, and the picture it shows is produced by
/// the same `applyLookAndGrade` running in the same shader.
///
/// What it deliberately does not have is a playhead, a timeline, a transport or
/// any notion of duration. A photograph does not have those, and inventing them
/// so the video UI could be reused wholesale would show up immediately as
/// controls that do nothing.
@MainActor
final class ImageEditorViewModel: ObservableObject, GradingModel {
    @Published private(set) var project: ImageProject
    let renderer: MetalVideoRenderer
    let colorSupport: ImageColorSupport

    private let frames = StillFrameProvider()
    private let context: MetalContext

    /// True until the full preview-resolution decode has landed.
    @Published private(set) var isPreparing = true
    @Published var editError: String?
    @Published private(set) var history = GradeHistory()
    /// The grade as it was before the current coalesced edit began.
    private var gradeBaseline: GradeSettings?
    private var gradeTask: Task<Void, Never>?
    private var historyLabel = "Color"
    private var decodeTask: Task<Void, Never>?

    // MARK: - Grade

    /// The one grade this document has. Writing it repaints immediately and
    /// closes into a single undo entry once the edit settles, exactly as the
    /// video editor's per-clip grade does.
    var settings: GradeSettings {
        get { project.gradeSettings }
        set {
            guard canGrade, project.gradeSettings != newValue else { return }
            if gradeBaseline == nil { gradeBaseline = project.gradeSettings }
            project.gradeSettings = newValue
            project.updatedAt = .now
            synchronizeRenderer()
            gradeTask?.cancel()
            gradeTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
                self?.flushGradeHistory()
            }
        }
    }

    var canGrade: Bool { colorSupport.allowsGrading }
    var gradeSubjectID: UUID? { project.id }

    // MARK: - Panels

    @Published var selectedPanel: GradePanel = .light
    @Published var selectedCurve: CurveType = .master
    @Published var selectedCurvePoint: UUID?
    @Published var isPickingCurveHue = false
    @Published var showsOriginal = false { didSet { synchronizeRenderer() } }
    @Published var showsExport = false

    var visibleParameters: [GradeParameter] {
        selectedPanel == .light ? GradeParameter.light : GradeParameter.color
    }

    // MARK: - Scopes

    @Published private(set) var scopeSettings = ScopeSettings.load()
    private var scopeRendererStorage: ScopeRenderer?

    var scopeAnalyzer: ScopeAnalyzer? { renderer.scopeAnalyzer }

    /// A still is graded in the app's Rec.709 working space, whatever the file
    /// was tagged with on the way in, so the scopes read Rec.709.
    var scopeColorSpace: ScopeColorSpace { .rec709 }

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
        scopeRendererStorage?.update(type: scopeSettings.type, intensity: scopeSettings.intensity)
        renderer.setScopes(scopeSettings)
    }

    // MARK: - Life cycle

    init(project: ImageProject) throws {
        try project.validate()
        self.project = project
        colorSupport = ImageColorSupport(metadata: project.metadata)
        context = try MetalContext()
        let size = project.metadata.displaySize
        // The still runs through the video renderer, with the picture's geometry
        // supplied directly. Orientation is already applied by the decode, so
        // the transform between encoded and displayed is the identity.
        renderer = try MetalVideoRenderer(
            context: context,
            frameProvider: frames,
            displaySize: size,
            encodedSize: size,
            preferredTransform: .identity,
            fallbackMatrix: nil,
            colorMode: .sdr)
        renderer.setStillGeometry(imageSize: size)
        synchronizeRenderer()
        renderer.setScopes(scopeSettings)
        renderer.preloadLooks()
        decodePreview()
    }

    deinit {
        gradeTask?.cancel()
        decodeTask?.cancel()
        previewTask?.cancel()
    }

    /// Decodes the picture once, at a size the display can resolve.
    ///
    /// A quick low-resolution pass lands first so the workspace is never empty,
    /// then the real preview replaces it. Nothing after this decodes again: a
    /// slider move changes uniforms on a texture that is already resident, which
    /// is what keeps a 48 megapixel photograph responsive.
    private func decodePreview() {
        let url = project.sourceURL
        let longEdge = ImageDecoder.previewLongEdge()
        decodeTask?.cancel()
        decodeTask = Task { [weak self] in
            do {
                let quick = try await ImageDecoder.decodeDetached(url: url, maximumLongEdge: 640)
                guard !Task.isCancelled, let model = self else { return }
                model.frames.replace(quick.buffer)
                model.renderer.invalidate()

                let full = try await ImageDecoder.decodeDetached(url: url, maximumLongEdge: longEdge)
                guard !Task.isCancelled else { return }
                model.frames.replace(full.buffer)
                model.renderer.invalidate()
                model.isPreparing = false
                model.refreshLookPreviews(force: true)
            } catch is CancellationError {
                return
            } catch {
                guard let model = self else { return }
                model.isPreparing = false
                model.editError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func synchronizeRenderer() {
        renderer.update(settings: settings, bypass: showsOriginal || !canGrade)
    }

    func setOriginalVisible(_ visible: Bool) { showsOriginal = visible }

    // MARK: - History

    var canUndo: Bool { gradeBaseline != nil || !history.undoEntries.isEmpty }
    var canRedo: Bool { gradeBaseline == nil && !history.redoEntries.isEmpty }

    func flushGradeHistory() {
        gradeTask?.cancel(); gradeTask = nil
        if let before = gradeBaseline {
            history.record(historyLabel, before: before, after: project.gradeSettings)
        }
        gradeBaseline = nil
        historyLabel = "Color"
    }

    func undo() {
        flushGradeHistory()
        guard let grade = history.undo() else { return }
        project.gradeSettings = grade
        project.updatedAt = .now
        prepareLook(in: grade)
        synchronizeRenderer()
    }

    func redo() {
        flushGradeHistory()
        guard let grade = history.redo() else { return }
        project.gradeSettings = grade
        project.updatedAt = .now
        prepareLook(in: grade)
        synchronizeRenderer()
    }

    /// Loads the look a restored grade names before the next frame is drawn, so
    /// undo does not flash the picture without it.
    private func prepareLook(in grade: GradeSettings) {
        if let identifier = grade.advanced?.lut { renderer.prepareLook(identifier) }
    }

    // MARK: - Controls

    func binding(for parameter: GradeParameter) -> Binding<Float> {
        Binding(
            get: { [weak self] in self?.settings[keyPath: parameter.keyPath] ?? parameter.neutralValue },
            set: { [weak self] newValue in
                guard let self, self.canGrade else { return }
                var updated = self.settings
                updated[keyPath: parameter.keyPath] = min(max(newValue, parameter.range.lowerBound),
                                                          parameter.range.upperBound)
                self.settings = updated
            })
    }

    func advancedBinding<T>(_ keyPath: WritableKeyPath<AdvancedGrade, T>) -> Binding<T> {
        Binding(get: { (self.settings.advanced ?? .neutral)[keyPath: keyPath] }, set: { value in
            var advanced = self.settings.advanced ?? .neutral
            advanced.normalizeCollections()
            advanced[keyPath: keyPath] = value
            self.settings.advanced = advanced == .neutral ? nil : advanced
        })
    }

    func resetPanel() {
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
        case .wheels: advanced.wheels = AdvancedGrade.neutral.wheels
        case .mask: advanced.mask = nil
        // Power windows are a timeline-clip feature, so the still editor never
        // shows the Masks tool and can never be asked to reset it.
        case .masks: return
        case .vignette:
            advanced.vignette = 0; advanced.vignetteMidpoint = 50; advanced.vignetteFeather = 70
        case .effects: advanced.effects = nil
        case .lut: advanced.lut = nil; advanced.lutIntensity = nil
        }
        settings.advanced = advanced == .neutral ? nil : advanced
        flushGradeHistory()
    }

    func resetAll() {
        guard canGrade, settings != .neutral else { return }
        historyLabel = "Reset All"
        settings.resetAll()
        flushGradeHistory()
    }

    // MARK: - Curves

    var curves: AdvancedCurves { (settings.advanced ?? .neutral).resolvedCurves }
    var hasCurveEdits: Bool { !curves.isNeutral }

    func editCurve(_ type: CurveType, _ edit: (inout AdvancedCurve) -> Void) {
        guard canGrade else { return }
        var updated = curves
        var curve = updated[type]
        edit(&curve)
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

    func beginCurveEdit(_ label: String = "Curves") {
        gradeTask?.cancel(); gradeTask = nil
        if gradeBaseline == nil { gradeBaseline = project.gradeSettings }
        historyLabel = label
    }

    func endCurveEdit() { flushGradeHistory() }

    /// Samples the graded picture under a tap and builds a three-point hue
    /// selection around it — the same eyedropper the video editor has, reading
    /// from the same renderer.
    @discardableResult
    func pickCurveHue(atViewPoint point: CGPoint) -> Bool {
        guard isPickingCurveHue, selectedCurve.isCyclic, canGrade else { return false }
        guard let colour = renderer.sampleGradedColor(atViewPoint: point) else { return false }
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

    // MARK: - Finishing effects

    var hasFilmEffects: Bool { !(settings.advanced?.resolvedEffects.isNeutral ?? true) }

    func resetFilmEffects() { advancedBinding(\.effects).wrappedValue = nil }

    // MARK: - Looks

    @Published private(set) var availableLooks: [LUTAsset] = LUTAsset.allLooks
    @Published private(set) var lookPreviews: [String: UIImage] = [:]
    private var previewTask: Task<Void, Never>?
    private var previewRenderer: LookPreviewRenderer?

    var selectedLook: LUTAsset? {
        guard let identifier = settings.advanced?.lut else { return nil }
        return availableLooks.first { $0.id == identifier }
    }

    func selectLook(_ asset: LUTAsset?) {
        guard canGrade else { return }
        var advanced = settings.advanced ?? .neutral
        advanced.normalizeCollections()
        if let asset {
            renderer.prepareLook(asset.id)
            advanced.lut = asset.id
            if advanced.lutIntensity == nil { advanced.lutIntensity = 100 }
        } else {
            advanced.lut = nil
            advanced.lutIntensity = nil
        }
        settings.advanced = advanced == .neutral ? nil : advanced
    }

    func importLooks(from urls: [URL]) {
        var failures: [String] = []
        var lastImported: LUTAsset?
        for url in urls {
            do { lastImported = try LUTStore.importLook(from: url) }
            catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        availableLooks = LUTAsset.allLooks
        refreshLookPreviews(force: true)
        if let lastImported {
            renderer.forgetLook(lastImported.id)
            selectLook(lastImported)
        }
        if !failures.isEmpty { editError = failures.joined(separator: "\n\n") }
    }

    func removeLook(_ asset: LUTAsset) {
        guard asset.origin == .device else { return }
        do { try LUTStore.remove(asset) }
        catch { editError = error.localizedDescription; return }
        renderer.forgetLook(asset.id)
        lookPreviews[asset.id] = nil
        availableLooks = LUTAsset.allLooks
        if settings.advanced?.lut == asset.id { selectLook(nil) }
    }

    /// Builds the look strip from the picture already on screen.
    ///
    /// The still is a BGRA frame in the renderer, so `lookPreviewSource` hands
    /// back a thumbnail of it without decoding the file a second time — the same
    /// route the video editor takes for its own strip.
    func refreshLookPreviews(force: Bool = false) {
        guard !isPreparing || force else { return }
        let looks = availableLooks
        if !force, lookPreviews.count > looks.count { return }
        previewTask?.cancel()
        let renderer: LookPreviewRenderer
        do {
            if previewRenderer == nil { previewRenderer = try LookPreviewRenderer(context: context) }
            guard let existing = previewRenderer else { return }
            renderer = existing
        } catch { return }
        let videoRenderer = self.renderer

        // This model is main-actor isolated. A plain Task inherits that actor,
        // which made the first Look visit parse every bundled cube on the UI
        // thread. Keep the expensive work detached and publish only completed
        // thumbnails on the main actor.
        let owner = self
        previewTask = Task.detached(priority: .utility) {
            guard let source = videoRenderer.lookPreviewSource() else { return }
            if let original = renderer.render(look: nil, source: source), !Task.isCancelled {
                await owner.storeLookPreview(original, for: LookPreviewKey.original)
            }
            for look in looks {
                if Task.isCancelled { return }
                guard let image = renderer.render(look: look, source: source) else { continue }
                await owner.storeLookPreview(image, for: look.id)
            }
        }
    }

    private func storeLookPreview(_ image: UIImage, for key: String) {
        lookPreviews[key] = image
    }

    // MARK: - Presets

    /// The same library the video editor writes to. A preset made on a video
    /// appears here, and one made here appears there, because a preset is a
    /// `GradeSettings` and both documents store one.
    let presets = GradePresetLibrary()

    func suggestedPresetName() -> String { presets.suggestedName() }

    func makePresetThumbnail() async -> UIImage? {
        let preview: LookPreviewRenderer
        do {
            if previewRenderer == nil { previewRenderer = try LookPreviewRenderer(context: context) }
            guard let existing = previewRenderer else { return nil }
            preview = existing
        } catch { return nil }
        guard let source = renderer.lookPreviewSource(maximumEdge: 400) else { return nil }
        return preview.render(settings: settings, source: source)
    }

    @discardableResult
    func saveGradeAsPreset(name: String, isFavorite: Bool, thumbnail existing: UIImage? = nil) async -> Bool {
        let snapshot = settings
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

    func updatePreset(_ id: UUID) async {
        let snapshot = settings
        let thumbnail = await makePresetThumbnail()
        do { try presets.update(id, gradeSettings: snapshot, thumbnail: thumbnail) }
        catch { editError = error.localizedDescription }
    }

    func applyPreset(_ preset: GradePreset) {
        replaceGrade(with: preset.gradeSettings, label: "Apply Preset", subject: "“\(preset.name)”")
    }

    // MARK: - Grade clipboard

    /// The session clipboard, shared with the video editor. A grade copied from
    /// a clip pastes onto a photograph and back again, because both sides of the
    /// exchange are a `GradeSettings` and nothing about the source's colour
    /// profile travels with it.
    let gradeClipboard = GradeClipboard.shared

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

    var canCopyGrade: Bool { canGrade }
    var canPasteGrade: Bool { canGrade && gradeClipboard.hasGrade }
    var canResetGrade: Bool { canGrade && settings != .neutral }

    func copyGrade() {
        guard canCopyGrade else { return }
        gradeClipboard.copy(settings, from: project.displayName)
        CurveHaptics.add()
        showStatus("Grade copied")
    }

    func pasteGrade() {
        guard canPasteGrade, let grade = gradeClipboard.grade else { return }
        replaceGrade(with: grade, label: "Paste Grade", subject: "The copied grade")
        CurveHaptics.add()
        showStatus("Grade pasted")
    }

    func resetGrade() {
        guard canResetGrade else { return }
        guard replaceGrade(with: .neutral, label: "Reset Grade", subject: "This grade") else { return }
        CurveHaptics.reset()
        showStatus("Grade reset")
    }

    /// The one path that swaps the whole grading state, matching the video
    /// editor's: replace outright rather than merge, land in undo as a single
    /// action, and say so plainly when a look the grade names is gone.
    @discardableResult
    private func replaceGrade(with grade: GradeSettings, label: String, subject: String) -> Bool {
        guard canGrade else { return false }
        flushGradeHistory()
        var applied = grade
        if let identifier = applied.advanced?.lut {
            if availableLooks.contains(where: { $0.id == identifier }) {
                renderer.prepareLook(identifier)
            } else {
                applied = applied.withoutLook
                editError = """
                    \(subject) uses a LUT that is no longer available.

                    Everything else has been applied. No other look was substituted.
                    """
            }
        }
        guard applied != settings else { return false }
        historyLabel = label
        settings = applied
        flushGradeHistory()
        return true
    }

    // MARK: - Scene

    func handleScenePhase(active: Bool) {
        if !active { flushGradeHistory() }
    }
}
