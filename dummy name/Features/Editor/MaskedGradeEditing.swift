import SwiftUI

// ---------------------------------------------------------------------------
// Masked local grading: the editor's side
//
// Every operation here is an ordinary clip edit, so it inherits the coalescing
// the Transform tools already use: the first change of a gesture opens an undo
// entry, the rest of the drag folds into it, and the entry closes when the
// finger lifts or after the usual idle delay. A drag is one undo step, not
// sixty.
// ---------------------------------------------------------------------------

extension EditorViewModel {
    /// The mask whose local grade the Color controls are pointed at, or nil for
    /// the clip's global grade.
    var selectedMask: MaskedGradeLayer? {
        guard let selectedMaskID else { return nil }
        return maskedGrades.first { $0.id == selectedMaskID }
    }

    /// The mask as rendered at the playhead, with geometry keyframes evaluated.
    /// This is what the preview overlay draws and what the inspector shows, so
    /// the handles sit exactly where the window is.
    func displayedMask(_ id: UUID) -> MaskedGradeLayer? {
        guard let clip = selectedClip else { return nil }
        guard let local = clip.localTime(for: playheadTime) else {
            return clip.resolvedMaskedGrades.first { $0.id == id }
        }
        return clip.resolvedMaskedGrades.first { $0.id == id }?.evaluated(atLocal: local)
    }

    var displayedSelectedMask: MaskedGradeLayer? {
        selectedMaskID.flatMap { displayedMask($0) }
    }

    /// Which mask the preview shows as a matte, resolved for the renderer.
    var maskMatte: MaskMatte {
        guard let maskMatteID, maskedGrades.contains(where: { $0.id == maskMatteID }) else { return .none }
        return .layer(maskMatteID)
    }

    var canAddMask: Bool { canGrade && maskedGrades.count < MaskedGradeLayer.maximumPerClip }

    // MARK: - Selection

    /// The Color tools offered in the current context.
    var availablePanels: [GradePanel] {
        guard selectedMaskID != nil else { return GradePanel.allCases }
        return GradePanel.localCapable
    }

    // MARK: - Structure

    func addMask(_ shape: MaskShape) {
        guard canAddMask else {
            if canGrade {
                editError = "A clip can carry \(MaskedGradeLayer.maximumPerClip) masks. Delete one to add another."
            }
            return
        }
        let layer = MaskedGradeLayer(
            name: maskedGrades.nextDefaultName(),
            geometry: .starting(shape))
        changeVisual("Add Mask", immediate: true) { clip in
            var masks = clip.resolvedMaskedGrades
            masks.append(layer)
            clip.maskedGrades = masks
        }
        selectMask(layer.id)
        // A freehand mask has no shape until it is drawn, so adding one opens
        // the drawing mode rather than dropping an invisible empty polygon.
        isDrawingMask = shape == .freehand
    }

    func deleteMask(_ id: UUID) {
        guard canGrade else { return }
        if selectedMaskID == id { selectMask(nil) }
        if maskMatteID == id { maskMatteID = nil }
        changeVisual("Delete Mask", immediate: true) { clip in
            var masks = clip.resolvedMaskedGrades
            masks.removeAll { $0.id == id }
            clip.maskedGrades = masks.isEmpty ? nil : masks
        }
        synchronizeRenderer()
    }

    func duplicateMask(_ id: UUID) {
        guard canAddMask, let source = maskedGrades.first(where: { $0.id == id }) else { return }
        let copy = source.duplicated(named: maskedGrades.nextDefaultName())
        changeVisual("Duplicate Mask", immediate: true) { clip in
            var masks = clip.resolvedMaskedGrades
            let index = masks.firstIndex { $0.id == id }.map { $0 + 1 } ?? masks.count
            masks.insert(copy, at: index)
            clip.maskedGrades = masks
        }
        selectMask(copy.id)
    }

    /// List order is composition order: mask 2 grades the picture mask 1
    /// produced. Moving one therefore changes the result, and does so
    /// predictably.
    func moveMasks(from offsets: IndexSet, to destination: Int) {
        guard canGrade else { return }
        changeVisual("Reorder Masks", immediate: true) { clip in
            var masks = clip.resolvedMaskedGrades
            masks.move(fromOffsets: offsets, toOffset: destination)
            clip.maskedGrades = masks
        }
    }

    func renameMask(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateMask(id, label: "Rename Mask", immediate: true) { $0.name = String(trimmed.prefix(40)) }
    }

    func setMaskEnabled(_ id: UUID, _ enabled: Bool) {
        updateMask(id, label: enabled ? "Show Mask Grade" : "Hide Mask Grade", immediate: true) {
            $0.isEnabled = enabled
        }
        if !enabled, maskMatteID == id { maskMatteID = nil }
        synchronizeRenderer()
    }

    /// Returns one mask's local grade to neutral and keeps its window. Deleting
    /// the window is `deleteMask`, and neither touches the global grade.
    func resetMaskGrade(_ id: UUID) {
        updateMask(id, label: "Reset Mask Grade", immediate: true) { $0.localGrade = .neutral }
    }

    // MARK: - Writing

    /// The single write path for a mask. `immediate` closes the undo entry at
    /// once, for discrete actions; a continuous gesture leaves it open so the
    /// whole drag coalesces into one entry, and `flushGradeHistory()` on
    /// finger-up closes it.
    func updateMask(
        _ id: UUID,
        label: String = "Mask",
        immediate: Bool = false,
        _ edit: (inout MaskedGradeLayer) -> Void
    ) {
        guard canGrade else { return }
        changeVisual(label, immediate: immediate) { clip in
            var masks = clip.resolvedMaskedGrades
            guard let index = masks.firstIndex(where: { $0.id == id }) else { return }
            edit(&masks[index])
            clip.maskedGrades = masks
        }
    }

    /// A geometry binding for the inspector sliders.
    ///
    /// Writes go through the keyframe engine when the property is animated, and
    /// straight to the authored value when it is not — the same rule every other
    /// animatable control in the app follows.
    func maskGeometryBinding(_ id: UUID, _ property: AnimatableProperty) -> Binding<Double> {
        Binding(
            get: { [weak self] in
                guard let self else { return 0 }
                let displayed = self.displayedMask(id)
                return displayed?.baseValue(of: property) ?? property.defaultValue.number ?? 0
            },
            set: { [weak self] value in
                self?.setMaskValue(id, property, value)
            }
        )
    }

    /// The write rule for an animatable mask property.
    func setMaskValue(_ id: UUID, _ property: AnimatableProperty, _ value: Double, immediate: Bool = false) {
        setMaskKeyframeValue(id, property, .number(value), immediate: immediate)
    }

    /// Clip-local time for mask keyframes: the clip's own animation window, so a
    /// trim or a split moves mask keyframes exactly as it moves transform ones.
    var maskAnimationTime: TimelineTime? { animationTime }

    func maskKeyframeState(_ id: UUID, _ property: AnimatableProperty) -> KeyframeState {
        guard let layer = maskedGrades.first(where: { $0.id == id }),
              let track = layer.animation?.track(property) else { return .off }
        guard let local = maskAnimationTime else { return .animated }
        return track.index(at: local) != nil ? .onKeyframe : .animated
    }

    /// Diamond tap: hold what is on screen as a keyframe, or remove the one on
    /// this exact frame.
    ///
    /// Written against `baseKeyframeValue`, so it covers a mask's local grade —
    /// including a whole-curve snapshot — with the same code that covers its
    /// geometry.
    func toggleMaskKeyframe(_ id: UUID, _ property: AnimatableProperty) {
        guard let local = maskAnimationTime,
              let displayed = displayedMask(id),
              let onScreen = displayed.baseKeyframeValue(of: property) else { return }
        playback.pause()
        let adding = maskKeyframeState(id, property) != .onKeyframe
        updateMask(id, label: adding ? "Add Keyframe" : "Remove Keyframe", immediate: true) { mask in
            var animation = mask.animation ?? ClipAnimation()
            if animation.track(property)?.index(at: local) != nil {
                animation.update(property) { $0.remove(at: local) }
                if animation.track(property) == nil { mask.setBaseKeyframeValue(onScreen, of: property) }
            } else {
                animation.update(property) { $0.set(onScreen, at: local) }
            }
            mask.animation = animation.isEmpty ? nil : animation
        }
    }

    /// The write rule for any animatable mask value, scalar or curve. Same shape
    /// as `setMaskValue`, which stays as the geometry panel's numeric entry
    /// point and now routes through this.
    func setMaskKeyframeValue(
        _ id: UUID, _ property: AnimatableProperty, _ value: KeyframeValue, immediate: Bool = false
    ) {
        guard let layer = maskedGrades.first(where: { $0.id == id }) else { return }
        let clamped = value.clamped(to: property)
        guard layer.animation?.track(property) != nil else {
            updateMask(id, label: property.title, immediate: immediate) {
                $0.setBaseKeyframeValue(clamped, of: property)
            }
            return
        }
        guard let local = maskAnimationTime else {
            editError = "Move the playhead inside the clip to change an animated mask value."
            return
        }
        playback.pause()
        updateMask(id, label: property.title, immediate: immediate) { mask in
            var animation = mask.animation ?? ClipAnimation()
            animation.update(property) { $0.set(clamped, at: local) }
            mask.animation = animation
        }
    }

    /// Stops animating a mask property and keeps the value on screen.
    func removeMaskAnimation(_ id: UUID, _ property: AnimatableProperty) {
        let onScreen = displayedMask(id)?.baseKeyframeValue(of: property)
        updateMask(id, label: "Remove Animation", immediate: true) { mask in
            guard var animation = mask.animation else { return }
            animation.removeAnimation(of: property)
            mask.animation = animation.isEmpty ? nil : animation
            if let onScreen { mask.setBaseKeyframeValue(onScreen, of: property) }
        }
    }

    /// Deletes one keyframe. Removing the last one keeps what was visible as the
    /// layer's new authored value, exactly as it does on a clip.
    func removeMaskKeyframe(_ id: UUID, _ property: AnimatableProperty, atLocal local: TimelineTime) {
        let onScreen = displayedMask(id)?.baseKeyframeValue(of: property)
        updateMask(id, label: "Remove Keyframe", immediate: true) { mask in
            guard var animation = mask.animation else { return }
            animation.update(property) { $0.remove(at: local) }
            if animation.track(property) == nil, let onScreen {
                mask.setBaseKeyframeValue(onScreen, of: property)
            }
            mask.animation = animation.isEmpty ? nil : animation
        }
    }

    /// Restores the documented default AND clears the property's animation.
    func resetMaskProperty(_ id: UUID, _ property: AnimatableProperty) {
        updateMask(id, label: "Reset \(property.title)", immediate: true) { mask in
            if var animation = mask.animation {
                animation.removeAnimation(of: property)
                mask.animation = animation.isEmpty ? nil : animation
            }
            mask.setBaseKeyframeValue(property.defaultValue, of: property)
        }
    }

    /// Removes every animation from one mask, keeping what is on screen. The
    /// clip-wide "Remove all" reaches masks through this.
    func removeAllMaskAnimation(_ id: UUID) {
        guard let displayed = displayedMask(id),
              let animated = maskedGrades.first(where: { $0.id == id })?.animation else { return }
        let held = animated.animatedProperties.compactMap { property -> (AnimatableProperty, KeyframeValue)? in
            displayed.baseKeyframeValue(of: property).map { (property, $0) }
        }
        updateMask(id, label: "Remove All Animation", immediate: true) { mask in
            mask.animation = nil
            for (property, value) in held { mask.setBaseKeyframeValue(value, of: property) }
        }
    }

    /// One mask track's keyframes in TIMELINE coordinates, restricted to the
    /// range the clip occupies.
    ///
    /// Mask keyframes are read against the CLIP's animation window — the same
    /// window `evaluatedMaskedGrades` uses — so a head trim or a split moves
    /// them exactly as it moves a transform keyframe.
    func maskVisibleKeyframes(
        _ id: UUID, _ property: AnimatableProperty
    ) -> [(local: TimelineTime, timeline: TimelineTime)] {
        guard let clip = selectedClip,
              let track = maskedGrades.first(where: { $0.id == id })?.animation?.track(property),
              let end = try? clip.placement.range.end else { return [] }
        let window = clip.animation ?? ClipAnimation()
        return track.keyframes.compactMap { frame in
            guard let time = window.compositionTime(forLocal: frame.time,
                                                    clipStart: clip.placement.timelineStart),
                  time >= clip.placement.timelineStart, time < end else { return nil }
            return (frame.time, time)
        }
    }

    // MARK: - Freehand drawing

    /// Adds a vertex to the mask being drawn, in frame-normalised coordinates.
    func appendMaskPoint(_ id: UUID, _ point: MaskPoint) {
        guard let layer = maskedGrades.first(where: { $0.id == id }),
              layer.geometry.shape == .freehand else { return }
        guard layer.geometry.points.count < MaskGeometry.maximumPoints else {
            editError = "A freehand mask can hold \(MaskGeometry.maximumPoints) points."
            return
        }
        updateMask(id, label: "Draw Mask", immediate: true) { mask in
            mask.geometry.points.append(point.clamped)
            // The pivot follows the shape while it is being drawn, and the
            // position is pinned to it, so the path starts untranslated and
            // scales and rotates about its own centre of gravity.
            if let centroid = mask.geometry.pointCentroid {
                mask.geometry.pivotX = min(max(centroid.x, 0), 1)
                mask.geometry.pivotY = min(max(centroid.y, 0), 1)
                mask.geometry.centerX = mask.geometry.pivotX
                mask.geometry.centerY = mask.geometry.pivotY
            }
        }
    }

    func moveMaskPoint(_ id: UUID, index: Int, to point: MaskPoint, committing: Bool) {
        updateMask(id, label: "Move Mask Point", immediate: committing) { mask in
            guard mask.geometry.points.indices.contains(index) else { return }
            mask.geometry.points[index] = point.clamped
            // The pivot follows the shape so later scaling stays centred, and
            // the position follows it so reshaping never nudges the mask.
            if let centroid = mask.geometry.pointCentroid {
                let aspect = selectedClip.flatMap { clip in
                    project.assets.first(where: { $0.id == clip.assetID })?.videoMetadata?.encodedSize.maskAspect
                } ?? 1
                let px = min(max(centroid.x, 0), 1), py = min(max(centroid.y, 0), 1)
                let dx = (px - mask.geometry.pivotX) * aspect * mask.geometry.width
                let dy = (py - mask.geometry.pivotY) * mask.geometry.height
                let angle = mask.geometry.rotationDegrees * .pi / 180
                // Moving the pivot must preserve the existing scaled/rotated
                // placement of every other vertex, including after tracking.
                mask.geometry.centerX = min(1, max(0, mask.geometry.centerX + (cos(angle) * dx - sin(angle) * dy) / aspect))
                mask.geometry.centerY = min(1, max(0, mask.geometry.centerY + sin(angle) * dx + cos(angle) * dy))
                mask.geometry.pivotX = px; mask.geometry.pivotY = py
            }
        }
    }

    /// The name shown in the Color tab's context bar, or nil when the controls
    /// are editing the whole clip.
    var editingMaskName: String? { selectedMask?.name }

    func removeMaskPoint(_ id: UUID, index: Int) {
        updateMask(id, label: "Delete Mask Point", immediate: true) { mask in
            guard mask.geometry.points.indices.contains(index),
                  mask.geometry.points.count > 3 else { return }
            mask.geometry.points.remove(at: index)
        }
    }

    func clearMaskPoints(_ id: UUID) {
        updateMask(id, label: "Reset Mask Shape", immediate: true) { mask in
            mask.geometry.points = []
            mask.geometry.centerX = 0.5
            mask.geometry.centerY = 0.5
            mask.geometry.pivotX = 0.5
            mask.geometry.pivotY = 0.5
            mask.geometry.width = 1
            mask.geometry.height = 1
            mask.geometry.rotationDegrees = 0
        }
        isDrawingMask = true
    }

    /// Ends drawing. A path with fewer than three points encloses nothing, so it
    /// is reported rather than left as a mask that silently never renders.
    func finishDrawingMask(_ id: UUID) {
        isDrawingMask = false
        guard let layer = maskedGrades.first(where: { $0.id == id }),
              layer.geometry.shape == .freehand,
              layer.geometry.points.count < 3 else { return }
        editError = "A freehand mask needs at least three points. Tap around the subject to draw one."
    }
}
