import Combine
import CoreMedia
import SwiftUI

@MainActor
final class SceneCameraPreview: ObservableObject {
    struct Edit: Equatable {
        let id: UUID
        let time: TimelineTime
        let position: SceneCameraPosition
    }

    @Published var edit: Edit?
}

extension EditorViewModel {
    var selectedSceneCamera: SceneCameraClip? {
        guard case .camera(let clip) = selectedItem else { return nil }
        return clip
    }

    var canAddSceneCamera: Bool { !isPreparingTimeline && project.timeline.duration > .zero }

    func addSceneCamera() {
        guard canAddSceneCamera else { return }
        let selectedLayer = selectedClipIDs.count == 1 && selectedItem?.isCompositable == true ? selectedItem : nil
        let activeFootage = sceneCameraDepthItems.last { $0.trackKind == .videoOverlay }
        let anchor = selectedLayer ?? activeFootage
        let range = anchor?.placement.range ?? TimelineRange(start: .zero, duration: project.timeline.duration)
        let shouldSeek = playheadTime < range.start || (try? range.end).map { playheadTime >= $0 } == true
        let initialBackground = (anchor?.trackKind == .videoOverlay ? anchor : activeFootage).flatMap { item in
            item.placement.cameraDepth == nil && canSetCameraDepth(for: item) ? item.id : nil
        }
        let trackID = UUID()
        let clip = SceneCameraClip(placement: ItemPlacement(id: UUID(), trackID: trackID,
                                                            timelineStart: range.start, duration: range.duration))
        playback.pause()
        commit(String(localized: "Add Camera"), seekToSelection: shouldSeek,
               rebuildsSequence: !maskOverlayUsesCanvas) { project in
            if let initialBackground {
                project.timeline.setCameraDepth(.background, for: initialBackground)
            }
            project.timeline.tracks.insert(
                TimelineTrack(id: trackID, name: TimelineTrack.defaultName(for: .camera),
                              kind: .camera, items: [.camera(clip)]), at: 0)
            return clip.id
        }
        if shouldSeek, selectedClipID == clip.id { goToSelectedClip() }
    }

    var canAdjustSceneCamera: Bool {
        selectedSceneCamera != nil && selectedClipIDs.count == 1 && canEditSelection && isPlayheadInsideSelection
    }

    var selectedCameraDrivesPreview: Bool {
        guard let camera = selectedSceneCamera else { return false }
        return project.timeline.activeCamera(at: playheadTime)?.id == camera.id
    }

    func editSceneCamera(_ name: String, edit: (inout SceneCameraClip) -> Void) {
        guard canEditSelection, selectedClipIDs.count == 1, var clip = selectedSceneCamera else { return }
        edit(&clip)
        commit(name, rebuildsSequence: false, preservingSelection: true) { project in
            try OverlayEditing.replace(clip.id, with: clip, in: &project)
            return clip.id
        }
    }

    func previewSceneCameraValue(_ number: Double?, property: AnimatableProperty) {
        guard let number else { setSceneCameraPreview(nil); return }
        guard canAdjustSceneCamera, let clip = selectedSceneCamera,
              let keyPath = SceneCameraClip.numberKeyPath(property) else { return }
        var evaluated = clip.evaluated(at: playheadTime)
        evaluated[keyPath: keyPath] = number
        setSceneCameraPreview(.init(id: clip.id, time: playheadTime, position: evaluated.position))
    }

    func setSceneCameraValue(_ number: Double, property: AnimatableProperty) {
        guard canAdjustSceneCamera else { setSceneCameraPreview(nil); return }
        setAnimatableValue(property, .number(number), immediate: true)
        setSceneCameraPreview(nil)
    }

    func previewSceneCameraGesture(_ position: SceneCameraPosition?, id: UUID, time: TimelineTime) {
        guard canAdjustSceneCamera, selectedCameraDrivesPreview,
              selectedClipID == id, time == playheadTime else { return }
        setSceneCameraPreview(position.map { .init(id: id, time: time, position: $0) })
    }

    func applySceneCameraGesture(_ position: SceneCameraPosition, id: UUID, time: TimelineTime,
                                 from original: SceneCameraPosition) {
        guard canAdjustSceneCamera, selectedCameraDrivesPreview, let clip = selectedSceneCamera,
              clip.id == id, time == playheadTime, let local = animationTime,
              clip.evaluated(at: time).position == original else {
            setSceneCameraPreview(nil)
            return
        }
        if original != position {
            editSceneCamera(String(localized: "Move Camera")) { clip in
                for property in SceneCameraClip.animatableProperties {
                    guard let key = SceneCameraPosition.keyPath(property) else { continue }
                    guard original[keyPath: key] != position[keyPath: key] else { continue }
                    clip.setValue(.number(position[keyPath: key]), of: property, atLocal: local)
                }
            }
        }
        setSceneCameraPreview(nil)
    }

    var sceneCameraDepthItems: [TimelineItem] {
        let time = playheadTime
        return project.timeline.tracks.filter(\.isEnabled).flatMap(\.items).filter { item in
            guard item.isCompositable, item.placement.isEnabled,
                  let end = try? item.placement.range.end else { return false }
            return item.placement.timelineStart <= time && time < end
        }
    }

    func canSetCameraDepth(for item: TimelineItem) -> Bool {
        item.isCompositable && !isPreparingTimeline && !item.placement.isLocked &&
            project.timeline.tracks.first(where: { $0.id == item.placement.trackID })?.isLocked == false
    }

    func setCameraDepth(_ depth: CameraLayerDepth, for itemID: UUID) {
        guard let item = project.timeline.item(id: itemID), canSetCameraDepth(for: item),
              depth != item.placement.resolvedCameraDepth else { return }
        playback.pause()
        setCameraPreview(nil)
        commit(String(localized: "Camera Depth"), rebuildsSequence: false, preservingSelection: true) { project in
            project.timeline.setCameraDepth(depth, for: itemID)
            return item.id
        }
    }

    func sceneProjection(for placement: ItemPlacement) -> SceneCameraPosition.Projection {
        project.timeline.cameraPosition(at: playheadTime).projection(for: placement.resolvedCameraDepth)
    }

    var cameraProjectedSelectedClip: VideoClip? {
        guard var clip = evaluatedSelectedClip else { return nil }
        let projection = sceneProjection(for: clip.placement)
        guard projection.visibility > 0 else { return nil }
        projection.apply(to: &clip.transform, canvas: cameraCanvasSize)
        return clip
    }

    func cameraDepthTitle(for item: TimelineItem) -> String {
        switch item {
        case .text(let clip): clip.text.isEmpty ? String(localized: "Text") : String(clip.text.prefix(60))
        case .shape(let clip): clip.kind.title
        case .video(let clip):
            clip.id == selectedClipID ? String(localized: "Selected footage") :
                (project.assets.first(where: { $0.id == clip.assetID })?.url.deletingPathExtension().lastPathComponent
                    ?? String(localized: "Footage"))
        case .audio: String(localized: "Audio")
        case .camera: String(localized: "Camera")
        }
    }
}

struct SceneCameraHeader: View {
    @ObservedObject var model: EditorViewModel
    @ObservedObject private var store = ProStore.shared
    let addCamera: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: AppSpacing.small) {
                Button(action: addCamera) {
                    Label("Add Camera", systemImage: "camera")
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(AppColors.accentMuted, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(AppColors.accent)
                }
                .buttonStyle(.plain)
                .disabled(!model.canAddSceneCamera)
                Spacer(minLength: 4)
                if let active = model.project.timeline.activeCamera(at: model.playheadTime),
                   active.id != model.selectedClipID {
                    Button("Select Active Camera") { model.selectClip(id: active.id) }
                        .font(AppTypography.caption)
                        .frame(minHeight: 44)
                }
            }
            if !store.hasPro {
                Text("Free to edit · Pro to export")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, AppSpacing.small)
    }
}

struct SceneCameraPanel: View {
    @ObservedObject var model: EditorViewModel
    @ObservedObject private var preview: SceneCameraPreview
    private enum Section: Hashable {
        case position, framing, depth
    }

    @State private var section = Section.position
    @State private var activeProperty: AnimatableProperty?
    @State private var selectedKeyframe: TimelineTime?

    init(model: EditorViewModel) {
        self.model = model
        preview = model.sceneCameraPreview
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Camera Controls", selection: $section) {
                Text("Position").tag(Section.position)
                Text("Framing").tag(Section.framing)
                Text("Layer Depth").tag(Section.depth)
            }
            .pickerStyle(.segmented)
            .frame(minHeight: 44)
            .padding(.horizontal, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.small) {
                    if !model.isPlayheadInsideSelection {
                        Button("Go to Camera", action: model.goToSelectedClip)
                            .frame(minHeight: 44)
                    } else if !model.selectedCameraDrivesPreview {
                        Text("Another camera is active here, or this camera is hidden.")
                            .font(AppTypography.caption).foregroundStyle(AppColors.textSecondary)
                    }

                    switch section {
                    case .position:
                        rows(SceneCameraClip.positionProperties)
                        if model.selectedCameraDrivesPreview {
                            hint("Drag the preview to pan. Pinch to move forward or back.")
                        }
                    case .framing:
                        hint("Frame Width and Height crop the view. Twist two fingers to rotate.")
                        rows(SceneCameraClip.framingProperties)
                    case .depth:
                        if model.selectedCameraDrivesPreview {
                            hint("Set a title to Foreground and move Position Z past 100% to pass it. Screen layers stay fixed.")
                            ForEach(model.sceneCameraDepthItems) { item in
                                CameraDepthPicker(model: model, item: item, title: model.cameraDepthTitle(for: item))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .id(section)
            .scrollIndicators(.visible)
        }
        .onChange(of: section) { _, _ in
            activeProperty = nil
            selectedKeyframe = nil
            model.setSceneCameraPreview(nil)
        }
    }

    private func rows(_ properties: [AnimatableProperty]) -> some View {
        ForEach(properties, id: \.self) { property in
            let draft: Double? = SceneCameraPosition.keyPath(property).flatMap { key in
                preview.edit?.position[keyPath: key]
            }
            let isRotation = property == .sceneCameraRotation
            KeyframePropertyRow(model: model, property: property, range: isRotation ? -180...180 : property.range,
                activeProperty: $activeProperty, selectedKeyframe: $selectedKeyframe,
                displayScale: isRotation ? 1 : 100, suffix: isRotation ? "°" : "%", previewedNumber: draft,
                previewNumber: { model.previewSceneCameraValue($0, property: property) },
                commitNumber: { model.setSceneCameraValue($0, property: property) })
        }
        .disabled(!model.canAdjustSceneCamera)
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text).font(AppTypography.caption).foregroundStyle(AppColors.textSecondary)
    }
}

struct SceneCameraResultGestures: View {
    let canvas: CGSize
    let position: SceneCameraPosition
    let onPreview: (SceneCameraPosition?) -> Void
    let onCommit: (SceneCameraPosition, SceneCameraPosition) -> Void
    @GestureState private var isEditing = false
    @State private var draft: SceneCameraPosition?

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / canvas.width, geometry.size.height / canvas.height)
            if scale > 0 {
                let size = CGSize(width: canvas.width * scale, height: canvas.height * scale)
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: size.width, height: size.height)
                    .gesture(gesture(size: size))
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
        .onChange(of: isEditing) { _, active in
            if !active, draft != nil {
                draft = nil
                onPreview(nil)
            }
        }
        .accessibilityHidden(true)
    }

    private func gesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 5)
            .simultaneously(with: MagnifyGesture(minimumScaleDelta: 0.025))
            .simultaneously(with: RotateGesture())
            .updating($isEditing) { _, active, _ in active = true }
            .onChanged { value in
                var updated = draft ?? position
                if let rotate = value.second {
                    updated.rotation = AnimatableProperty.sceneCameraRotation.clamped(
                        position.rotation + rotate.rotation.degrees)
                }
                if let drag = value.first?.first {
                    let distance = max(0.25, 2 - position.z)
                    let projection = SceneCameraPosition.Projection(magnification: position.zoom, rotation: updated.rotation)
                    let movement = projection.authoredDelta(
                        CGVector(dx: drag.translation.width / size.width, dy: drag.translation.height / size.height),
                        canvas: size)
                    updated.x = AnimatableProperty.cameraPositionX.clamped(position.x - movement.dx * distance)
                    updated.y = AnimatableProperty.cameraPositionY.clamped(position.y - movement.dy * distance)
                }
                if let zoom = value.first?.second {
                    updated.z = AnimatableProperty.cameraPositionZ.clamped(
                        position.z + log2(zoom.magnification))
                }
                draft = updated
                onPreview(updated)
            }
            .onEnded { _ in
                guard let draft else { return }
                self.draft = nil
                onCommit(position, draft)
            }
    }
}

struct CameraDepthPicker: View {
    @ObservedObject var model: EditorViewModel
    let item: TimelineItem
    var title = String(localized: "Camera Depth")

    var body: some View {
        HStack(spacing: AppSpacing.small) {
            Text(title)
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Picker(title, selection: Binding(
                get: { item.placement.resolvedCameraDepth },
                set: { model.setCameraDepth($0, for: item.id) }
            )) {
                ForEach(CameraLayerDepth.allCases, id: \.self) { depth in
                    Text(depth.title).tag(depth)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .frame(minHeight: 44)
            .accessibilityLabel(title)
        }
        .disabled(!model.canSetCameraDepth(for: item))
    }
}
