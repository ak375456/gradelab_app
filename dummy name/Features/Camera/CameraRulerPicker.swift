#if !targetEnvironment(macCatalyst)
import AudioToolbox
import SwiftUI
import UIKit

struct CameraRulerScale: Equatable {
    let values: [Double]
    let labelEvery: Int

    init(range: ClosedRange<Double>, step: Double, labelEvery: Int) {
        let first = ceil(range.lowerBound / step)
        let last = floor(range.upperBound / step)
        let steps = first <= last ? stride(from: first, through: last, by: 1).map { $0 * step } : []
        self.init(range: range, stops: steps, labelEvery: labelEvery)
    }

    private init(range: ClosedRange<Double>, stops: [Double], labelEvery: Int) {
        let interior = stops.filter { $0 - range.lowerBound > 1e-9 && range.upperBound - $0 > 1e-9 }
        values = Set(interior + [range.lowerBound, range.upperBound]).sorted()
        self.labelEvery = labelEvery
    }

    static func iso(_ range: ClosedRange<Double>) -> Self {
        .init(range: range, stops: [25, 32, 40, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500,
                                    640, 800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400,
                                    8000, 10000, 12800, 16000, 20000, 25600], labelEvery: 3)
    }

    static func shutter(_ range: ClosedRange<Double>, fps: Int) -> Self {
        let denominators: [Double] = [24, 25, 30, 40, 48, 50, 60, 80, 100, 120, 125, 160, 200, 250,
                                      320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200,
                                      4000, 5000, 6400, 8000, 10000, 12500, 16000, 20000, 32000]
        let speeds = (denominators + [Double(fps) * 2]).map { 1 / $0 }
        return .init(range: range, stops: speeds, labelEvery: 4)
    }

    /// Opening a ruler can show a camera reading between ticks without moving the camera.
    func position(of value: Double) -> CGFloat {
        guard value.isFinite, value > values[0] else { return 0 }
        guard let upper = values.firstIndex(where: { $0 >= value }) else { return CGFloat(values.count - 1) }
        let lower = upper - 1
        let fraction = (value - values[lower]) / (values[upper] - values[lower])
        return CGFloat(lower) + CGFloat(fraction)
    }

    func index(at position: CGFloat) -> Int {
        Int(min(max(position.rounded(), 0), CGFloat(values.count - 1)))
    }
}

struct CameraRulerPicker: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let scale: CameraRulerScale
    let feedbackEnabled: Bool
    let soundsEnabled: Bool
    let format: (Double) -> String
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
            Text(title).font(AppTypography.sectionLabel).foregroundStyle(AppColors.textSecondary)
            VStack(spacing: AppSpacing.xSmall) {
                Text(format(value))
                    .font(AppTypography.numeric)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundStyle(isEnabled ? AppColors.accent : AppColors.textSecondary)
                    .padding(.horizontal, AppSpacing.compact).padding(.vertical, AppSpacing.xSmall)
                    .background(AppColors.accentMuted, in: Capsule())
                    .frame(maxWidth: .infinity)
                Track(value: $value, scale: scale, enabled: isEnabled, feedbackEnabled: feedbackEnabled,
                      soundsEnabled: soundsEnabled, reduceMotion: reduceMotion, format: format)
                    .frame(height: 44)
                    .mask {
                        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white, location: 0.09),
                                               .init(color: .white, location: 0.91), .init(color: .clear, location: 1)],
                                       startPoint: .leading, endPoint: .trailing)
                    }
                    .overlay(alignment: .top) {
                        Capsule().fill(isEnabled ? AppColors.accent : AppColors.textTertiary)
                            .frame(width: 2, height: 26).padding(.top, 2).allowsHitTesting(false)
                    }
                    .appSurface(fill: AppColors.background, border: AppColors.separator)
            }
            .opacity(isEnabled ? 1 : 0.64)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(format(value)))
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment:
                if let next = scale.values.first(where: { $0 > value + 1e-9 }) { value = next }
            case .decrement:
                if let previous = scale.values.last(where: { $0 < value - 1e-9 }) { value = previous }
            @unknown default: break
            }
        }
    }

    private struct Track: UIViewRepresentable {
        @Binding var value: Double
        let scale: CameraRulerScale
        let enabled: Bool
        let feedbackEnabled: Bool
        let soundsEnabled: Bool
        let reduceMotion: Bool
        let format: (Double) -> String

        func makeUIView(context: Context) -> CameraRulerScrollView { CameraRulerScrollView() }

        func updateUIView(_ view: CameraRulerScrollView, context: Context) {
            view.onSelect = { value = $0 }
            view.feedbackEnabled = feedbackEnabled
            view.soundsEnabled = soundsEnabled
            view.reduceMotion = reduceMotion
            view.update(scale: scale, value: value, enabled: enabled, format: format)
        }
    }
}

/// UIKit owns the pan and deceleration so horizontal scrubbing can coexist
/// with the drawer's vertical scroll and settle using native momentum.
private final class CameraRulerScrollView: UIScrollView, UIScrollViewDelegate {
    var onSelect: (Double) -> Void = { _ in }
    var feedbackEnabled = false
    var soundsEnabled = false
    var reduceMotion = false

    private let ticks = CameraRulerTicksView()
    private let selectionFeedback = UISelectionFeedbackGenerator()
    private var lastFeedback: CFTimeInterval = 0
    private var value: Double = 0
    private var activeIndex: Int?
    private var needsCentering = true

    init() {
        super.init(frame: .zero)
        delegate = self
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        scrollsToTop = false
        isDirectionalLockEnabled = true
        ticks.isOpaque = false
        ticks.isUserInteractionEnabled = false
        addSubview(ticks)
    }

    required init?(coder: NSCoder) { nil }

    func update(scale: CameraRulerScale, value: Double, enabled: Bool, format: @escaping (Double) -> String) {
        let canScroll = enabled && scale.values.count > 1
        let scaleChanged = ticks.scale != scale
        let valueChanged = abs(value - self.value) > 1e-9
        if scaleChanged || canScroll != isScrollEnabled || (valueChanged && !isDragging) {
            cancelScroll()
            self.value = value
            needsCentering = true
            setNeedsLayout()
        }
        let labels = stride(from: 0, to: scale.values.count, by: scale.labelEvery).map { format(scale.values[$0]) }
        if scaleChanged || ticks.labels != labels {
            ticks.scale = scale
            ticks.labels = labels
            ticks.setNeedsDisplay()
        }
        if isScrollEnabled != canScroll { isScrollEnabled = canScroll }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let scale = ticks.scale, bounds.width > 0, bounds.height > 0 else { return }
        let span = CGFloat(scale.values.count - 1) * CameraRulerTicksView.spacing
        let size = CGSize(width: bounds.width + span, height: bounds.height)
        if contentSize != size {
            cancelScroll()
            ticks.frame = CGRect(origin: .zero, size: size)
            contentSize = size
            ticks.setNeedsDisplay()
            needsCentering = true
        }
        if needsCentering {
            needsCentering = false
            setContentOffset(CGPoint(x: scale.position(of: value) * CameraRulerTicksView.spacing, y: 0), animated: false)
        }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            let velocity = panGestureRecognizer.velocity(in: self)
            guard abs(velocity.x) > abs(velocity.y) else { return false }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard let scale = ticks.scale else { return }
        activeIndex = scale.index(at: scale.position(of: value))
        if feedbackEnabled { selectionFeedback.prepare() }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard let scale = ticks.scale, let activeIndex else { return }
        let index = scale.index(at: contentOffset.x / CameraRulerTicksView.spacing)
        guard index != activeIndex else { return }
        self.activeIndex = index
        value = scale.values[index]
        onSelect(value)

        let now = CACurrentMediaTime()
        guard feedbackEnabled, now - lastFeedback >= 0.035 else { return }
        lastFeedback = now
        selectionFeedback.selectionChanged()
        selectionFeedback.prepare()
        if soundsEnabled, let sound = Self.tickSound { AudioServicesPlaySystemSound(sound) }
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard let scale = ticks.scale, activeIndex != nil else { return }
        let spacing = CameraRulerTicksView.spacing
        let index = scale.index(at: targetContentOffset.pointee.x / spacing)
        targetContentOffset.pointee.x = CGFloat(index) * spacing
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { finishScrolling() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finishScrolling() }

    private func cancelScroll() {
        guard activeIndex != nil else { return }
        activeIndex = nil
        if isScrollEnabled {
            isScrollEnabled = false
            isScrollEnabled = true
        }
    }

    private func finishScrolling() {
        guard let scale = ticks.scale, activeIndex != nil else { return }
        scrollViewDidScroll(self)
        activeIndex = nil
        let x = scale.position(of: value) * CameraRulerTicksView.spacing
        if abs(contentOffset.x - x) > 0.5 {
            setContentOffset(CGPoint(x: x, y: 0), animated: !reduceMotion)
        }
    }

    private static let tickSound: SystemSoundID? = {
        guard let url = Bundle.main.url(forResource: "CameraRulerTick", withExtension: "wav") else { return nil }
        var sound: SystemSoundID = 0
        return AudioServicesCreateSystemSoundID(url as CFURL, &sound) == kAudioServicesNoError ? sound : nil
    }()
}

private final class CameraRulerTicksView: UIView {
    static let spacing: CGFloat = 18
    var scale: CameraRulerScale?
    var labels: [String] = []

    override func draw(_ rect: CGRect) {
        guard let scale, let context = UIGraphicsGetCurrentContext() else { return }
        let inset = (bounds.width - CGFloat(scale.values.count - 1) * Self.spacing) / 2
        let labelStyle: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: UIColor(AppColors.textSecondary)
        ]
        for index in scale.values.indices {
            let major = index.isMultiple(of: scale.labelEvery)
            let x = inset + CGFloat(index) * Self.spacing
            context.setStrokeColor(UIColor(major ? AppColors.textSecondary : AppColors.textDisabled).cgColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: x, y: 6))
            context.addLine(to: CGPoint(x: x, y: major ? 23 : 16))
            context.strokePath()
            if major {
                let label = labels[index / scale.labelEvery] as NSString
                let width = label.size(withAttributes: labelStyle).width
                label.draw(at: CGPoint(x: x - width / 2, y: 28), withAttributes: labelStyle)
            }
        }
    }
}
#endif
