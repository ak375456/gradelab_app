import SwiftUI

/// Scope-panel sizing. A plain enum rather than statics on `ScopePanel`, which
/// is generic over its model and so cannot hold them.
enum ScopeLayout {
    /// The trace height when nobody has resized it.
    static func automaticTraceHeight(isRegularWidth: Bool) -> CGFloat {
        isRegularWidth ? 220 : 132
    }
}

/// The scope panel: a selector, the scope itself, and one intensity control.
///
/// Deliberately plain — black ground, hairline grid, monospaced numerals, no
/// cards or gradients. It should read as an instrument rather than as part of
/// the editing chrome.
struct ScopePanel<Model: GradingModel>: View {
    @ObservedObject var model: Model
    /// Larger layouts can afford a taller scope and can keep it open beside the
    /// grading controls.
    let isRegularWidth: Bool
    /// Height of the trace itself, chosen by the caller so a workspace divider
    /// can drive it. Nil keeps the size the layout picks on its own.
    var traceHeight: CGFloat?

    @ObservedObject private var store = ProStore.shared
    @State private var paywallFeature: ProFeature?

    private var settings: ScopeSettings { model.scopeSettings }

    /// The histogram is free; the three measurement scopes are not.
    ///
    /// These are the exception to the app's preview-free rule, and they have to
    /// be: a scope never reaches the exported file, so there is no export to
    /// gate. Reading one *is* the whole feature.
    ///
    /// So rather than refusing to open them, they open and run, and the trace
    /// is covered by an obscuring layer. You can see the waveform is really
    /// there and really responding to your grade; you cannot read a value off
    /// it. A greyed-out tab would have shown neither.
    private func isProScope(_ type: ScopeType) -> Bool { type != .histogram }
    private func isLocked(_ type: ScopeType) -> Bool { isProScope(type) && !store.hasPro }


    var body: some View {
        VStack(spacing: 0) {
            selector
            scope
                .frame(height: traceHeight ?? ScopeLayout.automaticTraceHeight(isRegularWidth: isRegularWidth))
                .background(Color.black)
                .overlay {
                    if isLocked(settings.type) {
                        ProObscuredOverlay(feature: .scopes) { paywallFeature = .scopes }
                    }
                }
                .clipped()
            footer
            assist
        }
        .background(Color.black)
        .overlay(alignment: .top) { Divider().overlay(Color.white.opacity(0.08)) }
        .overlay(alignment: .bottom) { Divider().overlay(Color.white.opacity(0.08)) }
        .paywallSheet($paywallFeature)
    }

    private var selector: some View {
        HStack(spacing: 0) {
            ForEach(ScopeType.allCases) { type in
                Button { model.selectScope(type) } label: {
                    HStack(spacing: 3) {
                        Text(type.title)
                            .font(.system(size: 11, weight: settings.type == type ? .semibold : .regular))
                            .foregroundStyle(settings.type == type ? AppColors.accent : AppColors.textSecondary)
                        if isLocked(type) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(ProStyle.gold)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(type.title)
                .accessibilityHint(isLocked(type) ? "\(type.summary). Pro feature" : type.summary)
                .accessibilityAddTraits(settings.type == type ? .isSelected : [])
            }
        }
        .background(Color.black)
    }

    @ViewBuilder
    private var scope: some View {
        if let analyzer = model.scopeAnalyzer, let renderer = model.scopeRenderer {
            ZStack {
                // The vectorscope is round, so it is kept square and centred
                // rather than stretched to the panel's shape.
                if settings.type == .vectorscope {
                    GeometryReader { geometry in
                        let side = min(geometry.size.width, geometry.size.height)
                        ZStack {
                            MetalScopeView(renderer: renderer, analyzer: analyzer,
                                           type: settings.type, intensity: settings.intensity)
                            ScopeGraticule(type: settings.type, colorSpace: model.scopeColorSpace)
                        }
                        .frame(width: side, height: side)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    }
                } else {
                    MetalScopeView(renderer: renderer, analyzer: analyzer,
                                   type: settings.type, intensity: settings.intensity)
                    ScopeGraticule(type: settings.type, colorSpace: model.scopeColorSpace)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("\(settings.type.title) scope")
            .accessibilityValue(settings.type.summary)
        } else {
            Text("Scopes are unavailable on this device.")
                .font(.caption2).foregroundStyle(AppColors.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            // Says which signal is being measured. An HDR project is analysed in
            // the HLG signal it displays and encodes, so the panel names that
            // rather than implying a reading it does not make.
            Text(model.scopeColorSpace.axisLabel)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(AppColors.textSecondary)
            if model.showsOriginal {
                Text("SOURCE").font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppColors.accent)
            }
            Spacer()
            Image(systemName: "sun.max").font(.system(size: 10))
                .foregroundStyle(AppColors.textSecondary)
            Slider(value: Binding(get: { model.scopeSettings.intensity },
                                  set: { model.setScopeIntensity($0) }),
                   in: ScopeSettings.intensityRange)
                .frame(width: isRegularWidth ? 160 : 110)
                .tint(AppColors.accent)
                .accessibilityLabel("Scope intensity")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color.black)
    }

    /// False colour and zebras.
    ///
    /// Beside the scopes because it answers the same question they do — is this
    /// exposed correctly — but on the picture rather than in a trace. It is not
    /// gated: an assist changes no pixel of the export, so like the histogram
    /// there is nothing to gate, and it is the one tool that makes Log footage
    /// legible to someone who has not graded it yet.
    private var assist: some View {
        VStack(spacing: 6) {
            Divider().overlay(Color.white.opacity(0.08))
            HStack(spacing: 0) {
                ForEach(ViewerAssist.allCases) { mode in
                    Button { model.setViewerAssist(mode) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: mode.symbol).font(.system(size: 9))
                            Text(mode.title)
                                .font(.system(size: 10,
                                              weight: model.viewerAssist.mode == mode ? .semibold : .regular))
                        }
                        .foregroundStyle(model.viewerAssist.mode == mode
                                         ? AppColors.accent : AppColors.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.viewerAssist.mode == mode ? [.isSelected] : [])
                }
            }
            // Only zebras have a threshold, so the row appears with them rather
            // than sitting inert under the other two.
            if model.viewerAssist.mode == .zebras {
                HStack(spacing: 8) {
                    Text("\(Int(model.viewerAssist.zebraThreshold))%")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(AppColors.textSecondary)
                        .frame(width: 34, alignment: .leading)
                    Slider(value: Binding(get: { model.viewerAssist.zebraThreshold },
                                          set: { model.setZebraThreshold($0) }),
                           in: ViewerAssistSettings.thresholdRange)
                        .tint(AppColors.accent)
                        .accessibilityLabel("Zebra threshold")
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
        }
        .background(Color.black)
    }
}
