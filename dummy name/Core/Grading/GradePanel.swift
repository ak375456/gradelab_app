import Foundation

/// The eight tools of the Color tab.
///
/// Lifted out of `EditorViewModel` so the still-image editor names the same
/// panels rather than declaring a parallel list that could drift from it.
/// `EditorViewModel.Panel` is an alias for this, so every existing reference
/// still reads the way it did.
///
/// It lives in Core rather than beside the views because the grading model
/// refers to it: every animatable grading property knows which tool shows it,
/// which is what the "this panel holds animation" marker reads.
enum GradePanel: String, CaseIterable, Identifiable, Sendable {
    case light = "Light"
    case color = "Color"
    case curves = "Curves"
    case hsl = "HSL"
    case wheels = "Wheels"
    case masks = "Masks"
    case mask = "Local"
    case vignette = "Vignette"
    case effects = "Effects"
    case lut = "Look"

    var id: String { rawValue }

    /// The tools a masked local grade can actually carry.
    ///
    /// The vignette, the finishing effects and the creative look are missing on
    /// purpose. None of them is a per-pixel colour transform — a vignette and
    /// grain are frame-absolute, and a look is a managed transform of the source
    /// signal — so applying them inside a window would mean inventing a
    /// behaviour rather than reusing the one the clip already has. They stay
    /// global until they can be composited correctly, and the strip simply does
    /// not offer them in a mask context rather than offering controls that do
    /// nothing.
    static let localCapable: [GradePanel] = [.light, .color, .curves, .hsl, .wheels, .masks]

    var symbol: String {
        switch self {
        case .light: "sun.max"
        case .color: "thermometer.medium"
        case .curves: "point.topleft.down.to.point.bottomright.curvepath"
        case .hsl: "slider.horizontal.3"
        case .wheels: "circle.lefthalf.filled"
        case .masks: "circle.dashed.inset.filled"
        case .mask: "circle.dashed"
        case .vignette: "camera.metering.center.weighted"
        case .effects: "sparkles"
        case .lut: "camera.filters"
        }
    }

    var help: String {
        switch self {
        case .light: "Start with Exposure, then shape contrast and bright or dark areas. Double-tap the slider to reset."
        case .color: "Temperature balances warm and cool. Tint balances green and magenta. Vibrance gently boosts quieter colors."
        case .curves: """
            The sharpest tool here, and worth the trouble.

            Tap the graph to drop a point, drag it to shape the curve, and tap a point again to remove it. Master, R, G and B shape tone and the three channels. The six color curves each target one thing: a hue, a saturation range, or one part of the tonal range — so you can deepen a sky without touching skin.

            On the hue curves, the eyedropper samples a color straight off the picture and builds a selection around it, holding the neighbouring colors still.

            Small moves go a long way. Every curve has its own Reset, and nothing here is permanent.
            """
        case .hsl: "Choose a color, then change its hue, saturation, or lightness. Try reducing blue lightness for a deeper sky. Nearby colors blend smoothly."
        case .wheels: "Tint shadows, midtones, or highlights separately. Drag toward a color; farther from the center means stronger color. Try cool shadows with warm highlights."
        case .masks: """
            Power windows. Add an ellipse, rectangle, gradient or freehand shape, place it on the picture, then grade only that area.

            Each mask starts neutral and carries its own Light, Color, Curves, HSL and Wheels — so brightening a face leaves the rest of the clip exactly as your main grade left it. Feather softens the edge, Invert grades everything outside instead, and Strength dials the whole thing back.

            Add as many as the shot needs: a face, a sky, a foreground. They apply in the order they are listed.
            """
        case .mask: "Local color limits this clip's creative grade to an ellipse or rectangle; it does not make the layer transparent. For separate graded areas that each carry their own colour, use Masks. Use the Mask tool beside Transform when you want to reveal clips underneath."
        case .vignette: "Darken the edges to draw attention inward, or brighten them for a softer look. Midpoint controls how far inward it reaches; feather softens the transition."
        case .effects: "Finishing effects. Fade lifts the blacks toward a matte print. Sharpen adds edge detail. Bloom, glow and halation spread light out of bright areas — halation is the red halo film gets. Grain is strongest through the midtones, as film is."
        case .lut: "Pick a creative look, then set its strength. The look is applied first and every other tool adjusts the result, so you can still fine-tune exposure and color afterwards."
        }
    }
}
