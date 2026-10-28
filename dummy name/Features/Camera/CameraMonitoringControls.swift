#if !targetEnvironment(macCatalyst)
import SwiftUI

struct CameraPeakingControls: View {
    @Binding var assist: ViewerAssistSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Focus peaking", isOn: $assist.focusPeaking).frame(minHeight: 44)
            if assist.focusPeaking {
                HStack(spacing: 4) {
                    ForEach(FocusPeakingColor.allCases) { color in
                        Button { assist.peakingColor = color } label: {
                            Circle().fill(color.swatch).frame(width: 17, height: 17)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background {
                                    if assist.peakingColor == color {
                                        RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08))
                                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.swatch.opacity(0.7), lineWidth: 1))
                                    }
                                }
                        }.buttonStyle(.plain).accessibilityLabel("\(color.title) focus peaking")
                            .accessibilityAddTraits(assist.peakingColor == color ? .isSelected : [])
                    }
                }
                HStack {
                    Text("Sensitivity")
                    Spacer()
                    Text("\(Int(assist.peakingSensitivity))%").monospacedDigit().foregroundStyle(AppColors.textSecondary)
                }.font(AppTypography.caption)
                Slider(value: $assist.peakingSensitivity, in: 0...100).frame(minHeight: 44)
                    .accessibilityLabel("Focus peaking sensitivity")
                Text("Highlights fine edges to help judge focus. Higher sensitivity can also highlight noise. Preview only.")
                    .font(.caption2).foregroundStyle(AppColors.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
        }.tint(AppColors.accent)
    }
}

private extension FocusPeakingColor {
    var swatch: Color {
        switch self { case .cyan: .cyan; case .red: .red; case .yellow: .yellow; case .white: .white }
    }
}

struct CameraStorageIndicator: View {
    let estimate: CameraRecordingEstimate?
    let freeBytes: Int64
    @State private var expanded = false

    var body: some View {
        Button { expanded = true } label: {
            VStack(alignment: .trailing, spacing: 4) {
                Image(systemName: "internaldrive").font(.system(size: 15))
                Text(estimate?.label ?? "—").font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(estimate?.isLow == true ? AppColors.warning : AppColors.textPrimary)
                Text(ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file))
                    .font(.system(size: 9)).foregroundStyle(AppColors.textTertiary)
            }.lineLimit(1).minimumScaleFactor(0.7).frame(minWidth: 60, minHeight: 60, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Estimated recording time remaining, \(estimate?.label ?? String(localized: "Unavailable")). \(ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)) available")
        .accessibilityHint("Show storage estimate details")
        .popover(isPresented: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Recording time remaining", systemImage: "internaldrive").font(AppTypography.headline)
                Text(estimate?.label ?? String(localized: "Preparing estimate…")).font(AppTypography.title).monospacedDigit()
                Text("Estimated from the selected resolution, frame rate and codec. During a take it updates from the recorded file size. Scene detail can change file sizes. Includes a 200 MB safety reserve.")
                    .font(AppTypography.callout).foregroundStyle(AppColors.textSecondary).fixedSize(horizontal: false, vertical: true)
            }.padding(20).frame(width: 280).preferredColorScheme(.dark).presentationCompactAdaptation(.popover)
        }
    }
}
#endif
