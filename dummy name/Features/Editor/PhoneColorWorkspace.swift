import SwiftUI
import UIKit

/// A workspace preference, never a project or grading setting.
enum PhoneColorLayout: String, CaseIterable, Identifiable {
    case compact, classic

    static let preferenceKey = "editor.phoneColorLayout"
    static let introductionSeenKey = "editor.phoneColorLayout.introductionSeen"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: String(localized: "Compact")
        case .classic: String(localized: "Classic")
        }
    }

    static func usesCompact(_ layout: Self, idiom: UIUserInterfaceIdiom, isMac: Bool) -> Bool {
        layout == .compact && idiom == .phone && !isMac
    }

    var isActiveOnThisDevice: Bool {
        Self.usesCompact(self, idiom: UIDevice.current.userInterfaceIdiom, isMac: AppPlatform.isMac)
    }
}

/// One acknowledgment per installation, shared by photo and video editors.
/// The host waits for a usable Compact workspace with no other presentation.
private struct PhoneColorLayoutIntroduction: ViewModifier {
    let isActive: Bool
    let canPresent: Bool
    let settingsMenuTitle: String
    let onOpenSettings: () -> Void
    @AppStorage(PhoneColorLayout.introductionSeenKey) private var hasSeenIntroduction = false
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content.background {
            // Own presentation branch so this alert does not replace the
            // editor's error alert or its sheets.
            Color.clear
                .alert("New Compact Color layout", isPresented: $isPresented) {
                    Button("Open Settings") {
                        hasSeenIntroduction = true
                        onOpenSettings()
                    }
                    Button("Got it", role: .cancel) { hasSeenIntroduction = true }
                } message: {
                    Text("You can switch between Compact and Classic anytime. Open the ••• menu at the top of the editor → \(settingsMenuTitle) → iPhone Color workspace.")
                }
                .onChange(of: isActive && canPresent && !hasSeenIntroduction, initial: true) { _, ready in
                    isPresented = ready
                }
        }
    }
}

extension View {
    func phoneColorLayoutIntroduction(isActive: Bool, canPresent: Bool,
                                      settingsMenuTitle: String,
                                      onOpenSettings: @escaping () -> Void) -> some View {
        modifier(PhoneColorLayoutIntroduction(isActive: isActive, canPresent: canPresent,
                                             settingsMenuTitle: settingsMenuTitle, onOpenSettings: onOpenSettings))
    }
}

struct PhoneColorLayoutSettings: View {
    @AppStorage(PhoneColorLayout.preferenceKey) private var layout = PhoneColorLayout.compact

    var body: some View {
        Section {
            Picker("Color workspace", selection: $layout) {
                ForEach(PhoneColorLayout.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.phoneColorLayout")
        } header: {
            Text("iPhone Color workspace")
        } footer: {
            Text("Compact keeps scopes small and gives the active adjustment more room. Classic uses the original layout. Applies to video and photo Color tools on iPhone.")
        }
    }
}

enum PhoneColorWorkspaceBudget {
    static let minimumControls: CGFloat = 220
    static let minimumPreview: CGFloat = 120
    static let previewFractionKey = "editor.phoneColor.previewFraction"
    static let expandedPreviewFractionKey = "editor.phoneColor.expandedPreviewFraction"

    static func movableHeight(height: CGFloat, scopeHeight: CGFloat,
                              transportHeight: CGFloat, footerHeight: CGFloat) -> CGFloat {
        max(0, height - scopeHeight - transportHeight - footerHeight - WorkspaceDivider.thickness)
    }

    static func previewRange(available: CGFloat) -> ClosedRange<CGFloat> {
        let ceiling = max(0, available - min(minimumControls, available * 0.65))
        return min(minimumPreview, ceiling)...ceiling
    }

    /// Height here excludes the host's project header and safe areas. Reserve
    /// the controls and navigation before offering the remaining room to the
    /// picture, including when scopes are open or a warm-up notice is visible.
    static func previewHeight(height: CGFloat, scopeHeight: CGFloat,
                              transportHeight: CGFloat, footerHeight: CGFloat,
                              isExpanded: Bool, preferredFraction: Double = 0) -> CGFloat {
        let available = movableHeight(height: height, scopeHeight: scopeHeight,
                                      transportHeight: transportHeight, footerHeight: footerHeight)
        let wanted: CGFloat
        if preferredFraction.isFinite && preferredFraction > 0 {
            wanted = available * CGFloat(preferredFraction)
        } else {
            wanted = isExpanded ? min(180, height * 0.28) : height * 0.46
        }
        let range = previewRange(available: available)
        return min(max(wanted, range.lowerBound), range.upperBound)
    }
}

/// Used only by the new portrait iPhone Color workspace. The host supplies its
/// existing preview, transport and navigation; this view changes their spacing,
/// not their actions or the image's inspection zoom.
struct PhoneColorWorkspace<Preview: View, Scope: View, Transport: View, Controls: View, Footer: View>: View {
    let showsScopes: Bool
    let isExpanded: Bool
    let scopeHeight: CGFloat
    let transportHeight: CGFloat
    let footerHeight: CGFloat
    var onResizeBegin: () -> Void = {}
    var onResizeEnd: () -> Void = {}
    @ViewBuilder let preview: () -> Preview
    @ViewBuilder let scope: () -> Scope
    @ViewBuilder let transport: () -> Transport
    @ViewBuilder let controls: () -> Controls
    @ViewBuilder let footer: () -> Footer

    @AppStorage(PhoneColorWorkspaceBudget.previewFractionKey) private var previewFraction = 0.0
    @AppStorage(PhoneColorWorkspaceBudget.expandedPreviewFractionKey) private var expandedPreviewFraction = 0.0
    @State private var livePreviewHeight: CGFloat?
    @State private var isResizing = false

    var body: some View {
        GeometryReader { geometry in
            let available = PhoneColorWorkspaceBudget.movableHeight(
                height: geometry.size.height, scopeHeight: showsScopes ? scopeHeight : 0,
                transportHeight: transportHeight, footerHeight: footerHeight)
            let range = PhoneColorWorkspaceBudget.previewRange(available: available)
            let automaticOrStored = PhoneColorWorkspaceBudget.previewHeight(
                height: geometry.size.height, scopeHeight: showsScopes ? scopeHeight : 0,
                transportHeight: transportHeight, footerHeight: footerHeight,
                isExpanded: isExpanded, preferredFraction: isExpanded ? expandedPreviewFraction : previewFraction)
            VStack(spacing: 0) {
                preview()
                    .frame(height: min(max(livePreviewHeight ?? automaticOrStored, range.lowerBound), range.upperBound))
                WorkspaceDivider(
                    orientation: .horizontal, label: String(localized: "Resize the Color preview"),
                    onResize: { delta in
                        livePreviewHeight = min(max((livePreviewHeight ?? automaticOrStored) + delta,
                                                    range.lowerBound), range.upperBound)
                    },
                    onBegin: {
                        isResizing = true
                        onResizeBegin()
                    },
                    onEnd: { finishResize(available: available) },
                    onReset: {
                        livePreviewHeight = nil
                        if isExpanded { expandedPreviewFraction = 0 } else { previewFraction = 0 }
                    })
                    .accessibilityIdentifier("color.previewDivider")
                if showsScopes { scope().frame(height: scopeHeight) }
                transport().fixedSize(horizontal: false, vertical: true)
                controls().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                footer().fixedSize(horizontal: false, vertical: true)
            }
            .onDisappear { finishResize(available: available) }
        }
    }

    private func finishResize(available: CGFloat) {
        guard isResizing else { return }
        if let livePreviewHeight, available > 0 {
            // Keep drag frames transient and remember one proportional size at
            // the end. Compact never writes Classic's pane sizes or grade history.
            let fraction = Double(livePreviewHeight / available)
            if isExpanded { expandedPreviewFraction = fraction } else { previewFraction = fraction }
        }
        livePreviewHeight = nil
        isResizing = false
        onResizeEnd()
    }
}
