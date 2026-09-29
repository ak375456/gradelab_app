import Foundation

/// The tools of the Color tab.
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
    case warper = "Warper"
    case noise = "Noise"
    case wheels = "Wheels"
    case match = "Match"
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
        case .warper: "circle.hexagongrid"
        case .noise: "camera.aperture"
        case .wheels: "circle.lefthalf.filled"
        case .match: "rectangle.on.rectangle.angled"
        case .masks: "circle.dashed.inset.filled"
        case .mask: "circle.dashed"
        case .vignette: "camera.metering.center.weighted"
        case .effects: "sparkles"
        case .lut: "camera.filters"
        }
    }

    var help: String {
        switch self {
        case .light: String(localized: "Start with Exposure, then shape contrast and bright or dark areas. Double-tap the slider to reset.")
        case .color: String(localized: "Temperature balances warm and cool. Tint balances green and magenta. Vibrance gently boosts quieter colors.")
        case .curves: String(localized: """
            The sharpest tool here, and worth the trouble.

            Tap the graph to drop a point, drag it to shape the curve, and tap a point again to remove it. Master, R, G and B shape tone and the three channels. The six color curves each target one thing: a hue, a saturation range, or one part of the tonal range — so you can deepen a sky without touching skin.

            On the hue curves, the eyedropper samples a color straight off the picture and builds a selection around it, holding the neighbouring colors still.

            Small moves go a long way. Every curve has its own Reset, and nothing here is permanent.
            """)
        case .hsl: String(localized: "Choose a color, then change its hue, saturation, or lightness. Try reducing blue lightness for a deeper sky. Nearby colors blend smoothly.")
        case .warper: String(localized: """
            Grab a color and drag it somewhere else.

            Unlike HSL or the curves, this holds on to two things at once: which hue a color is AND how saturated it is. So the strong orange in a shirt can go to red while the pale orange in skin stays exactly where it is.

            Tap the picture with the eyedropper to land on the color you want, then drag its handle. Range decides how much of the surrounding color comes along, and the falloff is smooth, so there is no edge where the change stops.

            Chroma / Luma is the same idea seen from the side: how colorful against how bright. Use it to lift dark saturated blues, or take the chroma out of highlights only.

            Preserve Luminance keeps brightness where it was while the color moves. Leave it on unless you mean to change it.
            """)
        case .noise: String(localized: """
            Two noise reducers, and they do different jobs.

            Temporal looks at the frames either side of this one. Where the same scene point is visible in several of them, the noise is different each time and the picture is not \u{2014} so averaging them removes the noise and leaves the detail. It is by far the better of the two, and it is why this starts with motion: every neighbouring frame is aligned to this one first, and any part of it that does not line up is thrown away rather than smeared across the shot.

            Spatial works inside the single frame, along edges rather than across them. Use it to finish what the temporal pass could not \u{2014} the first frame of a shot, a fast movement, anything that only appears once.

            Luma and Chroma are separate everywhere. Colour noise takes far more cleaning than luminance noise before anything shows, so it is usually right to push Chroma well past Luma.

            Detail Recovery is not sharpening. It measures what the reduction removed and puts back only the part too large to have been noise.

            Hold the picture to compare, and zoom in while you tune \u{2014} noise reduction is judged at 100%, not fitted to the screen.
            """)
        case .wheels: String(localized: "Tint shadows, midtones, or highlights separately. Drag toward a color; farther from the center means stronger color. Try cool shadows with warm highlights.")
        case .match: String(localized: """
            Bring this shot closer to another one.

            Pick a reference \u{2014} another clip on the timeline, or an image you import \u{2014} and GradeLab measures both pictures and works out the grade that moves this one toward it. Exposure, white balance, contrast, saturation and the tint of the shadows, midtones and highlights.

            What it writes are ordinary values in the tools beside this one. Open Light after a match and Exposure will have moved; open Wheels and the shadows will have a tint. Every one of them is still yours to drag, and Reset puts back exactly the grade you had before.

            Shot matches two shots meant to cut together. Look carries the style of a film still across without relighting your scene. Strength moves the whole result between nothing and everything, and the component switches decide what it is allowed to touch at all.

            It is a starting point, not an answer. A reference from a different world will say so.
            """)
        case .masks: String(localized: """
            Power windows. Add an ellipse, rectangle, gradient or freehand shape, place it on the picture, then grade only that area.

            Each mask starts neutral and carries its own Light, Color, Curves, HSL and Wheels — so brightening a face leaves the rest of the clip exactly as your main grade left it. Feather softens the edge, Invert grades everything outside instead, and Strength dials the whole thing back.

            Add as many as the shot needs: a face, a sky, a foreground. They apply in the order they are listed.
            """)
        case .mask: String(localized: "Local color limits this clip's creative grade to an ellipse, rectangle or gradient; it does not make the layer transparent. For separate graded areas that each carry their own colour, use Masks. Use the Mask tool beside Transform when you want to reveal clips underneath.")
        case .vignette: String(localized: "Darken the edges to draw attention inward, or brighten them for a softer look. Midpoint controls how far inward it reaches; feather softens the transition.")
        case .effects: String(localized: "Finishing effects. Fade lifts the blacks toward a matte print. Sharpen adds edge detail. Bloom, glow and halation spread light out of bright areas — halation is the red halo film gets. Grain is strongest through the midtones, as film is.")
        case .lut: String(localized: "Pick a creative look, then set its strength. The look is applied first and every other tool adjusts the result, so you can still fine-tune exposure and color afterwards.")
        }
    }
}
