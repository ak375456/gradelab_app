import SwiftUI

/// Scope-panel sizing. A plain enum rather than statics on `ScopePanel`, which
/// is generic over its model and so cannot hold them.
enum ScopeLayout {
    /// The trace height when nobody has resized it.
    static func automaticTraceHeight(isRegularWidth: Bool) -> CGFloat {
        isRegularWidth ? 220 : 132
    }

    static let compactTraceHeight: CGFloat = 76
    static let compactHeaderHeight: CGFloat = 44
    static let compactCaptionHeight: CGFloat = 20
    static var compactHeight: CGFloat { compactHeaderHeight + compactTraceHeight + compactCaptionHeight }
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
    var usesCompactLayout = false
    var canExpand = true

    @ObservedObject private var store = ProStore.shared
    @State private var paywallFeature: ProFeature?
    @State private var showsSettings = false
    @State private var showsExpandedScope = false

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
            if usesCompactLayout { compactHeader } else { selector }
            scope
                .frame(height: traceHeight ?? (usesCompactLayout ? ScopeLayout.compactTraceHeight : ScopeLayout.automaticTraceHeight(isRegularWidth: isRegularWidth)))
                .background(Color.black)
                .overlay {
                    if isLocked(settings.type) {
                        ProObscuredOverlay(feature: .scopes) { paywallFeature = .scopes }
                    }
                }
                .clipped()
            if usesCompactLayout { compactCaption }
            else { footer; assist }
        }
        .background(Color.black)
        .overlay(alignment: .top) { Divider().overlay(Color.white.opacity(0.08)) }
        .overlay(alignment: .bottom) { Divider().overlay(Color.white.opacity(0.08)) }
        .paywallSheet($paywallFeature)
        .sheet(isPresented: $showsSettings) { ScopeOptions(model: model) }
        .sheet(isPresented: $showsExpandedScope) {
            NavigationStack {
                GeometryReader { geometry in
                    ScopePanel(model: model, isRegularWidth: false,
                               traceHeight: max(140, geometry.size.height - ScopeLayout.compactHeaderHeight - ScopeLayout.compactCaptionHeight),
                               usesCompactLayout: true, canExpand: false)
                }
                .navigationTitle("Scopes").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { showsExpandedScope = false } }
            }
            .background(.black).preferredColorScheme(.dark)
            .presentationDetents([.large])
        }
    }

    private var compactHeader: some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(ScopeType.allCases) { type in
                    Button { model.selectScope(type) } label: {
                        Label(type.title, systemImage: settings.type == type ? "checkmark" : (isLocked(type) ? "lock" : "waveform"))
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(settings.type.title).font(AppTypography.callout.weight(.semibold))
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                }
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Scope type")
            .accessibilityValue(settings.type.title)
            Spacer(minLength: 4)
            if canExpand {
                Button { showsExpandedScope = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Expand scopes")
            }
            Button { showsSettings = true } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Scope and exposure assist settings")
        }
        .padding(.leading, 12).padding(.trailing, 4)
        .frame(height: ScopeLayout.compactHeaderHeight)
        .foregroundStyle(AppColors.textSecondary)
    }

    private var compactCaption: some View {
        HStack(spacing: 8) {
            Text(model.scopeColorSpace.axisLabel)
            if model.showsOriginal { Text("SOURCE").foregroundStyle(AppColors.accent) }
            Spacer(minLength: 0)
            if model.viewerAssist.mode != .off {
                Text(model.viewerAssist.mode.title).foregroundStyle(AppColors.accent)
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(AppColors.textSecondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: ScopeLayout.compactCaptionHeight)
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

/// Secondary scope controls are kept off the grading workspace, with full-size
/// native controls when explicitly opened. All use the existing model setters.
private struct ScopeOptions<Model: GradingModel>: View {
    @ObservedObject var model: Model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Trace") {
                    HStack {
                        Text("Scope intensity")
                        Spacer()
                        Text(model.scopeSettings.intensity.formatted(.number.precision(.fractionLength(1))))
                            .monospacedDigit().foregroundStyle(AppColors.textSecondary)
                    }
                    Slider(value: Binding(get: { model.scopeSettings.intensity }, set: model.setScopeIntensity),
                           in: ScopeSettings.intensityRange)
                        .accessibilityLabel("Scope intensity")
                }
                Section {
                    Picker("Preview assist", selection: Binding(get: { model.viewerAssist.mode }, set: model.setViewerAssist)) {
                        ForEach(ViewerAssist.allCases) { Text($0.title).tag($0) }
                    }
                    if model.viewerAssist.mode == .zebras {
                        HStack {
                            Text("Zebra threshold")
                            Spacer()
                            Text("\(Int(model.viewerAssist.zebraThreshold))%").monospacedDigit()
                        }
                        Slider(value: Binding(get: { model.viewerAssist.zebraThreshold }, set: model.setZebraThreshold),
                               in: ViewerAssistSettings.thresholdRange)
                            .accessibilityLabel("Zebra threshold")
                    }
                } header: { Text("Exposure assist") }
                  footer: { Text("False Colour and Zebras are preview aids. They do not appear in exports.") }
            }
            .tint(AppColors.accent)
            .navigationTitle("Scope settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
