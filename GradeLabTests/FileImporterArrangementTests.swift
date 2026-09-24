import XCTest
import SwiftUI
import UniformTypeIdentifiers
@testable import GradeLab

/// Every `present` a view asks for, recorded and swallowed, so a test can ask
/// whether a file browser was opened without one appearing on screen.
private enum PresentationRecorder {
    static var records: [String] = []

    static func install() { exchange() }
    static func remove() { exchange() }

    private static func exchange() {
        let original = class_getInstanceMethod(
            UIViewController.self, #selector(UIViewController.present(_:animated:completion:)))!
        let replacement = class_getInstanceMethod(
            UIViewController.self, #selector(UIViewController.recorded_present(_:animated:completion:)))!
        method_exchangeImplementations(original, replacement)
    }
}

extension UIViewController {
    @objc fileprivate func recorded_present(_ controller: UIViewController,
                                            animated: Bool,
                                            completion: (() -> Void)?) {
        PresentationRecorder.records.append(String(describing: type(of: controller)))
    }
}

/// A screen may install only one `fileImporter` above its content.
///
/// SwiftUI presents the **outermost** `fileImporter` in a hosting controller's
/// view tree and no other: a second one below it never opens, whether it is
/// chained onto the same view or attached inside a child view, and whether or
/// not the outer one's binding is ever set. Measured on Mac Catalyst and on
/// iOS. `EditorView` had three — the media bin's, audio's, and the one inside
/// `MediaImportPicker` — so Import Media and Add audio from Files opened
/// nothing at all, while the tool panels' own importers for fonts and `.cube`
/// looks were shadowed too.
///
/// The arrangement that gets all of them back is one browser for the screen,
/// carried beside the content by `sideFileImporter` rather than above it. This
/// reproduces it and checks each part still opens.
@MainActor
final class FileImporterArrangementTests: XCTestCase {
    final class Flags: ObservableObject {
        @Published var screen = false
        @Published var photos = false
        @Published var panel = false
    }

    /// `EditorView`'s shape: a screen browser on its own branch, a Photos
    /// picker, the sheets and dialogs, and a tool panel with an importer of its
    /// own inside the content.
    struct Screen: View {
        @ObservedObject var flags: Flags

        var body: some View {
            VStack {
                Color.black.frame(width: 400, height: 300)
                // Stands in for the font and look importers in the tool panels.
                Color.gray.frame(width: 100, height: 40)
                    .fileImporter(isPresented: $flags.panel, allowedContentTypes: [.font]) { _ in }
            }
            .sheet(isPresented: .constant(false)) { Text("Layers") }
            .confirmationDialog("Reset", isPresented: .constant(false)) { Button("Reset") {} }
            .alert("Edit unavailable", isPresented: .constant(false)) { Button("OK") {} }
            .sideFileImporter(isPresented: $flags.screen,
                              allowedContentTypes: [.movie, .image, .audio],
                              allowsMultipleSelection: true) { _ in }
            .modifier(PhotoImportPicker(isPresented: $flags.photos, onSelection: { _ in }))
        }
    }

    private var window: UIWindow?

    override func setUp() { PresentationRecorder.install() }

    override func tearDown() async throws {
        PresentationRecorder.remove()
        window?.isHidden = true
        window = nil
    }

    func testTheScreensOwnBrowserOpens() {
        XCTAssertEqual(presentations { $0.screen = true }, ["UIDocumentPickerViewController"],
                       "the media bin's Import Media button opens this one")
    }

    func testAPanelInsideTheScreenKeepsItsOwnBrowser() {
        XCTAssertEqual(presentations { $0.panel = true }, ["UIDocumentPickerViewController"],
                       "a font or .cube import must not be shadowed by the screen's browser")
    }

    func testThePhotosPickerStillOpensBesideIt() {
        XCTAssertFalse(presentations { $0.photos = true }.isEmpty,
                       "Photos is how video and stills are chosen off Mac")
    }

    // MARK: - Harness

    private func presentations(_ trigger: (Flags) -> Void) -> [String] {
        PresentationRecorder.records = []
        let flags = Flags()
        let controller = UIHostingController(rootView: Screen(flags: flags))
        let frame = CGRect(x: 0, y: 0, width: 600, height: 500)
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        self.window = window

        pump(0.5)
        trigger(flags)
        pump(1.2)
        return PresentationRecorder.records
    }

    private func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }
}
