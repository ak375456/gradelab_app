import AVFoundation
import CoreVideo
import Foundation

// Decodes a tagged HLG file three ways and reports the ACTUAL float values
// produced for known HLG signal levels. Establishes the working-space
// normalisation empirically instead of assuming it.
let url = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "hlg_test.mov")
let levels: [Double] = ProcessInfo.processInfo.environment["GAMUT"] != nil ? [0, 1, 2, 3] : [0.0, 0.25, 0.50, 0.75, 1.0]
let labels = ["white .75", "BT2020 red", "BT2020 green", "BT2020 blue"]

func describeMetadata() async throws {
    let asset = AVURLAsset(url: url)
    let track = try await asset.loadTracks(withMediaType: .video)[0]
    let fd = try await track.load(.formatDescriptions)[0]
    let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:]
    print("Source tags:")
    for key in ["ColorPrimaries", "TransferFunction", "CVImageBufferYCbCrMatrix",
                "BitsPerComponent", "FullRangeVideo"] {
        if let v = ext.first(where: { $0.key.contains(key) }) { print("  \(v.key) = \(v.value)") }
    }
    print("  subtype = \(CMFormatDescriptionGetMediaSubType(fd))")
}

func read(settings: [String: Any], label: String) async throws {
    let asset = AVURLAsset(url: url)
    let track = try await asset.loadTracks(withMediaType: .video)[0]
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    guard reader.canAdd(output) else { print("\(label): settings REJECTED"); return }
    reader.add(output)
    reader.startReading()
    guard let sample = output.copyNextSampleBuffer(),
          let buffer = CMSampleBufferGetImageBuffer(sample) else {
        print("\(label): no frame (status \(reader.status.rawValue)) \(reader.error?.localizedDescription ?? "")")
        return
    }
    let fmt = CVPixelBufferGetPixelFormatType(buffer)
    func fourCC(_ c: OSType) -> String {
        String(bytes: [UInt8(c >> 24 & 255), UInt8(c >> 16 & 255), UInt8(c >> 8 & 255), UInt8(c & 255)],
               encoding: .macOSRoman) ?? "\(c)"
    }
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let h = CVPixelBufferGetHeight(buffer)
    let w = CVPixelBufferGetWidth(buffer)
    let band = h / levels.count
    print("\n\(label)")
    print("  pixel format: \(fourCC(fmt))  \(w)x\(h)")
    guard fmt == kCVPixelFormatType_64RGBAHalf else {
        print("  (not half-float, skipping value read)")
        return
    }
    let row = CVPixelBufferGetBytesPerRow(buffer)
    let base = CVPixelBufferGetBaseAddress(buffer)!
    for (i, level) in levels.enumerated() {
        let y = min(h - 1, i * band + band / 2)
        let p = base.advanced(by: y * row + (w / 2) * 8).assumingMemoryBound(to: Float16.self)
        if ProcessInfo.processInfo.environment["GAMUT"] != nil {
            let neg = (Float(p[0]) < -0.001 || Float(p[1]) < -0.001 || Float(p[2]) < -0.001)
            print(String(format: "  %-13@ -> R %8.4f  G %8.4f  B %8.4f   %@",
                         labels[i] as NSString, Float(p[0]), Float(p[1]), Float(p[2]),
                         neg ? "out-of-gamut PRESERVED (negative)" : "in gamut / clamped"))
        } else {
            print(String(format: "  HLG %.2f (code %4d) -> R %.4f  G %.4f  B %.4f",
                         level, Int(64 + level * 876),
                         Float(p[0]), Float(p[1]), Float(p[2])))
        }
    }
}

@main struct Measure {
  static func main() async throws {
let linear2020: [String: Any] = [
    AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_Linear,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
    ],
    AVVideoAllowWideColorKey: true,
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf
]
var linearP3 = linear2020
linearP3[AVVideoColorPropertiesKey] = [
    AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
    AVVideoTransferFunctionKey: AVVideoTransferFunction_Linear,
    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
]
let passthrough10: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
]

    try await describeMetadata()
    try await read(settings: passthrough10, label: "A. native 10-bit x420 passthrough")
    try await read(settings: linear2020, label: "B. linear BT.2020 primaries, 64RGBAHalf")
    try await read(settings: linearP3, label: "C. linear Display P3 primaries, 64RGBAHalf")

  }
}
