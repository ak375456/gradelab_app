import AVFoundation
import CoreImage
import SwiftUI
import UIKit

struct ClipCameraSourceFrame: Equatable, Sendable {
    let url: URL
    let time: TimelineTime
    let isStill: Bool
    let size: CGSize
    let encoded: CGSize
    let preferred: CGAffineTransform
    let stabilization: CGAffineTransform

    func load() async throws -> CGImage {
        let longEdge = 960
        if isStill {
            let image = await Task.detached(priority: .userInitiated) {
                ImageDecoder.thumbnail(url: url, maximumPixelSize: longEdge)
            }.value
            guard let image else { throw GradeLabError.rendererInitializationFailed }
            return image
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = stabilization.isIdentity
        generator.maximumSize = CGSize(width: longEdge, height: longEdge)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: time.cmTime).image
        guard !stabilization.isIdentity else { return image }
        let pixelSize = CGSize(width: image.width, height: image.height)
        let toEncoded = CGAffineTransform(scaleX: encoded.width / pixelSize.width,
                                          y: encoded.height / pixelSize.height)
        let bounds = CGRect(origin: .zero, size: encoded)
        let display = bounds.applying(preferred).standardized
        let fit = min(1, CGFloat(longEdge) / max(display.width, display.height))
        let orient = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: encoded.height)
            .concatenating(preferred)
            .concatenating(.init(a: 1, b: 0, c: 0, d: -1, tx: -display.minX, ty: display.maxY))
            .concatenating(.init(scaleX: fit, y: fit))
        let source = CIImage(cgImage: image)
            .transformed(by: toEncoded.concatenating(stabilization))
            .cropped(to: bounds)
            .transformed(by: orient)
        guard let corrected = CIContext().createCGImage(source, from: source.extent) else {
            throw GradeLabError.rendererInitializationFailed
        }
        return corrected
    }
}

struct ClipCameraViewfinder: View {
    let source: ClipCameraSourceFrame
    let canvasSize: CGSize
    let camera: ClipCamera
    let canEdit: Bool
    let isPickingPoint: Bool
    let onPoint: (CGPoint) -> Void
    @ObservedObject var preview: ClipCameraPreview
    let onPreview: (ClipCamera?) -> Void
    let onCommit: (ClipCamera, ClipCamera) -> Void

    @State private var image: CGImage?
    @State private var loadedSource: ClipCameraSourceFrame?
    @State private var loadFailed = false

    var body: some View {
        GeometryReader { geometry in
            let inset: CGFloat = camera.mode == .crop ? 12 : 0
            let factor = min((geometry.size.width - 2 * inset) / source.size.width,
                             (geometry.size.height - 2 * inset) / source.size.height)
            let size = CGSize(width: source.size.width * factor, height: source.size.height * factor)
            if let image, loadedSource == source, factor > 0 {
                ZStack {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                    if isPickingPoint {
                        Color.clear.contentShape(Rectangle()).gesture(SpatialTapGesture().onEnded { tap in
                            onPoint(CGPoint(x: tap.location.x / size.width, y: tap.location.y / size.height))
                        })
                    }
                }
                .frame(width: size.width, height: size.height)
                .padding(inset)
                .overlay { guide(size: size, scale: factor, inset: inset) }
                .overlay {
                    if canEdit && !isPickingPoint {
                        ClipCameraGestureSurface(camera: camera, source: source.size, canvas: canvasSize, scale: factor,
                            sourceInset: inset, onChange: onPreview, onCommit: onCommit)
                    }
                }
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                .accessibilityLabel("Source framing preview")
            } else {
                Group {
                    if loadFailed {
                        Text("Frame unavailable. Move the playhead or show the result.").font(AppTypography.caption)
                    } else {
                        ProgressView().accessibilityLabel("Loading source frame")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.black)
        .task(id: source) {
            loadFailed = false
            guard loadedSource != source else { return }
            do {
                try await Task.sleep(for: .milliseconds(55))
                let loaded = try await source.load()
                try Task.checkCancellation()
                image = loaded
                loadedSource = source
            } catch {
                if !Task.isCancelled { loadFailed = true }
            }
        }
    }

    private func guide(size: CGSize, scale: CGFloat, inset: CGFloat) -> some View {
        Canvas { context, _ in
            let camera = preview.edit?.camera ?? camera
            let frame = camera.frame(source: source.size, canvas: canvasSize)
            let transform = CGAffineTransform(rotationAngle: frame.radians)
                .concatenating(.init(translationX: frame.center.x, y: frame.center.y))
                .concatenating(.init(scaleX: scale, y: scale))
                .concatenating(.init(translationX: inset, y: inset))
            let rect = CGRect(x: -frame.size.width / 2, y: -frame.size.height / 2,
                              width: frame.size.width, height: frame.size.height)
            let outline = Path(rect).applying(transform)
            var shade = Path(CGRect(origin: CGPoint(x: inset, y: inset), size: size))
            shade.addPath(outline)
            context.fill(shade, with: .color(.black.opacity(0.56)), style: FillStyle(eoFill: true))
            context.stroke(outline, with: .color(.black.opacity(0.7)), lineWidth: 3)
            context.stroke(outline, with: .color(AppColors.accent), lineWidth: 1.5)
            if camera.focusAmount > 0 {
                let center = CGPoint(x: rect.minX + camera.focusX * rect.width,
                                     y: rect.minY + camera.focusY * rect.height)
                let radius = min(rect.width, rect.height) * camera.focusRadius
                let focus = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                    width: 2 * radius, height: 2 * radius))
                var clipped = context
                clipped.clip(to: outline)
                clipped.stroke(focus.applying(transform), with: .color(.white.opacity(0.9)),
                               style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            if camera.mode == .crop {
                for handle in ClipCamera.CropHandle.allCases {
                    let grip = handle.position(in: frame.size).applying(transform)
                    let marker = Path(ellipseIn: CGRect(x: grip.x - 4, y: grip.y - 4, width: 8, height: 8))
                    context.fill(marker, with: .color(AppColors.accent))
                    context.stroke(marker, with: .color(.black.opacity(0.8)), lineWidth: 1)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct ClipCameraResultGestures: View {
    let clip: VideoClip
    let camera: ClipCamera
    let source: CGSize
    let canvas: CGSize
    let onPreview: (ClipCamera?) -> Void
    let onCommit: (ClipCamera, ClipCamera) -> Void

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / canvas.width, geometry.size.height / canvas.height)
            if scale > 0 {
                let placement = ClipPicturePlacement(clip: clip, encoded: source, preferred: .identity, canvas: canvas)
                let deltaTransform = CGAffineTransform(scaleX: 1 / scale, y: -1 / scale)
                    .concatenating(placement.sourceToCanvas.inverted())
                    .concatenating(.init(scaleX: -1, y: 1))
                ClipCameraGestureSurface(camera: camera, source: source, canvas: canvas, scale: scale,
                    resultDeltaTransform: deltaTransform, onChange: onPreview, onCommit: onCommit)
                    .frame(width: canvas.width * scale, height: canvas.height * scale)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ClipCameraGestureSurface: UIViewRepresentable {
    let camera: ClipCamera
    let source: CGSize
    let canvas: CGSize
    let scale: CGFloat
    var sourceInset: CGFloat = 0
    var resultDeltaTransform: CGAffineTransform?
    let onChange: (ClipCamera?) -> Void
    let onCommit: (ClipCamera, ClipCamera) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let coordinator = context.coordinator
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.gradeLabCameraPan))
        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.gradeLabCameraPinch))
        let rotation = UIRotationGestureRecognizer(target: coordinator, action: #selector(Coordinator.gradeLabCameraRotate))
        for recognizer in [pan as UIGestureRecognizer, pinch, rotation] {
            recognizer.delegate = coordinator
            view.addGestureRecognizer(recognizer)
        }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { context.coordinator.parent = self }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: ClipCameraGestureSurface
        private var original: ClipCamera?
        private var draft: ClipCamera?
        private var commitEdit: ((ClipCamera, ClipCamera) -> Void)?
        private var previewEdit: ((ClipCamera?) -> Void)?
        private var deltaTransform: CGAffineTransform?
        private var gestureScale: CGFloat = 1
        private var participants = Set<ObjectIdentifier>()
        private var translation = CGPoint.zero
        private var zoom: CGFloat = 1
        private var rotation: CGFloat = 0
        private var resize: ClipCamera.CropHandle?

        init(_ parent: ClipCameraGestureSurface) { self.parent = parent }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            gestureRecognizer.view === other.view && resize == nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let view = gestureRecognizer.view else { return false }
            if parent.resultDeltaTransform != nil { return true }
            let location = gestureRecognizer.location(in: view)
            let delta = (gestureRecognizer as? UIPanGestureRecognizer)?.translation(in: view) ?? .zero
            let frame = parent.camera.frame(source: parent.source, canvas: parent.canvas)
            let point = localPoint(CGPoint(x: location.x - delta.x, y: location.y - delta.y), in: frame)
            let margin = 22 / parent.scale
            return abs(point.x) <= frame.size.width / 2 + margin &&
                abs(point.y) <= frame.size.height / 2 + margin
        }

        @objc func gradeLabCameraPan(_ recognizer: UIPanGestureRecognizer) {
            if recognizer.state == .began, participants.isEmpty, parent.camera.mode == .crop,
               parent.resultDeltaTransform == nil, recognizer.numberOfTouches <= 1,
               let view = recognizer.view {
                let frame = parent.camera.frame(source: parent.source, canvas: parent.canvas)
                let movement = recognizer.translation(in: view)
                let start = recognizer.location(in: view)
                let point = localPoint(CGPoint(x: start.x - movement.x, y: start.y - movement.y), in: frame)
                resize = ClipCamera.CropHandle.hit(at: point, in: frame.size, tolerance: 22 / parent.scale)
            }
            translation = recognizer.translation(in: recognizer.view)
            update(recognizer)
        }

        @objc func gradeLabCameraPinch(_ recognizer: UIPinchGestureRecognizer) {
            zoom = recognizer.scale
            update(recognizer)
        }

        @objc func gradeLabCameraRotate(_ recognizer: UIRotationGestureRecognizer) {
            rotation = recognizer.rotation
            update(recognizer)
        }

        private func localPoint(_ point: CGPoint, in frame: ClipCamera.Frame) -> CGPoint {
            frame.localPoint(CGPoint(x: (point.x - parent.sourceInset) / parent.scale,
                                     y: (point.y - parent.sourceInset) / parent.scale))
        }

        private func update(_ recognizer: UIGestureRecognizer) {
            let id = ObjectIdentifier(recognizer)
            switch recognizer.state {
            case .began:
                if original == nil {
                    original = parent.camera
                    commitEdit = parent.onCommit
                    previewEdit = parent.onChange
                    deltaTransform = parent.resultDeltaTransform
                    gestureScale = parent.scale
                }
                participants.insert(id)
            case .changed, .ended:
                guard participants.contains(id) else { return }
            case .cancelled, .failed:
                if participants.contains(id) { finish(commit: false) }
                return
            default: return
            }
            guard let original else { return }
            let updated = adjusted(original)
            draft = updated
            previewEdit?(updated)
            if recognizer.state == .ended {
                participants.remove(id)
                if participants.isEmpty { finish(commit: true) }
            }
        }

        private func finish(commit: Bool) {
            if commit, let original, let draft { commitEdit?(original, draft) }
            else { previewEdit?(nil) }
            original = nil
            draft = nil
            commitEdit = nil
            previewEdit = nil
            deltaTransform = nil
            participants.removeAll()
            translation = .zero
            zoom = 1
            rotation = 0
            resize = nil
        }

        private func adjusted(_ original: ClipCamera) -> ClipCamera {
            let source = parent.source, canvas = parent.canvas
            let map = deltaTransform ?? CGAffineTransform(scaleX: 1 / gestureScale, y: 1 / gestureScale)
            let delta = CGSize(width: translation.x, height: translation.y).applying(map)
            let offset = CGPoint(x: delta.width, y: delta.height)
            if let resize {
                return original.resizing(resize, by: offset, source: source, canvas: canvas)
            }
            return original.moving(by: offset, zoomFactor: zoom,
                rotation: deltaTransform == nil ? rotation : -rotation,
                source: source, canvas: canvas, sourcePointsPerScreenPoint: max(hypot(map.a, map.b), hypot(map.c, map.d)))
        }
    }
}
