import SwiftUI

/// Where the canvas ends and the workspace around it begins.
///
/// Editor furniture only: this line is drawn over the preview and never enters
/// a rendered or exported frame. It exists because the canvas can legitimately
/// be filled with black, and a black canvas inside a dark workspace has no
/// visible edge at all — the moment a clip is scaled down inside it, there is
/// nothing on screen that says which part of the darkness will be exported.
///
/// The rectangle is computed from the canvas aspect rather than read back from
/// the renderer, which is the same aspect fit `MetalVideoRenderer.makeVertices`
/// applies. Deriving it here means the line cannot lag a canvas change by a
/// frame, and it stays correct while the viewport is zoomed, because this view
/// sits inside the transform with the picture.
struct CanvasEdgeOverlay: View {
    let canvas: ProjectCanvas

    var body: some View {
        GeometryReader { proxy in
            let rect = Self.fitted(canvas, in: proxy.size)
            // Two strokes, dark under light, for the same reason the lasso
            // outline uses two: a single colour disappears against the one
            // background that happens to match it, and the canvas background
            // is now anything the user wants.
            ZStack {
                Rectangle().path(in: rect.insetBy(dx: -1, dy: -1))
                    .stroke(.black.opacity(0.55), lineWidth: 2)
                Rectangle().path(in: rect)
                    .stroke(.white.opacity(0.38), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The canvas rectangle inside a preview of `size`, aspect-fitted and
    /// centred exactly as the renderer fits it.
    static func fitted(_ canvas: ProjectCanvas, in size: CGSize) -> CGRect {
        guard canvas.width > 0, canvas.height > 0, size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let viewAspect = size.width / size.height
        let canvasAspect = CGFloat(canvas.width) / CGFloat(canvas.height)
        let width = canvasAspect > viewAspect ? size.width : size.height * canvasAspect
        let height = canvasAspect > viewAspect ? size.width / canvasAspect : size.height
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2,
                      width: width, height: height)
    }
}
