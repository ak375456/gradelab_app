import SwiftUI
import UIKit

/// Uses the system save panel without reading a large movie into memory.
struct SaveFileSheet: UIViewControllerRepresentable {
    let url: URL
    var onSaved: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSaved: onSaved) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onSaved: () -> Void
        init(onSaved: @escaping () -> Void) { self.onSaved = onSaved }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if !urls.isEmpty { onSaved() }
        }
    }
}
