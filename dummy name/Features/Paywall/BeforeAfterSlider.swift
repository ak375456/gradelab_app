import SwiftUI

/// The paywall's hero: one frame ungraded, the same frame graded, and a handle
/// to wipe between them.
///
/// This is the app's whole argument in one control. A feature list tells someone
/// what the app has; dragging the handle across their own kind of footage shows
/// them what it does, which is the thing that actually makes them want it. So it
/// sits above the plans rather than below them.
///
/// PaywallBefore is the ungraded photograph and PaywallAfter is the creator's
/// finished grade. The graded photo was framed a little differently, so it gets
/// its own small display offset to line the subject up at the comparison seam.
struct BeforeAfterSlider: View {
    /// How far in to crop, so the subject fills the frame instead of the scene
    /// around them. 1 shows the whole photograph.
    var zoom: CGFloat = 1.25
    /// What the crop is centred on, in unit coordinates of the source image.
    /// Set for a face a little above centre.
    var focus: UnitPoint = UnitPoint(x: 0.54, y: 0.38)

    @State private var split: CGFloat = 0.5
    @State private var isDragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let corner: CGFloat = 18

    init(zoom: CGFloat = 1.25, focus: UnitPoint = UnitPoint(x: 0.54, y: 0.38)) {
        self.zoom = zoom
        self.focus = focus
    }

    private var before: Image? { UIImage(named: "PaywallBefore").map(Image.init(uiImage:)) }
    private var after: Image? { UIImage(named: "PaywallAfter").map(Image.init(uiImage:)) }

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            ZStack(alignment: .leading) {
                layer(after, size: geometry.size, offset: CGSize(
                    width: -geometry.size.width * 0.032,
                    height: geometry.size.height * 0.045
                ))
                // The ungraded frame sits on top, revealed from the left edge to
                // the handle. Masking rather than resizing keeps both images
                // still, so the wipe reads as one photograph changing rather
                // than two images sliding past each other.
                layer(before, size: geometry.size)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: width * split)
                    }

                label("BEFORE", alignment: .leading)
                    .opacity(split > 0.18 ? 1 : 0)
                label("AFTER", alignment: .trailing)
                    .opacity(split < 0.82 ? 1 : 0)

                handle(width: width, height: geometry.size.height)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: corner))
            .overlay(
                RoundedRectangle(cornerRadius: corner)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        split = min(max(value.location.x / width, 0), 1)
                    }
                    .onEnded { _ in isDragging = false }
            )
        }
        .aspectRatio(4.0 / 5.0, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Before and after grading comparison")
        .accessibilityValue("\(Int(split * 100))% showing the ungraded image")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: split = min(1, split + 0.1)
            case .decrement: split = max(0, split - 0.1)
            @unknown default: break
            }
        }
    }

    @ViewBuilder
    private func layer(_ image: Image?, size: CGSize, offset: CGSize = .zero) -> some View {
        if let image {
            image
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .scaleEffect(zoom, anchor: focus)
                .offset(offset)
                .clipped()
        } else {
            // Never a blank rectangle if an asset is missing: the paywall still
            // has to look deliberate.
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.13, blue: 0.18),
                         Color(red: 0.18, green: 0.16, blue: 0.22)],
                startPoint: .top, endPoint: .bottom)
        }
    }

    private func label(_ text: String, alignment: Alignment) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold)).tracking(1.2)
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .allowsHitTesting(false)
    }

    private func handle(width: CGFloat, height: CGFloat) -> some View {
        let x = width * split
        return ZStack {
            Rectangle()
                .fill(.white.opacity(0.9))
                .frame(width: 2, height: height)
                .shadow(color: .black.opacity(0.35), radius: 3)
            Circle()
                .fill(.white)
                .frame(width: 34, height: 34)
                .shadow(color: .black.opacity(0.3), radius: 5, y: 1)
                .overlay {
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.black.opacity(0.75))
                }
                .scaleEffect(isDragging && !reduceMotion ? 1.12 : 1)
                .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7),
                           value: isDragging)
        }
        .position(x: x, y: height / 2)
        .allowsHitTesting(false)
    }
}
