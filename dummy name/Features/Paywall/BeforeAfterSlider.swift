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
    /// The shape of the card. Wider than it is tall: a portrait card the width
    /// of the paywall's column is taller than an iPad sheet, which left the
    /// plans below it with nowhere to appear.
    var aspect: CGFloat = 3.0 / 2.0

    @State private var split: CGFloat = 0.5
    @State private var isDragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let corner: CGFloat = 18

    init(zoom: CGFloat = 1.25,
         focus: UnitPoint = UnitPoint(x: 0.54, y: 0.38),
         aspect: CGFloat = 3.0 / 2.0) {
        self.zoom = zoom
        self.focus = focus
        self.aspect = aspect
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

                label(String(localized: "BEFORE"), alignment: .leading)
                    .opacity(split > 0.18 ? 1 : 0)
                label(String(localized: "AFTER"), alignment: .trailing)
                    .opacity(split < 0.82 ? 1 : 0)

                handle(width: width, height: geometry.size.height)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: corner))
            .overlay(
                RoundedRectangle(cornerRadius: corner)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            )
            .overlay(
                WipeGestures(
                    onMove: { x in moveHandle(to: x, width: width) },
                    onDragging: { isDragging = $0 }
                )
            )
        }
        .aspectRatio(aspect, contentMode: .fit)
        // Touches belong to the card and nothing outside it.
        //
        // `layer` scales its image up by `zoom` to crop in on the subject, and
        // `scaleEffect` enlarges a view's touch region along with its drawing —
        // `clipped()` only trims what is painted. That left the enlarged image
        // claiming a band of the sheet above the card, which is exactly where
        // the paywall's close button sits, so the close button received nothing.
        .contentShape(Rectangle())
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

    private func moveHandle(to x: CGFloat, width: CGFloat) {
        split = min(max(x / width, 0), 1)
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

/// The wipe's touch handling, in UIKit.
///
/// SwiftUI's `DragGesture` cannot do the one thing this control needs. Inside a
/// scroll view it claims the touch the moment a finger lands, whether that
/// finger turns out to be wiping or scrolling, and `simultaneousGesture` does
/// not change that — it only stops the wipe from also moving. That is what got
/// the paywall rejected: on iPad the card filled the sheet, so every touch that
/// could have scrolled to the plans landed on a control that swallowed it.
///
/// A gesture recognizer can refuse. `gestureRecognizerShouldBegin` is asked the
/// question at exactly the right moment — the finger has moved, its direction is
/// known, and nothing has been claimed yet — so a pan heading up or down fails
/// itself and the touch goes on to the scroll view, untouched.
private struct WipeGestures: UIViewRepresentable {
    /// Where the finger is, in the card's own coordinates.
    var onMove: (CGFloat) -> Void
    /// Whether a wipe is in progress, for the handle's grow-on-touch.
    var onDragging: (Bool) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        // The card speaks for itself through SwiftUI's accessibility element;
        // this layer is only here to carry recognizers.
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true

        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.pan(_:)))
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.tap(_:)))
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onMove = onMove
        context.coordinator.onDragging = onDragging
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onMove: onMove, onDragging: onDragging)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onMove: (CGFloat) -> Void
        var onDragging: (Bool) -> Void

        init(onMove: @escaping (CGFloat) -> Void, onDragging: @escaping (Bool) -> Void) {
            self.onMove = onMove
            self.onDragging = onDragging
        }

        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                onDragging(true)
                onMove(recognizer.location(in: recognizer.view).x)
            default:
                onDragging(false)
            }
        }

        /// A tap moves the handle to where it landed.
        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            onMove(recognizer.location(in: recognizer.view).x)
        }

        /// Sideways only. A finger heading up or down belongs to the scroll view.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }
    }
}

