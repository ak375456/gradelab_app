import Combine
import CoreGraphics
import Foundation
import SwiftUI
@preconcurrency import Metal

enum ImageEditorTool: String, CaseIterable, Identifiable {
    case color
    case background
    var id: String { rawValue }
}

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
    private var sourcePreviewBuffer: CVPixelBuffer?

    /// True until the full preview-resolution decode has landed.
    @Published private(set) var isPreparing = true
    @Published var editError: String?
    @Published private(set) var history = ImageProjectHistory()
    /// The grade as it was before the current coalesced edit began.
    private var gradeBaseline: ImageProject?
    private var gradeTask: Task<Void, Never>?
    private var backgroundTask: Task<Void, Never>?
    private var backgroundAnalysisTask: Task<Void, Never>?
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
            if gradeBaseline == nil { gradeBaseline = project }
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
    /// Color Warper editor state. The warp itself lives on the grade; which
    /// plane is showing, which handle is selected and whether the eyedropper is
    /// armed belong to the panel.
    @Published var selectedWarpMode: ColorWarpMode = .hueSaturation
    @Published var selectedWarpPoint: UUID?
    @Published var isPickingWarpColor = false
    @Published var showsOriginal = false { didSet { synchronizeRenderer() } }
    @Published var showsExport = false
    @Published var imageTool: ImageEditorTool = .color
    @Published var backgroundAnalysisProgress: BackgroundRemovalAnalysisProgress?
    @Published var backgroundAnalysisMessage: String?
    @Published var isDrawingBackgroundLasso = false
    @Published var isPickingBackgroundColor = false
    @Published var backgroundBrush: BackgroundRemovalBrush?
    @Published var backgroundBrushSize = 0.04
    @Published var backgroundBrushSoftness = 0.65
    @Published var showsBackgroundMatte = false { didSet { refreshBackgroundPreview() } }

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

    // MARK: - Viewer assist

    /// False colour and zebras. A preference like the scope settings above, and
    /// for the same reason: it describes how someone is looking at the picture,
    /// not anything the project contains.
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
        renderer.setViewerAssist(viewerAssist)
        renderer.preloadLooks()
        decodePreview()
    }

    deinit {
        gradeTask?.cancel()
        backgroundTask?.cancel()
        backgroundAnalysisTask?.cancel()
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
                model.sourcePreviewBuffer = quick.buffer
                model.refreshBackgroundPreview()
                model.renderer.invalidate()

                let full = try await ImageDecoder.decodeDetached(url: url, maximumLongEdge: longEdge)
                guard !Task.isCancelled else { return }
                model.sourcePreviewBuffer = full.buffer
                model.refreshBackgroundPreview()
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

    var selectedBackgroundRemoval: BackgroundRemovalSettings? {
        guard let settings = project.backgroundRemoval?.clamped, settings.isEnabled else { return nil }
        return settings
    }

    func backgroundRemovalBinding<T>(_ keyPath: WritableKeyPath<BackgroundRemovalSettings, T>) -> Binding<T> {
        Binding(get: { [weak self] in
            (self?.selectedBackgroundRemoval ?? .automatic)[keyPath: keyPath]
        }, set: { [weak self] value in
            self?.changeBackground { settings in
                settings[keyPath: keyPath] = value; settings.isEnabled = true
            }
        })
    }

    func startAutomaticBackgroundRemoval() {
        changeBackground("Auto Background Removal", immediate: true) {
            $0.beginAnalysis(mode: .automatic)
        }
        runBackgroundAnalysis()
    }

    func armBackgroundLasso() {
        backgroundAnalysisTask?.cancel(); backgroundAnalysisTask = nil
        backgroundAnalysisProgress = nil
        backgroundBrush = nil; isPickingBackgroundColor = false; isDrawingBackgroundLasso = true
        backgroundAnalysisMessage = String(localized: "Draw a closed outline around the object you want to keep.")
    }

    /// Adopts a freshly drawn outline. A still needs no analysis pass at all:
    /// the cutout is on screen as soon as the preview redraws.
    func commitBackgroundLasso(_ points: [MaskPoint]) {
        guard isDrawingBackgroundLasso else { return }
        isDrawingBackgroundLasso = false
        let authored = BackgroundLassoSelection.authored(points)
        guard authored.count >= 3 else {
            backgroundAnalysisMessage = String(localized: "That outline was too small. Draw all the way around the object.")
            return
        }
        changeBackground("Lasso Selection", immediate: true) { $0.adopt(.init(points: authored)) }
        backgroundAnalysisMessage = String(localized: "Everything outside the outline is removed. Turn on Invert to cut out the object instead.")
    }

    func clearBackgroundLasso() {
        changeBackground("Clear Lasso", immediate: true) { $0.lasso = nil }
        armBackgroundLasso()
    }

    func useColorBackgroundRemoval() {
        backgroundAnalysisTask?.cancel(); backgroundAnalysisProgress = nil
        changeBackground("Color Background Removal", immediate: true) {
            $0.mode = .colorKey; $0.isEnabled = true
        }
    }

    func armBackgroundColorPicker() {
        useColorBackgroundRemoval(); backgroundBrush = nil; isDrawingBackgroundLasso = false
        isPickingBackgroundColor = true
        backgroundAnalysisMessage = String(localized: "Tap the background color to remove.")
    }

    func pickBackgroundColor(at point: CGPoint) {
        guard isPickingBackgroundColor, let sourcePreviewBuffer,
              let color = Self.sample(sourcePreviewBuffer, at: point) else { return }
        isPickingBackgroundColor = false
        changeBackground("Pick Background Color", immediate: true) {
            $0.mode = .colorKey; $0.isEnabled = true
            $0.colorKey.color = .init(red: color.x, green: color.y, blue: color.z)
        }
        backgroundAnalysisMessage = nil
    }

    func addBackgroundStroke(_ points: [MaskPoint]) {
        guard let kind = backgroundBrush, !points.isEmpty else { return }
        changeBackground(kind == .add ? "Add Cutout Detail" : "Remove Cutout Detail", immediate: true) {
            $0.strokes.append(.init(kind: kind, points: points,
                radius: self.backgroundBrushSize, softness: self.backgroundBrushSoftness))
        }
    }

    func resetBackgroundRefinement() {
        changeBackground("Reset Background Refinement", immediate: true) { $0.resetRefinement() }
    }

    func removeBackgroundRemoval() {
        flushBackgroundHistory(); backgroundAnalysisTask?.cancel()
        let before = project
        project.backgroundRemoval = nil; project.updatedAt = .now
        history.record("Remove Background Removal", before: before, after: project)
        backgroundAnalysisProgress = nil; backgroundAnalysisMessage = nil
        backgroundBrush = nil; isDrawingBackgroundLasso = false; isPickingBackgroundColor = false
        refreshBackgroundPreview()
    }

    func cancelBackgroundAnalysis() {
        backgroundAnalysisTask?.cancel(); backgroundAnalysisTask = nil
        backgroundAnalysisProgress = nil
        backgroundAnalysisMessage = String(localized: "Analysis canceled.")
    }

    func refreshBackgroundPreview() {
        guard let source = sourcePreviewBuffer else { return }
        if showsOriginal {
            frames.replace(source); renderer.invalidate(); return
        }
        guard let settings = selectedBackgroundRemoval else {
            frames.replace(source); renderer.invalidate(); return
        }
        let matte = ImageBackgroundMatteBuilder.make(projectID: project.id, itemID: project.id,
                                                      source: source, settings: settings)
        let displayed: CVPixelBuffer?
        if showsBackgroundMatte {
            displayed = ImageBackgroundMatteBuilder.mattePreview(matte,
                width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
        } else {
            displayed = ImageBackgroundMatteBuilder.applying(matte, to: source, settings: settings)
        }
        frames.replace(displayed ?? source); renderer.invalidate()
    }

    private func changeBackground(_ label: String = "Remove Background", immediate: Bool = false,
                                  _ edit: (inout BackgroundRemovalSettings) -> Void) {
        flushGradeHistory()
        let before = project
        var settings = project.backgroundRemoval ?? .automatic
        edit(&settings)
        settings = settings.clamped
        guard settings != project.backgroundRemoval else { return }
        if _backgroundBaseline == nil { _backgroundBaseline = before; backgroundHistoryLabel = label }
        project.backgroundRemoval = settings; project.updatedAt = .now
        refreshBackgroundPreview()
        backgroundTask?.cancel()
        if immediate { flushBackgroundHistory(); return }
        backgroundTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            self?.flushBackgroundHistory()
        }
    }

    private var _backgroundBaseline: ImageProject?
    private var backgroundHistoryLabel = "Remove Background"

    private func flushBackgroundHistory() {
        backgroundTask?.cancel(); backgroundTask = nil
        if let before = _backgroundBaseline {
            history.record(backgroundHistoryLabel, before: before, after: project)
        }
        _backgroundBaseline = nil; backgroundHistoryLabel = "Remove Background"
    }

    private func runBackgroundAnalysis() {
        backgroundAnalysisTask?.cancel()
        guard let settings = selectedBackgroundRemoval else { return }
        let duration = (try? TimelineTime.seconds(1)) ?? .zero
        let trackID = UUID()
        let clip = VideoClip(placement: .init(id: project.id, trackID: trackID,
            timelineStart: .zero, duration: duration), assetID: project.asset.id,
            sourceRange: .init(start: .zero, duration: duration), backgroundRemoval: settings)
        let asset = ProjectMediaAsset(id: project.asset.id, url: project.sourceURL,
            sourceRange: .init(start: .zero, duration: duration),
            stillImage: .init(width: project.metadata.pixelWidth, height: project.metadata.pixelHeight))
        let request = BackgroundRemovalAnalysisRequest(projectID: project.id, clip: clip,
                                                       asset: asset, settings: settings)
        backgroundAnalysisProgress = .init(fraction: 0, frames: 0, preparing: true)
        backgroundAnalysisMessage = nil
        backgroundAnalysisTask = Task { [weak self] in
            do {
                let summary = try await BackgroundRemovalAnalyzer.analyze(request) { update in
                    Task { @MainActor [weak self] in self?.backgroundAnalysisProgress = update }
                }
                guard !Task.isCancelled else { return }
                self?.backgroundAnalysisProgress = nil
                self?.backgroundAnalysisMessage = summary.frames > 0
                    ? String(localized: "Background ready")
                    : String(localized: "No clear subject was found. Try the Lasso tool instead.")
                self?.refreshBackgroundPreview()
            } catch is CancellationError { return }
            catch {
                self?.backgroundAnalysisProgress = nil
                self?.backgroundAnalysisMessage = error.localizedDescription
            }
        }
    }

    private nonisolated static func sample(_ buffer: CVPixelBuffer, at point: CGPoint) -> SIMD3<Double>? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let pixels = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let x = min(max(Int(point.x * CGFloat(CVPixelBufferGetWidth(buffer))), 0), CVPixelBufferGetWidth(buffer)-1)
        let y = min(max(Int(point.y * CGFloat(CVPixelBufferGetHeight(buffer))), 0), CVPixelBufferGetHeight(buffer)-1)
        let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return SIMD3(Double(pixels[offset+2])/255, Double(pixels[offset+1])/255, Double(pixels[offset])/255)
    }

    func setOriginalVisible(_ visible: Bool) {
        showsOriginal = visible
        refreshBackgroundPreview()
    }

    // MARK: - History

    var canUndo: Bool { gradeBaseline != nil || _backgroundBaseline != nil || !history.undoEntries.isEmpty }
    var canRedo: Bool { gradeBaseline == nil && _backgroundBaseline == nil && !history.redoEntries.isEmpty }

    func flushGradeHistory() {
        gradeTask?.cancel(); gradeTask = nil
        if let before = gradeBaseline {
            history.record(historyLabel, before: before, after: project)
        }
        gradeBaseline = nil
        historyLabel = "Color"
    }

    func undo() {
        flushGradeHistory()
        flushBackgroundHistory()
        guard let restored = history.undo() else { return }
        project = restored
        project.updatedAt = .now
        prepareLook(in: project.gradeSettings)
        refreshBackgroundPreview()
        synchronizeRenderer()
    }

    func redo() {
        flushGradeHistory()
        flushBackgroundHistory()
        guard let restored = history.redo() else { return }
        project = restored
        project.updatedAt = .now
        prepareLook(in: project.gradeSettings)
        refreshBackgroundPreview()
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
        case .mask: advanced.mask = nil
        // Power windows and Shot Match are both timeline-clip features, so the
        // still editor never shows either tool and can never be asked to reset
        // one. See `availablePanels`.
        // Noise reduction is a video tool: temporal reduction has no other
        // frames to look at in a photograph, and a still already has its own
        // route from file to picture. See `availablePanels`.
        // Relight is a video tool too: its depth is estimated across a shot
        // and carried along the motion between frames.
        case .masks, .match, .noise, .relight: return
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
        if gradeBaseline == nil { gradeBaseline = project }
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
        showStatus(String(localized: "Grade copied"))
    }

    /// `.replace` swaps the whole grading state for the copied one; `.addOnTop`
    /// keeps what is on the picture and lays the copied grade over it. The user
    /// chooses, through the same question the video editor asks.
    func pasteGrade(_ mode: GradePasteMode) {
        guard canPasteGrade, let grade = gradeClipboard.grade else { return }
        switch mode {
        case .replace:
            replaceGrade(with: grade, label: "Paste Grade", subject: "The copied grade")
            showStatus(String(localized: "Grade pasted"))
        case .addOnTop:
            replaceGrade(with: grade.stacked(onto: settings),
                         label: "Add Grade", subject: "The copied grade")
            showStatus(String(localized: "Grade added"))
        }
        CurveHaptics.add()
    }

    func resetGrade() {
        guard canResetGrade else { return }
        guard replaceGrade(with: .neutral, label: "Reset Grade", subject: "This grade") else { return }
        CurveHaptics.reset()
        showStatus(String(localized: "Grade reset"))
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
                editError = String(localized: """
                    \(subject) uses a LUT that is no longer available.

                    Everything else has been applied. No other look was substituted.
                    """)
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
