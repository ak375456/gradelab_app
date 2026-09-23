import SwiftUI
import UniformTypeIdentifiers

/// The project's media, as a column of its own.
///
/// A desktop window has room to keep every imported source on screen beside the
/// edit, the way an NLE does, instead of making the timeline the only record of
/// what was imported. That changes what import means: a source lands in the bin
/// once and is placed from there as many times as the edit wants, rather than
/// each use costing another trip through the file browser.
///
/// Shown only where `AppPlatform.usesDesktopWorkspace` is true and the window is
/// wide enough — a phone has nowhere to put it, and taking a third of an iPad's
/// width for a list would cost more than it returns.
struct MediaBinPanel: View, Equatable {
    let assets: [ProjectMediaAsset]
    /// How many clips use each asset, counted once by the editor.
    ///
    /// This used to be asked of the view model per row, and each answer walked
    /// every item on the timeline — so a project with two dozen sources paid
    /// that cost two dozen times over, on every rebuild.
    let usageCounts: [UUID: Int]
    /// Decoded first frames, already loaded by the editor for the timeline's
    /// filmstrips. Reused rather than decoded a second time.
    let assetFrames: [UUID: [UIImage]]
    let isEnabled: Bool
    /// Opens the file browser. One entry point for all three kinds, because the
    /// file itself says which it is.
    let onImport: () -> Void
    let onPlace: (UUID, EditorViewModel.MediaPlacement) -> Void
    let onImportFiles: ([URL]) -> Void
    @State private var selection: UUID?
    @State private var isDropTarget = false

    /// Compared on its data alone.
    ///
    /// The bin held the view model and so rebuilt every time anything on it
    /// published — which includes the playhead, sixty times a second during
    /// playback, and every step of a divider drag. Now it takes values, and
    /// `.equatable()` at the call site means a rebuild only happens when the
    /// media actually changed.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.assets == rhs.assets
            && lhs.usageCounts == rhs.usageCounts
            && lhs.isEnabled == rhs.isEnabled
            // Thumbnails only ever arrive, so a count is enough to notice one.
            && lhs.assetFrames.count == rhs.assetFrames.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(AppColors.border)
            if assets.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(assets) { asset in
                            row(asset)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
            }
            Divider().overlay(AppColors.border)
            importBar
        }
        .background(AppColors.surface)
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(AppColors.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        // Files dragged in from the Finder land in the bin, which is where
        // someone dropping a folder of rushes expects them — not on the
        // timeline, and not one dialog at a time.
        .dropDestination(for: URL.self) { urls, _ in
            guard isEnabled, !urls.isEmpty else { return false }
            onImportFiles(urls)
            return true
        } isTargeted: { isDropTarget = $0 && isEnabled }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.full").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColors.accent)
            Text("Media").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppColors.textPrimary)
            Spacer(minLength: 0)
            Text("\(assets.count)").font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(AppColors.textSecondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Media, \(assets.count) items")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Image(systemName: "tray").font(.system(size: 26, weight: .light))
                .foregroundStyle(AppColors.textSecondary.opacity(0.6))
            Text("Nothing imported yet").font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppColors.textSecondary)
            Text("Drop video, photos and audio here, or use Import Media. Then drag one onto the canvas or the timeline.")
                .font(.system(size: 11)).foregroundStyle(AppColors.textSecondary.opacity(0.75))
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ asset: ProjectMediaAsset) -> some View {
        let selected = selection == asset.id
        let uses = usageCounts[asset.id] ?? 0
        return HStack(spacing: 9) {
            thumbnail(asset)
            VStack(alignment: .leading, spacing: 2) {
                Text(MediaBinEntry.name(of: asset))
                    .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(AppColors.textPrimary)
                HStack(spacing: 5) {
                    Text(MediaBinEntry.kind(of: asset))
                    if let detail = MediaBinEntry.detail(of: asset) {
                        Text("·"); Text(detail)
                    }
                    if uses > 0 {
                        Text("·")
                        // Reads as "in the edit" rather than a bare number, so a
                        // source that was imported and never used is obvious.
                        Text("\(uses)×").foregroundStyle(AppColors.accent)
                    }
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(1)
                // A photo's pixel dimensions are the longest thing that can
                // appear here and were truncating at the bin's default width.
                // Shrinking the line beats hiding the number.
                .minimumScaleFactor(0.75)
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            Button { place(asset, as: .mainTrack) } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(AppColors.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .foregroundStyle(AppColors.accent)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .help("Add to the timeline")
            .accessibilityLabel("Add \(MediaBinEntry.name(of: asset)) to the timeline")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(selected ? AppColors.accent.opacity(0.14) : AppColors.surfaceRaised,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? AppColors.accent.opacity(0.5) : .clear, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        // The two-click gesture is attached first deliberately: SwiftUI gives
        // the earlier one the chance to claim the pair, and with the single
        // tap first a double click only ever reads as two selections.
        //
        // Double-click is how a desktop list opens the thing under the pointer,
        // and the + button covers anyone who would rather not know that.
        .onTapGesture(count: 2) { place(asset, as: .mainTrack) }
        .onTapGesture { selection = asset.id }
        .contextMenu { menu(asset) }
        // The payload is the asset's id. The timeline resolves it against the
        // project, so a stale drag from a closed project cannot place anything.
        .draggable(MediaBinEntry.dragIdentifier(asset.id)) {
            dragPreview(asset)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func menu(_ asset: ProjectMediaAsset) -> some View {
        Button("Add to Timeline", systemImage: "plus.rectangle") { place(asset, as: .mainTrack) }
        Button("Add as Overlay", systemImage: "square.2.layers.3d") { place(asset, as: .overlay) }
        Divider()
        Button("Reveal in Finder", systemImage: "folder") {
            MediaBinEntry.reveal(asset.url)
        }
    }

    private func thumbnail(_ asset: ProjectMediaAsset) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(AppColors.editorBackground)
            if let image = assetFrames[asset.id]?.first {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: MediaBinEntry.symbol(of: asset))
                    .font(.system(size: 13))
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
        .frame(width: 46, height: 28)
        .accessibilityHidden(true)
    }

    private func dragPreview(_ asset: ProjectMediaAsset) -> some View {
        HStack(spacing: 6) {
            thumbnail(asset)
            Text(MediaBinEntry.name(of: asset)).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .padding(6)
        .background(AppColors.surfaceRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// One button, not one per kind. Choosing between Video, Photo and Audio
    /// before the file browser opens is a question the file already answers,
    /// and the browser can show all three at once.
    private var importBar: some View {
        Button(action: onImport) {
            Label("Import Media", systemImage: "plus")
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity).frame(height: 34)
                .background(AppColors.accent.opacity(isEnabled ? 0.18 : 0.08),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(isEnabled ? AppColors.accent : AppColors.textSecondary)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .help("Import video, photos or audio")
    }

    private func place(_ asset: ProjectMediaAsset, as placement: EditorViewModel.MediaPlacement) {
        guard isEnabled else { return }
        selection = asset.id
        onPlace(asset.id, placement)
    }
}

/// How an asset describes itself in the bin, and the drag payload the timeline
/// reads back. Kept out of the view so the timeline's drop can use the same
/// encoding without importing the panel.
enum MediaBinEntry {
    /// Prefixed so a text drag from somewhere else in the system — a file name,
    /// a snippet — can never be mistaken for a placeable asset.
    private static let dragPrefix = "gradelab.asset:"

    static func dragIdentifier(_ id: UUID) -> String { dragPrefix + id.uuidString }

    static func assetID(fromDrag payload: String) -> UUID? {
        guard payload.hasPrefix(dragPrefix) else { return nil }
        return UUID(uuidString: String(payload.dropFirst(dragPrefix.count)))
    }

    static func name(of asset: ProjectMediaAsset) -> String {
        if let audio = asset.audioName, !audio.isEmpty { return audio }
        return asset.url.deletingPathExtension().lastPathComponent
    }

    static func kind(of asset: ProjectMediaAsset) -> String {
        if asset.audioName != nil { return String(localized: "Audio") }
        if asset.stillImage != nil { return String(localized: "Photo") }
        return String(localized: "Video")
    }

    static func symbol(of asset: ProjectMediaAsset) -> String {
        if asset.audioName != nil { return "waveform" }
        if asset.stillImage != nil { return "photo" }
        return "film"
    }

    /// The one measurement that matters per kind: pixels for a still, length for
    /// anything that plays.
    static func detail(of asset: ProjectMediaAsset) -> String? {
        if let still = asset.stillImage { return "\(still.width)×\(still.height)" }
        let seconds = asset.sourceRange.duration.seconds
        guard seconds.isFinite, seconds > 0 else { return nil }
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    static func reveal(_ url: URL) {
        // Catalyst routes this to the Finder; elsewhere it opens the Files app
        // at the item, which is the closest equivalent the platform has.
        UIApplication.shared.open(url.deletingLastPathComponent())
    }
}

/// Collects URLs from the several concurrent `NSItemProvider` loads one drop
/// produces. `NSItemProvider` calls back on its own queue, so the array needs a
/// lock rather than being appended to from the drop handler directly.
final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    var urls: [URL] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func append(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        storage.append(url)
    }
}
