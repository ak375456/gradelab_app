#if !targetEnvironment(macCatalyst)
import SwiftUI

extension View {
    func cameraGlass(radius: CGFloat = 14) -> some View {
        background(.black.opacity(0.64), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.13), lineWidth: 0.5))
    }
}

struct CameraModePicker: View {
    @Binding var pro: Bool
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            mode("Simple", selected: !pro) { pro = false }
            mode("Pro", selected: pro) { pro = true }
        }
        .padding(.horizontal, 3).cameraGlass(radius: 24)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Camera control mode")
    }

    private func mode(_ title: LocalizedStringKey, selected: Bool, action: @escaping () -> Void) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.2), action) } label: {
            Text(title).font(.system(size: 11, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.65)
                .foregroundStyle(selected ? AppColors.textPrimary : AppColors.textTertiary)
                .frame(width: 48, height: 44)
                .background {
                    if selected {
                        Capsule().fill(.white.opacity(0.10))
                            .overlay(Capsule().strokeBorder(AppColors.accent.opacity(0.35), lineWidth: 0.5))
                            .matchedGeometryEffect(id: "mode", in: selection).padding(.vertical, 5)
                    }
                }
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct CameraLiveDashboard: View {
    @ObservedObject var model: CameraViewModel
    let pro: Bool
    let selected: CameraTool?
    let onSelect: (CameraTool) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        GeometryReader { geometry in
            let scrolls = typeSize.isAccessibilitySize || geometry.size.width < 300
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    if pro {
                        readout("ISO", value: "\(Int(model.telemetry.iso))", manual: model.controls.manualExposure, tool: .exposure)
                        separator
                        readout(model.shutterUnit == .angle ? String(localized: "ANGLE") : String(localized: "SHUTTER"),
                            value: model.shutterUnit == .angle
                                ? CameraGeometry.angleLabel(model.telemetry.shutter, fps: model.configuration?.selected.fps ?? 30)
                                : CameraGeometry.shutterLabel(model.telemetry.shutter), manual: model.controls.manualExposure, tool: .exposure)
                    } else {
                        readout("EXPOSURE", value: "\(Int(model.telemetry.iso)) · \(CameraGeometry.shutterLabel(model.telemetry.shutter))", manual: model.controls.manualExposure, tool: .exposure)
                    }
                    separator
                    readout("WB", value: "\(Int(model.telemetry.temperature))K", manual: model.controls.manualWhiteBalance, tool: .whiteBalance)
                    if pro {
                        separator
                        readout("FOCUS", value: model.configuration?.limits.supportsFocus == false ? String(localized: "Fixed") : String(format: "%.0f%%", model.telemetry.focus * 100), manual: model.controls.manualFocus, tool: .focus, fixed: model.configuration?.limits.supportsFocus == false)
                    }
                }.frame(width: scrolls ? (pro ? 400 : 300) : geometry.size.width)
            }.scrollIndicators(.hidden).scrollDisabled(!scrolls)
        }
        .frame(height: 58)
        .cameraGlass()
    }

    private var separator: some View { Rectangle().fill(.white.opacity(0.09)).frame(width: 0.5, height: 25) }

    private func readout(_ title: String, value: String, manual: Bool, tool: CameraTool, fixed: Bool = false) -> some View {
        Button { onSelect(tool) } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text(LocalizedStringKey(title)).font(.system(size: 8, weight: .semibold)).tracking(0.8)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    Text(fixed ? "—" : manual ? "M" : "A").font(.system(size: 7, weight: .bold))
                        .foregroundStyle(manual ? AppColors.accent : AppColors.textTertiary)
                }
                Text(value).font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(selected == tool ? AppColors.accent : AppColors.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(AppColors.textSecondary)
            .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 54)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(String(localized: String.LocalizationValue(title))), \(value), \(fixed ? String(localized: "fixed") : manual ? String(localized: "manual") : String(localized: "automatic"))")
        .accessibilityHint("Opens \(tool.title) controls")
    }
}

struct CameraZoomControls: View {
    @ObservedObject var model: CameraViewModel
    let vertical: Bool

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        layout {
            ForEach(model.zoomStops) { stop in
                let selected = model.configuration?.lensID == stop.lensID && abs(model.zoomFactor - stop.factor) < 0.15
                Button { model.selectZoom(stop) } label: {
                    Text(stop.label).font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(selected ? AppColors.accent : AppColors.textPrimary)
                        .frame(width: 44, height: 44)
                        .background { if selected { Circle().strokeBorder(AppColors.accent.opacity(0.8), lineWidth: 1).padding(5) } }
                }
                .buttonStyle(.plain)
                .disabled(!model.canZoom || (model.isRecording && stop.lensID != model.configuration?.lensID))
                .accessibilityLabel("Zoom to \(stop.label)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3).cameraGlass(radius: 26)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Camera zoom. Current \(CameraGeometry.zoomLabel(model.displayedZoom))")
        .accessibilityHint("Pinch the picture for continuous zoom")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.setZoom(model.zoomFactor + 0.1)
            case .decrement: model.setZoom(model.zoomFactor - 0.1)
            @unknown default: break
            }
        }
    }
}

struct CameraHeatIndicator: View {
    @State private var expanded = false
    var body: some View {
        Button { expanded = true } label: {
            Image(systemName: "thermometer.high").font(.system(size: 17, weight: .medium))
                .foregroundStyle(AppColors.warning).frame(width: 44, height: 44).cameraGlass(radius: 22)
        }
        .buttonStyle(.plain).accessibilityLabel("Device is warm. Show details")
        .popover(isPresented: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Device is warm", systemImage: "thermometer.high").font(AppTypography.headline).foregroundStyle(AppColors.warning)
                Text("Recording may stop if the device gets too warm. A lower frame rate or resolution can reduce the camera workload.")
                    .font(AppTypography.callout).fixedSize(horizontal: false, vertical: true)
            }.padding(20).frame(width: 280).presentationCompactAdaptation(.popover).preferredColorScheme(.dark)
        }
    }
}

struct CameraGuidesOverlay: View {
    let settings: CameraGuideSettings
    let image: CGRect

    var body: some View {
        Canvas { context, _ in
            let frame = CameraGeometry.guideRect(aspect: settings.frame.aspect, image: image)
            if settings.frame != .off {
                var mask = Path(image); mask.addRect(frame)
                context.fill(mask, with: .color(.black.opacity(0.36)), style: FillStyle(eoFill: true))
                context.stroke(Path(frame), with: .color(.white.opacity(0.8)), lineWidth: 1)
            }
            var grid = Path()
            for fraction in settings.grid.divisions {
                let x = frame.minX + frame.width * fraction
                let y = frame.minY + frame.height * fraction
                grid.move(to: CGPoint(x: x, y: frame.minY)); grid.addLine(to: CGPoint(x: x, y: frame.maxY))
                grid.move(to: CGPoint(x: frame.minX, y: y)); grid.addLine(to: CGPoint(x: frame.maxX, y: y))
            }
            context.stroke(grid, with: .color(.white.opacity(0.38)), lineWidth: 0.7)
            if settings.center {
                var cross = Path()
                cross.move(to: CGPoint(x: frame.midX - 12, y: frame.midY)); cross.addLine(to: CGPoint(x: frame.midX + 12, y: frame.midY))
                cross.move(to: CGPoint(x: frame.midX, y: frame.midY - 12)); cross.addLine(to: CGPoint(x: frame.midX, y: frame.midY + 12))
                context.stroke(cross, with: .color(.white.opacity(0.7)), lineWidth: 1)
            }
            if settings.safeArea {
                context.stroke(Path(frame.insetBy(dx: frame.width * 0.05, dy: frame.height * 0.05)),
                    with: .color(.white.opacity(0.5)), style: StrokeStyle(lineWidth: 0.7, dash: [4, 4]))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
#endif
