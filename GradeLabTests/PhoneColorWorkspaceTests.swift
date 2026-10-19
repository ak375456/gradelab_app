import SwiftUI
import XCTest
@testable import GradeLab

@MainActor
final class PhoneColorWorkspaceTests: XCTestCase {
    func testCompactPreferenceIsLimitedToIPhone() {
        XCTAssertTrue(PhoneColorLayout.usesCompact(.compact, idiom: .phone, isMac: false))
        XCTAssertFalse(PhoneColorLayout.usesCompact(.classic, idiom: .phone, isMac: false))
        for idiom in [UIUserInterfaceIdiom.pad, .mac, .unspecified] {
            XCTAssertFalse(PhoneColorLayout.usesCompact(.compact, idiom: idiom, isMac: false))
        }
        XCTAssertFalse(PhoneColorLayout.usesCompact(.compact, idiom: .phone, isMac: true))
    }

    func testClassicPreferenceSurvivesReopeningSettings() throws {
        let name = "GradeLab.PhoneColorLayoutTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = AppStorage(wrappedValue: PhoneColorLayout.compact, PhoneColorLayout.preferenceKey, store: defaults)
        XCTAssertEqual(first.wrappedValue, .compact)
        first.wrappedValue = .classic
        let reopened = AppStorage(wrappedValue: PhoneColorLayout.compact, PhoneColorLayout.preferenceKey, store: defaults)
        XCTAssertEqual(reopened.wrappedValue, .classic)
        reopened.wrappedValue = .compact
        let compact = AppStorage(wrappedValue: PhoneColorLayout.classic, PhoneColorLayout.preferenceKey, store: defaults)
        XCTAssertEqual(compact.wrappedValue, .compact)
    }

    func testDefaultBudgetKeepsControlsAndNavigationVisibleWithScopes() {
        for height in [CGFloat(603), 671, 715, 804] {
            for transport in [CGFloat(0), 44] {
                for notice in [CGFloat(0), 36] {
                    let footer: CGFloat = 52 + notice
                    let preview = PhoneColorWorkspaceBudget.previewHeight(
                        height: height, scopeHeight: ScopeLayout.compactHeight,
                        transportHeight: transport, footerHeight: footer, isExpanded: false)
                    let controls = height - preview - ScopeLayout.compactHeight - transport - footer - WorkspaceDivider.thickness
                    XCTAssertGreaterThanOrEqual(controls, 200)
                    XCTAssertGreaterThanOrEqual(preview, 100)
                    XCTAssertLessThan(preview, height)
                }
            }
        }
        XCTAssertLessThan(ScopeLayout.compactHeight, 170, "the whole scope panel, including controls, must stay compact")
    }

    func testExpandingControlsReturnsScopeAndPreviewRoomToTheTool() {
        let height: CGFloat = 715
        let normal = PhoneColorWorkspaceBudget.previewHeight(
            height: height, scopeHeight: ScopeLayout.compactHeight, transportHeight: 44,
            footerHeight: 52, isExpanded: false)
        let expanded = PhoneColorWorkspaceBudget.previewHeight(
            height: height, scopeHeight: 0, transportHeight: 44, footerHeight: 52, isExpanded: true)
        XCTAssertLessThan(expanded, normal)
        XCTAssertGreaterThan(height - expanded - 44 - 52 - WorkspaceDivider.thickness, 400)
    }

    func testRememberedPreviewProportionsClampWhenScopesAndScreenSizeChange() {
        for height in [CGFloat(603), 715, 804] {
            for scope in [CGFloat(0), ScopeLayout.compactHeight] {
                for fraction in [0.01, 0.4, 0.7, 1.5, Double.nan] {
                    let available = PhoneColorWorkspaceBudget.movableHeight(
                        height: height, scopeHeight: scope, transportHeight: 44, footerHeight: 52)
                    let range = PhoneColorWorkspaceBudget.previewRange(available: available)
                    let preview = PhoneColorWorkspaceBudget.previewHeight(
                        height: height, scopeHeight: scope, transportHeight: 44, footerHeight: 52,
                        isExpanded: true, preferredFraction: fraction)
                    XCTAssertTrue(preview.isFinite)
                    XCTAssertTrue(range.contains(preview))
                    XCTAssertGreaterThanOrEqual(available - preview, PhoneColorWorkspaceBudget.minimumControls)
                }
            }
        }
        let enlarged = PhoneColorWorkspaceBudget.previewHeight(
            height: 715, scopeHeight: 0, transportHeight: 44, footerHeight: 52,
            isExpanded: true, preferredFraction: 0.6)
        XCTAssertGreaterThan(enlarged, 350, "an expanded single slider must let the user reclaim room for the viewer")
    }

    func testCompactSizingPreferencesStaySeparateFromEachOtherAndClassic() throws {
        let name = "GradeLab.PhoneColorSizingTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(310.0, forKey: "editor.previewHeight")
        let normal = AppStorage(wrappedValue: 0.0, PhoneColorWorkspaceBudget.previewFractionKey, store: defaults)
        let expanded = AppStorage(wrappedValue: 0.0, PhoneColorWorkspaceBudget.expandedPreviewFractionKey, store: defaults)
        normal.wrappedValue = 0.55
        expanded.wrappedValue = 0.38
        let reopened = AppStorage(wrappedValue: 0.0, PhoneColorWorkspaceBudget.previewFractionKey, store: defaults)
        XCTAssertEqual(reopened.wrappedValue, 0.55)
        expanded.wrappedValue = 0 // double-tap reset only affects the active preset
        XCTAssertEqual(defaults.double(forKey: PhoneColorWorkspaceBudget.previewFractionKey), 0.55)
        XCTAssertEqual(defaults.double(forKey: PhoneColorWorkspaceBudget.expandedPreviewFractionKey), 0)
        XCTAssertEqual(defaults.double(forKey: "editor.previewHeight"), 310)
    }

    func testEveryAdjustmentHasADistinctAvailableSymbol() {
        let symbols = GradeParameter.allCases.map { $0.compactAppearance.symbol }
        XCTAssertEqual(Set(symbols).count, GradeParameter.allCases.count)
        for parameter in GradeParameter.allCases {
            XCTAssertNotNil(UIImage(systemName: parameter.compactAppearance.symbol), parameter.title)
        }
        for panel in GradePanel.allCases {
            XCTAssertNotNil(UIImage(systemName: panel.compactAppearance.symbol), panel.title)
        }
    }

    func testIPhone15ScopesAndExposureFitWithoutDisplacingTheFooter() throws {
        try render(size: CGSize(width: 393, height: 715), panel: .light, name: "iphone15-color-scopes")
    }

    func testSmallPhoneAndLargeTextRemainScrollable() throws {
        try render(size: CGSize(width: 320, height: 603), panel: .light,
                   textSize: .accessibility3, name: "small-phone-color-large-text")
    }

    func testExpandedCurvesKeepThePreviewAndNavigationOnScreen() throws {
        try render(size: CGSize(width: 393, height: 715), panel: .curves,
                   expanded: true, name: "iphone15-color-curves-expanded")
    }

    func testExpandedExposureCanGiveMoreRoomBackToTheViewer() throws {
        try render(size: CGSize(width: 393, height: 715), panel: .light,
                   expanded: true, preferredFraction: 0.6, name: "iphone15-color-resized-exposure")
    }

    func testTemperatureSelectorFitsSmallPhoneAndLargerText() throws {
        try render(size: CGSize(width: 320, height: 603), panel: .color,
                   textSize: .accessibility3, name: "small-phone-temperature-selector")
    }

    func testColorControlsAndScopesFitAFullWidthLandscapeInspector() throws {
        let model = try makeModel()
        let before = model.project
        let panel = GradingControls(model: model, usesCompactLayout: true)
        try host(panel, size: CGSize(width: 320, height: 280), name: "phone-landscape-color") { view in
            try self.assertNoHorizontalOverflow(view)
        }
        XCTAssertEqual(model.project, before)
    }

    func testChangingTheLayoutPreservesTheGradeAndItsSingleUndoEntry() throws {
        let model = try makeModel()
        model.gradeBinding(.gradeExposure).wrappedValue = 0.7
        model.flushGradeHistory()
        let before = model.project
        let historyCount = model.history.undoEntries.count
        for compact in [true, false] {
            try host(GradingControls(model: model, usesCompactLayout: compact),
                     size: CGSize(width: 393, height: 320), name: compact ? "color-compact" : "color-classic") { view in
                if compact { try self.assertNoHorizontalOverflow(view) }
            }
        }
        XCTAssertEqual(model.project, before)
        XCTAssertEqual(model.history.undoEntries.count, historyCount)
        model.undo()
        XCTAssertEqual(model.gradeBinding(.gradeExposure).wrappedValue, 0, accuracy: 0.001)
    }

    func testPhotoUsesTheSameCompactControlsWithoutChangingItsEdits() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("phone-color-photo-\(UUID()).png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 48)).image { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
        }
        try XCTUnwrap(image.pngData()).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let project = ImageProject(displayName: "Color photo", asset: .init(id: UUID(), url: url,
                                                                          metadata: try ImageMetadataReader.read(url: url)))
        let model = try ImageEditorViewModel(project: project)
        let panel = GradingControls(model: model, usesCompactLayout: true, onToggleExpanded: {})
        try host(panel, size: CGSize(width: 393, height: 300), name: "photo-compact-color") { view in
            try self.assertNoHorizontalOverflow(view)
        }
        XCTAssertEqual(model.project, project)
        XCTAssertFalse(model.canUndo)
    }

    func testLayoutSettingFitsPhoneWidth() throws {
        let view = NavigationStack {
            Form { PhoneColorLayoutSettings() }.navigationTitle("Settings")
        }.preferredColorScheme(.dark)
        try host(view, size: CGSize(width: 393, height: 350), name: "phone-color-layout-setting") { view in
            try self.assertNoHorizontalOverflow(view)
        }
    }

    func testExpandedScopeFitsWithTheSameFullSizeMenuControls() throws {
        let model = try makeModel()
        let savedScopes = model.scopeSettings
        model.setScopesEnabled(true)
        defer { savedScopes.save() }
        let panel = ScopePanel(model: model, isRegularWidth: false, traceHeight: 340,
                               usesCompactLayout: true, canExpand: false)
        try host(panel.preferredColorScheme(.dark), size: CGSize(width: 393, height: 404),
                 name: "phone-expanded-scope") { _ in }
        XCTAssertFalse(model.canUndo)
    }

    private func makeModel() throws -> EditorViewModel {
        let project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/phone-color-layout.mov"),
                                   displayName: "Color layout", metadata: makeVideoMetadata(durationSeconds: 10))
        let model = try EditorViewModel(project: project)
        model.suspendPreviewForExport()
        return model
    }

    private final class Measurements {
        var frames: [String: CGRect] = [:]
    }

    private func render(size: CGSize, panel: GradePanel, textSize: DynamicTypeSize = .large,
                        expanded: Bool = false, preferredFraction: Double = 0, name: String) throws {
        let model = try makeModel()
        model.selectedPanel = panel
        let savedScopes = model.scopeSettings
        model.setScopesEnabled(true)
        defer { savedScopes.save() }
        let before = model.project
        let measurements = Measurements()
        func measure<V: View>(_ view: V, _ name: String) -> some View {
            view.onGeometryChange(for: CGRect.self) { $0.frame(in: .named("phoneColor")) } action: {
                measurements.frames[name] = $0
            }
        }
        let root = PhoneColorWorkspace(
            showsScopes: !expanded, isExpanded: expanded, scopeHeight: ScopeLayout.compactHeight,
            transportHeight: 44, footerHeight: 52,
            preview: {
                measure(ZStack {
                    AppColors.surfaceRaised
                    VStack { Spacer(); Text("Preview").foregroundStyle(AppColors.textSecondary); Spacer()
                        HStack { Text("Fit"); Spacer(); Text("Compare") }.font(.caption)
                            .padding(.horizontal, 12).frame(height: 44).background(.black)
                    }
                }, "preview")
            },
            scope: {
                measure(ScopePanel(model: model, isRegularWidth: false, usesCompactLayout: true), "scope")
            },
            transport: {
                measure(HStack {
                    Image(systemName: "play.fill")
                    Spacer(); Text("00:00:00:00 / 00:00:10:00").font(.caption.monospacedDigit()); Spacer()
                }.padding(.horizontal, 16).frame(height: 44), "transport")
            },
            controls: {
                measure(GradingControls(model: model, usesCompactLayout: true,
                                        isExpanded: expanded, onToggleExpanded: {}), "controls")
            },
            footer: {
                measure(HStack {
                    Text("Timeline"); Spacer(); Text("Color").foregroundStyle(AppColors.accent)
                    Spacer(); Text("Mask"); Spacer(); Text("Speed")
                }.font(.caption).padding(.horizontal, 16).frame(height: 52), "footer")
            })
            .coordinateSpace(name: "phoneColor")
            .environment(\.dynamicTypeSize, textSize)
            .background(AppColors.background).foregroundStyle(AppColors.textPrimary)
            .preferredColorScheme(.dark).buttonStyle(.plain)
        try host(root, size: size, name: name, previewFraction: preferredFraction) { view in
            let footer = try XCTUnwrap(measurements.frames["footer"])
            let controls = try XCTUnwrap(measurements.frames["controls"])
            let preview = try XCTUnwrap(measurements.frames["preview"])
            XCTAssertLessThanOrEqual(footer.maxY, size.height + 1)
            XCTAssertGreaterThanOrEqual(footer.minY, controls.maxY - 1)
            XCTAssertGreaterThanOrEqual(controls.height, 200)
            XCTAssertGreaterThan(preview.height, 80)
            if preferredFraction == 0.6 {
                XCTAssertGreaterThan(preview.height, 350)
            }
            if !expanded {
                XCTAssertEqual(try XCTUnwrap(measurements.frames["scope"]).height,
                               ScopeLayout.compactHeight, accuracy: 1)
            }
            try self.assertNoHorizontalOverflow(view)
        }
        XCTAssertEqual(model.project, before, "rearranging controls must not change the grade or timeline")
        XCTAssertFalse(model.canUndo)
    }

    private func assertNoHorizontalOverflow(_ view: UIView) throws {
        func scrollViews(_ view: UIView) -> [UIScrollView] {
            (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        let scrolls = scrollViews(view)
        XCTAssertFalse(scrolls.isEmpty)
        // Curves and wheels contain intentional horizontal selectors inside
        // the vertical inspector. Check the inspector's viewport itself.
        for scroll in scrolls.prefix(1) {
            XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
        }
    }

    private func host<V: View>(_ root: V, size: CGSize, name: String,
                               previewFraction: Double = 0,
                               check: (UIView) throws -> Void) throws {
        let domain = "GradeLab.PhoneColorRenderTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(previewFraction, forKey: PhoneColorWorkspaceBudget.previewFractionKey)
        defaults.set(previewFraction, forKey: PhoneColorWorkspaceBudget.expandedPreviewFractionKey)
        let controller = UIHostingController(rootView: root.defaultAppStorage(defaults)
            .frame(width: size.width, height: size.height).ignoresSafeArea())
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.frame = window.bounds
        window.layoutIfNeeded()
        let end = Date().addingTimeInterval(0.3)
        while Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        controller.view.layoutIfNeeded()
        try check(controller.view)
        let image = UIGraphicsImageRenderer(size: size).image { controller.view.layer.render(in: $0.cgContext) }
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(name).png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("PHONE_COLOR_SHOT \(url.path)")
    }
}
