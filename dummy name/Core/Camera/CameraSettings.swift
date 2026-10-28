import Foundation
import CoreGraphics

enum CameraProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case sdr, hdrHLG, displayP3, appleLog, appleLog2
    var id: String { rawValue }
    var title: String {
        switch self { case .sdr: "SDR · Rec.709"; case .hdrHLG: "HDR · Rec.2020 HLG"; case .displayP3: "P3 D65 · SDR"; case .appleLog: "Apple Log"; case .appleLog2: "Apple Log 2" }
    }
    var badge: String {
        switch self { case .sdr: "SDR"; case .hdrHLG: "HDR HLG"; case .displayP3: "P3"; case .appleLog: "Apple Log"; case .appleLog2: "Apple Log 2" }
    }
    var colorMode: ProjectColorMode {
        switch self { case .sdr: .sdr; case .hdrHLG: .hdrHLG; case .displayP3: .sdrWide; case .appleLog: .appleLog; case .appleLog2: .appleLog2 }
    }
    var needsTenBit: Bool { self == .hdrHLG || self == .appleLog || self == .appleLog2 }
    var isLog: Bool { self == .appleLog || self == .appleLog2 }
    var detail: String {
        switch self {
        case .sdr: String(localized: "Ready-to-view color. Works on every supported lens.")
        case .hdrHLG: String(localized: "10-bit HDR with brighter highlights. Requires HEVC or ProRes and an HDR display for full brightness.")
        case .displayP3: String(localized: "Wide-gamut SDR originals. GradeLab converts P3 to Rec.709 for editing and export.")
        case .appleLog, .appleLog2: String(localized: "Native Log capture for grading flexibility.")
        }
    }
    func matches(_ profile: SourceColorProfile) -> Bool {
        switch (self, profile) {
        case (.sdr, .rec709), (.sdr, .rec709Wide), (.hdrHLG, .hlgBT2020), (.displayP3, .displayP3), (.appleLog, .appleLog), (.appleLog2, .appleLog2): true
        default: false
        }
    }
}

enum CameraCodec: String, CaseIterable, Identifiable, Sendable {
    case hevc, h264, proResHQ, proRes, proResLT, proResProxy
    var id: String { rawValue }
    var title: String {
        switch self { case .hevc: "HEVC"; case .h264: "H.264"; case .proResHQ: "ProRes 422 HQ"; case .proRes: "ProRes 422"; case .proResLT: "ProRes 422 LT"; case .proResProxy: "ProRes 422 Proxy" }
    }
    var isProRes: Bool { self != .hevc && self != .h264 }
    var baseBitRate: Double {
        switch self { case .hevc: 12_000_000; case .h264: 20_000_000; case .proResHQ: 220_000_000; case .proRes: 147_000_000; case .proResLT: 102_000_000; case .proResProxy: 45_000_000 }
    }
}

enum CameraRecordingQuality: String, CaseIterable, Identifiable, Sendable {
    case efficient, balanced, high, maximum
    var id: Self { self }
    var title: String {
        switch self { case .efficient: String(localized: "Efficient"); case .balanced: String(localized: "Balanced"); case .high: String(localized: "High"); case .maximum: String(localized: "Maximum") }
    }
    var multiplier: Double {
        switch self { case .efficient: 0.5; case .balanced: 0.75; case .high: 1; case .maximum: 1.5 }
    }
    func bitRate(format: CameraFormatOption, codec: CameraCodec) -> Int {
        let pixels = Double(format.width) * Double(format.height) / (1920 * 1080)
        return Int(codec.baseBitRate * pixels * Double(format.fps) / 30
                   * (codec.isProRes ? 1 : multiplier * (format.profile.needsTenBit ? 1.25 : 1)))
    }
}

struct CameraFormatOption: Equatable, Hashable, Identifiable, Sendable {
    let width: Int
    let height: Int
    let fps: Int
    let profile: CameraProfile
    var id: String { "\(width)x\(height)-\(fps)-\(profile.rawValue)" }
    var resolutionID: String { "\(width)x\(height)" }
    var isOpenGate: Bool { Double(width) / Double(max(1, height)) < 1.4 }
    var resolution: String {
        if isOpenGate { return "4:3 · \(width)×\(height)" }
        return width >= 3840 ? "4K" : width >= 1920 ? "1080p" : "720p"
    }
    var title: String { "\(resolution) · \(fps) fps" }
    /// MovieFileOutput + VideoDataOutput exceeds the iPhone 15 ISP budget at
    /// 4K50/60. These modes encode from one full-resolution data output instead.
    var usesSampleRecording: Bool { (width >= 3840 && fps > 30) || isOpenGate || profile != .sdr }
}

struct CameraLens: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let isFront: Bool
    var baseZoom: Double = 1
    var maxZoom: Double = 1
}

struct CameraZoomStop: Identifiable, Equatable {
    let lensID: String
    let factor: Double
    let display: Double
    var id: String { "\(lensID)-\(factor)" }
    var label: String { CameraGeometry.zoomLabel(display) }
}

enum CameraGrid: String, CaseIterable, Identifiable {
    case off, thirds, quarters, golden
    var id: String { rawValue }
    var title: String {
        switch self { case .off: String(localized: "Off"); case .thirds: String(localized: "Thirds"); case .quarters: String(localized: "Quarters"); case .golden: String(localized: "Golden ratio") }
    }
    var divisions: [Double] {
        switch self { case .off: []; case .thirds: [1/3, 2/3]; case .quarters: [0.25, 0.5, 0.75]; case .golden: [0.382, 0.618] }
    }
}

enum CameraFrameGuide: String, CaseIterable, Identifiable {
    case off, square, portrait, wide, cinema
    var id: String { rawValue }
    var title: String {
        switch self { case .off: String(localized: "Full frame"); case .square: "1:1"; case .portrait: "4:5"; case .wide: "16:9"; case .cinema: "2.39:1" }
    }
    var aspect: Double? {
        switch self { case .off: nil; case .square: 1; case .portrait: 0.8; case .wide: 16/9; case .cinema: 2.39 }
    }
}

struct CameraGuideSettings: Equatable {
    var grid: CameraGrid = .off
    var frame: CameraFrameGuide = .off
    var center = false
    var safeArea = false
    var level = false
    var isEnabled: Bool { grid != .off || frame != .off || center || safeArea || level }
}

enum CameraShutterUnit: String, CaseIterable, Identifiable {
    case speed, angle
    var id: Self { self }
    var title: String {
        self == .speed ? String(localized: "camera.shutter.speed", defaultValue: "Speed") : String(localized: "Angle")
    }
}

enum CameraFlicker: String, CaseIterable, Identifiable, Sendable {
    case off, hz50, hz60
    var id: Self { self }
    var title: String {
        switch self { case .off: String(localized: "Off"); case .hz50: "50 Hz"; case .hz60: "60 Hz" }
    }

    /// Whole lighting cycles nearest a 180° shutter, within the sensor's range.
    /// Shorter exposure wins ties. No partial-cycle clamp is called flicker-safe.
    func duration(fps: Int, range: ClosedRange<Double>) -> Double? {
        guard self != .off else { return nil }
        let cycle = 1 / Double(self == .hz50 ? 100 : 120)
        let first = max(1, Int(ceil(range.lowerBound / cycle - 0.000001)))
        let last = Int(floor(range.upperBound / cycle + 0.000001))
        guard first <= last else { return nil }
        let target = 1 / Double(max(1, fps) * 2)
        return (first...last).map { Double($0) * cycle }.min {
            let a = abs($0 - target), b = abs($1 - target)
            return abs(a - b) < 0.000001 ? $0 < $1 : a < b
        }
    }
}

struct CameraControls: Equatable, Sendable {
    var manualExposure = false
    var iso: Double = 100
    var shutterSeconds: Double = 1.0 / 60
    /// An angle follows FPS changes; a speed remains an absolute duration.
    var shutterAngle: Double?
    var flicker: CameraFlicker = .off
    var exposureBias: Double = 0
    var manualWhiteBalance = false
    var temperature: Double = 5600
    var tint: Double = 0
    var manualFocus = false
    var focus: Double = 0.5
}

struct CameraControlLimits: Equatable, Sendable {
    var iso: ClosedRange<Double> = 25...2000
    var shutter: ClosedRange<Double> = (1.0 / 8000)...(1.0 / 30)
    var bias: ClosedRange<Double> = -2...2
    var supportsExposure = false
    var supportsWhiteBalance = false
    var supportsFocus = false

    func shutterRange(fps: Int) -> ClosedRange<Double> {
        shutter.lowerBound...max(shutter.lowerBound, min(shutter.upperBound, 1 / Double(max(1, fps))))
    }

    func clamped(_ controls: CameraControls, fps: Int) -> CameraControls {
        var result = controls
        result.iso = min(max(controls.iso, iso.lowerBound), iso.upperBound)
        result.shutterSeconds = min(max(controls.shutterSeconds, shutterRange(fps: fps).lowerBound), shutterRange(fps: fps).upperBound)
        if controls.manualExposure {
            let range = shutterRange(fps: fps)
            if let duration = controls.flicker.duration(fps: fps, range: range) {
                result.shutterSeconds = duration
                result.shutterAngle = nil
            } else {
                result.flicker = .off
                if let angle = controls.shutterAngle, angle.isFinite {
                    result.shutterSeconds = min(max(angle / 360 / Double(max(1, fps)), range.lowerBound), range.upperBound)
                    result.shutterAngle = result.shutterSeconds * Double(max(1, fps)) * 360
                }
            }
        }
        result.exposureBias = min(max(controls.exposureBias, bias.lowerBound), bias.upperBound)
        result.temperature = min(max(controls.temperature, 2500), 10000)
        result.tint = min(max(controls.tint, -100), 100)
        result.focus = min(max(controls.focus, 0), 1)
        result.manualExposure = controls.manualExposure && supportsExposure
        result.manualWhiteBalance = controls.manualWhiteBalance && supportsWhiteBalance
        result.manualFocus = controls.manualFocus && supportsFocus
        return result
    }
}

enum CameraGeometry {
    static func clampedZoom(_ value: Double, range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    static func zoomLabel(_ factor: Double) -> String {
        String(format: factor.rounded() == factor ? "%.0f×" : "%.1f×", factor)
    }

    static func guideRect(aspect: Double?, image: CGRect) -> CGRect {
        guard let aspect, aspect > 0 else { return image }
        let fit = fittedRect(image: CGSize(width: aspect, height: 1), in: image.size)
        return fit.offsetBy(dx: image.minX, dy: image.minY)
    }
    static func fittedRect(image: CGSize, in bounds: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / image.width, bounds.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// Preview buffers are physically rotated. Convert the tap back to the
    /// sensor's landscape coordinates; taps in the letterbox do nothing.
    static func focusPoint(tap: CGPoint, imageRect: CGRect, rotation: Int) -> CGPoint? {
        guard imageRect.width > 0, imageRect.height > 0, imageRect.contains(tap) else { return nil }
        let x = (tap.x - imageRect.minX) / imageRect.width
        let y = (tap.y - imageRect.minY) / imageRect.height
        switch rotation {
        case 90: return CGPoint(x: y, y: 1 - x)
        case 180: return CGPoint(x: 1 - x, y: 1 - y)
        case 270: return CGPoint(x: 1 - y, y: x)
        default: return CGPoint(x: x, y: y)
        }
    }

    static func shutterLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        return "1/\(Int((1 / seconds).rounded()))"
    }

    static func shutterAngle(_ seconds: Double, fps: Int) -> Double {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return min(360, seconds * Double(max(1, fps)) * 360)
    }

    static func angleLabel(_ seconds: Double, fps: Int) -> String {
        let angle = shutterAngle(seconds, fps: fps)
        return String(format: abs(angle - angle.rounded()) < 0.05 ? "%.0f°" : "%.1f°", angle)
    }

    /// Gravity is device-relative; the preview buffers carry capture rotation.
    /// Looking straight up/down has no useful projected horizon.
    static func horizonAngle(x: Double, y: Double, rotation: Int) -> Double? {
        guard x.isFinite, y.isFinite, hypot(x, y) >= 0.2 else { return nil }
        var angle = atan2(-x, -y) * 180 / .pi + Double(rotation - 90)
        angle = (angle + 90).truncatingRemainder(dividingBy: 180)
        if angle < 0 { angle += 180 }
        return angle - 90
    }
}

/// A level can align to either quarter-turn, even with portrait orientation
/// lock enabled. The reference and the live line must use the same axis.
struct CameraHorizonReading {
    let angle: Double
    var reference: Double { abs(angle) > 45 ? (angle > 0 ? 90 : -90) : 0 }
    var deviation: Double { angle - reference }
    var isLevel: Bool { abs(deviation) < 0.8 }
    var isVertical: Bool { reference != 0 }
}

struct CameraRecordingEstimate {
    /// Matches the recorder's free-space reserve. Container/audio overhead is
    /// included; variable scene complexity means this is always an estimate.
    static let reserveBytes: Int64 = 200_000_000
    let seconds: Double

    init(freeBytes: Int64, format: CameraFormatOption, codec: CameraCodec, hasAudio: Bool,
         recordedBytes: Int64 = 0, elapsed: Double = 0, quality: CameraRecordingQuality = .high) {
        let video = Double(quality.bitRate(format: format, codec: codec))
        let predicted = (video + (hasAudio ? 256_000 : 0)) / 8 * 1.03
        // Fragmented MOVs can buffer a few seconds before reaching disk.
        let observed = elapsed >= 5 && recordedBytes > 0 ? Double(recordedBytes) / elapsed * 1.08 : 0
        let bytesPerSecond = observed > 0 ? observed : predicted
        seconds = Double(max(0, freeBytes - Self.reserveBytes)) / max(1, bytesPerSecond)
    }

    var label: String {
        if seconds < 60 { return String(localized: "< 1 min") }
        let minutes = Int(seconds / 60)
        if minutes >= 60 { return String(localized: "≈ \(minutes / 60)h \(minutes % 60)m") }
        return String(localized: "≈ \(minutes) min")
    }
    var isLow: Bool { seconds < 120 }
}
