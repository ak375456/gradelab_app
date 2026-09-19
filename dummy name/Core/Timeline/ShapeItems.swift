import CoreGraphics
import Foundation

/// The geometric figures a shape layer can draw.
///
/// A kind is a discrete choice, never an animated one: there is no meaningful
/// halfway point between a star and an arrow, and pretending there is would
/// turn a keyframe into a jump cut that looks like a bug. What animates is the
/// geometry underneath — size, corner radius, star waist — so a shape can grow,
/// round off and spin without ever changing what it is.
enum ShapeKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case rectangle
    case ellipse
    case triangle
    case star
    case polygon
    case arrow
    /// A capsule bar. Distinct from a rectangle in that it is always fully
    /// rounded, which is what an underline, a divider or a progress bar is.
    case line

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rectangle: String(localized: "Rectangle")
        case .ellipse: String(localized: "Ellipse")
        case .triangle: String(localized: "Triangle")
        case .star: String(localized: "Star")
        case .polygon: String(localized: "Polygon")
        case .arrow: String(localized: "Arrow")
        case .line: String(localized: "Line")
        }
    }

    /// Corner radius only means something on a rectangle: every other kind
    /// either has no corners or defines its own.
    var usesCornerRadius: Bool { self == .rectangle }
    /// Star and polygon are the two kinds built from a vertex count.
    var usesPointCount: Bool { self == .star || self == .polygon }
    /// Only a star has a waist between its outer and inner radius.
    var usesInnerRadius: Bool { self == .star }

    /// Vertex counts a kind can be built from. A polygon needs three corners;
    /// a star needs three points. Both stop where more vertices stop reading as
    /// anything but a circle.
    static let pointCountRange: ClosedRange<Int> = 3...20

    /// Untransformed proportions this kind looks right at, as fractions of the
    /// canvas width. A line wants a wide thin bar; everything else starts square
    /// so a circle is a circle and a star is symmetric whatever the frame shape.
    var defaultProportions: (width: Double, height: Double) {
        switch self {
        case .line: (0.6, 0.014)
        case .arrow: (0.36, 0.22)
        default: (0.3, 0.3)
        }
    }
}

/// A drawn overlay layer. The visual sibling of `TextClip`: same placement, same
/// transform, same blend modes, and the same keyframe engine — a shape animates
/// because it is an `AnimatableClip`, not because anything here knows about time.
///
/// Measurements are in authored canvas points, the coordinate system text point
/// sizes already live in (`LayerSequence.previewRenderSize`), so a shape drawn in
/// the editor renders identically at export whatever the output resolution.
///
/// Unlike `TextClip` nothing here is optional-for-compatibility: shapes are new,
/// so there is no older document whose absent keys have to decode. The one
/// optional, `gradient`, is optional because nil genuinely means "flat fill".
struct ShapeClip: TimelineClip {
    var placement: ItemPlacement
    var kind: ShapeKind = .rectangle
    var transform = VisualTransform()
    var opacity: Double = 1
    var blendMode: VisualBlendMode = .normal
    /// Untransformed size in canvas points. `transform.scale` is applied on top,
    /// so this is the shape's own dimensions rather than its drawn extent.
    var width: Double = 480
    var height: Double = 480
    var fillColor = Self.defaultFill
    /// Replaces the flat fill when present, exactly as on a text layer.
    var gradient: GradientFill? = nil
    /// Black, like a text layer's, because that is what `AnimatableProperty
    /// .strokeColor` restores — a new shape and a reset one must not differ.
    var strokeColor = RGBAColor.black
    /// Centred on the outline, in canvas points. Zero draws no stroke.
    var strokeWidth: Double = 0
    var cornerRadius: Double = 0
    /// Star points, or polygon corners.
    var pointCount = 5
    /// A star's waist, as a fraction of its outer radius.
    var innerRadius: Double = 0.5
    var shadowColor = RGBAColor.black
    var shadowOpacity: Double = 0
    var shadowRadius: Double = 8
    var shadowOffsetX: Double = 0
    var shadowOffsetY: Double = 4
    var glowColor = RGBAColor.white
    var glowOpacity: Double = 0
    var glowRadius: Double = 12
    /// Optional for the same reason a text clip's is: an unanimated shape stores
    /// no animation at all rather than an empty one.
    var animation: ClipAnimation? = nil

    static let defaultFill = RGBAColor(red: 0.16, green: 0.72, blue: 1)

    /// The size a newly inserted shape of this kind takes on this canvas.
    ///
    /// Both axes are measured against the canvas WIDTH, not one each, so a
    /// square is square and a circle round whatever the frame's aspect ratio is.
    static func defaultSize(for kind: ShapeKind, canvas: CGSize) -> (width: Double, height: Double) {
        let reference = max(160, Double(canvas.width))
        let proportions = kind.defaultProportions
        return (reference * proportions.width, max(2, reference * proportions.height))
    }

    /// The largest corner radius this shape can actually show.
    ///
    /// Past half the shorter side the corners meet and the figure is already as
    /// round as it will ever be — on a square that is a circle, on an oblong a
    /// capsule. Both the renderer and the inspector's slider are bounded by
    /// this, which is what keeps the whole sweep of that slider doing something:
    /// bounded by a fixed number instead, most of its travel was dead.
    ///
    /// The stored radius is deliberately NOT clamped to it. Shrinking a shape
    /// would otherwise destroy a radius the user authored at a larger size, and
    /// growing it again would not bring the roundness back.
    var maximumCornerRadius: Double { max(1, min(width, height)/2) }

    /// Vertex count as the renderer will actually use it.
    var resolvedPointCount: Int {
        min(ShapeKind.pointCountRange.upperBound, max(ShapeKind.pointCountRange.lowerBound, pointCount))
    }
}
