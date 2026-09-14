import PhotosUI
import SwiftUI

/// A single-selection movie picker that asks Photos for the current representation.
/// The system picker grants access to the selected item without full-library access.
struct VideoPhotosPicker<Label: View>: View {
    @Binding private var selection: PhotosPickerItem?
    private let label: Label

    init(
        selection: Binding<PhotosPickerItem?>,
        @ViewBuilder label: () -> Label
    ) {
        _selection = selection
        self.label = label()
    }

    var body: some View {
        PhotosPicker(
            selection: $selection,
            matching: .videos,
            preferredItemEncoding: .current
        ) {
            label
        }
    }
}
