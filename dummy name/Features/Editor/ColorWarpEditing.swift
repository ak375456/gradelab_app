import SwiftUI

// ---------------------------------------------------------------------------
// Color Warper editing
//
// Written once, against the protocol, rather than twice against the two view
// models - because the write path is identical: change `settings`, and live
// preview, undo coalescing and autosave all follow from that the way they do for
// every other grading control.
//
// Only the eyedropper is implemented per model. It needs the renderer, which is
// not on the protocol, and each model already has its own - exactly as
// `pickCurveHue` does.
// ---------------------------------------------------------------------------

extension GradingModel {
    /// The authored warp. There is no playhead reading here because a moving
    /// control point is not animated yet: only the strength is, and that goes
    /// through `gradeBinding` like every other animated number.
    var colorWarp: ColorWarp {
        (settings.advanced ?? .neutral).colorWarp ?? .neutral
    }

    /// Whether the panel has anything to show or reset. Points resting on their
    /// own source count: they are still handles the user placed.
    var hasColorWarpEdits: Bool {
        let warp = colorWarp
        return warp.hasPoints || warp != ColorWarp()
    }

    /// Applies an edit to the warp.
    ///
    /// Stored as nil whenever it is indistinguishable from a fresh one, which is
    /// what keeps a project that has never opened this panel from carrying it -
    /// the same optional-storage rule the curves, the mask and the finishing
    /// effects all follow. Compared against the DEFAULT rather than against
    /// "has points", so turning Preserve Luminance off before placing the first
    /// point is remembered.
    func editColorWarp(_ edit: (inout ColorWarp) -> Void) {
        guard canGrade else { return }
        var warp = colorWarp
        edit(&warp)
        var updated = settings
        var advanced = updated.advanced ?? .neutral
        advanced.normalizeCollections()
        advanced.colorWarp = warp == ColorWarp() ? nil : warp
        updated.advanced = advanced == .neutral ? nil : advanced
        settings = updated
    }

    /// Places a point, or returns the one already sitting there.
    ///
    /// A second point on top of the first would fight it for the same colours,
    /// so a tap near an existing handle selects that handle instead - the same
    /// rule `AdvancedCurve.addPoint` applies on the curve graph, and on a phone
    /// it is nearly always what was meant.
    @discardableResult
    func addColorWarpPoint(x: Float, y: Float, mode: ColorWarpMode) -> UUID? {
        guard canGrade else { return nil }
        let warp = colorWarp
        let spacing = max(warp.density.defaultRadius * 0.5, ColorWarpPoint.minimumRadius)
        if let existing = warp.nearestPoint(to: x, y, mode: mode, within: spacing) {
            return existing.id
        }
        let point = ColorWarpPoint(mode: mode, sourceX: x, sourceY: y,
                                   radius: warp.density.defaultRadius)
        editColorWarp { $0.points.append(point) }
        return point.id
    }

    func moveColorWarpPoint(id: UUID, toX x: Float, y: Float) {
        editColorWarp { warp in
            guard var point = warp[id] else { return }
            point.targetX = point.mode.wrapsHorizontally ? ColorWarpMath.wrap(x) : min(max(x, 0), 1)
            point.targetY = min(max(y, 0), 1)
            warp[id] = point
        }
    }

    func setColorWarpRadius(id: UUID, _ radius: Float) {
        editColorWarp { warp in
            guard var point = warp[id] else { return }
            point.radius = min(max(radius, ColorWarpPoint.minimumRadius), 1)
            warp[id] = point
        }
    }

    /// Puts one point back on its own colour, keeping the handle so the next
    /// drag starts from where it was placed.
    func resetColorWarpPoint(id: UUID) {
        guard canGrade else { return }
        beginCurveEdit(String(localized: "Reset warp point"))
        editColorWarp { $0.resetPoint(id: id) }
        endCurveEdit()
    }

    func removeColorWarpPoint(id: UUID) {
        guard canGrade else { return }
        beginCurveEdit(String(localized: "Delete warp point"))
        editColorWarp { $0.removePoint(id: id) }
        endCurveEdit()
        if selectedWarpPoint == id { selectedWarpPoint = nil }
    }

    /// Clears one plane, leaving the other alone - so resetting the hue wheel
    /// cannot silently throw away a chroma/luma move that is not on screen.
    func resetColorWarp(_ mode: ColorWarpMode) {
        guard canGrade else { return }
        beginCurveEdit(String(localized: "Reset Color Warper"))
        editColorWarp { $0.reset(mode) }
        endCurveEdit()
        selectedWarpPoint = nil
    }

    func resetColorWarp() {
        guard canGrade else { return }
        beginCurveEdit(String(localized: "Reset Color Warper"))
        editColorWarp { $0.reset() }
        endCurveEdit()
        selectedWarpPoint = nil
        isPickingWarpColor = false
    }

    // MARK: Bindings
    //
    // Written out rather than reached through `$model.property` for the reason
    // stated on the other bindings in `GradingModel`: these views only ever see
    // the protocol.

    var selectedWarpModeBinding: Binding<ColorWarpMode> {
        Binding(get: { self.selectedWarpMode }, set: { self.selectedWarpMode = $0 })
    }

    var selectedWarpPointBinding: Binding<UUID?> {
        Binding(get: { self.selectedWarpPoint }, set: { self.selectedWarpPoint = $0 })
    }

    var isPickingWarpColorBinding: Binding<Bool> {
        Binding(get: { self.isPickingWarpColor }, set: { self.isPickingWarpColor = $0 })
    }

    var colorWarpPreservesLuminanceBinding: Binding<Bool> {
        Binding(
            get: { self.colorWarp.preservesLuminance },
            set: { value in
                self.beginCurveEdit(String(localized: "Preserve luminance"))
                self.editColorWarp { $0.preservesLuminance = value }
                self.endCurveEdit()
            }
        )
    }

    var colorWarpDensityBinding: Binding<ColorWarpDensity> {
        Binding(
            get: { self.colorWarp.density },
            // Changing density cannot disturb a stored point - see the note at
            // the top of ColorWarp.swift - so this needs no resampling step and
            // no warning.
            set: { value in
                self.beginCurveEdit(String(localized: "Mesh density"))
                self.editColorWarp { $0.density = value }
                self.endCurveEdit()
            }
        )
    }

    /// The selected point's range, or nil when nothing is selected.
    var selectedWarpPointRadius: Float? {
        selectedWarpPoint.flatMap { colorWarp[$0]?.radius }
    }

    /// The point the mesh has selected, if it is still there.
    var selectedWarpPointValue: ColorWarpPoint? {
        selectedWarpPoint.flatMap { colorWarp[$0] }
    }
}
