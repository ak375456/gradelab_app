import CoreMedia
import Foundation
import SwiftUI
import UIKit

// ---------------------------------------------------------------------------
// Shot Match, from the editor's side
//
// Everything here is coordination: choosing a reference, asking the engine for
// a solution, writing the result into the clip, and taking it back out again.
// None of the colour science is in this file, and none of the editor's state is
// in the engine.
//
// The one idea worth reading twice is what "applying a match" means. It writes
// ordinary grading values into the clip's ordinary `GradeSettings`, and keeps
// the grade that was there before in `ShotMatchSettings.baseGrade`. So:
//
//   - The result is editable, because it IS the controls.
//   - Preview and export cannot disagree, because there is nothing new for them
//     to disagree about.
//   - Strength and the component toggles rebuild from `baseGrade` rather than
//     trying to subtract the last result back out, so moving the slider a
//     hundred times is as exact as moving it once.
//   - Reset restores a grade rather than reconstructing one.
// ---------------------------------------------------------------------------

/// What the Match panel is doing and holding. Editor state: none of it is
/// persisted, because all of it is recoverable from the clip.
struct ShotMatchUIState {
    /// The reference the user has chosen but not yet matched against, or the
    /// one the current match used.
    var reference: ShotMatchReference?
    var mode: ShotMatchMode = .shot
    var components: ShotMatchComponents = .default
    /// 0...1. Lives here as well as on the clip so dragging the slider is not a
    /// document write per frame.
    var strength: Float = 0.75
    var progress: ShotMatchProgress?
    /// The solution the current match produced, for the readout. Nil before the
    /// first match and after a reset.
    var solution: ShotMatchSolution?
    var referenceThumbnail: UIImage?
    var currentThumbnail: UIImage?
    /// Whether the reference clip is measured across its length or at one frame.
    var analyzesWholeClip = true
    /// What a new match does to what is already on the clip.
    var applyMode: ShotMatchApplyMode = .replace

    var isWorking: Bool { progress != nil }
}

/// What running a match does to the grade already on the clip.
///
/// The distinction only matters once there is something to preserve, which is
/// why the panel offers it only then.
enum ShotMatchApplyMode: String, CaseIterable, Identifiable, Sendable {
    /// Replace the previous match, keeping the grade that was underneath it.
    ///
    /// The default, and what pressing the button twice should obviously do:
    /// two matches against two references are two attempts at the same problem,
    /// not a stack. Hand edits made since the last match are part of what gets
    /// replaced, which is the one thing about it worth warning about.
    case replace
    /// Match on top of everything currently on the clip, previous match
    /// included.
    ///
    /// For the case Replace cannot serve: a match, then half an hour of manual
    /// work on top of it, then a decision to bring the shot closer to a
    /// different reference. Replace would throw that half hour away; this keeps
    /// it and solves for what is left.
    case add

    var id: String { rawValue }

    var title: String {
        switch self {
        case .replace: String(localized: "Replace")
        case .add: String(localized: "Add")
        }
    }

    var explanation: String {
        switch self {
        case .replace: String(localized: "Replaces the last match. Anything you changed by hand since is replaced too.")
        case .add: String(localized: "Keeps the grade you have now, including the last match, and matches on top of it.")
        }
    }
}

extension EditorViewModel {

    // MARK: - Panel state

    var shotMatch: ShotMatchSettings? { selectedClip?.shotMatch }

    /// True when a match is on this clip and the grade is still exactly what it
    /// produced. False after a hand edit, which the panel says out loud rather
    /// than letting Strength silently throw the edit away.
    var shotMatchIsIntact: Bool {
        guard let match = selectedClip?.shotMatch else { return false }
        return !match.isDetached(from: globalSettings)
    }

    /// Clips that can serve as a reference: every other video clip on the
    /// timeline. A clip cannot be its own reference — matching a shot to itself
    /// is a no-op by construction, and offering it would suggest otherwise.
    var shotMatchReferenceCandidates: [VideoClip] {
        project.timeline.tracks
            .flatMap(\.items)
            .compactMap { if case .video(let clip) = $0 { return clip } else { return nil } }
            .filter { $0.id != selectedClipID }
            .sorted { $0.placement.timelineStart.seconds < $1.placement.timelineStart.seconds }
    }

    // MARK: - Choosing a reference

    /// Uses another timeline clip as the reference.
    ///
    /// `seconds` is a time on the TIMELINE, which is converted to the clip's own
    /// source time here — a retimed or trimmed clip shows a different frame at
    /// the same timeline position, and analysing the wrong frame of the right
    /// clip is the kind of error nobody would ever spot from the result.
    func setShotMatchReference(clip: VideoClip, atTimelineSeconds seconds: Double? = nil) {
        guard let asset = project.assets.first(where: { $0.id == clip.assetID }) else {
            editError = String(localized: "That clip's media is missing.")
            return
        }
        let timelineSeconds = seconds ?? (clip.placement.timelineStart.seconds
                                          + clip.placement.duration.seconds * 0.5)
        let sourceSeconds: Double
        if let time = try? TimelineTime.seconds(timelineSeconds),
           let source = try? clip.sourceTime(at: time) {
            sourceSeconds = source.seconds
        } else {
            sourceSeconds = clip.sourceRange.start.seconds
        }
        shotMatchState.reference = ShotMatchReference(
            source: .timelineClip(clipID: clip.id, seconds: sourceSeconds),
            displayName: asset.url.deletingPathExtension().lastPathComponent,
            // Empty until the analysis fills it in. Kept rather than made
            // optional so the reference is one value from the moment it is
            // chosen, and the panel has something to name.
            profile: ShotAnalyzer.empty(),
            isClipAverage: shotMatchState.analyzesWholeClip,
            thumbnailFileName: nil)
        shotMatchState.solution = nil
        Task { await refreshShotMatchThumbnails() }
    }

    /// Uses an imported still as the reference.
    ///
    /// The file is copied into the project's own folder first. A reference
    /// picked out of Photos or Files lives somewhere the app does not control,
    /// and a project that reopens to a missing reference thumbnail because the
    /// user tidied their downloads is a bad enough experience to be worth one
    /// copy. The match itself survives regardless — that is what keeping the
    /// profile is for — but the panel should still be able to show what it was
    /// matched to.
    func setShotMatchReference(imageURL url: URL) {
        let name = url.deletingPathExtension().lastPathComponent
        Task { @MainActor in
            do {
                let stored = try await Self.importShotMatchReference(url)
                shotMatchState.reference = ShotMatchReference(
                    source: .importedImage(fileName: stored.lastPathComponent),
                    displayName: name,
                    profile: ShotAnalyzer.empty(),
                    isClipAverage: false,
                    thumbnailFileName: nil)
                shotMatchState.solution = nil
                await refreshShotMatchThumbnails()
            } catch {
                editError = error.localizedDescription
            }
        }
    }

    /// Copies an imported reference into the app's own `Imports` folder.
    ///
    /// Through `ProjectStore`, so it lands beside every other piece of managed
    /// media and is repaired by `relocateManagedFiles` when iOS moves the data
    /// container — which it does on every install from Xcode. The user's
    /// original file is copied, never moved and never modified, exactly as
    /// video and photo import already promise.
    private static func importShotMatchReference(_ url: URL) async throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let store = ProjectStore()
        let destination = try await store.sourceImportURL(
            fileExtension: url.pathExtension.isEmpty ? "jpg" : url.pathExtension)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    /// The file a reference's picture lives in, when there still is one.
    ///
    /// Nil is an ordinary answer, not a failure: a reference image the user has
    /// since deleted costs the panel its thumbnail and nothing else, because
    /// everything the match needs was measured into its profile when it ran.
    func shotMatchReferenceURL(_ reference: ShotMatchReference) -> URL? {
        switch reference.source {
        case .timelineClip(let clipID, _):
            guard let clip = project.timeline.videoClip(id: clipID),
                  let asset = project.assets.first(where: { $0.id == clip.assetID }) else { return nil }
            return FileManager.default.fileExists(atPath: asset.url.path) ? asset.url : nil
        case .importedImage(let fileName):
            let url = shotMatchImportsFolder.appendingPathComponent(fileName)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    /// The managed `Imports` folder, resolved the same way `ProjectStore`
    /// resolves it. Read synchronously because the panel asks for it while
    /// drawing; it is a path calculation, not I/O.
    private var shotMatchImportsFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GradeLab", isDirectory: true)
            .appendingPathComponent("Imports", isDirectory: true)
    }

    // MARK: - Matching

    /// Analyse both pictures and solve, then show the result without committing
    /// it — the preview updates, the panel fills in, and Apply is what makes it
    /// part of the document.
    ///
    /// Running the match already changes what is on screen, because the grade is
    /// written to the clip as the preview. That is deliberate: a match that
    /// could only be judged after committing it would have to be undone to be
    /// rejected. `baseGrade` is what makes it free to reject.
    func runShotMatch() {
        guard canGrade, let clip = selectedClip else { return }
        guard let reference = shotMatchState.reference else {
            editError = String(localized: "Choose a reference first.")
            return
        }
        guard let shotRequest = shotMatchRequest(for: clip, wholeClip: true) else {
            editError = String(localized: "This clip's media is missing.")
            return
        }
        let referenceRequest = shotMatchRequest(for: reference)
        // The grade this match sits on. Replace drops the previous match and
        // builds on what was under it; Add treats everything currently on the
        // clip as the floor.
        let base = shotMatchState.applyMode == .add
            ? clip.gradeSettings
            : (clip.shotMatch?.baseGrade ?? clip.gradeSettings)
        let components = shotMatchState.components
        let mode = shotMatchState.mode

        shotMatchTask?.cancel()
        shotMatchState.progress = .analyzingReference
        shotMatchTask = Task { [weak self] in
            guard let self, let engine = await self.shotMatchEngine() else {
                await MainActor.run {
                    self?.shotMatchState.progress = nil
                    self?.editError = ShotMatchError.analysisUnavailable.errorDescription
                }
                return
            }
            do {
                let stored = reference.profile.isUsable ? reference.profile : nil
                let result = try await engine.match(
                    shot: shotRequest, reference: referenceRequest, referenceProfile: stored,
                    components: components, mode: mode,
                    progress: { [weak self] stage in
                        Task { @MainActor in self?.shotMatchState.progress = stage }
                    })
                try Task.checkCancellation()
                await MainActor.run {
                    self.finishShotMatch(
                        solution: result.solution, referenceProfile: result.reference,
                        reference: reference, base: base, components: components, mode: mode)
                }
            } catch is CancellationError {
                await MainActor.run { self.shotMatchState.progress = nil }
            } catch {
                await MainActor.run {
                    self.shotMatchState.progress = nil
                    self.editError = error.localizedDescription
                }
            }
        }
    }

    /// Re-solves with the current components and mode, reusing both
    /// measurements. What a component toggle and the mode switch call: neither
    /// changes the pictures, so neither should pay for a decode.
    func reresolveShotMatch() {
        guard let clip = selectedClip, let match = clip.shotMatch,
              let shotRequest = shotMatchRequest(for: clip, wholeClip: true) else { return }
        let reference = match.reference
        let components = shotMatchState.components
        let mode = shotMatchState.mode
        let base = match.baseGrade

        shotMatchTask?.cancel()
        shotMatchState.progress = .matching
        shotMatchTask = Task { [weak self] in
            guard let self, let engine = await self.shotMatchEngine() else { return }
            do {
                let solution = try await engine.resolve(
                    shot: shotRequest, referenceProfile: reference.profile,
                    components: components, mode: mode)
                try Task.checkCancellation()
                await MainActor.run {
                    self.finishShotMatch(
                        solution: solution, referenceProfile: reference.profile,
                        reference: reference, base: base, components: components, mode: mode)
                }
            } catch is CancellationError {
                await MainActor.run { self.shotMatchState.progress = nil }
            } catch {
                await MainActor.run {
                    self.shotMatchState.progress = nil
                    self.editError = error.localizedDescription
                }
            }
        }
    }

    private func finishShotMatch(
        solution: ShotMatchSolution,
        referenceProfile: ShotProfile,
        reference: ShotMatchReference,
        base: GradeSettings,
        components: ShotMatchComponents,
        mode: ShotMatchMode
    ) {
        shotMatchState.progress = nil
        shotMatchState.solution = solution
        var resolved = reference
        resolved.profile = referenceProfile
        resolved.isClipAverage = shotMatchState.analyzesWholeClip
        shotMatchState.reference = resolved

        let settings = ShotMatchSettings(
            reference: resolved, mode: mode, components: components,
            strength: shotMatchState.strength, adjustment: solution.adjustment,
            confidence: solution.confidence, baseGrade: base)
        applyShotMatch(settings, label: String(localized: "Shot Match"))
    }

    /// Match Strength.
    ///
    /// Rebuilds from `baseGrade` every time rather than nudging the current
    /// grade, so dragging the slider back and forth lands on exactly the same
    /// numbers it started from. `coalesced` is what keeps a drag to one undo
    /// entry.
    func setShotMatchStrength(_ strength: Float, coalesced: Bool = true) {
        shotMatchState.strength = min(max(strength, 0), 1)
        guard var settings = selectedClip?.shotMatch else { return }
        settings.strength = shotMatchState.strength
        applyShotMatch(settings, label: String(localized: "Match Strength"), coalesced: coalesced)
    }

    /// Stops an analysis in flight and leaves everything as it was.
    ///
    /// A cancel is not a reset: the clip keeps whatever match it already had,
    /// because the user asked to stop waiting, not to undo.
    func cancelShotMatch() {
        shotMatchTask?.cancel()
        shotMatchTask = nil
        shotMatchState.progress = nil
    }

    func setShotMatchMode(_ mode: ShotMatchMode) {
        guard shotMatchState.mode != mode else { return }
        shotMatchState.mode = mode
        if selectedClip?.shotMatch != nil { reresolveShotMatch() }
    }

    func toggleShotMatchComponent(_ component: ShotMatchComponents) {
        if shotMatchState.components.contains(component) {
            shotMatchState.components.remove(component)
        } else {
            shotMatchState.components.insert(component)
        }
        if selectedClip?.shotMatch != nil { reresolveShotMatch() }
    }

    /// Removes the match and puts back the grade that was underneath it.
    ///
    /// Exact, not reconstructed: `baseGrade` is the grade itself, stored at the
    /// moment the match landed, so a reset cannot leave a residue behind
    /// however many times Strength was moved in between.
    func resetShotMatch() {
        guard let clip = selectedClip, let match = clip.shotMatch else { return }
        let base = match.baseGrade
        commit(String(localized: "Reset Shot Match"), rebuildsSequence: false) { project in
            project.timeline.setShotMatch(nil, grade: base, for: clip.id)
            return self.selectedClipID
        }
        shotMatchState.solution = nil
        synchronizeRenderer()
    }

    /// Writes a match and the grade it produces as ONE document change.
    ///
    /// The single-undo-entry requirement, met structurally rather than by
    /// remembering to group things: exposure, white balance, contrast,
    /// saturation and the wheels are not separate edits that happen to arrive
    /// together, they are one value being written once. `commit` is the app's
    /// ordinary history path, so undo restores the previous grade and redo puts
    /// the match back with no special case anywhere.
    private func applyShotMatch(
        _ settings: ShotMatchSettings, label: String, coalesced: Bool = false
    ) {
        guard let clipID = selectedClipID else { return }
        let grade = settings.resolvedGrade
        if coalesced {
            // A drag writes continuously. The grade-history coalescing the
            // colour sliders already use turns the whole gesture into one
            // entry, and is why this does not go through `commit`.
            applyCoalescedGradeEdit(label: label) { project in
                project.timeline.setShotMatch(settings, grade: grade, for: clipID)
            }
            return
        }
        commit(label, rebuildsSequence: false) { project in
            project.timeline.setShotMatch(settings, grade: grade, for: clipID)
            return self.selectedClipID
        }
        synchronizeRenderer()
    }

    // MARK: - Requests

    private func shotMatchRequest(for clip: VideoClip, wholeClip: Bool) -> ShotMatchRequest? {
        guard let asset = project.assets.first(where: { $0.id == clip.assetID }) else { return nil }
        // The shot is measured wearing exactly the grade the solved values will
        // be added to — which is the same grade `runShotMatch` picked as the
        // base, and has to be, or the solver would be correcting a picture
        // nobody is going to see.
        let grade = shotMatchState.applyMode == .add
            ? clip.gradeSettings
            : (clip.shotMatch?.baseGrade ?? clip.gradeSettings)
        let source: ShotMatchRequest.Source
        if asset.stillImage != nil {
            source = .image(url: asset.url)
        } else if wholeClip {
            source = .clipAverage(url: asset.url, range: clip.sourceRange)
        } else {
            let seconds = (try? clip.sourceTime(at: playheadTime))?.seconds
                ?? clip.sourceRange.start.seconds
            source = .clipFrame(url: asset.url, seconds: seconds)
        }
        return ShotMatchRequest(
            source: source, grade: grade,
            masks: clip.resolvedMaskedGrades,
            colorMode: project.colorMode,
            fallbackMatrix: asset.videoMetadata?.yCbCrMatrix)
    }

    private func shotMatchRequest(for reference: ShotMatchReference) -> ShotMatchRequest? {
        switch reference.source {
        case .timelineClip(let clipID, let seconds):
            guard let clip = project.timeline.videoClip(id: clipID),
                  let asset = project.assets.first(where: { $0.id == clip.assetID }) else { return nil }
            // The reference's OWN grade is applied. A reference shot is a graded
            // shot; measuring its ungraded source would match the camera rather
            // than the colorist, which is the opposite of what was asked for.
            let source: ShotMatchRequest.Source = shotMatchState.analyzesWholeClip
                ? .clipAverage(url: asset.url, range: clip.sourceRange)
                : .clipFrame(url: asset.url, seconds: seconds)
            return ShotMatchRequest(
                source: source, grade: clip.gradeSettings,
                masks: clip.resolvedMaskedGrades,
                colorMode: project.colorMode,
                fallbackMatrix: asset.videoMetadata?.yCbCrMatrix)
        case .importedImage:
            guard let url = shotMatchReferenceURL(reference) else { return nil }
            // An imported still carries no grade of its own and is decoded
            // through `ImageDecoder`, which colour-manages it out of whatever
            // profile it was tagged with into the working space.
            return ShotMatchRequest(
                source: .image(url: url), grade: .neutral, masks: [],
                colorMode: project.colorMode, fallbackMatrix: nil)
        }
    }

    // MARK: - Thumbnails

    /// The two pictures shown side by side. Display only — nothing is measured
    /// from these.
    func refreshShotMatchThumbnails() async {
        let reference = shotMatchState.reference
        let clip = selectedClip
        let current = await shotMatchThumbnail(forClip: clip)
        var referenceImage: UIImage?
        if let reference {
            switch reference.source {
            case .timelineClip(let clipID, let seconds):
                referenceImage = await shotMatchThumbnail(
                    forClip: project.timeline.videoClip(id: clipID), atSourceSeconds: seconds)
            case .importedImage:
                if let url = shotMatchReferenceURL(reference) {
                    referenceImage = ImageDecoder.thumbnail(url: url, maximumPixelSize: 480)
                        .map { UIImage(cgImage: $0) }
                }
            }
        }
        shotMatchState.currentThumbnail = current
        shotMatchState.referenceThumbnail = referenceImage
    }

    private func shotMatchThumbnail(
        forClip clip: VideoClip?, atSourceSeconds seconds: Double? = nil
    ) async -> UIImage? {
        guard let clip, let asset = project.assets.first(where: { $0.id == clip.assetID }) else {
            return nil
        }
        if asset.stillImage != nil {
            return ImageDecoder.thumbnail(url: asset.url, maximumPixelSize: 480)
                .map { UIImage(cgImage: $0) }
        }
        let time = seconds
            ?? (try? clip.sourceTime(at: playheadTime))?.seconds
            ?? clip.sourceRange.start.seconds
        return try? await ThumbnailGenerator().makeThumbnail(
            for: asset.url, at: CMTime(seconds: max(0, time), preferredTimescale: 600),
            maximumSize: CGSize(width: 480, height: 480))
    }
}
