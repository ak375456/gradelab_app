import Foundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum AppPlatform {
    static var isMac: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        ProcessInfo.processInfo.isiOSAppOnMac
        #endif
    }

    /// Room for a desktop-shaped layout: a timeline that stays visible beside a
    /// tool panel, transport actions laid out instead of folded into a menu.
    ///
    /// **This is about screen size, not about the platform.** It is true on
    /// iPad, so it must never gate anything that belongs to the Mac — a media
    /// bin, a keyboard-shortcut menu, a pointer-sized hit target. Those gate on
    /// `isMac`. Getting this wrong put the whole Mac workspace on iPad.
    static var usesDesktopWorkspace: Bool {
        isMac || UIDevice.current.userInterfaceIdiom == .pad
    }

    /// Hardware-keyboard commands are useful on Mac and iPad. An iPad receives
    /// the same key events from a paired Bluetooth/Magic Keyboard and from a
    /// Mac keyboard routed through Universal Control, so this must not be gated
    /// by `isMac` even though pointer-sized desktop chrome still is.
    static var supportsWorkspaceShortcuts: Bool {
        isMac || UIDevice.current.userInterfaceIdiom == .pad
    }
}

/// Both sources enter the same validation and project-creation pipeline.
enum MediaImportSource: Equatable {
    case photos(PhotosPickerItem)
    case file(URL)
}

extension View {
    /// A file browser carried on a branch of its own, beside the content
    /// rather than above it.
    ///
    /// SwiftUI presents only the **outermost** `fileImporter` in a hosting
    /// controller's view tree. A second one anywhere below it never opens —
    /// chained onto the same view, or attached inside a child view, and whether
    /// or not the outer one's binding is ever set. Measured on a Mac Catalyst
    /// run and on an iOS simulator: two importers on one chain, only the outer
    /// one presents; an importer inside a child view, dead as soon as an
    /// ancestor has one; two importers on sibling branches, both present with
    /// their own content types.
    ///
    /// That is what the media bin's Import Media button ran into. A screen that
    /// contains panels with importers of their own — the editor holds one for
    /// fonts and one for `.cube` looks — therefore keeps its own browser on a
    /// sibling, where it shadows nothing.
    func sideFileImporter(isPresented: Binding<Bool>,
                          allowedContentTypes: [UTType],
                          allowsMultipleSelection: Bool = false,
                          onCompletion: @escaping (Result<[URL], Error>) -> Void) -> some View {
        background {
            Color.clear
                .allowsHitTesting(false)
                .fileImporter(isPresented: isPresented,
                              allowedContentTypes: allowedContentTypes,
                              allowsMultipleSelection: allowsMultipleSelection,
                              onCompletion: onCompletion)
        }
    }
}

/// The Photos half of an import, on its own.
///
/// A screen that already installs its own `fileImporter` takes this rather than
/// `MediaImportPicker`: SwiftUI presents only the outermost `fileImporter` in a
/// chain, so a second one — even one whose binding is never set — silently
/// kills the first. `EditorView` is that screen; see the note on its importer.
struct PhotoImportPicker: ViewModifier {
    @Binding var isPresented: Bool
    var images: Bool = false
    var allowsMultipleSelection: Bool = false
    var onSelection: ([MediaImportSource]) -> Void
    @State private var photoItems: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $isPresented, selection: $photoItems,
                          maxSelectionCount: allowsMultipleSelection ? nil : 1,
                          selectionBehavior: .ordered, matching: images ? .images : .videos,
                          preferredItemEncoding: .current)
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                onSelection(items.map(MediaImportSource.photos))
                photoItems = []
            }
    }
}

/// Files on Mac, Photos on iPhone/iPad. File imports can also be requested
/// explicitly on mobile, without changing the normal Photos workflow.
struct MediaImportPicker: ViewModifier {
    @Binding var isPresented: Bool
    var images: Bool = false
    var allowsMultipleSelection: Bool = false
    var useFiles: Bool = AppPlatform.isMac
    var onSelection: ([MediaImportSource]) -> Void
    var onFailure: (Error) -> Void

    private func presentation(files: Bool) -> Binding<Bool> {
        Binding(get: { isPresented && useFiles == files },
                set: { if useFiles == files { isPresented = $0 } })
    }

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: presentation(files: true),
                          allowedContentTypes: images ? [.image] : [.movie],
                          allowsMultipleSelection: allowsMultipleSelection) { result in
                switch result {
                case .success(let urls):
                    if !urls.isEmpty { onSelection(urls.map(MediaImportSource.file)) }
                case .failure(let error):
                    let cocoa = error as NSError
                    if cocoa.domain != NSCocoaErrorDomain || cocoa.code != NSUserCancelledError { onFailure(error) }
                }
            }
            .modifier(PhotoImportPicker(isPresented: presentation(files: false), images: images,
                                        allowsMultipleSelection: allowsMultipleSelection,
                                        onSelection: onSelection))
    }
}
