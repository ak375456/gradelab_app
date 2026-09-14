import SwiftUI
import CoreImage

/// Previews use the export renderer, not simulated SwiftUI outlines/shadows.
struct TextPresetTile: View {
    let preset: TextStylePreset
    let selected: Bool
    @State private var thumbnail: CGImage?
    private static let context = CIContext(options: [.cacheIntermediates: false])
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.09))
            if let thumbnail {
                Image(decorative: thumbnail, scale: 2).resizable().scaledToFit().padding(4)
            }
            RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.cyan : .clear, lineWidth: 2)
        }.frame(height: 64)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .task(id: preset.id) {
                var clip = TextClip(placement: .init(id: UUID(), trackID: UUID(), timelineStart: .zero, duration: .zero))
                clip.text = "Aa"; clip.style = preset.style; clip.style.fontSize = 66
                clip.color = preset.color; clip.strokeColor = preset.strokeColor; clip.strokeWidth = preset.strokeWidth
                clip.backgroundColor = preset.backgroundColor; clip.backgroundOpacity = preset.backgroundOpacity
                clip.gradient = preset.gradient
                clip.cornerRadius = 14; clip.decoration = .init(padding: 6)
                let canvas = CGSize(width: 152, height: 120)
                if let image = TextRenderer.image(clip, canvas: canvas) {
                    thumbnail = Self.context.createCGImage(image, from: CGRect(origin: .zero, size: canvas))
                }
            }
    }
}
