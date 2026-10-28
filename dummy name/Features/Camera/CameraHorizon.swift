#if !targetEnvironment(macCatalyst)
import CoreMotion
import Combine
import SwiftUI

/// Motion runs only while its visible guide is in use. Publishing here keeps
/// sensor updates from invalidating the whole camera workspace.
@MainActor
final class CameraLevelMonitor: ObservableObject {
    @Published private(set) var angle: Double?
    private let manager = CMMotionManager()
    private var rotation = 90
    private(set) var gravity: SIMD2<Double>?
    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func setEnabled(_ enabled: Bool, rotation: Int) {
        self.rotation = rotation
        guard enabled, isAvailable else { stop(); return }
        if let gravity { angle = CameraGeometry.horizonAngle(x: gravity.x, y: gravity.y, rotation: rotation) }
        guard !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1 / 20
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            let x = motion?.gravity.x, y = motion?.gravity.y
            Task { @MainActor [weak self] in
                guard let self, self.manager.isDeviceMotionActive else { return }
                if let x, let y {
                    self.gravity = SIMD2(x, y)
                    self.angle = CameraGeometry.horizonAngle(x: x, y: y, rotation: self.rotation)
                }
            }
        }
    }

    func stop() {
        if manager.isDeviceMotionActive { manager.stopDeviceMotionUpdates() }
        gravity = nil
        if angle != nil { angle = nil }
    }
    deinit { manager.stopDeviceMotionUpdates() }
}

struct CameraHorizonView: View {
    @ObservedObject var monitor: CameraLevelMonitor

    var body: some View {
        if let angle = monitor.angle {
            CameraHorizonIndicator(angle: angle)
        }
    }
}

struct CameraHorizonIndicator: View {
    let angle: Double
    private var reading: CameraHorizonReading { CameraHorizonReading(angle: angle) }
    private var aligned: Bool { reading.isLevel }

    var body: some View {
        ZStack {
            ZStack {
                HStack(spacing: 76) {
                    Capsule().frame(width: 14, height: 2)
                    Capsule().frame(width: 14, height: 2)
                }.foregroundStyle(.white.opacity(0.65)).rotationEffect(.degrees(reading.reference))
                HStack(spacing: 9) {
                    Capsule().frame(width: 28, height: 2)
                    Circle().strokeBorder(lineWidth: 1.5).frame(width: 7, height: 7)
                    Capsule().frame(width: 28, height: 2)
                }
                .foregroundStyle(aligned ? Color.green : Color.white)
                .rotationEffect(.degrees(angle))
            }.frame(width: 110, height: 110)
            Text(aligned ? String(localized: "LEVEL") : String(format: "%.1f°", abs(reading.deviation)))
                .font(.system(size: 8, weight: .semibold, design: .monospaced)).tracking(1)
                .lineLimit(1).minimumScaleFactor(0.65).frame(maxWidth: reading.isVertical ? 36 : 80)
                .foregroundStyle(aligned ? Color.green : Color.white.opacity(0.85))
                .padding(.horizontal, 7).padding(.vertical, 4).background(.black.opacity(0.45), in: Capsule())
                .offset(x: reading.isVertical ? 47 : 0, y: reading.isVertical ? 0 : 36)
        }
        .frame(width: 144, height: 120)
        .shadow(color: .black.opacity(0.7), radius: 2, y: 1)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Horizon level")
        .accessibilityValue(aligned ? String(localized: "Level") : String(localized: "\(abs(reading.deviation).formatted(.number.precision(.fractionLength(1)))) degrees"))
    }
}
#endif
