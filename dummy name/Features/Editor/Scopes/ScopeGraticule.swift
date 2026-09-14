import SwiftUI

/// The reference grid drawn over a scope's density.
///
/// Vector, not raster: it is drawn in SwiftUI over the Metal view so the lines
/// stay one pixel at any size and the labels come out as text rather than as
/// pixels baked into a shader. It is also the reason the shaders stay small —
/// they only ever plot density.
///
/// Every vectorscope position here is computed from the same `ScopeColorSpace`
/// transform the shader plots with, so a target cannot end up somewhere the
/// trace can never reach.
struct ScopeGraticule: View {
    let type: ScopeType
    let colorSpace: ScopeColorSpace

    private let line = Color.white.opacity(0.14)
    private let strongLine = Color.white.opacity(0.22)
    private let label = Color.white.opacity(0.38)

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            switch type {
            case .histogram: histogram(size)
            case .waveform: levels(size, sections: 1)
            case .rgbParade: levels(size, sections: 3)
            case .vectorscope: vector(size)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Histogram

    /// Vertical guides at quarters of the level range: shadows on the left,
    /// highlights on the right.
    private func histogram(_ size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                for step in 1..<4 {
                    let x = size.width * CGFloat(step) / 4
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
            }.stroke(line, lineWidth: 0.5)
            Path { path in
                for x in [CGFloat(0.5), size.width - 0.5] {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
            }.stroke(strongLine, lineWidth: 1)
            HStack {
                Text("0").font(.system(size: 9, design: .monospaced)).foregroundStyle(label)
                Spacer()
                Text("100").font(.system(size: 9, design: .monospaced)).foregroundStyle(label)
            }
            .padding(.horizontal, 4)
            .frame(height: size.height, alignment: .bottom)
        }
    }

    // MARK: - Waveform and parade

    /// Horizontal luminance guides at 0/25/50/75/100. These are percentages of
    /// the signal the pipeline actually produces, not broadcast legal range —
    /// the app has no legal-range control, so labelling them IRE would be
    /// claiming something it does not do.
    private func levels(_ size: CGSize, sections: Int) -> some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                for step in 0...4 {
                    let y = size.height * CGFloat(step) / 4
                    let clamped = min(max(y, 0.5), size.height - 0.5)
                    path.move(to: CGPoint(x: 0, y: clamped))
                    path.addLine(to: CGPoint(x: size.width, y: clamped))
                }
            }.stroke(line, lineWidth: 0.5)
            if sections > 1 {
                Path { path in
                    for section in 1..<sections {
                        let x = size.width * CGFloat(section) / CGFloat(sections)
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                    }
                }.stroke(strongLine, lineWidth: 0.5)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(stride(from: 100, through: 0, by: -25)), id: \.self) { value in
                    Text("\(value)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(label)
                        .frame(height: 0)
                        .offset(y: value == 100 ? 5 : value == 0 ? -5 : 0)
                    if value > 0 { Spacer() }
                }
            }
            .padding(.leading, 4)
            .frame(height: size.height)
        }
    }

    // MARK: - Vectorscope

    private func vector(_ size: CGSize) -> some View {
        let radius = min(size.width, size.height) / 2
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        func place(_ point: CGPoint) -> CGPoint {
            CGPoint(x: centre.x + point.x * radius, y: centre.y - point.y * radius)
        }
        return ZStack {
            // The outer circle is the visualisation limit: a fully saturated
            // primary of this colour space. Nothing plots outside it.
            Circle().stroke(strongLine, lineWidth: 1)
                .frame(width: radius * 2, height: radius * 2).position(centre)
            ForEach([0.25, 0.5, 0.75], id: \.self) { fraction in
                Circle().stroke(line, lineWidth: 0.5)
                    .frame(width: radius * 2 * fraction, height: radius * 2 * fraction)
                    .position(centre)
            }
            Path { path in
                path.move(to: CGPoint(x: centre.x - radius, y: centre.y))
                path.addLine(to: CGPoint(x: centre.x + radius, y: centre.y))
                path.move(to: CGPoint(x: centre.x, y: centre.y - radius))
                path.addLine(to: CGPoint(x: centre.x, y: centre.y + radius))
            }.stroke(line, lineWidth: 0.5)

            // Skin-tone reference. The conventional flesh-tone axis of a
            // vectorscope, at 123 degrees in the Cb/Cr plane. It marks a HUE
            // direction only: skin of any tone that is neutrally lit tends to
            // lie along it, at whatever distance its own saturation puts it, and
            // at whatever brightness. It says nothing about how light or
            // saturated skin should be.
            Path { path in
                let angle = 123.0 * .pi / 180
                path.move(to: centre)
                path.addLine(to: place(CGPoint(x: cos(angle) * 0.95, y: sin(angle) * 0.95)))
            }.stroke(Color.white.opacity(0.3), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))

            // Six targets at 75% bars, the standard graticule amplitude, each
            // computed through the same transform the shader plots with.
            ForEach(Self.targets, id: \.name) { target in
                let point = place(scaled(colorSpace.scopePoint(target.rgb), by: 0.75))
                ZStack {
                    Rectangle().stroke(strongLine, lineWidth: 0.8).frame(width: 9, height: 9)
                    Text(target.name)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(label)
                        .offset(y: -11)
                }.position(point)
            }
        }
    }

    private func scaled(_ point: CGPoint, by factor: Double) -> CGPoint {
        CGPoint(x: point.x * factor, y: point.y * factor)
    }

    /// The colour-bar primaries and complements, in the conventional order.
    static let targets: [(name: String, rgb: SIMD3<Double>)] = [
        ("R", .init(1, 0, 0)), ("Yl", .init(1, 1, 0)), ("G", .init(0, 1, 0)),
        ("Cy", .init(0, 1, 1)), ("B", .init(0, 0, 1)), ("Mg", .init(1, 0, 1))
    ]
}
