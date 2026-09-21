import SwiftUI
import UIKit

/// Video and image transforms use the SAME keyframe engine and controls as text: one
/// property list, one diamond, one lane, one set of editing rules.
struct LiveTransformPanel: View {
    @ObservedObject var model: EditorViewModel
    @State private var activeProperty: AnimatableProperty?
    @State private var selectedKeyframe: TimelineTime?
    @State private var keyframeHelp = false
    @State private var confirmsRemoveAll = false

    private let properties: [(AnimatableProperty, ClosedRange<Double>)] = [
        (.positionX, -1...2), (.positionY, -1...2), (.scale, 0.05...6),
        (.widthScale, 0.1...6), (.heightScale, 0.1...6),
        // Wide enough for two full turns by dragging; type more for further spins.
        (.rotation, -720...720), (.opacity, 0...1)
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                KeyframeSectionHeader(model: model, help: $keyframeHelp, confirmsRemoveAll: $confirmsRemoveAll)
                ForEach(properties, id: \.0) { property, range in
                    KeyframePropertyRow(model: model, property: property, range: range,
                                        activeProperty: $activeProperty, selectedKeyframe: $selectedKeyframe)
                }
                HStack {
                    Picker("Blend", selection: Binding(get: { model.selectedClip?.blendMode ?? .normal },
                                                       set: { mode in model.changeVisual("Blend", immediate: true) { $0.blendMode = mode } })) {
                        ForEach(VisualBlendMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }.pickerStyle(.menu)
                    Spacer()
                    Button("Reset") {
                        model.changeVisual("Reset Transform", immediate: true) {
                            $0.transform = .init(); $0.opacity = 1; $0.blendMode = .normal; $0.animation = nil
                        }
                        activeProperty = nil; selectedKeyframe = nil
                    }.font(.caption).frame(height: 44)
                }
                Text("Live preview · X/Y 0.5 is the canvas center. Reset also clears this clip's animation.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20).padding(.bottom, 12)
        }
        .scrollIndicators(.visible)
        .disabled(model.isPreparingTimeline || !model.canGrade)
        .onChange(of: model.selectedClipID) { _, _ in activeProperty = nil; selectedKeyframe = nil }
        .sheet(isPresented: $keyframeHelp) { KeyframeHelp() }
        .confirmationDialog("Remove all animation from this clip?", isPresented: $confirmsRemoveAll, titleVisibility: .visible) {
            Button("Remove All Animation", role: .destructive) {
                model.removeAllAnimation(); activeProperty = nil; selectedKeyframe = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Every animated property keeps the value you can see now.") }
    }
}

/// Structural clip masking, deliberately outside the Color tools. This edits
/// alpha/coverage, so the selected top layer reveals visual tracks beneath it.
struct LayerMaskPanel: View {
    @ObservedObject var model: EditorViewModel
    @State private var activeProperty: AnimatableProperty?
    @State private var selectedKeyframe: TimelineTime?
    @State private var keyframeHelp = false
    @State private var confirmsRemoveAll = false

    private let geometryProperties: [(AnimatableProperty, ClosedRange<Double>, Double, String)] = [
        (.layerMaskPositionX, 0...1, 100, "%"),
        (.layerMaskPositionY, 0...1, 100, "%"),
        (.layerMaskWidth, 0.01...2, 100, "%"),
        (.layerMaskHeight, 0.01...2, 100, "%"),
        (.layerMaskRotation, -180...180, 1, "°"),
        (.layerMaskFeather, 0...1, 100, "%")
    ]

    var body: some View {
        ScrollView {
            if model.selectedClip == nil {
                Text("Select a video or image clip to add a layer mask.")
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            } else {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Toggle("Layer mask", isOn: model.layerMaskBinding(\.isEnabled))
                            .tint(AppColors.accent)
                        Text("The selected clip stays visible in the chosen area; transparent areas reveal layers below.")
                            .font(.caption2)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if !model.selectedLayerMask.isEnabled {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Choose a shape to apply the mask immediately")
                                .font(.subheadline.weight(.semibold))
                            HStack(spacing: 10) {
                                addMaskButton(String(localized: "Linear"), shape: .linear, icon: "line.diagonal")
                                addMaskButton(String(localized: "Ellipse"), shape: .ellipse, icon: "circle")
                                addMaskButton(String(localized: "Rectangle"), shape: .rectangle, icon: "rectangle")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .appSurface(fill: AppColors.surfaceRaised, border: AppColors.border)
                    }

                    if model.selectedLayerMask.isEnabled && !model.hasVisibleLayerBelowSelection {
                        Label("There is no visible clip beneath this one at the playhead, so transparent areas show the canvas instead.",
                              systemImage: "square.3.layers.3d")
                            .font(.caption)
                            .foregroundStyle(AppColors.warning)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .appSurface(fill: AppColors.warning.opacity(0.10), border: AppColors.warning.opacity(0.28))
                    }

                    if model.selectedLayerMask.isEnabled {
                        Picker("Shape", selection: model.layerMaskBinding(\.shape)) {
                            ForEach(LayerMaskShape.allCases) { shape in
                                Text(shape.title).tag(shape)
                            }
                        }
                        .pickerStyle(.segmented)

                        if model.selectedLayerMask.shape == .linear {
                            Label("Swipe animation: keyframe Position X, move the playhead, then drag the line across the picture.",
                                  systemImage: "diamond")
                                .font(.caption)
                                .foregroundStyle(AppColors.accent)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .appSurface(fill: AppColors.accent.opacity(0.09),
                                            border: AppColors.accent.opacity(0.24))
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.selectedLayerMask.shape == .linear ? "Reveal lower layer" : "Top clip remains")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppColors.textSecondary)
                            Picker(model.selectedLayerMask.shape == .linear ? "Reveal lower layer" : "Top clip remains",
                                   selection: model.layerMaskBinding(\.isInverted)) {
                                if model.selectedLayerMask.shape == .linear {
                                    Text("Right side").tag(false)
                                    Text("Left side").tag(true)
                                } else {
                                    Text("Inside shape").tag(false)
                                    Text("Outside shape").tag(true)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        HStack {
                            Text("Drag the shape directly on the picture.")
                                .font(.caption2)
                                .foregroundStyle(AppColors.textSecondary)
                            Spacer(minLength: 8)
                            Button("Center") {
                                model.setAnimatableValue(.layerMaskPositionX, .number(0.5))
                                model.setAnimatableValue(.layerMaskPositionY, .number(0.5))
                                model.flushGradeHistory()
                            }
                            .font(.caption.weight(.semibold))
                            .frame(minHeight: 44)
                        }

                        KeyframeSectionHeader(model: model, help: $keyframeHelp,
                                              confirmsRemoveAll: $confirmsRemoveAll)
                        ForEach(geometryProperties.filter { entry in
                            model.selectedLayerMask.shape != .linear ||
                                (entry.0 != .layerMaskWidth && entry.0 != .layerMaskHeight)
                        }, id: \.0) { property, range, scale, suffix in
                            KeyframePropertyRow(model: model, property: property, range: range,
                                                activeProperty: $activeProperty,
                                                selectedKeyframe: $selectedKeyframe,
                                                displayScale: scale, suffix: suffix)
                        }

                        Button("Remove layer mask", action: model.resetLayerMask)
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(AppColors.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .scrollIndicators(.visible)
        .disabled(model.isPreparingTimeline || !model.canEditSelection)
        .onChange(of: model.selectedClipID) { _, _ in
            activeProperty = nil; selectedKeyframe = nil
        }
        .sheet(isPresented: $keyframeHelp) { KeyframeHelp() }
        .confirmationDialog("Remove all animation from this clip?", isPresented: $confirmsRemoveAll,
                            titleVisibility: .visible) {
            Button("Remove All Animation", role: .destructive) {
                model.removeAllAnimation(); activeProperty = nil; selectedKeyframe = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Every animated property keeps the value you can see now.") }
    }

    private func addMaskButton(_ title: String, shape: LayerMaskShape, icon: String) -> some View {
        Button {
            model.addLayerMask(shape)
        } label: {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 54)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppColors.textPrimary)
        .background(AppColors.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppColors.accent.opacity(0.45)))
    }

}

/// Preview-only outline for a structural layer mask. Its geometry follows the
/// selected clip's preferred orientation and authored transform, while the
/// actual transparency is produced by the compositor.
struct LayerMaskOverlay: View {
    @ObservedObject var model: EditorViewModel
    let displayedRect: () -> CGRect?

    @State private var dragOrigin: CGPoint?
    @State private var snappedToVerticalCenter = false
    @State private var snappedToHorizontalCenter = false

    var body: some View {
        GeometryReader { proxy in
            let picture = pictureRect(in: proxy.size)
            Canvas { context, _ in
                guard let geometry = sourceGeometry(in: picture) else { return }
                context.clip(to: Path(picture))
                if snappedToVerticalCenter {
                    var guide = Path()
                    guide.move(to: sourcePoint(u: 0.5, v: -1, geometry: geometry))
                    guide.addLine(to: sourcePoint(u: 0.5, v: 2, geometry: geometry))
                    context.stroke(guide, with: .color(AppColors.accent.opacity(0.9)),
                                   style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                if snappedToHorizontalCenter {
                    var guide = Path()
                    guide.move(to: sourcePoint(u: -1, v: 0.5, geometry: geometry))
                    guide.addLine(to: sourcePoint(u: 2, v: 0.5, geometry: geometry))
                    context.stroke(guide, with: .color(AppColors.accent.opacity(0.9)),
                                   style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
                let path = maskPath(mask: model.selectedLayerMask, geometry: geometry)
                context.stroke(path, with: .color(.black.opacity(0.82)),
                               style: StrokeStyle(lineWidth: 5, lineJoin: .round))
                context.stroke(path,
                               with: .color(model.selectedLayerMask.isEnabled ? AppColors.accent : AppColors.textSecondary),
                               style: StrokeStyle(lineWidth: 2, lineJoin: .round, dash: [7, 5]))

                let center = sourcePoint(
                    u: model.selectedLayerMask.centerX,
                    v: model.selectedLayerMask.centerY,
                    geometry: geometry
                )
                let handle = CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)
                context.fill(Path(ellipseIn: handle),
                             with: .color(model.selectedLayerMask.isEnabled ? AppColors.accent : AppColors.textSecondary))
                context.stroke(Path(ellipseIn: handle), with: .color(.black.opacity(0.8)), lineWidth: 2)
            }
            .contentShape(Rectangle())
            .gesture(moveGesture(in: picture))

        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Layer mask")
        .accessibilityValue(accessibilityStatus)
        .accessibilityHint("Drag to move the mask over the selected clip")
    }

    /// Kept for VoiceOver only; the preview itself stays visually clean.
    private var accessibilityStatus: String {
        let mask = model.selectedLayerMask
        guard mask.isEnabled else { return String(localized: "Off") }
        if mask.shape == .linear {
            return mask.isInverted ? String(localized: "Lower layer visible on left")
                                   : String(localized: "Lower layer visible on right")
        }
        return mask.isInverted
            ? String(localized: "Lower layer visible inside \(mask.shape.title)")
            : String(localized: "Lower layer visible outside \(mask.shape.title)")
    }

    private struct Geometry {
        let sourceSize: CGSize
        let sourceToPreview: CGAffineTransform
    }

    private func sourceGeometry(in picture: CGRect) -> Geometry? {
        guard let clip = model.selectedClip,
              let asset = model.project.assets.first(where: { $0.id == clip.assetID }) else { return nil }
        let sourceSize: CGSize
        let preferred: CGAffineTransform
        if let still = asset.stillImage {
            sourceSize = CGSize(width: still.width, height: still.height)
            preferred = .identity
        } else if let metadata = asset.videoMetadata {
            sourceSize = metadata.encodedSize
            preferred = metadata.preferredTransform.cgTransform
        } else { return nil }
        let canvas = CGSize(width: model.project.canvas.width, height: model.project.canvas.height)
        guard sourceSize.width > 0, sourceSize.height > 0, canvas.width > 0, canvas.height > 0 else { return nil }
        let placement = LayerCompositor.transform(clip.transform, encoded: sourceSize,
                                                  preferred: preferred, canvas: canvas)
        let sourceTopToBottom = CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                                                  tx: 0, ty: sourceSize.height)
        let canvasBottomToTop = CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                                                  tx: 0, ty: canvas.height)
        let canvasToPreview = CGAffineTransform(
            a: picture.width / canvas.width, b: 0,
            c: 0, d: picture.height / canvas.height,
            tx: picture.minX, ty: picture.minY
        )
        return Geometry(
            sourceSize: sourceSize,
            sourceToPreview: sourceTopToBottom
                .concatenating(placement)
                .concatenating(canvasBottomToTop)
                .concatenating(canvasToPreview)
        )
    }

    private func sourcePoint(u: Double, v: Double, geometry: Geometry) -> CGPoint {
        CGPoint(x: u * geometry.sourceSize.width,
                y: v * geometry.sourceSize.height)
            .applying(geometry.sourceToPreview)
    }

    private func maskPath(mask authored: LayerMask, geometry: Geometry) -> Path {
        let mask = authored.clamped
        if mask.shape == .linear {
            let angle = mask.rotationDegrees * .pi / 180
            let directionX = -sin(angle), directionY = cos(angle)
            let reach = 2.2
            var path = Path()
            path.move(to: sourcePoint(u: mask.centerX - directionX * reach,
                                      v: mask.centerY - directionY * reach, geometry: geometry))
            path.addLine(to: sourcePoint(u: mask.centerX + directionX * reach,
                                         v: mask.centerY + directionY * reach, geometry: geometry))
            return path
        }
        let count = mask.shape == .ellipse ? 96 : 4
        let angle = mask.rotationDegrees * .pi / 180
        let cosine = cos(angle), sine = sin(angle)
        func point(_ index: Int) -> CGPoint {
            let x: Double, y: Double
            if mask.shape == .ellipse {
                let phase = Double(index) / Double(count) * .pi * 2
                x = cos(phase) * mask.width * 0.5
                y = sin(phase) * mask.height * 0.5
            } else {
                let corners = [(-0.5, -0.5), (0.5, -0.5), (0.5, 0.5), (-0.5, 0.5)]
                x = corners[index].0 * mask.width
                y = corners[index].1 * mask.height
            }
            let u = mask.centerX + cosine * x - sine * y
            let v = mask.centerY + sine * x + cosine * y
            return sourcePoint(u: u, v: v, geometry: geometry)
        }
        var path = Path()
        guard count > 0 else { return path }
        path.move(to: point(0))
        for index in 1..<count { path.addLine(to: point(index)) }
        path.closeSubpath()
        return path
    }

    private func pictureRect(in size: CGSize) -> CGRect {
        guard let normalized = displayedRect(), normalized.width > 0, normalized.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        return CGRect(x: normalized.minX * size.width, y: normalized.minY * size.height,
                      width: normalized.width * size.width, height: normalized.height * size.height)
    }

    private func moveGesture(in picture: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = CGPoint(x: model.selectedLayerMask.centerX,
                                         y: model.selectedLayerMask.centerY)
                }
                guard let origin = dragOrigin,
                      let geometry = sourceGeometry(in: picture) else { return }
                let inverse = geometry.sourceToPreview.inverted()
                let zero = CGPoint.zero.applying(inverse)
                let translated = CGPoint(x: value.translation.width,
                                         y: value.translation.height).applying(inverse)
                let deltaX = (translated.x - zero.x) / geometry.sourceSize.width
                let deltaY = (translated.y - zero.y) / geometry.sourceSize.height
                var x = min(1, max(0, origin.x + deltaX))
                var y = min(1, max(0, origin.y + deltaY))
                let projectedX = hypot(geometry.sourceToPreview.a * geometry.sourceSize.width,
                                       geometry.sourceToPreview.b * geometry.sourceSize.width)
                let projectedY = hypot(geometry.sourceToPreview.c * geometry.sourceSize.height,
                                       geometry.sourceToPreview.d * geometry.sourceSize.height)
                let snapX = abs(x - 0.5) <= 12 / max(projectedX, 1)
                let snapY = abs(y - 0.5) <= 12 / max(projectedY, 1)
                if snapX { x = 0.5 }
                if snapY { y = 0.5 }
                if (snapX && !snappedToVerticalCenter) || (snapY && !snappedToHorizontalCenter) {
                    UISelectionFeedbackGenerator().selectionChanged()
                }
                snappedToVerticalCenter = snapX
                snappedToHorizontalCenter = snapY
                model.setAnimatableValue(.layerMaskPositionX,
                                         .number(x))
                model.setAnimatableValue(.layerMaskPositionY,
                                         .number(y))
            }
            .onEnded { _ in
                dragOrigin = nil
                snappedToVerticalCenter = false
                snappedToHorizontalCenter = false
                model.flushGradeHistory()
            }
    }
}

struct CanvasTools: View {
    @ObservedObject var model: EditorViewModel
    @State private var width = "1080"
    @State private var height = "1920"
    /// What the colour wheel is showing while a drag is still in flight, before
    /// it has been written to the document.
    @State private var pickedBackground: RGBAColor?
    @State private var backgroundCommit: Task<Void, Never>?
    private let presets: [(String, Int, Int)] = [
        ("TikTok · 9:16", 1080, 1920), ("Instagram Reel · 9:16", 1080, 1920),
        ("Instagram Feed · 4:5", 1080, 1350), ("Instagram Square · 1:1", 1080, 1080),
        ("YouTube · 16:9", 1920, 1080), ("YouTube Shorts · 9:16", 1080, 1920)
    ]
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("Canvas \(model.project.canvas.width) × \(model.project.canvas.height)").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [.init(.flexible()), .init(.flexible())]) {
                    ForEach(presets.indices, id: \.self) { i in
                        Button(presets[i].0) { model.setCanvas(width: presets[i].1, height: presets[i].2) }
                            .font(.caption).frame(maxWidth: .infinity, minHeight: 44)
                            .background(AppColors.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                HStack {
                    TextField("Width", text: $width).keyboardType(.numberPad)
                    Text("×")
                    TextField("Height", text: $height).keyboardType(.numberPad)
                    Button("Custom") { model.setCanvas(width: Int(width) ?? 0, height: Int(height) ?? 0) }.frame(height: 44)
                }.font(.subheadline)
                Button("Match original video") { model.setCanvas(width: model.project.metadata.displayWidth, height: model.project.metadata.displayHeight) }.font(.caption).frame(height: 44)
                Text("Clips fit inside the canvas. Use Transform to reposition or enlarge them. Export Original preserves this canvas size.").font(.caption2).foregroundStyle(.secondary)
                background
            }.padding(16)
        }.disabled(model.isPreparingTimeline)
    }

    /// The colour the canvas is filled with wherever no clip covers it.
    ///
    /// Part of the exported frame, not a viewing preference: scale a clip down
    /// and this is what surrounds it in the file. The outline drawn on the
    /// preview keeps saying where the canvas is whatever colour it is given, so
    /// a white canvas is still recognisably the canvas and not the workspace.
    private var background: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BACKGROUND").font(.caption.weight(.semibold)).tracking(1.2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                backgroundPreset("Black", color: .black)
                backgroundPreset("White", color: .white)
                Spacer(minLength: 0)
                // Fixed size keeps the wheel beside its own label instead of
                // letting the picker stretch the two apart across the row.
                ColorPicker("Custom", selection: backgroundBinding, supportsOpacity: false)
                    .font(.caption).fixedSize().frame(minHeight: 44)
            }
            Text("Fills the canvas wherever no clip covers it, and is part of the export. The outline on the preview shows where the canvas ends.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func backgroundPreset(_ title: LocalizedStringKey, color: RGBAColor) -> some View {
        Button { model.setCanvasBackground(color) } label: {
            HStack(spacing: 7) {
                Circle().fill(Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: 1))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
                Text(title)
            }.font(.caption).frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.project.canvas.background == color ? AppColors.accent : AppColors.textSecondary)
        .accessibilityAddTraits(model.project.canvas.background == color ? .isSelected : [])
    }

    /// The picker writes to local state and the document is written once the
    /// drag settles. A colour wheel emits continuously, and every distinct
    /// value would otherwise be its own undo step.
    private var backgroundBinding: Binding<Color> {
        Binding {
            let color = pickedBackground ?? model.project.canvas.background
            return Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: 1)
        } set: { color in
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            let value = RGBAColor(red: red, green: green, blue: blue)
            pickedBackground = value
            backgroundCommit?.cancel()
            backgroundCommit = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                model.setCanvasBackground(value)
                pickedBackground = nil
            }
        }
    }
}

struct EditorSettings: View {
    @AppStorage("editor.frameStep") private var frameStep = 2
    @AppStorage("keyframes.hintDismissed") private var hintDismissed = false
    @AppStorage("timeline.showsClipNames") private var showsClipNames = true
    @AppStorage("timeline.showsClipDurations") private var showsClipDurations = true
    @AppStorage("preview.showsCanvasEdge") private var showsCanvasEdge = true
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Frames per press", selection: $frameStep) {
                        ForEach([1, 2, 5, 10, 20, 30], id: \.self) { Text("\($0) frames").tag($0) }
                        if ![1, 2, 5, 10, 20, 30].contains(frameStep) { Text("\(frameStep) frames").tag(frameStep) }
                    }
                    Stepper("Custom: \(frameStep) frames", value: $frameStep, in: 1...120)
                } header: { Text("Frame-step buttons") } footer: { Text("Backward and forward step by project frames. This preference is saved for all projects.") }

                Section {
                    Toggle("Canvas outline", isOn: $showsCanvasEdge)
                } header: { Text("Preview") }
                  footer: { Text("A thin line around the canvas on the preview, so the frame you are exporting stays visible against the workspace even when a clip is scaled down inside it. The canvas colour itself is set per project in the Canvas tool.") }

                Section {
                    Toggle("Clip names", isOn: $showsClipNames)
                    Toggle("Clip lengths", isOn: $showsClipDurations)
                } header: { Text("Timeline labels") }
                  footer: { Text("The file name and the length shown on each clip. Turning them off uncovers the thumbnails and the waveform, which is worth doing once you know your own footage.") }

                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "hand.tap").font(.title3).foregroundStyle(AppColors.accent)
                            .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Double-tap to reset").font(.subheadline.weight(.medium))
                            Text("Works on every slider in the app — grading, transform, text, audio and export.")
                                .font(.caption).foregroundStyle(AppColors.textSecondary)
                        }
                    }.padding(.vertical, 2)
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "keyboard").font(.title3).foregroundStyle(AppColors.accent)
                            .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Tap the number to type it").font(.subheadline.weight(.medium))
                            Text("Tap any slider's value to enter an exact number instead of dragging for it.")
                                .font(.caption).foregroundStyle(AppColors.textSecondary)
                        }
                    }.padding(.vertical, 2)
                } header: { Text("Sliders") }
                  footer: { Text("A double tap on an animated property resets its value at the playhead. Use Reset in the property's Animation menu to clear its keyframes as well.") }

                Section {
                    NavigationLink {
                        ScrollView { KeyframeGuide().padding(20) }
                            .navigationTitle("Keyframes").navigationBarTitleDisplayMode(.inline)
                            .background(AppColors.background.ignoresSafeArea())
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            KeyframeDiamondIcon(state: .onKeyframe, size: 18).frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("How keyframes work").font(.subheadline.weight(.medium))
                                Text("What the diamond does, and how to animate a property in three steps.")
                                    .font(.caption).foregroundStyle(AppColors.textSecondary)
                            }
                        }.padding(.vertical, 2)
                    }
                    if hintDismissed {
                        Button("Show the keyframe tip again") { hintDismissed = false }
                            .font(.subheadline)
                    }
                } header: { Text("Keyframes") }
                  footer: { Text("Keyframes belong to the clip, so they move, copy and split with it, and the preview always matches the export.") }

                // Above About because someone with a question is usually
                // better served by people who have already hit it than by a
                // support email that only reaches me.
                Section {
                    if let url = ProConfiguration.communityURL {
                        Link(destination: url) {
                            settingsLink("r/GradeLabApp", "bubble.left.and.bubble.right",
                                         String(localized: "Ask questions, share your grading, and help decide what gets built next."))
                        }
                    }
                } header: { Text("Community") }
                  footer: { Text("Answers there often come faster than by email, and feature requests get discussed in the open.") }

                // Reachable from Settings as well as from the paywall. Someone
                // looking for the privacy policy or a way to report a bug
                // should not have to open a purchase screen to find either.
                Section {
                    if let url = ProConfiguration.supportURL {
                        Link(destination: url) {
                            settingsLink(String(localized: "Support & contact"), "questionmark.circle",
                                         String(localized: "Report a bug, request a feature, or restore a purchase."))
                        }
                    }
                    if let url = ProConfiguration.privacyPolicyURL {
                        Link(destination: url) {
                            settingsLink(String(localized: "Privacy Policy"), "hand.raised",
                                         String(localized: "What GradeLab does with your information."))
                        }
                    }
                    if let url = ProConfiguration.termsURL {
                        Link(destination: url) {
                            settingsLink(String(localized: "Terms of Use"), "doc.text",
                                         String(localized: "The agreement covering the app and purchases."))
                        }
                    }
                } header: { Text("About") }
                  footer: { Text("GradeLab collects no data. No accounts, no analytics, no advertising and no trackers — your footage never leaves this device.") }
            }.navigationTitle("Settings").navigationBarTitleDisplayMode(.inline).toolbar { Button("Done") { dismiss() } }
        }.preferredColorScheme(.dark)
    }

    private func settingsLink(_ title: String, _ icon: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(AppColors.accent)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(AppColors.textSecondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
                .font(.caption2)
                .foregroundStyle(AppColors.textTertiary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens in your browser")
    }
}
