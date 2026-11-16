import AVFoundation
import Combine
import SwiftUI

@MainActor
final class ClipCameraPreview: ObservableObject {
    struct Edit: Equatable {
        let clipID: UUID
        let time: TimelineTime
        let camera: ClipCamera
        let property: AnimatableProperty?
        let showsResult: Bool
    }

    @Published var edit: Edit?
}

extension EditorViewModel {
    var canEditCamera: Bool {
        selectedClipIDs.count == 1 && selectedClip != nil && canEditSelection
    }

    var cameraCanvasSize: CGSize { CGSize(width: project.canvas.width, height: project.canvas.height) }

    func addClipCamera() {
        guard canEditCamera, let clip = selectedClip, clip.camera == nil else { return }
        playback.pause()
        commit("Add Reframe", rebuildsSequence: !maskOverlayUsesCanvas, preservingSelection: true) { project in
            var updated = try TimelineEditing.editable(clip.id, in: project)
            updated.camera = ClipCamera()
            try TimelineEditing.replace(clip.id, with: [updated], in: &project)
            return clip.id
        }
    }

    func removeClipCamera() {
        guard canEditCamera, selectedClip?.camera != nil else { return }
        changeVisual("Remove Reframe", immediate: true) { clip in
            clip.camera = nil
            clip.animation?.tracks.removeAll { ClipCamera.properties.contains($0.property) }
        }
    }

    func setCameraMode(_ mode: ClipCamera.Mode) {
        guard canEditCamera, selectedClip?.camera != nil else { return }
        changeVisual("Camera Framing", immediate: true) { $0.camera?.mode = mode }
    }

    func applyCameraGesture(from original: ClipCamera, to camera: ClipCamera,
                            clipID: UUID, time: TimelineTime) {
        setCameraPreview(nil)
        guard canEditCamera, selectedClipID == clipID, time == playheadTime,
              evaluatedSelectedClip?.camera == original, original != camera,
              let local = animationTime else { return }
        changeVisual("Frame Camera", immediate: true) { clip in
            for property in ClipCamera.properties {
                guard let key = ClipCamera.keyPath(property), camera[keyPath: key] != original[keyPath: key] else { continue }
                clip.setValue(.number(camera[keyPath: key]), of: property, atLocal: local)
            }
        }
    }

    func previewCameraGesture(_ camera: ClipCamera?, clipID: UUID, time: TimelineTime, showsResult: Bool) {
        guard canEditCamera, selectedClipID == clipID, time == playheadTime else { return }
        setCameraPreview(camera.map {
            .init(clipID: clipID, time: time, camera: $0, property: nil, showsResult: showsResult)
        })
    }

    func previewCameraValue(_ number: Double?, property: AnimatableProperty, showsResult: Bool) {
        guard let number else {
            if cameraPreview.edit?.property == property { setCameraPreview(nil) }
            return
        }
        guard let (clip, original, camera) = cameraAdjustment(for: property, number: number) else { return }
        setCameraPreview(camera == original ? nil :
            .init(clipID: clip.id, time: playheadTime, camera: camera, property: property, showsResult: showsResult))
    }

    func setCameraValue(_ number: Double, property: AnimatableProperty) {
        guard let (clip, original, camera) = cameraAdjustment(for: property, number: number) else { return }
        playback.pause()
        applyCameraGesture(from: original, to: camera, clipID: clip.id, time: playheadTime)
    }

    private func cameraAdjustment(for property: AnimatableProperty, number: Double) -> (VideoClip, ClipCamera, ClipCamera)? {
        guard number.isFinite, canEditCamera, isPlayheadInsideSelection, let clip = evaluatedSelectedClip,
              let original = clip.camera, let source = displaySize(of: clip) else { return nil }
        let camera = original.adjusting(property, to: number, source: source, canvas: cameraCanvasSize)
        return (clip, original, camera)
    }

    var hasCameraKeyframe: Bool {
        guard let time = animationTime else { return false }
        return ClipCamera.framingProperties.allSatisfy {
            selectedClip?.animation?.track($0)?.index(at: time) != nil
        }
    }

    func toggleCameraKeyframe() {
        guard canEditCamera, selectedClip?.camera != nil, let local = animationTime else { return }
        playback.pause()
        let removing = hasCameraKeyframe
        changeVisual(removing ? "Remove Camera Keyframe" : "Add Camera Keyframe", immediate: true) { clip in
            for property in ClipCamera.framingProperties {
                if removing {
                    clip.removeKeyframe(property, atLocal: local)
                } else if let value = clip.evaluatedValue(of: property, atLocal: local) {
                    var animation = clip.animation ?? ClipAnimation()
                    animation.update(property) {
                        if $0.index(at: local) == nil { $0.set(value, at: local, interpolation: .easeInOut) }
                    }
                    clip.animation = animation
                }
            }
        }
    }

    func placeCameraFocus(_ point: CGPoint) {
        guard let clip = evaluatedSelectedClip, let camera = clip.camera, let source = cameraSourceFrame else { return }
        let position = camera.frame(source: source.size, canvas: cameraCanvasSize).cameraCoordinate(
            of: CGPoint(x: point.x * source.size.width, y: point.y * source.size.height))
        var updated = camera
        updated.focusX = position.x
        updated.focusY = position.y
        if updated.focusAmount == 0 { updated.focusAmount = 0.45 }
        applyCameraGesture(from: camera, to: updated, clipID: clip.id, time: playheadTime)
    }

    var cameraSourceFrame: ClipCameraSourceFrame? {
        guard let clip = selectedClip, let asset = project.assets.first(where: { $0.id == clip.assetID }),
              let size = displaySize(of: clip), size.width > 0, size.height > 0,
              clip.localTimeInside(playheadTime) != nil else { return nil }
        let time = asset.stillImage != nil ? .zero : ((try? clip.sourceTime(at: playheadTime)) ?? clip.sourceRange.start)
        let metadata = asset.videoMetadata
        let encoded = metadata?.encodedSize ?? size
        return ClipCameraSourceFrame(url: asset.url, time: time, isStill: asset.stillImage != nil,
            size: size, encoded: encoded, preferred: metadata?.preferredTransform.cgTransform ?? .identity,
            stabilization: clip.stabilizationCorrection(at: playheadTime.cmTime, size: encoded))
    }
}

struct ClipCameraPanel: View {
    @ObservedObject var model: EditorViewModel
    @ObservedObject var tracking: ClipCameraTracking
    @ObservedObject private var livePreview: ClipCameraPreview
    @Binding var showsFrame: Bool
    @Binding var pickingFocus: Bool
    @State private var activeProperty: AnimatableProperty?
    @State private var selectedKeyframe: TimelineTime?
    @State private var showControls = false
    @State private var showsFocusControls = false

    init(model: EditorViewModel, tracking: ClipCameraTracking,
         showsFrame: Binding<Bool>, pickingFocus: Binding<Bool>) {
        self.model = model
        self.tracking = tracking
        livePreview = model.cameraPreview
        _showsFrame = showsFrame
        _pickingFocus = pickingFocus
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                if let camera = model.selectedClip?.camera {
                    cameraControls(camera)
                        .disabled(!model.canEditCamera)
                } else if model.canEditCamera {
                    Button {
                        model.addClipCamera()
                        if !model.isPlayheadInsideSelection { model.goToSelectedClip() }
                        showsFrame = false
                    } label: {
                        Label("Add Reframe", systemImage: "viewfinder")
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(AppColors.accentMuted, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppColors.accent)
                } else {
                    Text("Select one unlocked video or image clip.")
                        .font(AppTypography.caption).foregroundStyle(AppColors.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.visible)
    }

    private func action(_ title: LocalizedStringKey, selected: Bool = false,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(title).font(AppTypography.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(selected ? AppColors.accentMuted : AppColors.surfaceRaised,
                            in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(selected ? AppColors.accent : AppColors.textPrimary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func cameraControls(_ camera: ClipCamera) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.small) {
            HStack(spacing: AppSpacing.small) {
                action("Fill", selected: camera.mode == .fill) { model.setCameraMode(.fill) }
                action("Crop & Fit", selected: camera.mode == .crop) { model.setCameraMode(.crop) }
                Menu {
                    Menu("Track Graphic") {
                        let targets = model.cameraTrackingTargets
                        if targets.isEmpty {
                            Text("Place an unanimated text, shape, or image over the shot.")
                        }
                        ForEach(targets) { target in
                            Button(target.title) {
                                model.playback.pause()
                                pickingFocus = false
                                tracking.choose(target.id)
                                showsFrame = true
                            }
                        }
                    }
                    .disabled(tracking.progress != nil)
                    Button(showsFocusControls ? "Hide Focus Controls" : "Focus Blur", systemImage: "camera.aperture") {
                        showsFocusControls.toggle()
                        if !showsFocusControls { pickingFocus = false }
                    }
                    Button("Remove Reframe", role: .destructive) {
                        pickingFocus = false
                        tracking.cancel()
                        model.removeClipCamera()
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Camera options")
            }
            if model.isPlayheadInsideSelection {
                let y = livePreview.edit?.camera.y ?? model.evaluatedSelectedClip?.camera?.y
                HStack(spacing: AppSpacing.small) {
                    action("Top", selected: y == 0) { model.setCameraValue(0, property: .cameraY) }
                    action("Center", selected: y == 0.5) { model.setCameraValue(0.5, property: .cameraY) }
                    action("Bottom", selected: y == 1) { model.setCameraValue(1, property: .cameraY) }
                }
                Text(cameraHint(camera.mode))
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textSecondary)
                propertyRow(.cameraZoom)
            } else {
                Button("Go to clip", action: model.goToSelectedClip)
                    .frame(minHeight: 44)
            }
            HStack {
                Button(action: model.toggleCameraKeyframe) {
                    Label(model.hasCameraKeyframe ? "Remove Keyframe" : "Add Keyframe",
                          systemImage: model.hasCameraKeyframe ? "diamond.fill" : "diamond")
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                .disabled(!model.isPlayheadInsideSelection)
                Spacer(minLength: 4)
                Button {
                    showControls.toggle()
                } label: {
                    Label("More Controls", systemImage: showControls ? "chevron.up" : "slider.horizontal.3")
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityValue(showControls ? "Expanded" : "Collapsed")
            }
            .font(AppTypography.caption.weight(.semibold))
            if let progress = tracking.progress {
                HStack {
                    ProgressView("Tracking graphic", value: progress)
                    Button("Cancel", action: tracking.cancel).frame(minHeight: 44)
                }
            } else if tracking.targetID != nil {
                Button("Cancel Tracking", action: tracking.cancel).frame(minHeight: 44)
            } else if let message = tracking.message {
                Text(message).font(AppTypography.caption).foregroundStyle(AppColors.textSecondary)
            }
            if showControls {
                let axes: [AnimatableProperty] = [.cameraX, .cameraY, .cameraRoll]
                ForEach(axes + (camera.mode == .crop ? [.cameraCropWidth, .cameraCropHeight] : []),
                        id: \.self, content: propertyRow)
            }
            if showsFocusControls {
                HStack {
                    Text("Focus Blur").font(AppTypography.caption.weight(.semibold))
                    Spacer()
                    Button(pickingFocus ? "Cancel" : "Set Focus Point") {
                        pickingFocus.toggle()
                        if pickingFocus {
                            tracking.cancel()
                            model.playback.pause()
                            showsFrame = true
                        }
                    }
                    .font(AppTypography.caption).frame(minHeight: 44)
                    .disabled(!model.isPlayheadInsideSelection)
                }
                ForEach([AnimatableProperty.cameraFocusAmount, .cameraFocusRadius, .cameraFocusX, .cameraFocusY],
                        id: \.self, content: propertyRow)
            }
        }
    }

    private func cameraHint(_ mode: ClipCamera.Mode) -> LocalizedStringKey {
        if mode == .crop {
            return showsFrame ? "Drag an edge or corner to resize the crop." : "Open Crop Handles to adjust the edges."
        }
        return "Drag to pan. Pinch to zoom. Panning can add a little zoom to keep the frame filled."
    }

    private func propertyRow(_ property: AnimatableProperty) -> some View {
        let draft = ClipCamera.keyPath(property).flatMap { key in livePreview.edit?.camera[keyPath: key] }
        return KeyframePropertyRow(model: model, property: property,
            range: property == .cameraRoll ? -180...180 : property.range,
            activeProperty: $activeProperty, selectedKeyframe: $selectedKeyframe,
            displayScale: property == .cameraRoll ? 1 : 100,
            suffix: property == .cameraRoll ? "°" : "%",
            previewedNumber: draft,
            previewNumber: { model.previewCameraValue($0, property: property, showsResult: !showsFrame) },
            commitNumber: { model.setCameraValue($0, property: property) })
            .disabled(!model.isPlayheadInsideSelection)
    }
}
