import SwiftUI
import UIKit

/// A workspace preference, never a project or grading setting.
enum PhoneColorLayout: String, CaseIterable, Identifiable {
    case compact, classic

    static let preferenceKey = "editor.phoneColorLayout"
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

    /// Height here excludes the host's project header and safe areas. Reserve
    /// the controls and navigation before offering the remaining room to the
    /// picture, including when scopes are open or a warm-up notice is visible.
    static func previewHeight(height: CGFloat, scopeHeight: CGFloat,
                              transportHeight: CGFloat, footerHeight: CGFloat,
                              isExpanded: Bool) -> CGFloat {
        let available = max(0, height - scopeHeight - transportHeight - footerHeight)
        let ceiling = max(0, available - min(minimumControls, available * 0.65))
        let wanted = isExpanded ? min(140, height * 0.23) : height * 0.46
        return min(wanted, ceiling)
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
    @ViewBuilder let preview: () -> Preview
    @ViewBuilder let scope: () -> Scope
    @ViewBuilder let transport: () -> Transport
    @ViewBuilder let controls: () -> Controls
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                preview()
                    .frame(height: PhoneColorWorkspaceBudget.previewHeight(
                        height: geometry.size.height, scopeHeight: showsScopes ? scopeHeight : 0,
                        transportHeight: transportHeight, footerHeight: footerHeight, isExpanded: isExpanded))
                if showsScopes { scope().frame(height: scopeHeight) }
                transport().fixedSize(horizontal: false, vertical: true)
                controls().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                footer().fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
