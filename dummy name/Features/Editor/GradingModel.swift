import SwiftUI

/// Where the "no look" thumbnail is filed in a look strip.
enum LookPreviewKey {
    static let original = "__original__"
}

/// Everything the Color tab needs from whatever it is grading.
///
/// This exists so there is one Color tab, not two. `EditorViewModel` grades the
/// selected clip of a video timeline and `ImageEditorViewModel` grades a
/// photograph, but the curve editor, the look strip, the finishing effects, the
/// scopes, the preset grid and the copy/paste actions are the same views driven
/// through this protocol — which also means a change to any of them lands on
/// both at once rather than in one and eventually in the other.
///
/// It is deliberately about *grading* and nothing else. There is no playhead, no
/// timeline, no selection and no transport here, because a photograph has none
/// of those and the shared views must not ask for them.
@MainActor
protocol GradingModel: ObservableObject, AnyObject {
    // MARK: Grade state
    var settings: GradeSettings { get set }
    /// False when the source is outside the validated colour pipeline, or the
    /// thing being graded is locked. Every control is disabled by it.
    var canGrade: Bool { get }
    var editError: String? { get set }
    /// Identifies the subject being graded, so a view can reset per-subject UI
    /// state when it changes. A clip id for video; the project id for a still.
    var gradeSubjectID: UUID? { get }
    /// True when the Colour controls are pointed at a masked local grade rather
    /// than at the clip's own.
    ///
    /// Exists because the two are not quite the same set of controls: a local
    /// layer has no offset wheel, since the whole mask stack must fit one
    /// 4096-byte `setBytes` and there is no word left for one. A panel that
    /// offered it anyway would move a slider and change nothing.
    var isEditingMaskGrade: Bool { get }
    /// Mask geometry currently shown. A timeline model returns its evaluated
    /// keyframed value; a still-image model returns the authored value.
    var displayedGradeMask: GradeMask { get }

    // MARK: Panels
    var selectedPanel: GradePanel { get set }
    /// The tools offered right now. A still has no masks; a video clip with a
    /// mask selected offers only the tools that mask can actually carry.
    var availablePanels: [GradePanel] { get }
    /// The name of the masked local grade the controls are pointed at, or nil
    /// when they are editing the whole clip. Drives the context indicator, so a
    /// slider can never be moved without it being clear what it is moving.
    var editingMaskName: String? { get }
    var visibleParameters: [GradeParameter] { get }
    func binding(for parameter: GradeParameter) -> Binding<Float>
    func advancedBinding<T>(_ keyPath: WritableKeyPath<AdvancedGrade, T>) -> Binding<T>
    func resetPanel()

    // MARK: Animatable grading values
    //
    // Grading controls address their value by PROPERTY IDENTITY rather than by
    // key path, which is what lets a timeline model route the write through the
    // keyframe engine while a photograph keeps writing the authored grade —
    // through one set of controls, not two.

    /// Reads the value at the playhead and writes it by the model's own rule.
    func gradeBinding(_ property: AnimatableProperty) -> Binding<Float>
    /// False only when the value is animated and the playhead is somewhere the
    /// keyframe could not be written.
    func canEditGradeValue(_ property: AnimatableProperty) -> Bool

    // MARK: Curves
    /// The curves at the playhead: the animated shape when a curve is animated,
    /// and the authored one otherwise.
    var curves: AdvancedCurves { get }
    var selectedCurve: CurveType { get set }
    var selectedCurvePoint: UUID? { get set }
    var isPickingCurveHue: Bool { get set }
    var hasCurveEdits: Bool { get }
    func editCurve(_ type: CurveType, _ edit: (inout AdvancedCurve) -> Void)
    func resetCurve(_ type: CurveType)
    func beginCurveEdit(_ label: String)
    func endCurveEdit()

    // MARK: Color Warper
    //
    // The warp itself lives on the grade and is reached through `editColorWarp`
    // in ColorWarpEditing.swift, which is written once against this protocol.
    // Only the editor's own state is declared here.

    /// Which plane the mesh is showing. Editor state, not grade state: both
    /// planes stay live whichever one is on screen.
    var selectedWarpMode: ColorWarpMode { get set }
    var selectedWarpPoint: UUID? { get set }
    /// True while the warper's eyedropper is armed and waiting for a tap on the
    /// preview.
    var isPickingWarpColor: Bool { get set }
    /// Samples the picture under `point` and selects the mesh handle for that
    /// colour, placing one if there is none there yet.
    @discardableResult
    func pickWarpColor(atViewPoint point: CGPoint) -> Bool

    // MARK: Finishing effects
    var hasFilmEffects: Bool { get }
    func resetFilmEffects()
    /// Closes the open coalesced edit into one undo entry.
    func flushGradeHistory()

    // MARK: Looks
    var availableLooks: [LUTAsset] { get }
    var selectedLook: LUTAsset? { get }
    var lookPreviews: [String: UIImage] { get }
    func selectLook(_ asset: LUTAsset?)
    func importLooks(from urls: [URL])
    func removeLook(_ asset: LUTAsset)
    func refreshLookPreviews(force: Bool)

    // MARK: Presets
    var presets: GradePresetLibrary { get }
    func applyPreset(_ preset: GradePreset)
    func updatePreset(_ id: UUID) async
    @discardableResult
    func saveGradeAsPreset(name: String, isFavorite: Bool, thumbnail: UIImage?) async -> Bool
    func suggestedPresetName() -> String
    func makePresetThumbnail() async -> UIImage?

    // MARK: Grade clipboard
    var canCopyGrade: Bool { get }
    var canPasteGrade: Bool { get }
    var canResetGrade: Bool { get }
    /// True when a paste would land on something that is already graded, and so
    /// would throw work away unless the user is asked first.
    var pasteWouldOverwriteGrade: Bool { get }
    func copyGrade()
    func pasteGrade(_ mode: GradePasteMode)
    func resetGrade()

    // MARK: Scopes
    var scopeSettings: ScopeSettings { get }
    var scopeAnalyzer: ScopeAnalyzer? { get }
    var scopeRenderer: ScopeRenderer? { get }
    var scopeColorSpace: ScopeColorSpace { get }
    var showsOriginal: Bool { get }
    func setScopesEnabled(_ enabled: Bool)
    func selectScope(_ type: ScopeType)
    func setScopeIntensity(_ intensity: Double)

    // MARK: Viewer assist
    /// False colour and zebras. Both editors render through the same
    /// `MetalVideoRenderer`, so a still gets this for the same reason it gets
    /// the scopes: it is the same display path.
    var viewerAssist: ViewerAssistSettings { get }
    func setViewerAssist(_ mode: ViewerAssist)
    func setZebraThreshold(_ threshold: Double)
}

extension GradingModel {
    /// Most models have no masked grades at all, so they are always editing the
    /// primary one.
    var isEditingMaskGrade: Bool { false }

    /// A drawn window on its own is deliberately not counted: it changes no
    /// pixel, and a paste replacing nothing is not worth a question.
    var pasteWouldOverwriteGrade: Bool {
        canPasteGrade && settings.hasCreativeChangeIgnoringMask
    }

    /// Masked local grades and Shot Match are both timeline-clip features: a
    /// still has one picture, no clip to hang windows on, and no other shot to
    /// match to. The still editor therefore never shows either tool rather than
    /// showing an empty one.
    ///
    /// Matching a photograph to a reference image is a perfectly sensible thing
    /// to want and the engine would serve it unchanged — it takes pixels and
    /// returns values. What is missing is the document side: a still project has
    /// nowhere to record which reference was used or what grade was underneath,
    /// which is what makes a match non-destructive. Offering the tool without
    /// that would offer a match that could not be undone.
    ///
    /// Noise reduction is absent for a plainer reason than either of those: its
    /// better half looks at the frames either side of this one, and a
    /// photograph has none. Offering the panel with the temporal section dead
    /// would be offering the spatial half of a tool under the name of the whole
    /// one.
    var availablePanels: [GradePanel] {
        GradePanel.allCases.filter { $0 != .masks && $0 != .match && $0 != .noise }
    }
    var editingMaskName: String? { nil }

    /// Bindings for the mutable UI state the shared panels drive.
    ///
    /// Written out rather than reached through `$model.property`: that form needs
    /// a writable key path into the concrete type, and these views only ever see
    /// the protocol. The protocol is class-bound, so assigning through `self`
    /// here is the same store the concrete model would do.
    var selectedPanelBinding: Binding<GradePanel> {
        Binding(get: { self.selectedPanel }, set: { self.selectedPanel = $0 })
    }

    var selectedCurveBinding: Binding<CurveType> {
        Binding(get: { self.selectedCurve }, set: { self.selectedCurve = $0 })
    }

    var selectedCurvePointBinding: Binding<UUID?> {
        Binding(get: { self.selectedCurvePoint }, set: { self.selectedCurvePoint = $0 })
    }

    var isPickingCurveHueBinding: Binding<Bool> {
        Binding(get: { self.isPickingCurveHue }, set: { self.isPickingCurveHue = $0 })
    }

    var editErrorBinding: Binding<String?> {
        Binding(get: { self.editError }, set: { self.editError = $0 })
    }

    /// A still has no timeline, so its grading values are simply the authored
    /// ones and every one of them is always editable.
    func gradeBinding(_ property: AnimatableProperty) -> Binding<Float> {
        Binding(
            get: { Float(self.settings.gradeNumber(property) ?? 0) },
            set: { value in
                guard self.canGrade else { return }
                var updated = self.settings
                updated.setGradeNumber(Double(value), for: property)
                self.settings = updated
            }
        )
    }

    func canEditGradeValue(_ property: AnimatableProperty) -> Bool { true }

    var gradeMask: GradeMask { (settings.advanced ?? .neutral).resolvedMask }
    var displayedGradeMask: GradeMask { gradeMask }

    func gradeMaskBinding<T>(_ keyPath: WritableKeyPath<GradeMask, T>) -> Binding<T> {
        Binding(
            get: { self.gradeMask[keyPath: keyPath] },
            set: { value in
                guard self.canGrade else { return }
                var updated = self.settings
                var advanced = updated.advanced ?? .neutral
                var mask = advanced.resolvedMask
                mask[keyPath: keyPath] = value
                advanced.mask = mask == .disabled ? nil : mask
                updated.advanced = advanced == .neutral ? nil : advanced
                self.settings = updated
            }
        )
    }
}
