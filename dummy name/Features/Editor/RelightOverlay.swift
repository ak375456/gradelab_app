import SwiftUI

// ---------------------------------------------------------------------------
// Direct manipulation of Relight lights on the preview
//
// Lights are placed in the UPRIGHT picture, so a handle is drawn by mapping
// that point to the view through the same coordinate boundary the mask tools
// use — straight across the letterboxed picture on the direct path, and
// through the clip's own transform when the timeline is composited. There is
// no second idea of where a light is.
//
//   Point   the bulb, and a ring at the distance its light has fallen to half
//           (the reach). The small knob on the ring changes the reach.
//   Spot    the lamp, its aim point, and the cone between them.
//   Sun     a disk centred on the picture. The handle sits on the side the
//           light comes from: at the centre the light comes from the camera,
//           on the ring it is pure side light, and in the band outside the
//           ring it comes from behind the subject.
//
// Handles are generous: the visible glyph is small so it hides little of the
// picture, the area that answers a finger is not. Nothing here is ever drawn
// into a frame.
// ---------------------------------------------------------------------------

struct RelightOverlay: View {
    @ObservedObject var model: EditorViewModel
    let displayedRect: () -> CGRect?
    @Environment(\.horizontalSizeClass) private var sizeClass

    private enum Part: Equatable { case body, target, reach }
    private struct Drag: Equatable {
        let id: UUID
        let part: Part
        /// From the touch to the handle's centre, so grabbing a handle off
        /// centre does not make it jump under the finger.
        let offset: CGSize
    }
    @State private var drag: Drag?

    private static let space = "relightOverlay"
    private var isCompact: Bool { sizeClass == .compact && !AppPlatform.isMac }
    /// The area that answers a touch or a click.
    private var hitSize: CGFloat { isCompact ? 60 : 44 }
    /// The glyph itself.
    private var glyphSize: CGFloat { isCompact ? 30 : 24 }

    var body: some View {
        GeometryReader { proxy in
            let picture = pictureRect(in: proxy.size)
            let lights = model.displayedRelight?.lights ?? []
            ZStack {
                Canvas { context, _ in
                    for light in lights { drawGuides(light, in: picture, context: &context) }
                }
                .allowsHitTesting(false)

                ForEach(lights) { light in
                    handles(light, picture: picture)
                }
            }
            .coordinateSpace(name: Self.space)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Relight lights")
    }

    // MARK: - Handles

    @ViewBuilder
    private func handles(_ light: RelightLight, picture: CGRect) -> some View {
        let selected = model.selectedLightID == light.id
        switch light.type {
        case .directional:
            handle(light, part: .body, at: directionPoint(light, picture), picture: picture, selected: selected)
        case .point:
            handle(light, part: .body, at: displayToView(light.positionX, light.positionY, picture),
                   picture: picture, selected: selected)
            if selected {
                knob(light, part: .reach, at: reachKnobPoint(light, picture), picture: picture,
                     symbol: "arrow.left.and.right", label: String(localized: "\(light.name) reach"))
            }
        case .spot:
            handle(light, part: .body, at: displayToView(light.positionX, light.positionY, picture),
                   picture: picture, selected: selected)
            if selected {
                knob(light, part: .target, at: displayToView(light.targetX, light.targetY, picture),
                     picture: picture, symbol: "scope", label: String(localized: "\(light.name) aim"))
            }
        }
    }

    private func handle(_ light: RelightLight, part: Part, at point: CGPoint, picture: CGRect,
                        selected: Bool) -> some View {
        let hovered = model.hoveredLightID == light.id
        let swatch = RelightColorScience.swatch(light)
        return ZStack {
            Circle()
                .fill(Color(.sRGB, red: swatch.x, green: swatch.y, blue: swatch.z, opacity: 1))
                .frame(width: glyphSize, height: glyphSize)
            Image(systemName: light.type.symbol)
                .font(.system(size: glyphSize * 0.45, weight: .bold))
                .foregroundStyle(.black.opacity(0.75))
            Circle()
                .stroke(selected ? AppColors.accent : .white.opacity(hovered ? 1 : 0.85),
                        lineWidth: selected ? 3 : (hovered ? 2.5 : 1.5))
                .frame(width: glyphSize + (hovered && !selected ? 4 : 0),
                       height: glyphSize + (hovered && !selected ? 4 : 0))
            if light.intensity < 0 {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white, .black)
                    .offset(x: glyphSize * 0.45, y: -glyphSize * 0.45)
            }
        }
        .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
        .opacity(light.isEnabled ? 1 : 0.45)
        .frame(width: hitSize, height: hitSize)
        .contentShape(Circle())
        .gesture(dragGesture(light, part: part, from: point, picture: picture))
        .onTapGesture { model.selectLight(light.id) }
        .onHover { inside in
            if inside { model.hoveredLightID = light.id }
            else if model.hoveredLightID == light.id { model.hoveredLightID = nil }
        }
        .contextMenu { menu(light) }
        .position(point)
        .accessibilityElement()
        .accessibilityLabel("\(light.name), \(light.type.title) light")
        .accessibilityValue(light.isEnabled ? "" : String(localized: "Disabled"))
        .accessibilityHint("Drag to move the light. Double-tap to select it.")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// A secondary handle of the selected light: a spot's aim, a point's reach.
    private func knob(_ light: RelightLight, part: Part, at point: CGPoint, picture: CGRect,
                      symbol: String, label: String) -> some View {
        ZStack {
            Circle().fill(.black.opacity(0.55)).frame(width: glyphSize * 0.8, height: glyphSize * 0.8)
            Circle().stroke(AppColors.accent, lineWidth: 2).frame(width: glyphSize * 0.8, height: glyphSize * 0.8)
            Image(systemName: symbol).font(.system(size: glyphSize * 0.32, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: hitSize, height: hitSize)
        .contentShape(Circle())
        .gesture(dragGesture(light, part: part, from: point, picture: picture))
        .position(point)
        .accessibilityElement()
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func menu(_ light: RelightLight) -> some View {
        Button("Duplicate", systemImage: "plus.square.on.square") { model.duplicateLight(light.id) }
            .disabled(!model.canAddLight)
        Button(light.isEnabled ? "Disable" : "Enable", systemImage: light.isEnabled ? "eye.slash" : "eye") {
            model.setLightEnabled(light.id, !light.isEnabled)
        }
        Button("Reset", systemImage: "arrow.uturn.backward") { model.resetLight(light.id) }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { model.deleteLight(light.id) }
    }

    private func dragGesture(_ light: RelightLight, part: Part, from handle: CGPoint,
                             picture: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if drag == nil {
                    drag = Drag(id: light.id, part: part,
                                offset: CGSize(width: handle.x - value.startLocation.x,
                                               height: handle.y - value.startLocation.y))
                    model.selectLight(light.id)
                    model.beginLightGesture()
                }
                guard let drag, drag.id == light.id else { return }
                let point = CGPoint(x: value.location.x + drag.offset.width,
                                    y: value.location.y + drag.offset.height)
                apply(drag.part, light: light, at: point, picture: picture)
            }
            .onEnded { _ in
                drag = nil
                model.endLightGesture()
            }
    }

    private func apply(_ part: Part, light: RelightLight, at point: CGPoint, picture: CGRect) {
        switch (part, light.type) {
        case (.body, .directional):
            let center = CGPoint(x: picture.midX, y: picture.midY)
            let radius = diskRadius(picture)
            model.pointLight(light.id, disk: CGPoint(x: (point.x - center.x) / radius,
                                                     y: (point.y - center.y) / radius))
        case (.body, _):
            model.moveLight(light.id, to: viewToDisplay(point, picture))
        case (.target, _):
            model.aimLight(light.id, at: viewToDisplay(point, picture))
        case (.reach, _):
            let center = displayToView(light.positionX, light.positionY, picture)
            let distance = hypot(point.x - center.x, point.y - center.y)
            let reach = Double(distance / max(picture.height, 1)) / (1 + 0.5 * light.softness)
            model.setLightReach(light.id, radius: reach)
        }
    }

    // MARK: - Guides

    private func drawGuides(_ light: RelightLight, in picture: CGRect, context: inout GraphicsContext) {
        let selected = model.selectedLightID == light.id
        let tint = selected ? AppColors.accent : Color.white
        let opacity = light.isEnabled ? (selected ? 0.9 : 0.35) : 0.18
        let dash = StrokeStyle(lineWidth: selected ? 1.5 : 1, dash: [5, 4])
        switch light.type {
        case .directional:
            guard selected else { return }
            let center = CGPoint(x: picture.midX, y: picture.midY)
            let radius = diskRadius(picture)
            context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                  width: radius * 2, height: radius * 2)),
                           with: .color(tint.opacity(opacity)), style: dash)
            let behind = radius * RelightDirectionDisk.outerLimit
            context.stroke(Path(ellipseIn: CGRect(x: center.x - behind, y: center.y - behind,
                                                  width: behind * 2, height: behind * 2)),
                           with: .color(tint.opacity(opacity * 0.35)), style: StrokeStyle(lineWidth: 1, dash: [2, 5]))
            // The direction the light travels: from the handle toward the
            // middle of the picture.
            let source = directionPoint(light, picture)
            var arrow = Path()
            arrow.move(to: source)
            let toward = CGPoint(x: source.x + (center.x - source.x) * 0.55,
                                 y: source.y + (center.y - source.y) * 0.55)
            arrow.addLine(to: toward)
            context.stroke(arrow, with: .color(tint.opacity(opacity)),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round))
            context.fill(Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)),
                         with: .color(tint.opacity(opacity)))
        case .point:
            let center = displayToView(light.positionX, light.positionY, picture)
            let reach = reachRadius(light, picture)
            context.stroke(Path(ellipseIn: CGRect(x: center.x - reach, y: center.y - reach,
                                                  width: reach * 2, height: reach * 2)),
                           with: .color(tint.opacity(opacity)), style: dash)
        case .spot:
            let source = displayToView(light.positionX, light.positionY, picture)
            let target = displayToView(light.targetX, light.targetY, picture)
            let dx = target.x - source.x, dy = target.y - source.y
            let length = max(hypot(dx, dy), 1)
            let half = light.coneAngle * .pi / 180
            let spread = length * CGFloat(tan(min(half, 1.4)))
            let nx = -dy / length, ny = dx / length
            var cone = Path()
            cone.move(to: source)
            cone.addLine(to: CGPoint(x: target.x + nx * spread, y: target.y + ny * spread))
            cone.move(to: source)
            cone.addLine(to: CGPoint(x: target.x - nx * spread, y: target.y - ny * spread))
            context.stroke(cone, with: .color(tint.opacity(opacity)), style: dash)
            var axis = Path()
            axis.move(to: source)
            axis.addLine(to: target)
            context.stroke(axis, with: .color(tint.opacity(opacity * 0.6)),
                           style: StrokeStyle(lineWidth: 1))
            if selected {
                context.stroke(Path(ellipseIn: CGRect(x: target.x - spread, y: target.y - spread,
                                                      width: spread * 2, height: spread * 2)),
                               with: .color(tint.opacity(opacity * 0.5)), style: dash)
            }
        }
    }

    // MARK: - Geometry

    private func pictureRect(in size: CGSize) -> CGRect {
        guard let rect = displayedRect() else { return CGRect(origin: .zero, size: size) }
        return CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
                      width: rect.width * size.width, height: rect.height * size.height)
    }

    private var coordinates: MaskTrackingCoordinates? {
        guard let clip = model.selectedClip,
              let metadata = model.project.assets.first(where: { $0.id == clip.assetID })?.videoMetadata else { return nil }
        return try? MaskTrackingCoordinates(encodedSize: metadata.encodedSize,
                                            preferredTransform: metadata.preferredTransform.cgTransform)
    }

    /// Source (encoded) to canvas, when the preview is the composited canvas
    /// rather than the clip on its own.
    private var canvasTransform: CGAffineTransform? {
        guard model.maskOverlayUsesCanvas, let coordinates, let clip = model.evaluatedSelectedClip else { return nil }
        return coordinates.sourceToCanvasTransform(
            clip.transform, canvas: CGSize(width: model.project.canvas.width, height: model.project.canvas.height))
    }

    /// An upright-picture point to the view.
    private func displayToView(_ x: Double, _ y: Double, _ picture: CGRect) -> CGPoint {
        var point = CGPoint(x: x, y: y)
        if let canvasTransform, let coordinates {
            point = coordinates.displayToSource(point).applying(canvasTransform)
        }
        return CGPoint(x: picture.minX + point.x * picture.width, y: picture.minY + point.y * picture.height)
    }

    /// The exact inverse of `displayToView`.
    private func viewToDisplay(_ point: CGPoint, _ picture: CGRect) -> CGPoint {
        let normalized = CGPoint(x: (point.x - picture.minX) / max(picture.width, 1),
                                 y: (point.y - picture.minY) / max(picture.height, 1))
        guard let canvasTransform, let coordinates else { return normalized }
        return coordinates.sourceToDisplay(normalized.applying(canvasTransform.inverted()))
    }

    private func diskRadius(_ picture: CGRect) -> CGFloat {
        max(min(picture.width, picture.height) * 0.3, 40)
    }

    private func directionPoint(_ light: RelightLight, _ picture: CGRect) -> CGPoint {
        let disk = RelightDirectionDisk.point(azimuth: light.azimuth, elevation: light.elevation)
        let radius = diskRadius(picture)
        return CGPoint(x: picture.midX + disk.x * radius, y: picture.midY + disk.y * radius)
    }

    /// Where a point light has fallen to half, in the picture plane — the
    /// same reach the shader divides distance by.
    private func reachRadius(_ light: RelightLight, _ picture: CGRect) -> CGFloat {
        CGFloat(light.radius * (1 + 0.5 * light.softness)) * picture.height
    }

    private func reachKnobPoint(_ light: RelightLight, _ picture: CGRect) -> CGPoint {
        let center = displayToView(light.positionX, light.positionY, picture)
        return CGPoint(x: center.x + reachRadius(light, picture), y: center.y)
    }
}
