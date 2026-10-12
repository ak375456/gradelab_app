import AppKit
import AVFoundation

let url = URL(fileURLWithPath: "/tmp/gradelab-mask-demo.mp4")
try? FileManager.default.removeItem(at: url)
let image = NSImage(contentsOfFile: "/tmp/gradelab-mask-photo.png")!
let photo = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
let width = 1920, height = 1080
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width, AVVideoHeightKey: height,
    AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                               AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                               AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000]
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
    kCVPixelBufferCGImageCompatibilityKey as String: true,
    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)
for frame in 0..<90 {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    let pixel = buffer!
    CVPixelBufferLockBaseAddress(pixel, [])
    let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    // A gentle camera move provides real source motion for the tracker.
    let shift = CGFloat(frame) / 89 * 40
    context.draw(photo, in: CGRect(x: -shift, y: -12, width: 1980, height: 1114))
    CVPixelBufferUnlockBaseAddress(pixel, [])
    precondition(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
precondition(writer.status == .completed, "\(String(describing: writer.error))")
print(url.path)
