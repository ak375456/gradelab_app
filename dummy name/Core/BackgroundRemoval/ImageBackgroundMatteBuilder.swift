import CoreGraphics
import CoreVideo
import Foundation

/// CPU builder used by still preview/export. It operates at a bounded matte
/// resolution, while authored brushes remain vector data and are rasterized
/// afresh for the requested output.
enum ImageBackgroundMatteBuilder {
    static func make(projectID: UUID, itemID: UUID, source: CVPixelBuffer,
                     settings authored: BackgroundRemovalSettings) -> BackgroundMaskPlane {
        let settings = authored.clamped
        let sourceWidth = CVPixelBufferGetWidth(source), sourceHeight = CVPixelBufferGetHeight(source)
        let factor = min(1, 2_048 / Double(max(sourceWidth, sourceHeight)))
        let width = max(1, Int(Double(sourceWidth) * factor))
        let height = max(1, Int(Double(sourceHeight) * factor))
        var base: BackgroundMaskPlane
        if settings.mode == .colorKey {
            base = colorKey(source: source, width: width, height: height, settings: settings.colorKey)
        } else if settings.mode == .lasso, let lasso = settings.lasso,
                  let outline = BackgroundLassoMatte.plane(for: lasso, atLocal: nil,
                                                           aspectWidth: width, aspectHeight: height) {
            base = resized(outline, width: width, height: height)
        } else if let cached = BackgroundRemovalMaskStore.shared.nearest(
            projectID: projectID, clipID: itemID, analysisID: settings.analysisID, frame: 0) {
            base = resized(cached, width: width, height: height)
        } else {
            base = .init(width: width, height: height,
                         values: Data(repeating: 255, count: width * height))
        }

        let shift = Int((abs(settings.edgeShift) / 100 * 0.02 * Double(min(width, height))).rounded())
        if shift > 0 { base = morphology(base, radius: shift, expands: settings.edgeShift > 0) }
        let feather = Int((settings.feather / 100 * 0.018 * Double(min(width, height))).rounded())
        if feather > 0 { base = boxBlur(base, radius: feather) }

        let add = strokes(settings.addStrokes, width: width, height: height)
        let remove = strokes(settings.removeStrokes, width: width, height: height)
        var result = base.values
        result.withUnsafeMutableBytes { outRaw in
            add.values.withUnsafeBytes { addRaw in
                remove.values.withUnsafeBytes { removeRaw in
                    let out = outRaw.bindMemory(to: UInt8.self)
                    let a = addRaw.bindMemory(to: UInt8.self), r = removeRaw.bindMemory(to: UInt8.self)
                    for i in 0..<out.count {
                        let kept = max(Int(out[i]), Int(a[i]))
                        let value = kept * (255 - Int(r[i])) / 255
                        out[i] = UInt8(settings.isInverted ? 255 - value : value)
                    }
                }
            }
        }
        return .init(width: width, height: height, values: result)
    }

    /// Returns a new premultiplied BGRA buffer with the matte in alpha.
    static func applying(_ matte: BackgroundMaskPlane, to source: CVPixelBuffer,
                         settings: BackgroundRemovalSettings? = nil) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA else { return nil }
        var output: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:],
                          kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                  attributes, &output) == kCVReturnSuccess,
              let output else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(output, [])
        defer {
            CVPixelBufferUnlockBaseAddress(output, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let input = CVPixelBufferGetBaseAddress(source)?.assumingMemoryBound(to: UInt8.self),
              let destination = CVPixelBufferGetBaseAddress(output)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let inputStride = CVPixelBufferGetBytesPerRow(source), outputStride = CVPixelBufferGetBytesPerRow(output)
        matte.values.withUnsafeBytes { raw in
            let mask = raw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                let my = min(matte.height - 1, y * matte.height / height)
                for x in 0..<width {
                    let mx = min(matte.width - 1, x * matte.width / width)
                    let alpha = Int(mask[my * matte.width + mx])
                    let sourceOffset = y * inputStride + x * 4
                    let outputOffset = y * outputStride + x * 4
                    var blue = input[sourceOffset]
                    var green = input[sourceOffset + 1]
                    var red = input[sourceOffset + 2]
                    suppressColorSpill(blue: &blue, green: &green, red: &red,
                                       alpha: alpha, settings: settings)
                    destination[outputOffset] = UInt8(Int(blue) * alpha / 255)
                    destination[outputOffset + 1] = UInt8(Int(green) * alpha / 255)
                    destination[outputOffset + 2] = UInt8(Int(red) * alpha / 255)
                    destination[outputOffset + 3] = UInt8(alpha)
                }
            }
        }
        return output
    }

    static func mattePreview(_ matte: BackgroundMaskPlane, width: Int, height: Int) -> CVPixelBuffer? {
        var output: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:],
                          kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                  attributes, &output) == kCVReturnSuccess,
              let output else { return nil }
        CVPixelBufferLockBaseAddress(output, [])
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        guard let destination = CVPixelBufferGetBaseAddress(output)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(output)
        matte.values.withUnsafeBytes { raw in
            let mask = raw.bindMemory(to: UInt8.self)
            for y in 0..<height { for x in 0..<width {
                let mx = min(matte.width-1, x*matte.width/width)
                let my = min(matte.height-1, y*matte.height/height)
                let value = mask[my*matte.width+mx], offset = y*stride+x*4
                destination[offset] = value; destination[offset+1] = value
                destination[offset+2] = value; destination[offset+3] = 255
            }}
        }
        return output
    }

    static func applyToExport(_ matte: BackgroundMaskPlane, bytes: UnsafeMutableRawPointer,
                              width: Int, height: Int, bytesPerRow: Int,
                              preserveAlpha: Bool, background: RGBAColor = .white,
                              settings: BackgroundRemovalSettings? = nil) {
        let pixels = bytes.assumingMemoryBound(to: UInt8.self)
        let backgroundBGRA = [background.blue, background.green, background.red].map {
            Int(min(max($0, 0), 1) * 255)
        }
        matte.values.withUnsafeBytes { raw in
            let mask = raw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                let my = min(matte.height - 1, y * matte.height / height)
                for x in 0..<width {
                    let mx = min(matte.width - 1, x * matte.width / width)
                    let alpha = Int(mask[my * matte.width + mx])
                    let offset = y * bytesPerRow + x * 4
                    var blue = pixels[offset]
                    var green = pixels[offset + 1]
                    var red = pixels[offset + 2]
                    suppressColorSpill(blue: &blue, green: &green, red: &red,
                                       alpha: alpha, settings: settings)
                    if preserveAlpha {
                        pixels[offset] = UInt8(Int(blue) * alpha / 255)
                        pixels[offset + 1] = UInt8(Int(green) * alpha / 255)
                        pixels[offset + 2] = UInt8(Int(red) * alpha / 255)
                        pixels[offset + 3] = UInt8(alpha)
                    } else {
                        let inverse = 255 - alpha
                        let foreground = [blue, green, red]
                        for channel in 0..<3 {
                            pixels[offset + channel] = UInt8((Int(foreground[channel]) * alpha
                                + backgroundBGRA[channel] * inverse) / 255)
                        }
                        pixels[offset + 3] = 255
                    }
                }
            }
        }
    }

    /// Pulls the keyed colour out of semi-transparent edge pixels without
    /// desaturating the retained subject. The effect deliberately falls to zero
    /// in fully opaque and fully transparent areas.
    private static func suppressColorSpill(blue: inout UInt8, green: inout UInt8, red: inout UInt8,
                                           alpha: Int, settings: BackgroundRemovalSettings?) {
        guard let settings, settings.mode == .colorKey,
              settings.colorKey.spill > 0, alpha > 0, alpha < 255 else { return }
        let key = settings.colorKey.color
        let keyChannels = [key.blue, key.green, key.red]
        guard let dominant = keyChannels.indices.max(by: { keyChannels[$0] < keyChannels[$1] }) else { return }
        var channels = [Int(blue), Int(green), Int(red)]
        let other = max(channels[(dominant + 1) % 3], channels[(dominant + 2) % 3])
        let edge = 1 - abs(Double(alpha) / 127.5 - 1)
        let strength = min(max(settings.colorKey.spill / 100, 0), 1) * edge
        channels[dominant] = Int((Double(channels[dominant]) * (1 - strength)
            + Double(min(channels[dominant], other)) * strength).rounded())
        blue = UInt8(clamping: channels[0])
        green = UInt8(clamping: channels[1])
        red = UInt8(clamping: channels[2])
    }

    private static func colorKey(source: CVPixelBuffer, width: Int, height: Int,
                                 settings: BackgroundColorKeySettings) -> BackgroundMaskPlane {
        var result = Data(repeating: 255, count: width * height)
        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA else {
            return .init(width: width, height: height, values: result)
        }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard let pixels = CVPixelBufferGetBaseAddress(source)?.assumingMemoryBound(to: UInt8.self) else {
            return .init(width: width, height: height, values: result)
        }
        let stride = CVPixelBufferGetBytesPerRow(source)
        let key = (r: settings.color.red, g: settings.color.green, b: settings.color.blue)
        func chroma(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double) {
            (-0.168736*r - 0.331264*g + 0.5*b, 0.5*r - 0.418688*g - 0.081312*b)
        }
        let kc = chroma(key.r, key.g, key.b)
        let low = settings.similarity / 200, smooth = max(0.002, settings.smoothness / 300)
        result.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                let sy = min(CVPixelBufferGetHeight(source)-1, y * CVPixelBufferGetHeight(source) / height)
                for x in 0..<width {
                    let sx = min(CVPixelBufferGetWidth(source)-1, x * CVPixelBufferGetWidth(source) / width)
                    let offset = sy * stride + sx * 4
                    let c = chroma(Double(pixels[offset+2])/255, Double(pixels[offset+1])/255,
                                   Double(pixels[offset])/255)
                    let d = hypot(c.0-kc.0, c.1-kc.1)
                    let t = min(max((d-low)/smooth, 0), 1)
                    let smoothstep = t*t*(3-2*t)
                    out[y*width+x] = UInt8((smoothstep * 255).rounded())
                }
            }
        }
        return .init(width: width, height: height, values: result)
    }

    private static func resized(_ source: BackgroundMaskPlane, width: Int, height: Int) -> BackgroundMaskPlane {
        var values = Data(repeating: 0, count: width * height)
        values.withUnsafeMutableBytes { outRaw in
            let out = outRaw.bindMemory(to: UInt8.self)
            for y in 0..<height { for x in 0..<width {
                out[y*width+x] = source.value(x: x*source.width/width, y: y*source.height/height)
            }}
        }
        return .init(width: width, height: height, values: values)
    }

    private static func strokes(_ strokes: [BackgroundRemovalStroke], width: Int, height: Int) -> BackgroundMaskPlane {
        var values = Data(repeating: 0, count: width * height)
        values.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.setLineCap(.round); context.setLineJoin(.round)
            for authored in strokes {
                let stroke = authored.clamped
                guard let first = stroke.points.first else { continue }
                let radius = stroke.radius * Double(min(width, height))
                for band in 0...8 {
                    let t = Double(band)/8
                    let line = max(1, radius*2*(1-stroke.softness+stroke.softness*t))
                    context.setStrokeColor(gray: 1, alpha: stroke.opacity*(0.075+0.11*t))
                    context.setLineWidth(line)
                    context.beginPath(); context.move(to: .init(x: first.x*Double(width), y: (1-first.y)*Double(height)))
                    if stroke.points.count == 1 {
                        context.addLine(to: .init(x: first.x*Double(width)+0.01, y: (1-first.y)*Double(height)+0.01))
                    } else {
                        for point in stroke.points.dropFirst() {
                            context.addLine(to: .init(x: point.x*Double(width), y: (1-point.y)*Double(height)))
                        }
                    }
                    context.strokePath()
                }
            }
        }
        return .init(width: width, height: height, values: values)
    }

    private static func morphology(_ source: BackgroundMaskPlane, radius: Int, expands: Bool) -> BackgroundMaskPlane {
        guard radius > 0 else { return source }
        var horizontal = Data(repeating: 0, count: source.values.count)
        var output = horizontal
        horizontal.withUnsafeMutableBytes { hRaw in source.values.withUnsafeBytes { sRaw in
            let h = hRaw.bindMemory(to: UInt8.self), s = sRaw.bindMemory(to: UInt8.self)
            for y in 0..<source.height { for x in 0..<source.width {
                var value: UInt8 = expands ? 0 : 255
                for dx in -radius...radius {
                    let sample = s[y*source.width+min(max(x+dx,0),source.width-1)]
                    value = expands ? max(value,sample) : min(value,sample)
                }
                h[y*source.width+x] = value
            }}
        }}
        output.withUnsafeMutableBytes { oRaw in horizontal.withUnsafeBytes { hRaw in
            let o = oRaw.bindMemory(to: UInt8.self), h = hRaw.bindMemory(to: UInt8.self)
            for y in 0..<source.height { for x in 0..<source.width {
                var value: UInt8 = expands ? 0 : 255
                for dy in -radius...radius {
                    let sample = h[min(max(y+dy,0),source.height-1)*source.width+x]
                    value = expands ? max(value,sample) : min(value,sample)
                }
                o[y*source.width+x] = value
            }}
        }}
        return .init(width: source.width, height: source.height, values: output)
    }

    private static func boxBlur(_ source: BackgroundMaskPlane, radius: Int) -> BackgroundMaskPlane {
        guard radius > 0 else { return source }
        let count = radius*2+1
        var horizontal = Data(repeating: 0, count: source.values.count), output = horizontal
        horizontal.withUnsafeMutableBytes { hRaw in source.values.withUnsafeBytes { sRaw in
            let h = hRaw.bindMemory(to: UInt8.self), s = sRaw.bindMemory(to: UInt8.self)
            for y in 0..<source.height { for x in 0..<source.width {
                var sum = 0
                for dx in -radius...radius { sum += Int(s[y*source.width+min(max(x+dx,0),source.width-1)]) }
                h[y*source.width+x] = UInt8(sum/count)
            }}
        }}
        output.withUnsafeMutableBytes { oRaw in horizontal.withUnsafeBytes { hRaw in
            let o = oRaw.bindMemory(to: UInt8.self), h = hRaw.bindMemory(to: UInt8.self)
            for y in 0..<source.height { for x in 0..<source.width {
                var sum = 0
                for dy in -radius...radius { sum += Int(h[min(max(y+dy,0),source.height-1)*source.width+x]) }
                o[y*source.width+x] = UInt8(sum/count)
            }}
        }}
        return .init(width: source.width, height: source.height, values: output)
    }
}
