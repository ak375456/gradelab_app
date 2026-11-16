import CoreGraphics
import CoreMedia
import Foundation

enum CameraLayerDepth: String, Codable, CaseIterable, Sendable {
    case screen
    case foreground
    case middle
    case background

    var title: String {
        switch self {
        case .screen: String(localized: "Screen")
        case .foreground: String(localized: "Foreground")
        case .middle: String(localized: "Middle")
        case .background: String(localized: "Background")
        }
    }

    var distance: Double? {
        switch self {
        case .screen: nil
        case .foreground: 1
        case .middle: 2
        case .background: 4
        }
    }
}

struct SceneCameraClip: AnimatableClip, Codable, Equatable, Sendable {
    var placement: ItemPlacement
    var position = SceneCameraPosition()
    var animation: ClipAnimation? = nil

    static let positionProperties: [AnimatableProperty] = [.cameraPositionX, .cameraPositionY, .cameraPositionZ]
    static let framingProperties: [AnimatableProperty] = [
        .sceneCameraZoom, .sceneCameraRotation, .sceneCameraFrameWidth, .sceneCameraFrameHeight
    ]
    static let animatableProperties = positionProperties + framingProperties

    static func numberKeyPath(_ property: AnimatableProperty) -> WritableKeyPath<Self, Double>? {
        guard let key = SceneCameraPosition.keyPath(property) else { return nil }
        return (\SceneCameraClip.position).appending(path: key)
    }

    static func colorKeyPath(_ property: AnimatableProperty) -> WritableKeyPath<Self, RGBAColor>? { nil }
}

/// Projects front-facing layers at a shared camera position. The timeline
/// retains control of stacking and matte relationships.
struct SceneCameraPosition: Codable, Equatable, Sendable {
    var x: Double = 0
    var y: Double = 0
    var z: Double = 0

    init(x: Double = 0, y: Double = 0, z: Double = 0) {
        self.x = x
        self.y = y
        self.z = z
    }

    struct Framing: Codable, Equatable, Sendable {
        var zoom = 1.0
        var rotation = 0.0
        var width = 1.0
        var height = 1.0
    }

    // Projects created before Camera Framing have only the three position keys.
    private(set) var framing: Framing? = nil

    var zoom: Double {
        get { framing?.zoom ?? 1 }
        set { setFraming(\.zoom, to: newValue) }
    }

    var rotation: Double {
        get { framing?.rotation ?? 0 }
        set { setFraming(\.rotation, to: newValue) }
    }

    var frameWidth: Double {
        get { framing?.width ?? 1 }
        set { setFraming(\.width, to: newValue) }
    }

    var frameHeight: Double {
        get { framing?.height ?? 1 }
        set { setFraming(\.height, to: newValue) }
    }

    private mutating func setFraming(_ key: WritableKeyPath<Framing, Double>, to value: Double) {
        var update = framing ?? Framing()
        update[keyPath: key] = value
        framing = update == Framing() ? nil : update
    }

    func frame(in canvas: CGSize) -> CGRect? {
        guard frameWidth < 1 || frameHeight < 1 else { return nil }
        return CGRect(origin: .zero, size: canvas).insetBy(
            dx: canvas.width * (1 - frameWidth) / 2,
            dy: canvas.height * (1 - frameHeight) / 2)
    }

    static func keyPath(_ property: AnimatableProperty) -> WritableKeyPath<Self, Double>? {
        switch property {
        case .cameraPositionX: \.x
        case .cameraPositionY: \.y
        case .cameraPositionZ: \.z
        case .sceneCameraZoom: \.zoom
        case .sceneCameraRotation: \.rotation
        case .sceneCameraFrameWidth: \.frameWidth
        case .sceneCameraFrameHeight: \.frameHeight
        default: nil
        }
    }

    var isValid: Bool {
        SceneCameraClip.animatableProperties.allSatisfy { property in
            Self.keyPath(property).map { property.range.contains(self[keyPath: $0]) } == true
        }
    }

    struct Projection {
        var magnification: Double = 1
        var offsetX: Double = 0
        var offsetY: Double = 0
        var visibility: Double = 1
        var rotation: Double = 0

        func apply(to transform: inout VisualTransform, canvas: CGSize) {
            let offset = rotated(CGVector(
                dx: (transform.positionX - 0.5) * magnification + offsetX,
                dy: (transform.positionY - 0.5) * magnification + offsetY),
                degrees: rotation, canvas: canvas)
            transform.positionX = 0.5 + offset.dx
            transform.positionY = 0.5 + offset.dy
            transform.scale *= magnification
            transform.rotationDegrees += rotation
        }

        func authoredPosition(_ point: CGPoint, canvas: CGSize) -> CGPoint {
            let offset = rotated(CGVector(dx: point.x - 0.5, dy: point.y - 0.5),
                                 degrees: -rotation, canvas: canvas)
            return CGPoint(x: 0.5 + (offset.dx - offsetX) / magnification,
                           y: 0.5 + (offset.dy - offsetY) / magnification)
        }

        func authoredDelta(_ delta: CGVector, canvas: CGSize) -> CGVector {
            let unrotated = rotated(delta, degrees: -rotation, canvas: canvas)
            return CGVector(dx: unrotated.dx / magnification, dy: unrotated.dy / magnification)
        }

        // Position is in normalized coordinates with a top-left origin. Roll
        // must rotate in pixels so a rectangle keeps its proportions.
        private func rotated(_ delta: CGVector, degrees: Double, canvas: CGSize) -> CGVector {
            guard degrees != 0, canvas.width > 0, canvas.height > 0 else { return delta }
            let radians = degrees * .pi / 180
            let x = delta.dx * canvas.width
            let y = delta.dy * canvas.height
            return CGVector(dx: (x * cos(radians) - y * sin(radians)) / canvas.width,
                            dy: (x * sin(radians) + y * cos(radians)) / canvas.height)
        }
    }

    func projection(for depth: CameraLayerDepth) -> Projection {
        guard let distance = depth.distance else { return Projection() }
        let remaining = distance - z
        guard remaining > 0 else { return Projection(visibility: 0) }
        // Limit magnification and fade the layer as it reaches the lens.
        let nearRange = distance / 12
        let visibleDistance = max(remaining, nearRange)
        return Projection(magnification: zoom * distance / visibleDistance,
                          offsetX: -x * zoom / visibleDistance, offsetY: -y * zoom / visibleDistance,
                          visibility: min(1, remaining / nearRange), rotation: rotation)
    }
}

extension Timeline {
    mutating func setCameraDepth(_ depth: CameraLayerDepth, for id: UUID) {
        for track in tracks.indices {
            guard let index = tracks[track].items.firstIndex(where: { $0.id == id }) else { continue }
            let item = tracks[track].items[index]
            var placement = item.placement
            placement.cameraDepth = depth
            tracks[track].items[index] = item.withPlacement(placement)
            return
        }
    }

    func activeCamera(at time: TimelineTime) -> SceneCameraClip? {
        for track in tracks where track.kind == .camera && track.isEnabled {
            for case .camera(let clip) in track.items
                where clip.placement.isEnabled && clip.localTimeInside(time) != nil {
                return clip
            }
        }
        return nil
    }

    func cameraPosition(at time: TimelineTime) -> SceneCameraPosition {
        activeCamera(at: time)?.evaluated(at: time).position ?? SceneCameraPosition()
    }

    /// Move saved clip-level camera motion to its own timeline row.
    mutating func migrateLegacyCameras() {
        var migrated: [TimelineTrack] = []
        for track in tracks.indices where tracks[track].kind == .mainVideo {
            let cameraTrackID = UUID()
            var cameras: [TimelineItem] = []
            for index in tracks[track].items.indices {
                guard case .video(var clip) = tracks[track].items[index],
                      let z = clip.camera?.dolly else { continue }
                let placement = ItemPlacement(id: UUID(), trackID: cameraTrackID,
                                              timelineStart: clip.placement.timelineStart,
                                              duration: clip.placement.duration,
                                              isEnabled: clip.placement.isEnabled)
                var camera = SceneCameraClip(placement: placement, position: SceneCameraPosition(z: z))
                if let animation = clip.animation, let track = animation.track(.cameraDolly) {
                    camera.animation = ClipAnimation(
                        tracks: [AnimationTrack(property: .cameraPositionZ, keyframes: track.keyframes)],
                        startOffset: animation.startOffset)
                }
                cameras.append(.camera(camera))
                clip.camera?.dolly = nil
                clip.animation?.removeAnimation(of: .cameraDolly)
                if clip.animation?.isEmpty == true { clip.animation = nil }
                tracks[track].items[index] = .video(clip)
            }
            if !cameras.isEmpty {
                migrated.append(TimelineTrack(id: cameraTrackID, name: TimelineTrack.defaultName(for: .camera),
                                              kind: .camera, isEnabled: tracks[track].isEnabled, items: cameras))
            }
        }
        if !migrated.isEmpty {
            // Keep existing camera rows above the migrated ones.
            let row = tracks.firstIndex { $0.kind != .camera } ?? tracks.endIndex
            tracks.insert(contentsOf: migrated, at: row)
        }
    }
}

extension VideoProject {
    /// Resolve placement in a render-only copy shared by SDR, HDR, Apple Log,
    /// transitions and track mattes. Audio and the authored project are intact.
    func projectedForSceneCamera(at time: TimelineTime, position evaluatedPosition: SceneCameraPosition? = nil,
                                 canvasSize: CGSize? = nil) -> VideoProject {
        let position = evaluatedPosition ?? timeline.cameraPosition(at: time)
        guard position.x != 0 || position.y != 0 || position.z != 0 ||
              position.zoom != 1 || position.rotation != 0 else { return self }
        let canvasSize = canvasSize ?? CGSize(width: canvas.width, height: canvas.height)
        let transitioning = Set(timeline.transitions.filter {
            $0.enabled && $0.progress(at: time.cmTime) != nil
        }.flatMap { [$0.outgoingClipID, $0.incomingClipID] })
        var frame = self
        for track in frame.timeline.tracks.indices where frame.timeline.tracks[track].isEnabled {
            for index in frame.timeline.tracks[track].items.indices {
                let item = frame.timeline.tracks[track].items[index]
                guard item.placement.isEnabled, item.placement.resolvedCameraDepth != .screen,
                      transitioning.contains(item.id) ||
                        (item.placement.timelineStart <= time && (try? item.placement.range.end).map { time < $0 } == true)
                else { continue }
                frame.timeline.tracks[track].items[index] = item.projected(by: position, at: time, canvas: canvasSize)
            }
        }
        return frame
    }
}

private protocol CameraProjectableClip: AnimatableClip {
    var transform: VisualTransform { get set }
    var opacity: Double { get set }
}

extension VideoClip: CameraProjectableClip {}
extension TextClip: CameraProjectableClip {}
extension ShapeClip: CameraProjectableClip {}

private extension TimelineItem {
    func projected(by position: SceneCameraPosition, at time: TimelineTime, canvas: CGSize) -> TimelineItem {
        let projection = position.projection(for: placement.resolvedCameraDepth)
        switch self {
        case .video(let clip): return .video(clip.projected(projection, at: time, canvas: canvas))
        case .text(let clip): return .text(clip.projected(projection, at: time, canvas: canvas, skipWhenHidden: true))
        case .shape(let clip): return .shape(clip.projected(projection, at: time, canvas: canvas, skipWhenHidden: true))
        case .audio, .camera: return self
        }
    }
}

private extension CameraProjectableClip {
    func projected(_ projection: SceneCameraPosition.Projection, at time: TimelineTime, canvas: CGSize, skipWhenHidden: Bool = false) -> Self {
        var clip = self
        if skipWhenHidden && projection.visibility == 0 { clip.placement.isEnabled = false }
        if let local = localTime(for: time) {
            for property in [AnimatableProperty.positionX, .positionY, .scale, .opacity, .rotation] {
                guard property != .rotation || projection.rotation != 0,
                      let value = animation?.track(property)?.value(at: local) else { continue }
                clip.setBaseValue(value, of: property)
                clip.animation?.removeAnimation(of: property)
            }
        }
        projection.apply(to: &clip.transform, canvas: canvas)
        clip.opacity *= projection.visibility
        return clip
    }
}
