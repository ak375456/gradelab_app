@preconcurrency import AVFoundation
import Combine
import SwiftUI

struct SoundEffectBrowser: View {
    let onAdd: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var preview = SoundEffectPreviewPlayer()
    @State private var query = ""
    @State private var selectedPack = "All"
    @State private var selectedCategory = "All"

    private let effects = SoundEffectCatalog.all

    private var packs: [String] {
        ["All"] + Array(Set(effects.map(\.pack))).sorted()
    }

    private var packEffects: [SoundEffectAsset] {
        selectedPack == "All" ? effects : effects.filter { $0.pack == selectedPack }
    }

    private var categories: [String] {
        ["All"] + Array(Set(packEffects.map(\.category))).sorted()
    }

    private var visibleEffects: [SoundEffectAsset] {
        packEffects.filter { effect in
            (selectedCategory == "All" || effect.category == selectedCategory)
                && (query.isEmpty
                    || effect.title.localizedStandardContains(query)
                    || effect.category.localizedStandardContains(query)
                    || Self.categoryLabel(effect.category).localizedStandardContains(query)
                    || effect.pack.localizedStandardContains(query))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                libraryHeader
                filters
                Divider().overlay(AppColors.separator)
                if visibleEffects.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(visibleEffects) { effect in
                                row(effect)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .background(AppColors.background.ignoresSafeArea())
            .foregroundStyle(AppColors.textPrimary)
            .navigationTitle("Sound Effects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search sounds")
        }
        .preferredColorScheme(.dark)
        .onChange(of: selectedPack) { _, _ in
            if !categories.contains(selectedCategory) { selectedCategory = "All" }
            preview.stop()
        }
        .onChange(of: selectedCategory) { _, _ in preview.stop() }
        .onDisappear { preview.stop() }
    }

    private var libraryHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.badge.plus")
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppColors.accent)
                .frame(width: 38, height: 38)
                .background(AppColors.accentMuted, in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 2) {
                Text("Built into GradeLab").font(.subheadline.weight(.semibold))
                Text("\(effects.count) sounds · available offline")
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
            }
            Spacer()
            Label("Offline", systemImage: "arrow.down.circle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppColors.accent)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(AppColors.accentMuted, in: Capsule())
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Sound pack", selection: $selectedPack) {
                ForEach(packs, id: \.self) { pack in
                    Text(packLabel(pack)).tag(pack)
                }
            }
            .pickerStyle(.segmented)

            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(categories, id: \.self) { category in
                        Button { selectedCategory = category } label: {
                            Text(Self.categoryLabel(category))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(selectedCategory == category ? Color.black : AppColors.textSecondary)
                                .padding(.horizontal, 11).padding(.vertical, 7)
                                .background(selectedCategory == category ? AppColors.accent : AppColors.surfaceRaised,
                                            in: Capsule())
                        }
                        .accessibilityAddTraits(selectedCategory == category ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.bottom, 12)
    }

    private func row(_ effect: SoundEffectAsset) -> some View {
        HStack(spacing: 12) {
            Button { preview.toggle(effect) } label: {
                Image(systemName: preview.playingID == effect.id ? "stop.fill" : "play.fill")
                    .font(.caption.weight(.bold))
                    .frame(width: 40, height: 40)
                    .foregroundStyle(preview.playingID == effect.id ? Color.black : AppColors.accent)
                    .background(preview.playingID == effect.id ? AppColors.accent : AppColors.accentMuted,
                                in: Circle())
            }
            .accessibilityLabel(preview.playingID == effect.id ? "Stop \(effect.title)" : "Preview \(effect.title)")

            VStack(alignment: .leading, spacing: 4) {
                Text(effect.title).font(.subheadline.weight(.medium)).lineLimit(1)
                HStack(spacing: 5) {
                    Text(Self.categoryLabel(effect.category))
                    Text("·")
                    Text(duration(effect.duration)).monospacedDigit()
                }
                .font(.caption2).foregroundStyle(AppColors.textSecondary)
            }
            Spacer(minLength: 4)
            Button {
                preview.stop()
                guard let url = effect.url() else { return }
                onAdd(url)
                dismiss()
            } label: {
                Image(systemName: "plus")
                    .font(.subheadline.weight(.bold))
                    .frame(width: 38, height: 38)
                    .background(AppColors.surfaceRaised, in: Circle())
            }
            .accessibilityLabel("Add \(effect.title) at playhead")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(AppColors.border, lineWidth: 1))
    }

    private func packLabel(_ pack: String) -> String {
        switch pack {
        case "All": String(localized: "All")
        case "Essential Effects": String(localized: "Essentials")
        case "Sound Design Essentials": String(localized: "Cinematic")
        default: pack
        }
    }

    /// Display only. The raw category drives `visibleEffects`, the "All" reset
    /// in `onChange` and the search, so the identity has to stay English. The
    /// effect titles themselves are catalogue data and stay as recorded.
    static func categoryLabel(_ category: String) -> String {
        switch category {
        case "All": String(localized: "All")
        case "Action": String(localized: "Action")
        case "Ambience": String(localized: "Ambience")
        case "Animals": String(localized: "Animals")
        case "Cinematic Hits": String(localized: "Cinematic Hits")
        case "Foley": String(localized: "Foley")
        case "Glitches": String(localized: "Glitches")
        case "Hits": String(localized: "Hits")
        case "Musical": String(localized: "Musical")
        case "Nature": String(localized: "Nature")
        case "Other": String(localized: "Other")
        case "People": String(localized: "People")
        case "Risers": String(localized: "Risers")
        default: category
        }
    }

    private func duration(_ seconds: Double) -> String {
        if seconds > 0, seconds < 1 { return "<1s" }
        let rounded = max(0, Int(seconds.rounded()))
        return rounded >= 60
            ? String(format: "%d:%02d", rounded / 60, rounded % 60)
            : "\(rounded)s"
    }
}

@MainActor
private final class SoundEffectPreviewPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playingID: String?
    private var player: AVAudioPlayer?

    func toggle(_ effect: SoundEffectAsset) {
        if playingID == effect.id { stop(); return }
        stop()
        guard let url = effect.url() else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.volume = 0.75
            player.prepareToPlay()
            guard player.play() else { return }
            self.player = player
            playingID = effect.id
        } catch {
            playingID = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingID = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.stop() }
    }
}
