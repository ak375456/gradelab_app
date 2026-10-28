#if !targetEnvironment(macCatalyst)
import SwiftUI

/// Expanded resolution near the recording ceiling, matching the marks on the
/// meter. Digital input clips at 0 dBFS; +3 is display headroom, not extra gain.
enum CameraAudioScale {
    static let marks: [(db: Double, position: Double)] = [
        (-45, 0), (-30, 0.15), (-20, 0.32), (-10, 0.61),
        (-6, 0.72), (-3, 0.81), (0, 0.90), (3, 1)
    ]

    static func position(_ db: Double) -> Double {
        guard !db.isNaN, db > marks[0].db else { return 0 }
        guard db < marks[marks.count - 1].db else { return 1 }
        for (low, high) in zip(marks, marks.dropFirst()) where db <= high.db {
            let fraction = (db - low.db) / (high.db - low.db)
            return low.position + fraction * (high.position - low.position)
        }
        return 0
    }
}

struct CameraAudioMeter: View {
    let levels: [Float]
    let hasAudio: Bool
    let microphone: String
    var onEnableAudio: () -> Void = {}
    @ScaledMetric(relativeTo: .caption2) private var titleSize = 10
    @State private var expanded = false

    private let green = Color(red: 0.05, green: 0.86, blue: 0.16)
    private let yellow = Color(red: 1, green: 0.89, blue: 0.12)
    private let red = Color(red: 1, green: 0.21, blue: 0.26)

    var body: some View {
        Button {
            if hasAudio { expanded = true }
            else { onEnableAudio() }
        } label: { panel }
            .buttonStyle(.plain)
            .accessibilityHint(hasAudio ? String(localized: "Tap to see the full decibel scale") : String(localized: "Tap to enable microphone access in Settings"))
            .popover(isPresented: $expanded, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                panel.frame(width: 300).padding(8)
                    .presentationCompactAdaptation(.popover)
                    .preferredColorScheme(.dark)
            }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if hasAudio {
                    Text(microphone.isEmpty ? String(localized: "Microphone") : microphone)
                } else {
                    Label("No audio", systemImage: "mic.slash.fill")
                }
            }
            .font(.system(size: titleSize, weight: .medium))
            .foregroundStyle(hasAudio ? AppColors.textPrimary : AppColors.warning)
            .lineLimit(1).minimumScaleFactor(0.75)

            Canvas { context, size in
                let gutter: CGFloat = 12
                let width = max(0, size.width - gutter - 1)
                let rowHeight: CGFloat = 9
                let yellowStart = width * CameraAudioScale.position(-10)
                let redStart = width * CameraAudioScale.position(0)
                let zones: [(CGFloat, CGFloat, Color)] = [
                    (0, yellowStart, green), (yellowStart, redStart, yellow), (redStart, width, red)
                ]
                for channel in 0..<2 {
                    let y = CGFloat(channel) * 12 + 1
                    let available = hasAudio && channel < levels.count
                    let db = available ? Double(levels[channel]) : -.infinity
                    let fill = width * CameraAudioScale.position(db)
                    let bar = CGRect(x: gutter, y: y, width: width, height: rowHeight)
                    context.fill(Path(bar.insetBy(dx: -1, dy: -1)), with: .color(.black))
                    for (start, end, color) in zones {
                        let region = CGRect(x: gutter + start, y: y, width: end - start, height: rowHeight)
                        context.fill(Path(region), with: .color(color.opacity(hasAudio ? 0.23 : 0.07)))
                        if available, fill > start {
                            let active = CGRect(x: gutter + start, y: y, width: min(fill, end) - start, height: rowHeight)
                            context.fill(Path(active), with: .color(color))
                        }
                    }
                    for edge in [yellowStart, redStart] {
                        context.fill(Path(CGRect(x: gutter + edge - 0.5, y: y, width: 1, height: rowHeight)), with: .color(.black))
                    }
                    if available, db >= 0 {
                        context.fill(Path(CGRect(x: gutter + redStart, y: y, width: 2, height: rowHeight)), with: .color(red))
                    }
                    // A missing second channel stays explicitly unavailable.
                    if hasAudio, levels.count == 1, channel == 1 {
                        context.draw(Text("—").font(.system(size: 8)).foregroundStyle(AppColors.textTertiary),
                                     at: CGPoint(x: gutter + width / 2, y: y + rowHeight / 2))
                    }
                    context.draw(Text("\(channel + 1)").font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(available ? AppColors.textPrimary : AppColors.textTertiary),
                        at: CGPoint(x: 4, y: y + rowHeight / 2))
                }
                let fullScale = width >= 190
                let compactMarks: [Double] = width >= 100 ? [-45, -20, -10, 0] : [-45, -10, 0]
                let marks = CameraAudioScale.marks.filter { fullScale || compactMarks.contains($0.db) }
                for mark in marks {
                    let x = gutter + width * mark.position
                    context.fill(Path(CGRect(x: x - 0.5, y: 24, width: 1, height: 2)), with: .color(.white.opacity(0.65)))
                    let anchor: UnitPoint = mark.position == 0 ? .topLeading : mark.position == 1 ? .topTrailing : .top
                    context.draw(Text("\(Int(mark.db))").font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(AppColors.textSecondary), at: CGPoint(x: x, y: 28), anchor: anchor)
                }
            }
            .frame(height: 38)
            if !hasAudio {
                Text("Enable in Settings").font(.system(size: 9)).foregroundStyle(AppColors.warning).lineLimit(1)
            }
        }
        .padding(7)
        .background(.black.opacity(0.60), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hasAudio ? (microphone.isEmpty ? String(localized: "Microphone") : microphone) : String(localized: "Microphone disabled. Video records without audio."))
        .accessibilityValue(accessibilityReading)
    }

    private var accessibilityReading: String {
        guard hasAudio else { return "" }
        guard !levels.isEmpty else { return String(localized: "Waiting for microphone levels") }
        return levels.prefix(2).enumerated().map { channel, level in
            let reading = level.isFinite && level > -45 ? "\(Int(level.rounded())) dBFS" : String(localized: "Silent")
            return String(localized: "Channel \(channel + 1): \(reading)")
        }.joined(separator: ", ")
    }
}
#endif
