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
}

/// Both sources enter the same validation and project-creation pipeline.
enum MediaImportSource: Equatable {
    case photos(PhotosPickerItem)
    case file(URL)
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
    @State private var photoItems: [PhotosPickerItem] = []

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
            .photosPicker(isPresented: presentation(files: false), selection: $photoItems,
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
