#if !targetEnvironment(macCatalyst)
import SwiftUI

enum CameraScopeLayout {
    static func frame(in image: CGRect, viewport: CGSize, expanded: Bool, topInset: CGFloat = 0) -> CGRect {
        var size = size(in: image.size, expanded: expanded)
        size.height = min(size.height, max(0, image.maxY - 8 - topInset))
        var x = image.minX + 8
        // A portrait take stays portrait when the phone rotates during capture.
        // Use the letterbox for an expanded card instead of crushing its controls.
        if expanded, size.width < 200, viewport.width >= 216 {
            size.width = 200
            x = image.minX >= 216 ? 8 : min(x, viewport.width - size.width - 8)
        }
        return CGRect(x: x, y: image.maxY - size.height - 8, width: size.width, height: size.height)
    }

    static func size(in image: CGSize, expanded: Bool) -> CGSize {
        let availableWidth = max(0, image.width - 16)
        let availableHeight = max(0, image.height - 16)
        if expanded {
            return CGSize(width: min(360, availableWidth),
                          height: min(220, availableHeight, max(144, image.height * 0.46)))
        }
        return CGSize(width: min(160, availableWidth, max(116, image.width * 0.44)),
                      height: min(76, availableHeight))
    }
}

/// One live trace changes size in place. The existing preview analyzer supplies
/// its buffers, so expanding never creates another camera output or decoder.
struct CameraScopesView: View {
    @ObservedObject var model: CameraViewModel
    let expanded: Bool
    var showsIntensity = true
    let onToggle: () -> Void

    private var settings: ScopeSettings { model.scopeSettings }

    var body: some View {
        Group {
            if expanded { expandedCard }
            else {
                Button(action: onToggle) {
                    VStack(spacing: 3) {
                        HStack(spacing: 4) {
                            Text(model.scopeColorSpace.axisLabel)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                            Spacer(minLength: 2)
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        trace(graticule: false).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }.padding(7)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Expand \(settings.type.title)")
                .accessibilityHint("Opens a larger live scope while keeping the camera visible")
            }
        }
        .foregroundStyle(AppColors.textPrimary)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var expandedCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Menu {
                    ForEach(ScopeType.allCases) { type in
                        Button {
                            model.scopeSettings.type = type
                        } label: {
                            if type == settings.type { Label(type.title, systemImage: "checkmark") }
                            else { Text(type.title) }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(settings.type.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }.frame(minHeight: 44)
                }
                .accessibilityLabel("Choose camera scope")
                Spacer(minLength: 0)
                Button(action: onToggle) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 13, weight: .semibold))
                        .frame(width: 44, height: 44)
                }.accessibilityLabel("Collapse scope")
            }
            .buttonStyle(.plain)
            .padding(.leading, 10)
            trace(graticule: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.horizontal, 8)
            if showsIntensity { HStack(spacing: 8) {
                Text("Display · \(model.scopeColorSpace.axisLabel)")
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(AppColors.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Slider(value: $model.scopeSettings.intensity, in: ScopeSettings.intensityRange)
                    .tint(AppColors.accent).frame(width: 82, height: 36)
                    .accessibilityLabel("Scope intensity")
            }.padding(.horizontal, 10) }
        }
    }

    @ViewBuilder private func trace(graticule: Bool) -> some View {
        ZStack {
            if let renderer = model.scopeRenderer, let analyzer = model.scopeAnalyzer {
                if settings.type == .vectorscope {
                    GeometryReader { geometry in
                        let side = min(geometry.size.width, geometry.size.height)
                        plot(renderer: renderer, analyzer: analyzer, graticule: graticule)
                            .frame(width: side, height: side)
                            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    }
                } else { plot(renderer: renderer, analyzer: analyzer, graticule: graticule) }
            } else {
                Text("Scope unavailable").font(.caption2).foregroundStyle(AppColors.textTertiary)
            }
        }
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(settings.type.title), displayed image, \(model.scopeColorSpace.axisLabel)")
    }

    private func plot(renderer: ScopeRenderer, analyzer: ScopeAnalyzer, graticule: Bool) -> some View {
        ZStack {
            MetalScopeView(renderer: renderer, analyzer: analyzer, type: settings.type, intensity: settings.intensity)
            if graticule { ScopeGraticule(type: settings.type, colorSpace: model.scopeColorSpace) }
        }
        .allowsHitTesting(false)
    }
}
#endif
