import SwiftUI
import Combine

@MainActor
final class StabilizationAnalysisController: ObservableObject {
    @Published private(set) var isAnalyzing = false
    @Published private(set) var progress = 0.0
    @Published private(set) var message: String?
    private var task: Task<Void, Never>?
    private var token = UUID()

    deinit { task?.cancel() }

    func cancel() {
        token = UUID(); task?.cancel(); task = nil
        isAnalyzing = false; progress = 0; message = nil
    }

    func analyze(_ model: EditorViewModel) {
        guard model.canStabilize, let clip = model.selectedClip,
              let asset = model.project.assets.first(where: { $0.id == clip.assetID }) else { return }
        guard model.requireStabilizationAccess() else { return }
        cancel()
        let generation = token
        message = nil; isAnalyzing = true
        model.playback.pause()
        model.unstabilizedPreviewClipID = nil
        let reportProgress: @Sendable (Double) -> Void = { [weak self] value in
            guard let controller = self else { return }
            Task { @MainActor [weak controller] in
                guard let controller, controller.token == generation else { return }
                controller.progress = value
            }
        }
        task = Task.detached(priority: .userInitiated) { [weak self, weak model] in
            do {
                let result = try await StabilizationAnalysis.analyze(url: asset.url, range: clip.sourceRange,
                                                                    progress: reportProgress)
                try Task.checkCancellation()
                await self?.finish(result, original: clip, model: model, generation: generation)
            } catch is CancellationError {
                // Cancel never applies a partial analysis or changes the document.
            } catch {
                await self?.failed(error.localizedDescription, generation: generation)
            }
        }
    }

    private func finish(_ result: VideoStabilization, original: VideoClip,
                        model: EditorViewModel?, generation: UUID) {
        guard token == generation else { return }
        isAnalyzing = false; task = nil
        guard let model, model.canStabilize, model.selectedClipID == original.id,
              let current = model.selectedClip, current.assetID == original.assetID,
              current.sourceRange == original.sourceRange else {
            message = String(localized: "The clip changed during analysis. Analyze it again to stabilize the current section.")
            return
        }
        model.applyStabilization(result, analyzedClip: original)
    }

    private func failed(_ text: String, generation: UUID) {
        guard token == generation else { return }
        isAnalyzing = false; task = nil; message = text
    }
}

struct StabilizationPanel: View {
    @ObservedObject var model: EditorViewModel
    @StateObject private var analysis = StabilizationAnalysisController()
    @ObservedObject private var store = ProStore.shared
    @Environment(\.requestNumericEntry) private var requestNumericEntry

    private var settings: VideoStabilization? { model.selectedClip?.stabilization }
    private var needsAnalysis: Bool {
        guard let settings, let clip = model.selectedClip else { return false }
        return !settings.covers(clip.sourceRange)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.standard) {
                HStack(spacing: 10) {
                    Image(systemName: "camera.metering.center.weighted")
                        .font(.title2).foregroundStyle(AppColors.accent).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("Stabilization").font(.headline)
                            if !model.hasStabilizationAccess { ProBadge() }
                        }
                        Text("Smooth handheld shake while keeping natural camera movement.")
                            .font(.caption).foregroundStyle(AppColors.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if analysis.isAnalyzing {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Analyzing motion…").font(.subheadline)
                            Spacer(minLength: 8)
                            Text(analysis.progress, format: .percent.precision(.fractionLength(0)))
                                .font(AppTypography.numeric).monospacedDigit()
                        }
                        ProgressView(value: analysis.progress).tint(AppColors.accent)
                        Button("Cancel analysis") { analysis.cancel() }
                            .frame(maxWidth: .infinity, minHeight: 44).buttonStyle(.bordered)
                    }
                } else {
                    if !model.hasStabilizationAccess {
                        Text(ProFeature.stabilization.detail)
                            .font(.caption).foregroundStyle(AppColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        analyzeButton
                    }
                    if let settings, !needsAnalysis {
                        controls(settings)
                    }
                    if needsAnalysis {
                        Label("The clip now includes frames outside its analysis. Analyze again to restore stabilization.",
                              systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption).foregroundStyle(AppColors.textSecondary)
                    }
                    if model.hasStabilizationAccess { analyzeButton }
                }
                if let message = analysis.message {
                    Label(message, systemImage: "info.circle")
                        .font(.caption).foregroundStyle(AppColors.textSecondary)
                }
                if !model.canStabilize && !analysis.isAnalyzing {
                    Text("Select one unlocked video clip to stabilize it.")
                        .font(.caption).foregroundStyle(AppColors.textSecondary)
                }
                Text("Analyzes this clip on your device. A fixed crop keeps the edges clean. Your original video and audio stay intact.")
                    .font(.caption2).foregroundStyle(AppColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, AppSpacing.large).padding(.vertical, AppSpacing.compact)
        }
        .scrollIndicators(.visible)
        .paywallSheet($model.stabilizationPaywallFeature)
        .onChange(of: store.hasPro) { _, hasPro in if !hasPro { analysis.cancel() } }
        .onChange(of: model.selectedClipID) { _, _ in leave() }
        .onDisappear(perform: leave)
    }

    private var analyzeButton: some View {
        let title = !model.hasStabilizationAccess ? String(localized: "Explore Pro")
            : settings == nil ? String(localized: "Analyze & Stabilize") : String(localized: "Analyze Again")
        return Button { analysis.analyze(model) } label: {
            Label(title, systemImage: model.hasStabilizationAccess ? "waveform.path" : "lock.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent).tint(model.hasStabilizationAccess ? AppColors.accent : ProStyle.gold)
        .disabled(!model.canStabilize || (!model.hasStabilizationAccess && store.isCheckingAccess))
    }

    private func controls(_ settings: VideoStabilization) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Stabilization", isOn: Binding(get: { settings.isEnabled }, set: { enabled in
                model.setStabilizationEnabled(enabled)
            }))
            .tint(AppColors.accent).frame(minHeight: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Smoothness").font(.caption)
                    Spacer()
                    Button {
                        requestNumericEntry(String(localized: "Smoothness"), value: settings.strength*100, range: 0...100) {
                            model.setStabilizationStrength($0/100)
                        }
                    } label: {
                        Text(settings.strength, format: .percent.precision(.fractionLength(0)))
                            .font(AppTypography.numeric).monospacedDigit().frame(minWidth: 48, minHeight: 44)
                    }
                    .buttonStyle(.plain).disabled(!requestNumericEntry.isAvailable)
                    .accessibilityLabel("Smoothness value")
                }
                ResettableSlider(value: Binding(get: { settings.strength }, set: { model.setStabilizationStrength($0) }),
                    range: 0...1, resetValue: 0.8, label: String(localized: "Smoothness"),
                    onEditingChanged: { model.stabilizationGestureChanged($0) },
                    onReset: { model.setStabilizationStrength(0.8) })
                    .tint(AppColors.accent).frame(minHeight: 44)
                HStack {
                    Text("Natural"); Spacer(); Text("Smoother")
                }.font(.caption2).foregroundStyle(AppColors.textTertiary)
            }
            .disabled(!settings.isEnabled || !model.hasStabilizationAccess)
            HStack {
                Text("Crop zoom").font(.caption).foregroundStyle(AppColors.textSecondary)
                Spacer()
                Text(settings.cropZoom, format: .number.precision(.fractionLength(2)))
                    .font(AppTypography.numeric).monospacedDigit()
                Text("×").font(.caption)
            }
            Toggle("Show before stabilization", isOn: Binding(
                get: { model.unstabilizedPreviewClipID == model.selectedClipID },
                set: { model.unstabilizedPreviewClipID = $0 ? model.selectedClipID : nil }))
                .font(.subheadline).tint(AppColors.accent).frame(minHeight: 44)
                .disabled(!settings.isEnabled)
            if settings.limitedCorrection {
                Text("Strong shake: correction is limited to preserve more of your picture.")
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
            }
            if settings.unreliableFrames > 0 {
                Text("Some frames could not be tracked confidently. Review cuts, blur and fast movement before exporting.")
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
            }
        }
        .disabled(!model.canStabilize)
    }

    private func leave() {
        analysis.cancel()
        model.unstabilizedPreviewClipID = nil
        model.stabilizationGestureChanged(false)
    }
}
