import SwiftUI

/// A preview of the values along a rail. Callers choose this by property,
/// never by its translated label, so colour keeps the same meaning everywhere.
struct SliderSpectrum {
    let colors: [Color]

    var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }

    static let temperature = Self(colors: [
        Color(red: 0.20, green: 0.38, blue: 1),
        Color(red: 0.72, green: 0.77, blue: 0.82),
        Color(red: 1, green: 0.79, blue: 0.20)
    ])
    static let tint = Self(colors: [
        Color(red: 0.27, green: 0.82, blue: 0.40),
        Color(red: 0.76, green: 0.77, blue: 0.78),
        Color(red: 0.91, green: 0.32, blue: 0.80)
    ])
    static let luminance = Self(colors: [Color(white: 0.20), Color(white: 0.95)])
    static let hue = hueRange(0...360)

    static func hueRange(_ degrees: ClosedRange<Double>) -> Self {
        Self(colors: (0...24).map { index in
            let angle = degrees.lowerBound + (degrees.upperBound - degrees.lowerBound) * Double(index) / 24
            let hue = (angle.truncatingRemainder(dividingBy: 360) + 360)
                .truncatingRemainder(dividingBy: 360) / 360
            return Color(hue: hue, saturation: 0.85, brightness: 0.95)
        })
    }

    static func saturation(hue: Double = 0) -> Self {
        Self(colors: [Color(white: 0.58), Color(hue: hue / 360, saturation: 0.95, brightness: 0.95)])
    }

    static func lightness(hue: Double) -> Self {
        Self(colors: [Color(white: 0.16), Color(hue: hue / 360, saturation: 0.8, brightness: 0.85),
                      Color(white: 0.95)])
    }

    /// Kelvin describes the light itself: low values are warm, high values cool.
    /// Sample the same colour science as the light, including its neutral 6500 K.
    static let lightTemperature = Self(colors: (0...24).map { index in
        let rgb = RelightColorScience.temperatureRGB(kelvin: 1500 + Double(index) / 24 * 13500)
        let peak = max(rgb.x, max(rgb.y, rgb.z))
        return Color(red: RelightColorScience.encoded(rgb.x / peak),
                     green: RelightColorScience.encoded(rgb.y / peak),
                     blue: RelightColorScience.encoded(rgb.z / peak))
    })

    static func grading(_ property: AnimatableProperty, wheelHue: Double = 0) -> Self? {
        switch property.gradeSlot {
        case .light(.temperature): .temperature
        case .light(.tint): .tint
        case .light(.saturation), .light(.vibrance): .saturation()
        case .light(.exposure), .light(.highlights), .light(.shadows), .light(.whites), .light(.blacks): .luminance
        case .hslHue(let band): .hueRange(Double(HueBand.centers[band] - 30)...Double(HueBand.centers[band] + 30))
        case .hslSaturation(let band): .saturation(hue: Double(HueBand.centers[band]))
        case .hslLuminance(let band): .lightness(hue: Double(HueBand.centers[band]))
        case .wheelHue: .hue
        case .wheelStrength: .saturation(hue: wheelHue)
        case .wheelBrightness: .luminance
        default: nil
        }
    }
}
