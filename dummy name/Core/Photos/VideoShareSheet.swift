import SwiftUI
import UIKit

/// Presents the native activity controller for an exported file.
///
/// Named for video because that is what it was built for; it has always been a
/// file URL and nothing about it is video-specific, so the still-image export
/// shares through the same sheet rather than through a second copy of it.
struct VideoShareSheet: UIViewControllerRepresentable {
    let videoURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: [videoURL],
            applicationActivities: nil
        )
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}
