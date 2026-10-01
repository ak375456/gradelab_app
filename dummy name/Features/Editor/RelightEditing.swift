import CoreGraphics
import Foundation
import Metal
import SwiftUI

// ---------------------------------------------------------------------------
// Relight: the editor's side
//
// Every write is an ordinary clip edit through `changeVisual`, so it inherits
// the coalescing every other tool uses: the first change of a gesture opens
// an undo entry, the rest of the drag folds into it, and the entry closes when
// the finger lifts — or a moment after the last keyboard nudge. A drag is one
// undo step, not sixty.
//
// Keyframes follow the rule masks follow. A value that is not animated is
// written as the authored value. Once it is animated, a change at the playhead
// is a keyframe there, and a change with the playhead outside the clip is
// refused with a reason rather than landing somewhere unseen.
//
// Nothing here runs the analysis on the main thread. The editor starts it,
// shows its progress and lets it be cancelled; the work runs detached.
// ---------------------------------------------------------------------------

extension EditorViewModel {
    // MARK: - Reading

    /// The selected clip's authored relight.
    var relightSettings: RelightSettings? { selectedClip?.resolvedRelight }

    var relightLights: [RelightLight] { relightSettings?.lights ?? [] }

    /// The relight as rendered at the playhead, keyframes evaluated. What the
    /// viewer handles and the inspector read, so a handle sits exactly where
    /// its light is on this frame.
    var displayedRelight: RelightSettings? {
        guard let clip = selectedClip, let relight = clip.resolvedRelight else { return nil }
        guard relight.isAnimated, let local = clip.localTime(for: playheadTime) else { return relight }
        return relight.evaluated(atLocal: local)
    }

    var selectedLight: RelightLight? {
        guard let selectedLightID else { return nil }
        return relightLights.first { $0.id == selectedLightID }
    }

    func displayedLight(_ id: UUID) -> RelightLight? {
        displayedRelight?.lights.first { $0.id == id }
    }

    /// Clip-local time for light keyframes: the clip's own window, as masks use.
    var relightAnimationTime: TimelineTime? { selectedClip?.localTimeInside(playheadTime) }

    /// The selected clip's media, when it is video Relight can light.
    var relightAsset: ProjectMediaAsset? {
        guard let clip = selectedClip,
              let asset = project.assets.first(where: { $0.id == clip.assetID }),
              asset.stillImage == nil, asset.videoMetadata != nil else { return nil }
        return asset
    }

    var relightSource: RelightSourceInfo? { relightAsset.flatMap(RelightSourceInfo.make(asset:)) }

    /// Why Relight cannot be used on the current selection, or nil when it can.
    var relightUnavailableReason: String? {
        guard let clip = selectedClip else { return String(localized: "Select a video clip to relight it.") }
        guard let asset = project.assets.first(where: { $0.id == clip.assetID }) else {
            return String(localized: "This clip's media is missing.")
        }
        if asset.stillImage != nil {
            return String(localized: "Relight works on video. Its depth is estimated across a shot and carried along the motion between frames, which a still image does not have.")
        }
        if asset.videoMetadata == nil || relightSource == nil {
            return String(localized: "This clip's file could not be read, so its scene cannot be analysed.")
        }
        return nil
    }

    var canEditRelight: Bool { canGrade && relightUnavailableReason == nil }

    var canAddLight: Bool { canEditRelight && relightLights.count < RelightSettings.maximumLights }

    /// True when the selection is lit and the viewer should show its handles.
    var showsRelightHandles: Bool { selectedPanel == .relight && selectedMaskID == nil && !relightLights.isEmpty }

    // MARK: - Writing

    /// The single write path. `immediate` closes the undo entry at once, for
    /// discrete actions; a continuous gesture leaves it open so the whole drag
    /// coalesces, and `flushGradeHistory()` on finger-up closes it.
    func editRelight(_ label: String, immediate: Bool = false, _ edit: (inout RelightSettings) -> Void) {
        guard canEditRelight else { return }
        changeVisual(label, immediate: immediate) { clip in
            var advanced = clip.gradeSettings.advanced ?? .neutral
            var relight = advanced.relight ?? RelightSettings()
            edit(&relight)
            advanced.normalizeCollections()
            advanced.relight = relight.isEmpty ? nil : relight
            clip.gradeSettings.advanced = advanced == .neutral ? nil : advanced
        }
    }

    func updateLight(_ id: UUID, label: String, immediate: Bool = false, _ edit: (inout RelightLight) -> Void) {
        editRelight(label, immediate: immediate) { relight in
            guard let index = relight.lights.firstIndex(where: { $0.id == id }) else { return }
            edit(&relight.lights[index])
        }
    }

    // MARK: - Structure

    func selectLight(_ id: UUID?) {
        guard selectedLightID != id else { return }
        flushGradeHistory()
        selectedLightID = id
    }

    func addLight(_ type: RelightLightType) {
        guard canAddLight else {
            if canEditRelight {
                editError = String(localized: "A clip can carry \(RelightSettings.maximumLights) lights. Delete one to add another.")
            }
            return
        }
        let light = RelightLight.starting(type, name: (relightSettings ?? RelightSettings()).nextLightName())
        editRelight("Add Light", immediate: true) { relight in
            relight.lights.append(light)
            relight.isEnabled = true
        }
        selectedLightID = light.id
        ensureRelightAnalysis()
    }

    func deleteLight(_ id: UUID) {
        guard canEditRelight else { return }
        let lights = relightLights
        if selectedLightID == id {
            // The neighbour takes the selection, so Delete pressed twice
            // deletes two lights rather than one and then nothing.
            let index = lights.firstIndex { $0.id == id } ?? 0
            let remaining = lights.filter { $0.id != id }
            selectedLightID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
        }
        if hoveredLightID == id { hoveredLightID = nil }
        editRelight("Delete Light", immediate: true) { relight in
            relight.lights.removeAll { $0.id == id }
        }
    }

    func duplicateLight(_ id: UUID) {
        guard canAddLight, let source = relightLights.first(where: { $0.id == id }) else { return }
        let copy = source.duplicated(named: (relightSettings ?? RelightSettings()).nextLightName())
        editRelight("Duplicate Light", immediate: true) { relight in
            let index = relight.lights.firstIndex { $0.id == id }.map { $0 + 1 } ?? relight.lights.count
            relight.lights.insert(copy, at: index)
        }
        selectedLightID = copy.id
    }

    func renameLight(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateLight(id, label: "Rename Light", immediate: true) { $0.name = String(trimmed.prefix(40)) }
    }

    func setLightEnabled(_ id: UUID, _ enabled: Bool) {
        updateLight(id, label: enabled ? "Enable Light" : "Disable Light", immediate: true) {
            $0.isEnabled = enabled
        }
    }

    /// Returns a light to where a new light of its kind starts, and drops its
    /// keyframes. Its name and identity stay.
    func resetLight(_ id: UUID) {
        updateLight(id, label: "Reset Light", immediate: true) { light in
            var fresh = RelightLight.starting(light.type, name: light.name)
            fresh = RelightLight(
                id: light.id, name: light.name, type: light.type, isEnabled: light.isEnabled,
                positionX: fresh.positionX, positionY: fresh.positionY, distance: fresh.distance,
                targetX: fresh.targetX, targetY: fresh.targetY, azimuth: fresh.azimuth,
                elevation: fresh.elevation, intensity: fresh.intensity, exposure: fresh.exposure,
                color: fresh.color, temperature: fresh.temperature, tint: fresh.tint,
                softness: fresh.softness, falloff: fresh.falloff, radius: fresh.radius,
                coneAngle: fresh.coneAngle, feather: fresh.feather, shadowResponse: fresh.shadowResponse,
                specular: fresh.specular, roughness: fresh.roughness, lightWrap: fresh.lightWrap)
            light = fresh
        }
    }

    /// Changes what kind of light this is. Everything that applies to both
    /// kinds is kept; keyframes on properties the new kind does not have go.
    func setLightType(_ id: UUID, _ type: RelightLightType) {
        updateLight(id, label: "Light Type", immediate: true) { light in
            guard light.type != type else { return }
            light.type = type
            if var animation = light.animation {
                for property in RelightLight.animatableProperties where !RelightLight.supports(property, type: type) {
                    animation.removeAnimation(of: property)
                }
                light.animation = animation.isEmpty ? nil : animation
            }
        }
    }

    func moveLights(from offsets: IndexSet, to destination: Int) {
        editRelight("Reorder Lights", immediate: true) { $0.lights.move(fromOffsets: offsets, toOffset: destination) }
    }

    func setRelightEnabled(_ enabled: Bool) {
        editRelight(enabled ? "Relight On" : "Relight Off", immediate: true) { $0.isEnabled = enabled }
    }

    func applyRelightPreset(_ preset: RelightPreset) {
        guard canEditRelight else { return }
        editRelight("Relight Preset", immediate: true) { relight in
            relight = preset.applied(to: relight)
        }
        selectedLightID = relightLights.first?.id
        ensureRelightAnalysis()
    }

    /// Removes every light, keyframe and scene setting. The depth cache stays:
    /// it describes the scene, not the lighting.
    func resetRelight() {
        guard canEditRelight else { return }
        selectedLightID = nil
        changeVisual("Reset Relight", immediate: true) { clip in
            guard var advanced = clip.gradeSettings.advanced else { return }
            advanced.relight = nil
            clip.gradeSettings.advanced = advanced == .neutral ? nil : advanced
        }
    }

    // MARK: - Animatable light values

    func lightKeyframeState(_ id: UUID, _ property: AnimatableProperty) -> KeyframeState {
        guard let track = relightLights.first(where: { $0.id == id })?.animation?.track(property) else { return .off }
        guard let local = relightAnimationTime else { return .animated }
        return track.index(at: local) != nil ? .onKeyframe : .animated
    }

    /// A slider's binding: reads the value on screen and writes by the
    /// keyframe rule.
    func lightBinding(_ id: UUID, _ property: AnimatableProperty) -> Binding<Double> {
        Binding(
            get: { [weak self] in
                self?.displayedLight(id)?.number(of: property) ?? property.defaultValue.number ?? 0
            },
            set: { [weak self] value in
                self?.setLightNumbers(id, [(property, value)], label: property.title)
            })
    }

    /// Writes several values of one light in one edit, each by the keyframe
    /// rule. A drag on the viewer moves X and Y together through this, so the
    /// two can never land in different undo entries.
    func setLightNumbers(_ id: UUID, _ values: [(AnimatableProperty, Double)], label: String,
                         immediate: Bool = false) {
        guard let light = relightLights.first(where: { $0.id == id }) else { return }
        let local = relightAnimationTime
        if values.contains(where: { light.animation?.track($0.0) != nil }) && local == nil {
            editError = String(localized: "Move the playhead inside the clip to change an animated light.")
            return
        }
        updateLight(id, label: label, immediate: immediate) { light in
            for (property, number) in values {
                let value = KeyframeValue.number(number).clamped(to: property)
                if var animation = light.animation, animation.track(property) != nil, let local {
                    animation.update(property) { $0.set(value, at: local) }
                    light.animation = animation
                } else {
                    light.setBaseKeyframeValue(value, of: property)
                }
            }
        }
    }

    /// The colour filter, by the same rule.
    func setLightColor(_ id: UUID, _ color: RGBAColor, immediate: Bool = false) {
        guard let light = relightLights.first(where: { $0.id == id }) else { return }
        let value = KeyframeValue.color(RGBAColor(red: color.red, green: color.green, blue: color.blue))
        let animated = light.animation?.track(.relightColor) != nil
        guard !animated || relightAnimationTime != nil else {
            editError = String(localized: "Move the playhead inside the clip to change an animated light.")
            return
        }
        let local = relightAnimationTime
        updateLight(id, label: "Light Color", immediate: immediate) { light in
            if animated, var animation = light.animation, let local {
                animation.update(.relightColor) { $0.set(value, at: local) }
                light.animation = animation
            } else {
                light.setBaseKeyframeValue(value, of: .relightColor)
            }
        }
    }

    /// Diamond tap: hold what is on screen as a keyframe, or remove the one on
    /// this exact frame.
    func toggleLightKeyframe(_ id: UUID, _ property: AnimatableProperty) {
        guard let local = relightAnimationTime,
              let onScreen = displayedLight(id)?.baseKeyframeValue(of: property) else { return }
        playback.pause()
        let adding = lightKeyframeState(id, property) != .onKeyframe
        updateLight(id, label: adding ? "Add Keyframe" : "Remove Keyframe", immediate: true) { light in
            var animation = light.animation ?? ClipAnimation()
            if animation.track(property)?.index(at: local) != nil {
                animation.update(property) { $0.remove(at: local) }
                if animation.track(property) == nil { light.setBaseKeyframeValue(onScreen, of: property) }
            } else {
                animation.update(property) { $0.set(onScreen, at: local) }
            }
            light.animation = animation.isEmpty ? nil : animation
        }
    }

    /// Stops animating one property and keeps the value on screen.
    func removeLightAnimation(_ id: UUID, _ property: AnimatableProperty) {
        let onScreen = displayedLight(id)?.baseKeyframeValue(of: property)
        updateLight(id, label: "Remove Animation", immediate: true) { light in
            guard var animation = light.animation else { return }
            animation.removeAnimation(of: property)
            light.animation = animation.isEmpty ? nil : animation
            if let onScreen { light.setBaseKeyframeValue(onScreen, of: property) }
        }
    }

    // MARK: - Scene values

    var relightStrengthKeyframeState: KeyframeState {
        guard let track = relightSettings?.animation?.track(.relightStrength) else { return .off }
        guard let local = relightAnimationTime else { return .animated }
        return track.index(at: local) != nil ? .onKeyframe : .animated
    }

    var relightStrengthBinding: Binding<Double> {
        Binding(
            get: { [weak self] in self?.displayedRelight?.strength ?? 1 },
            set: { [weak self] value in self?.setRelightStrength(value) })
    }

    func setRelightStrength(_ value: Double, immediate: Bool = false) {
        let animated = relightSettings?.animation?.track(.relightStrength) != nil
        let local = relightAnimationTime
        guard !animated || local != nil else {
            editError = String(localized: "Move the playhead inside the clip to change an animated strength.")
            return
        }
        editRelight("Relight Strength", immediate: immediate) { relight in
            let clamped = KeyframeValue.number(value).clamped(to: .relightStrength)
            if animated, var animation = relight.animation, let local {
                animation.update(.relightStrength) { $0.set(clamped, at: local) }
                relight.animation = animation
            } else if let number = clamped.number {
                relight.setNumber(number, of: .relightStrength)
            }
        }
    }

    func toggleRelightStrengthKeyframe() {
        guard let local = relightAnimationTime, let shown = displayedRelight?.strength else { return }
        playback.pause()
        let adding = relightStrengthKeyframeState != .onKeyframe
        editRelight(adding ? "Add Keyframe" : "Remove Keyframe", immediate: true) { relight in
            var animation = relight.animation ?? ClipAnimation()
            if animation.track(.relightStrength)?.index(at: local) != nil {
                animation.update(.relightStrength) { $0.remove(at: local) }
                if animation.track(.relightStrength) == nil { relight.setNumber(shown, of: .relightStrength) }
            } else {
                animation.update(.relightStrength) { $0.set(.number(shown), at: local) }
            }
            relight.animation = animation.isEmpty ? nil : animation
        }
    }

    func removeRelightStrengthAnimation() {
        let shown = displayedRelight?.strength
        editRelight("Remove Animation", immediate: true) { relight in
            guard var animation = relight.animation else { return }
            animation.removeAnimation(of: .relightStrength)
            relight.animation = animation.isEmpty ? nil : animation
            if let shown { relight.setNumber(shown, of: .relightStrength) }
        }
    }

    /// A scene control that does not animate: Form, Preserve Highlights and
    /// Protect Blacks.
    func relightSceneBinding(_ keyPath: WritableKeyPath<RelightSettings, Double>, label: String) -> Binding<Double> {
        Binding(
            get: { [weak self] in (self?.relightSettings ?? RelightSettings())[keyPath: keyPath] },
            set: { [weak self] value in
                self?.editRelight(label) { $0[keyPath: keyPath] = value.isFinite ? value : 0 }
            })
    }

    /// Which of the clip's masks limits the relight, or nil for the whole
    /// frame. The masks are the clip's own power windows: Relight has no mask
    /// system of its own.
    func setRelightMask(_ id: UUID?) {
        editRelight("Relight Area", immediate: true) { $0.maskID = id }
    }

    /// The mask the relight is limited to, if it still exists.
    var relightMask: MaskedGradeLayer? {
        guard let id = relightSettings?.maskID else { return nil }
        return maskedGrades.first { $0.id == id }
    }

    // MARK: - Viewer manipulation

    /// Brackets a drag on the viewer. Geometry drops to a lighter resolution
    /// for its length so the light keeps up with the pointer, and the frame
    /// left on screen is redrawn at full quality when it ends.
    func beginLightGesture() {
        playback.pause()
        renderer.setRelightInteractive(true)
        RelightInteraction.isActive = true
    }

    func endLightGesture() {
        renderer.setRelightInteractive(false)
        RelightInteraction.isActive = false
        flushGradeHistory()
        if maskOverlayUsesCanvas { synchronizeRenderer() }
    }

    /// Moves a point or spot light to a place in the upright picture.
    func moveLight(_ id: UUID, to point: CGPoint) {
        setLightNumbers(id, [(.relightPositionX, Double(point.x)), (.relightPositionY, Double(point.y))],
                        label: "Move Light")
    }

    /// Aims a spot light at a place in the upright picture.
    func aimLight(_ id: UUID, at point: CGPoint) {
        setLightNumbers(id, [(.relightTargetX, Double(point.x)), (.relightTargetY, Double(point.y))],
                        label: "Aim Light")
    }

    /// Sets a directional light from a point on the direction disk.
    func pointLight(_ id: UUID, disk point: CGPoint) {
        let angles = RelightDirectionDisk.angles(from: point)
        setLightNumbers(id, [(.relightAzimuth, angles.azimuth), (.relightElevation, angles.elevation)],
                        label: "Light Direction")
    }

    func setLightReach(_ id: UUID, radius: Double) {
        setLightNumbers(id, [(.relightRadius, radius)], label: "Light Reach")
    }

    /// The keyboard: arrows move the selected light, Shift moves it further
    /// and Option moves it finely. Each press is an ordinary coalesced edit, so
    /// a run of presses undoes as one step.
    func nudgeSelectedLight(dx: Double, dy: Double) {
        guard canEditRelight, let id = selectedLightID, let light = displayedLight(id) else { return }
        playback.pause()
        switch light.type {
        case .directional:
            var point = RelightDirectionDisk.point(azimuth: light.azimuth, elevation: light.elevation)
            point.x += CGFloat(dx * 3)
            point.y += CGFloat(dy * 3)
            pointLight(id, disk: point)
        case .point, .spot:
            moveLight(id, to: CGPoint(x: light.positionX + dx, y: light.positionY + dy))
        }
    }

    // MARK: - Analysis

    /// True while this clip's media is being analysed.
    var isAnalyzingSelectedClip: Bool {
        guard relightProgress != nil, let identifier = relightAnalysisIdentifier else { return false }
        return relightSource?.cacheIdentifier == identifier
    }

    /// How much of the selected clip has depth at `quality`, 0…1.
    func relightCoverage(_ quality: RelightQuality) -> Double? {
        _ = relightDepthRevision
        guard let clip = selectedClip, let source = relightSource,
              let end = try? clip.sourceRange.end else { return nil }
        let first = source.frameIndex(sourceTime: clip.sourceRange.start)
        let last = max(first, source.frameIndex(sourceTime: end) - 1)
        return RelightDepthStore.shared.coverage(identifier: source.cacheIdentifier, quality: quality,
                                                 frames: first...last)
    }

    /// Which estimator the stored analysis used, when there is one.
    var relightManifest: RelightAnalysisManifest? {
        _ = relightDepthRevision
        guard let source = relightSource else { return nil }
        for quality in [relightQuality, relightQuality == .high ? .fast : .high] {
            if let manifest = RelightDepthStore.shared.manifest(
                .init(identifier: source.cacheIdentifier, quality: quality)) { return manifest }
        }
        return nil
    }

    func setRelightQuality(_ quality: RelightQuality) {
        guard relightQuality != quality else { return }
        relightQuality = quality
        quality.savePreference()
        renderer.setRelightQuality(quality)
    }

    /// Starts analysis when a clip that has just been given its first light
    /// has no depth at all yet. A partial analysis is left for the person to
    /// continue: they may have stopped it on purpose.
    func ensureRelightAnalysis() {
        guard let source = relightSource, !isAnalyzingSelectedClip,
              RelightDepthStore.shared.availableQuality(identifier: source.cacheIdentifier,
                                                        preferring: relightQuality) == nil else { return }
        analyzeRelight()
    }

    /// Analyses the selected clip's scene at the preview quality, starting at
    /// the playhead. `restart` discards what was stored first.
    func analyzeRelight(restart: Bool = false) {
        guard canGrade, let clip = selectedClip, let asset = relightAsset, let source = relightSource else {
            relightNotice = relightUnavailableReason
            return
        }
        cancelRelightAnalysis()
        let quality = relightQuality
        if restart {
            RelightDepthStore.shared.clear(.init(identifier: source.cacheIdentifier, quality: quality))
            renderer.invalidateRelightDepth()
            relightDepthRevision &+= 1
        }
        let startAt: TimelineTime? = clip.localTimeInside(playheadTime) != nil
            ? (try? clip.sourceTime(at: playheadTime)) : nil
        let request = RelightAnalysisRequest(
            asset: asset, source: source, sourceRange: clip.sourceRange, startAt: startAt,
            quality: quality, colorMode: project.colorMode)
        let context = renderer.metalContext
        let run = UUID()
        let clipID = clip.id
        let identifier = source.cacheIdentifier
        relightAnalysisRun = run
        relightAnalysisIdentifier = identifier
        relightNotice = nil
        relightProgress = RelightAnalysisProgress(
            fraction: 0, frames: 0, totalFrames: 0, isPreparing: true, isThermallyPaused: false, estimator: nil)
        let sink: @Sendable (RelightAnalysisProgress) -> Void = { [weak self] progress in
            Task { @MainActor in self?.relightAnalysisReported(progress, run: run) }
        }
        relightAnalysisTask = Task.detached(priority: .utility) { [weak self] in
            do {
                let summary = try await RelightAnalyzer.analyze(request, context: context, progress: sink)
                await self?.relightAnalysisFinished(run: run, clipID: clipID, identifier: identifier,
                                                    quality: quality, summary: summary, failure: nil)
            } catch is CancellationError {
                await self?.relightAnalysisFinished(run: run, clipID: clipID, identifier: identifier,
                                                    quality: quality, summary: nil, failure: nil)
            } catch {
                await self?.relightAnalysisFinished(run: run, clipID: clipID, identifier: identifier,
                                                    quality: quality, summary: nil,
                                                    failure: error.localizedDescription)
            }
        }
    }

    func cancelRelightAnalysis() {
        relightAnalysisTask?.cancel()
        relightAnalysisTask = nil
        relightAnalysisRun = nil
        relightAnalysisIdentifier = nil
        relightProgress = nil
    }

    /// Deletes the selected clip's stored depth at both qualities.
    func clearRelightCache() {
        guard let source = relightSource else { return }
        if isAnalyzingSelectedClip { cancelRelightAnalysis() }
        RelightDepthStore.shared.remove(identifier: source.cacheIdentifier)
        renderer.invalidateRelightDepth()
        RelightSharedStage.shared(for: renderer.metalContext)?.stage.releaseResources()
        relightDepthRevision &+= 1
        synchronizeRenderer()
    }

    private func relightAnalysisReported(_ progress: RelightAnalysisProgress, run: UUID) {
        guard relightAnalysisRun == run else { return }
        relightProgress = progress
        // The composited preview has no repaint-when-depth-lands of its own,
        // so it is refreshed now and then while the analysis is filling in.
        if maskOverlayUsesCanvas, !playback.isPlaying,
           Date.now.timeIntervalSince(relightCompositeRefresh) > 1.5 {
            relightCompositeRefresh = .now
            synchronizeRenderer()
        }
    }

    private func relightAnalysisFinished(run: UUID, clipID: UUID, identifier: String,
                                         quality: RelightQuality, summary: RelightAnalysisSummary?,
                                         failure: String?) {
        guard relightAnalysisRun == run else { return }
        relightAnalysisRun = nil
        relightAnalysisIdentifier = nil
        relightAnalysisTask = nil
        relightProgress = nil
        relightDepthRevision &+= 1
        if summary != nil {
            recordRelightAnalysis(
                RelightAnalysisReference(version: RelightSettings.analysisVersion,
                                         cacheIdentifier: identifier, quality: quality, startedAt: .now),
                on: clipID)
        }
        if let failure { relightNotice = failure }
        renderer.invalidate()
        synchronizeRenderer()
    }
}

// MARK: - The direction disk

/// How a directional light is drawn and dragged on the viewer: a disk centred
/// on the picture, in units of its radius. The centre is light from the camera,
/// the ring is pure side light, and the band outside it — out to one and a half
/// radii — is light from behind the subject. The handle sits on the side the
/// light comes from.
enum RelightDirectionDisk {
    static let outerLimit: Double = 1.5

    static func point(azimuth: Double, elevation: Double) -> CGPoint {
        let radius: Double = elevation >= 0
            ? cos(min(elevation, 90) * .pi / 180)
            : 1 + (outerLimit - 1) * min(-elevation, 80) / 80
        let angle = azimuth * .pi / 180
        return CGPoint(x: radius * cos(angle), y: -radius * sin(angle))
    }

    static func angles(from point: CGPoint) -> (azimuth: Double, elevation: Double) {
        let radius = min(Double(hypot(point.x, point.y)), outerLimit)
        var azimuth = atan2(-Double(point.y), Double(point.x)) * 180 / .pi
        if azimuth < 0 { azimuth += 360 }
        if azimuth >= 360 { azimuth -= 360 }
        let elevation = radius <= 1
            ? acos(radius) * 180 / .pi
            : -(radius - 1) / (outerLimit - 1) * 80
        return (azimuth, min(max(elevation, -80), 90))
    }
}
