import SwiftUI
import UIKit

/// Layout decisions use the current window, including an unfolded phone. Keep
/// platform-specific Mac surfaces and the existing iPad layout separate.
enum AdaptiveWorkspaceLayout {
    static func hasExpandedPhoneSpace(horizontal: UserInterfaceSizeClass?, vertical: UserInterfaceSizeClass?) -> Bool {
        horizontal == .regular && vertical == .regular
    }

    static func budgetSize(_ size: CGSize, headerHeight: CGFloat, budgetedHeader: CGFloat = 44) -> CGSize {
        CGSize(width: size.width, height: max(0, size.height - max(0, headerHeight - budgetedHeader)))
    }

    static func usesColumns(size: CGSize, horizontalSizeClass: UserInterfaceSizeClass?,
                            idiom: UIUserInterfaceIdiom, isMac: Bool) -> Bool {
        // Portrait keeps the full-width canvas, as on iPad. A regular width
        // alone is not enough room for a useful picture beside the inspector.
        return size.width > size.height
    }
}

/// Only the header must avoid a corner camera/status region. The picture and
/// controls below it can use the full width instead of losing an entire column.
struct WorkspaceHeaderClearance: Equatable {
    var leading: CGFloat = 0
    var trailing: CGFloat = 0
    var height: CGFloat = 0
    var isActive: Bool { height > 0 }

    static func resolve(size: CGSize, occlusions: [CGRect],
                        layoutDirection: LayoutDirection = .leftToRight) -> Self {
        let bounds = CGRect(origin: .zero, size: size)
        let regions = occlusions.map { $0.intersection(bounds) }.filter { !$0.isEmpty && !$0.isNull }
        guard !regions.isEmpty else { return .init() }
        // A region extending down a whole edge cannot be reclaimed by moving
        // one header. Leave ordinary safe-area handling in charge in that case.
        guard regions.allSatisfy({ $0.maxY <= min(180, size.height * 0.3)
            && ($0.maxX <= size.width * 0.3 || $0.minX >= size.width * 0.7) }) else { return .init() }
        var left: CGFloat = 0
        var right: CGFloat = 0
        for region in regions {
            if region.midX < size.width / 2 { left = max(left, region.maxX) }
            else { right = max(right, size.width - region.minX) }
        }
        return .init(leading: layoutDirection == .leftToRight ? left : right,
                     trailing: layoutDirection == .leftToRight ? right : left,
                     height: regions.map(\.maxY).max() ?? 0)
    }
}

private struct WorkspaceHeaderClearanceKey: EnvironmentKey {
    static let defaultValue = WorkspaceHeaderClearance()
}

extension EnvironmentValues {
    var workspaceHeaderClearance: WorkspaceHeaderClearance {
        get { self[WorkspaceHeaderClearanceKey.self] }
        set { self[WorkspaceHeaderClearanceKey.self] = newValue }
    }
}

private struct AdaptivePhoneWorkspace: ViewModifier {
    @Environment(\.layoutDirection) private var layoutDirection

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content
        #else
        if #available(iOS 27.1, *) {
            GeometryReader { safeGeometry in
                let canAdapt = !AppPlatform.isMac && UIDevice.current.userInterfaceIdiom == .phone
                GeometryReader { geometry in
                    let occlusions = geometry.reservedRegions(kind: .occlusion, layoutDirectionBehavior: .fixed)
                        .map { region in
                            let margins = region.margins
                            let left = layoutDirection == .leftToRight ? margins.leading : margins.trailing
                            let right = layoutDirection == .leftToRight ? margins.trailing : margins.leading
                            return CGRect(x: region.frame.minX - left, y: region.frame.minY - margins.top,
                                          width: region.frame.width + left + right,
                                          height: region.frame.height + margins.top + margins.bottom)
                        }
                    let clearance = canAdapt ? WorkspaceHeaderClearance.resolve(
                        size: geometry.size, occlusions: occlusions, layoutDirection: layoutDirection) : .init()
                    content
                        .environment(\.workspaceHeaderClearance, clearance)
                        .padding(.leading, canAdapt && !clearance.isActive ? safeGeometry.safeAreaInsets.leading : 0)
                        .padding(.trailing, canAdapt && !clearance.isActive ? safeGeometry.safeAreaInsets.trailing : 0)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .ignoresSafeArea(.container, edges: canAdapt ? .horizontal : [])
            }
        } else {
            content
        }
        #endif
    }
}

private struct ReservedRegionHeader: ViewModifier {
    @Environment(\.workspaceHeaderClearance) private var clearance

    func body(content: Content) -> some View {
        content
            .padding(.leading, clearance.leading)
            .padding(.trailing, clearance.trailing)
            .frame(minHeight: clearance.height, alignment: .top)
    }
}

extension View {
    func adaptivePhoneWorkspace() -> some View { modifier(AdaptivePhoneWorkspace()) }
    func reservedRegionHeader() -> some View { modifier(ReservedRegionHeader()) }
}
