@preconcurrency import AVFoundation
import Metal
import Foundation
import ImageIO

/// Real, synthetic-media integration test on the Mac; no simulator or user media.
@main
struct ValidateSequence {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GradeLab-Sequence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("source.mov")
        log("Generating synthetic video + audio")
        try await generateSource(url)
        log("Inspecting source and building sequence")
        let asset = try await VideoMetadataReader().read(from: url)
        var project = VideoProject(sourceURL: url, displayName: "Sequence test", metadata: asset.metadata,
                                   sourceRange: asset.sourceRange, frameDuration: asset.frameDuration)
        let first = project.timeline.firstVideoClip!.id
        let second = try TimelineEditing.split(first, at: .seconds(1), in: &project)
        try TimelineEditing.move(second, to: .seconds(2), in: &project)
        var grade = GradeSettings.neutral; grade.exposure = -1
        project.timeline.setGrade(grade, for: second)
        _ = try TimelineEditing.clips(in: project)
        let sequence = try await SequenceComposition.build(project: project)
        precondition(abs(sequence.source.duration.seconds - 4) < 0.001)
        precondition(sequence.source.audioTracks.count == 1)
        let device = MTLCreateSystemDefaultDevice()!
        let shader = try String(contentsOfFile: "dummy name/Metal/Shaders.metal", encoding: .utf8)
        let library = try await device.makeLibrary(source: shader, options: nil)
        let context = try MetalContext(library: library)
        let exporter = try VideoExporter(context: context)
        try await validateExportScheduling(asset: asset, context: context, exporter: exporter, root: root)
        var configuration = ExportConfiguration(codec: .h264)
        configuration.container = .mp4
        let output = try await exporter.export(asset: asset, settings: .neutral, configuration: configuration,
            project: project, outputURL: root.appendingPathComponent("result.mp4"),
            onStateChange: { state in
                switch state { case .preparing: log("Export preparing"); case .completed: log("Export completed"); default: break }
            })
        let result = AVURLAsset(url: output)
        let duration = try await result.load(.duration)
        precondition(abs(duration.seconds - 4) < 0.06, "Incorrect export duration")
        let tracks = try await result.loadTracks(withMediaType: .audio)
        precondition(tracks.count == 1, "Linked audio missing")
        let generator = AVAssetImageGenerator(asset: result)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let red = try await pixel(generator, time: 0.5)
        let gap = try await pixel(generator, time: 1.5)
        let blue = try await pixel(generator, time: 2.5)
        precondition(red[0] > 0.5 && red[2] < 0.3, "First clip content incorrect")
        precondition(gap.prefix(3).allSatisfy { $0 < 0.04 }, "Gap must be black, not a held frame")
        precondition(blue[2] > blue[0] * 2 && blue[2] < 0.65, "Second clip content/grade incorrect")
        let silence = try await audioRMS(result, at: 1.4)
        let signal = try await audioRMS(result, at: 2.4)
        precondition(silence < 0.005 && signal > 0.03, "Audio gap/timing incorrect")
        configuration.codec = .hevc; configuration.container = .mov
        configuration.frameRate = .fps24
        configuration.resolution = .custom; configuration.customLongEdge = 320
        let converted = try await exporter.export(asset: asset, settings: .neutral, configuration: configuration,
            project: project, outputURL: root.appendingPathComponent("converted.mov"))
        let convertedMetadata = try await VideoMetadataReader().read(from: converted).metadata
        precondition(convertedMetadata.displayWidth == 320 && convertedMetadata.displayHeight == 180)
        precondition(abs((convertedMetadata.nominalFrameRate ?? 0)-24) < 0.01)
        let convertedGenerator = AVAssetImageGenerator(asset: AVURLAsset(url: converted))
        let convertedGap = try await pixel(convertedGenerator, time: 1.5)
        precondition(convertedGap.prefix(3).allSatisfy { $0 < 0.04 }, "FPS conversion filled the gap with a previous clip")
        print("PASS: real split/move composition, 4-second MP4/H.264 export, per-clip grade, black gap, linked AAC audio and silent gap")
        print("PASS: HEVC/MOV resize + 24 FPS conversion preserves black gap and output dimensions/cadence")
        log("Testing multiple sources and real layered export")
        let secondURL = root.appendingPathComponent("second.mov")
        try await generateSource(secondURL)
        let secondAsset = try await VideoMetadataReader().read(from: secondURL)
        var layered = VideoProject(sourceURL: url, displayName: "Layers", metadata: asset.metadata,
            sourceRange: asset.sourceRange, frameDuration: asset.frameDuration)
        let media = ProjectMediaAsset(id: UUID(), url: secondURL, sourceRange: secondAsset.sourceRange!, videoMetadata: secondAsset.metadata, frameDuration: secondAsset.frameDuration)
        layered.addAsset(media)
        let trackID = UUID()
        var overlay = VideoClip(placement: .init(id: UUID(), trackID: trackID, timelineStart: .zero, duration: try .seconds(1)),
            assetID: media.id, sourceRange: .init(start: try .seconds(1), duration: try .seconds(1)), embeddedAudio: EmbeddedAudio())
        overlay.gradeSettings.exposure = -1
        layered.timeline.tracks.insert(.init(id: trackID, name: "Overlay", kind: .videoOverlay, items: [.video(overlay)]), at: 0)
        configuration = .init(codec: .h264)
        let layeredURL = try await exporter.export(asset: asset, settings: .neutral, configuration: configuration, project: layered,
            outputURL: root.appendingPathComponent("layered.mov"))
        let layeredReader = AVAssetImageGenerator(asset: AVURLAsset(url: layeredURL))
        let top = try await pixel(layeredReader, time: 0.5)
        precondition(top[2] > top[0]*2 && top[2] < 0.65, "Overlay grade/order missing: \(top)")
        let layerAudio = try await AVURLAsset(url: layeredURL).loadTracks(withMediaType: .audio)
        precondition(layerAudio.count == 1, "Layer audio must mix into one delivery track")
        layered.timeline.tracks[0].isEnabled = false
        let hiddenURL = try await exporter.export(asset: asset, settings: .neutral, configuration: configuration, project: layered,
            outputURL: root.appendingPathComponent("hidden.mov"))
        let hidden = try await pixel(AVAssetImageGenerator(asset: AVURLAsset(url: hiddenURL)), time: 0.5)
        precondition(hidden[0] > hidden[2]*2, "Hidden overlay still rendered")
        layered.timeline.tracks[0].isEnabled = true
        overlay.transform.scale = 0.5; overlay.transform.rotationDegrees = 90
        overlay.opacity = 0.5; overlay.blendMode = .screen
        layered.timeline.tracks[0].items = [.video(overlay)]
        let transformedURL = try await exporter.export(asset: asset, settings: .neutral, configuration: configuration, project: layered,
            outputURL: root.appendingPathComponent("transformed.mov"))
        let transformed = try await pixel(AVAssetImageGenerator(asset: AVURLAsset(url: transformedURL)), time: 0.5)
        precondition(transformed[0] > top[0] && transformed[2] < top[2], "Transform/opacity/blend not reflected")
        layered.timeline.tracks.swapAt(0, 1)
        let reorderedURL = try await exporter.export(asset: asset, settings: .neutral, configuration: configuration, project: layered,
            outputURL: root.appendingPathComponent("reordered.mov"))
        let reordered = try await pixel(AVAssetImageGenerator(asset: AVURLAsset(url: reorderedURL)), time: 0.5)
        precondition(reordered[0] > reordered[2]*2, "Track order not applied")
        print("PASS: additional source, layered per-clip grading, visibility, transform/opacity/screen blend, track order and mixed audio export")
        let portraitURL = root.appendingPathComponent("portrait.mov")
        try await generateSource(portraitURL, portraitPattern: true)
        let portrait = try await VideoMetadataReader().read(from: portraitURL)
        var portraitProject = VideoProject(sourceURL: portraitURL, displayName: "Portrait", metadata: portrait.metadata,
            sourceRange: portrait.sourceRange, frameDuration: portrait.frameDuration)
        portraitProject.timeline.tracks.insert(.init(id: UUID(), name: "Empty overlay", kind: .videoOverlay), at: 0)
        let portraitExport = try await exporter.export(asset: portrait, settings: .neutral, configuration: configuration,
            project: portraitProject, outputURL: root.appendingPathComponent("portrait-result.mov"))
        let portraitMetadata = try await VideoMetadataReader().read(from: portraitExport).metadata
        precondition(portraitMetadata.displayWidth == 90 && portraitMetadata.displayHeight == 160, "Portrait canvas rotated twice")
        let reference = AVAssetImageGenerator(asset: AVURLAsset(url: portraitURL)); reference.appliesPreferredTrackTransform = true
        let rendered = AVAssetImageGenerator(asset: AVURLAsset(url: portraitExport)); rendered.appliesPreferredTrackTransform = true
        for x in [0.25, 0.75] {
            let expected = try await pixelAt(reference, x: x, y: 0.5)
            let actual = try await pixelAt(rendered, x: x, y: 0.5)
            precondition(zip(expected, actual).allSatisfy { abs($0-$1) < 0.1 }, "Portrait orientation mismatch \(expected) vs \(actual)")
        }
        print("PASS: portrait layered composition matches source orientation and canvas dimensions")
        let imageURL = root.appendingPathComponent("overlay.png")
        var pixels = [UInt8](repeating: 0, count: 64*32*4)
        for y in 0..<32 { for x in 32..<64 { pixels[(y*64+x)*4+1] = 190; pixels[(y*64+x)*4+3] = 255 } }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let still = CGImage(width: 64, height: 32, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 64*4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(imageURL as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, still, nil); precondition(CGImageDestinationFinalize(destination))
        var imageProject = VideoProject(sourceURL: url, displayName: "Still test", metadata: asset.metadata, sourceRange: asset.sourceRange, frameDuration: asset.frameDuration)
        let imageAsset = ProjectMediaAsset(id: UUID(), url: imageURL, sourceRange: .init(start: .zero, duration: try .seconds(3)), videoMetadata: nil, frameDuration: nil, stillImage: .init(width: 64, height: 32))
        imageProject.addAsset(imageAsset)
        let imageTrack = UUID()
        let imageClip = VideoClip(placement: .init(id: UUID(), trackID: imageTrack, timelineStart: .zero, duration: try .seconds(3)),
            assetID: imageAsset.id, sourceRange: imageAsset.sourceRange)
        imageProject.timeline.tracks.insert(.init(id: imageTrack, name: "Image", kind: .videoOverlay, items: [.video(imageClip)]), at: 0)
        let imageExport = try await exporter.export(asset: asset, settings: .neutral, configuration: configuration, project: imageProject, outputURL: root.appendingPathComponent("image.mov"))
        let imageReader = AVAssetImageGenerator(asset: AVURLAsset(url: imageExport))
        let transparent = try await pixelAt(imageReader, x: 0.25, y: 0.5)
        let opaque = try await pixelAt(imageReader, x: 0.75, y: 0.5)
        precondition(transparent[0] > transparent[1]*2 && opaque[1] > opaque[0]*2, "Image alpha or image rendering failed")
        imageProject.timeline.tracks[1].items = []
        let stillOnly = try await exporter.export(asset: asset, settings: .neutral, configuration: configuration, project: imageProject, outputURL: root.appendingPathComponent("still-only.mov"))
        let only = try await pixelAt(AVAssetImageGenerator(asset: AVURLAsset(url: stillOnly)), x: 0.75, y: 0.5)
        precondition(only[1] > 0.4, "Image-only timeline is blank")
        imageProject.canvas.width = 108; imageProject.canvas.height = 192
        let customCanvas = try await exporter.export(asset: asset, settings: .neutral, configuration: configuration, project: imageProject, outputURL: root.appendingPathComponent("canvas.mov"))
        let customMetadata = try await VideoMetadataReader().read(from: customCanvas).metadata
        precondition(customMetadata.displayWidth == 108 && customMetadata.displayHeight == 192)
        print("PASS: transparent PNG overlay, image-only timeline and custom canvas export")
        var liveProject = VideoProject(sourceURL: url, displayName: "Live", metadata: asset.metadata, sourceRange: asset.sourceRange, frameDuration: asset.frameDuration)
        let live = try await SequenceComposition.buildLayers(project: liveProject, forExport: false, context: context)
        let liveReader = AVAssetImageGenerator(asset: live.source.asset)
        liveReader.videoComposition = live.source.videoComposition
        let beforeLive = try await pixel(liveReader, time: 0.5)
        var liveClip = liveProject.timeline.firstVideoClip!
        liveClip.transform.positionX = 2
        try TimelineEditing.replace(liveClip.id, with: [liveClip], in: &liveProject)
        live.layerState!.update(liveProject, bypass: false)
        liveReader.videoComposition = live.source.videoComposition?.mutableCopy() as? AVVideoComposition
        let afterLive = try await pixel(liveReader, time: 0.6)
        precondition(beforeLive[0] > 0.5 && afterLive.prefix(3).allSatisfy { $0 < 0.04 }, "Live transform state did not update the existing composition")
        print("PASS: live transform refresh without export or composition rebuild")
        log("Testing independent audio and shared preview/export mix")
        var audioProject = VideoProject(sourceURL: url, displayName: "Audio", metadata: asset.metadata,
            sourceRange: asset.sourceRange, frameDuration: asset.frameDuration)
        let originalAudio = try await audioRMS(AVURLAsset(url: url), at: 0.5)
        let soundID = try AudioEditing.separate(audioProject.timeline.firstVideoClip!.id, in: &audioProject)
        let separatedSequence = try await SequenceComposition.build(project: audioProject, context: context)
        precondition(separatedSequence.source.audioTracks.count == 1, "Separation doubled the audio")
        let previewSound = try await audioRMS(separatedSequence.source.asset, at: 0.5, mix: separatedSequence.source.audioMix)
        precondition(abs(previewSound/originalAudio-1) < 0.06, "Separated preview changed source level")
        var soundClip = audioProject.timeline.audioClip(id: soundID)!
        soundClip.volume = 0.25
        try AudioEditing.replace(soundID, with: [soundClip], in: &audioProject)
        let liveMix = separatedSequence.audioRouting.makeMix(audioProject)
        let liveVolume = try await audioRMS(separatedSequence.source.asset, at: 0.5, mix: liveMix)
        precondition(abs(liveVolume/previewSound-0.25) < 0.03, "Live mix did not update existing composition")
        log("Exporting separated audio at 25%")
        let quietURL = try await exporter.export(asset: asset, settings: .neutral, configuration: configuration,
            project: audioProject, outputURL: root.appendingPathComponent("quiet.mov"))
        let exportedVolume = try await audioRMS(AVURLAsset(url: quietURL), at: 0.5)
        precondition(abs(exportedVolume/liveVolume-1) < 0.12, "Preview and export audio levels differ")
        soundClip.isMuted = true
        try AudioEditing.replace(soundID, with: [soundClip], in: &audioProject)
        let mutedVolume = try await audioRMS(separatedSequence.source.asset, at: 0.5, mix: separatedSequence.audioRouting.makeMix(audioProject))
        precondition(mutedVolume < 0.0001)
        soundClip.isMuted = false; soundClip.volume = 1
        try AudioEditing.replace(soundID, with: [soundClip], in: &audioProject)
        let audioRight = try AudioEditing.split(soundID, at: .seconds(1), in: &audioProject)
        try AudioEditing.replace(soundID, with: [], in: &audioProject)
        try AudioEditing.edit(audioRight, operation: .trimEnd, to: .seconds(2), in: &audioProject)
        try AudioEditing.edit(audioRight, operation: .move, to: .seconds(3), in: &audioProject)
        log("Exporting moved audio with a black tail")
        let movedURL = try await exporter.export(asset: asset, settings: .neutral, configuration: configuration,
            project: audioProject, outputURL: root.appendingPathComponent("moved-audio.mov"))
        let movedSound = AVURLAsset(url: movedURL)
        let earlySilence = try await audioRMS(movedSound, at: 0.5)
        let lateSound = try await audioRMS(movedSound, at: 3.5)
        let audioTail = try await pixel(AVAssetImageGenerator(asset: movedSound), time: 3.5)
        precondition(earlySilence < 0.001 && lateSound > 0.03 && audioTail.prefix(3).allSatisfy { $0 < 0.04 }, "Moved audio timing or black tail incorrect")
        audioProject.timeline.tracks[0].items = []
        log("Exporting audio-only timeline")
        let audioOnlyURL = try await exporter.export(asset: asset, settings: .neutral, configuration: configuration,
            project: audioProject, outputURL: root.appendingPathComponent("audio-only.mov"))
        let audioOnlySound = try await audioRMS(AVURLAsset(url: audioOnlyURL), at: 3.5)
        precondition(audioOnlySound > 0.03, "Audio-only timeline lost its sound")
        print("PASS: no doubled audio after separation, live mix changes, preview/export volume parity, mute, split/trim/move gaps, audio tail and audio-only timeline export")

        let wavURL = root.appendingPathComponent("External sound.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88_200)!
        buffer.frameLength = 88_200
        for i in 0..<88_200 { buffer.floatChannelData![0][i] = Float(sin(Double(i)*2*Double.pi*330/44_100))*0.2 }
        do {
            let file = try AVAudioFile(forWriting: wavURL, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
            try file.write(from: buffer)
        }
        let importedAudio = try await AudioImportService.load(wavURL, store: ProjectStore(rootURL: root.appendingPathComponent("ImportTest")))
        precondition(importedAudio.url != wavURL && importedAudio.audioName == "External sound" && importedAudio.videoMetadata == nil)
        precondition(tryData(importedAudio.url) == tryData(wavURL), "Import modified source audio")
        audioProject.addAsset(importedAudio)
        let importTrack = UUID()
        let externalClip = AudioClip(placement: .init(id: UUID(), trackID: importTrack, timelineStart: .zero,
            duration: importedAudio.sourceRange.duration), assetID: importedAudio.id, sourceRange: importedAudio.sourceRange)
        audioProject.timeline.tracks.append(.init(id: importTrack, name: "External", kind: .audio, items: [.audio(externalClip)]))
        let externalURL = try await exporter.export(asset: asset, settings: .neutral, configuration: configuration,
            project: audioProject, outputURL: root.appendingPathComponent("external-audio.mov"))
        let externalLevel = try await audioRMS(AVURLAsset(url: externalURL), at: 0.5)
        precondition(externalLevel > 0.05, "External WAV missing from export")
        audioProject.timeline.tracks[audioProject.timeline.tracks.count-1].isEnabled = false
        let trackMuted = try await SequenceComposition.build(project: audioProject, context: context)
        let mutedTrackLevel = try await audioRMS(trackMuted.source.asset, at: 0.5, mix: trackMuted.source.audioMix)
        precondition(mutedTrackLevel < 0.001, "Muted audio track still plays")
        let waveformDirectory = root.appendingPathComponent("Waveforms")
        let waveformStore = AudioWaveformStore(cacheDirectory: waveformDirectory)
        let envelope = try await waveformStore.load(importedAudio)
        let cachedEnvelope = try await AudioWaveformStore(cacheDirectory: waveformDirectory).load(importedAudio)
        precondition(!envelope.isEmpty && envelope.contains { $0 > 0.1 } && envelope == cachedEnvelope)
        let badAudio = root.appendingPathComponent("bad.wav")
        try Data("not audio".utf8).write(to: badAudio)
        do {
            _ = try await AudioImportService.load(badAudio, store: ProjectStore(rootURL: root.appendingPathComponent("ImportTest")))
            fatalError("Invalid audio imported")
        } catch { }
        print("PASS: durable external WAV import, decoding validation, waveform generation/disk cache, audio-track mute and external audio export")
        log("Testing visible text, live state updates and exported text timing")
        var textProject = VideoProject(sourceURL: url, displayName: "Text", metadata: asset.metadata, sourceRange: asset.sourceRange, frameDuration: asset.frameDuration)
        let textTrack = UUID()
        var title = TextClip(placement: .init(id: UUID(), trackID: textTrack, timelineStart: .zero, duration: try .seconds(1)))
        title.text = "TEXT"; title.style.fontSize = 32; title.style.isBold = true
        textProject.timeline.tracks.insert(.init(id: textTrack, name: "Text", kind: .text, items: [.text(title)]), at: 0)
        let textSequence = try await SequenceComposition.build(project: textProject, context: context)
        let textPreview = AVAssetImageGenerator(asset: textSequence.source.asset)
        textPreview.videoComposition = textSequence.source.videoComposition
        let previewText = try await pixel(textPreview, time: 0.5)
        let plain = try await pixel(AVAssetImageGenerator(asset: AVURLAsset(url: url)), time: 0.5)
        precondition(previewText[1] > plain[1]+0.025, "White text missing from composed preview")
        let textURL = try await exporter.export(asset: asset, settings: .neutral, configuration: .init(codec: .h264), project: textProject, outputURL: root.appendingPathComponent("text.mov"))
        let textReader = AVAssetImageGenerator(asset: AVURLAsset(url: textURL))
        let exportedText = try await pixel(textReader, time: 0.5)
        precondition(zip(previewText, exportedText).allSatisfy { abs($0-$1) < 0.06 }, "Text preview/export disagree")
        let afterText = try await pixel(textReader, time: 1.5)
        let afterSource = try await pixel(AVAssetImageGenerator(asset: AVURLAsset(url: url)), time: 1.5)
        precondition(zip(afterText, afterSource).allSatisfy { abs($0-$1) < 0.06 }, "Text persists after its end")
        title.color = .init(red: 0, green: 1, blue: 0)
        textProject.timeline.tracks[0].items = [.text(title)]
        textSequence.layerState!.update(textProject, bypass: false)
        let updatedPreview = AVAssetImageGenerator(asset: textSequence.source.asset)
        updatedPreview.videoComposition = textSequence.source.videoComposition?.mutableCopy() as? AVVideoComposition
        let updated = try await pixel(updatedPreview, time: 0.5)
        precondition(updated[2] < previewText[2]-0.015, "Live text color did not update without rebuilding")
        print("PASS: text visible in actual video composition and H.264 export, matching pixels, exact duration, live color state without sequence rebuild")
        try await animation(url: url, asset: asset, exporter: exporter, context: context, root: root)
    }

    /// Animation must render identically in preview and export, at exact keyframe times and
    /// between them, and must survive a split through an eased span.
    static func animation(url: URL, asset: VideoAsset, exporter: VideoExporter, context: MetalContext, root: URL) async throws {
        log("Testing animated text: preview/export parity, intermediate times, eased split, layered animation")
        func makeProject(_ build: (inout TextClip) -> Void) -> (VideoProject, UUID) {
            var project = VideoProject(sourceURL: url, displayName: "Animated", metadata: asset.metadata,
                                       sourceRange: asset.sourceRange, frameDuration: asset.frameDuration)
            let trackID = UUID()
            var clip = TextClip(placement: .init(id: UUID(), trackID: trackID, timelineStart: .zero, duration: try! .seconds(3)))
            clip.text = "AA"; clip.style.fontSize = 40; clip.style.isBold = true
            clip.style.layoutWidth = 1.4
            build(&clip)
            project.timeline.tracks.insert(.init(id: trackID, name: "Text", kind: .text, items: [.text(clip)]), at: 0)
            return (project, clip.id)
        }

        // Position, scale, rotation and opacity animated together over the clip.
        let (project, clipID) = makeProject { clip in
            var animation = ClipAnimation()
            animation.update(.positionX) { track in
                track.set(.number(0.2), at: .zero)
                track.set(.number(0.8), at: try! .seconds(2))
            }
            animation.update(.scale) { track in
                track.set(.number(0.6), at: .zero, interpolation: .easeInOut)
                track.set(.number(2.2), at: try! .seconds(2), interpolation: .easeInOut)
            }
            animation.update(.rotation) { track in
                track.set(.number(0), at: .zero)
                track.set(.number(360), at: try! .seconds(2))
            }
            animation.update(.opacity) { track in
                track.set(.number(0), at: .zero)
                track.set(.number(1), at: try! .seconds(1))
            }
            clip.animation = animation
        }
        precondition(project.needsLayerCompositor, "animation did not force the compositing path")

        let sequence = try await SequenceComposition.build(project: project, context: context)
        let preview = AVAssetImageGenerator(asset: sequence.source.asset)
        preview.videoComposition = sequence.source.videoComposition
        preview.requestedTimeToleranceBefore = .zero; preview.requestedTimeToleranceAfter = .zero
        let exportURL = try await exporter.export(asset: asset, settings: .neutral, configuration: .init(codec: .h264),
                                                  project: project, outputURL: root.appendingPathComponent("animated.mov"))
        let exported = AVAssetImageGenerator(asset: AVURLAsset(url: exportURL))
        exported.requestedTimeToleranceBefore = .zero; exported.requestedTimeToleranceAfter = .zero

        // Exact keyframe times AND intermediate times.
        var previews: [Double: [Double]] = [:]
        for time in [0.0, 0.25, 0.5, 1.0, 1.4, 1.75, 2.0, 2.5] {
            let composed = try await pixel(preview, time: time)
            let written = try await pixel(exported, time: time)
            previews[time] = composed
            precondition(zip(composed, written).allSatisfy { abs($0-$1) < 0.06 },
                "Animated preview and export disagree at \(time)s: \(composed) vs \(written)")
        }
        // Opacity 0 at the clip start must look like the untouched source.
        let source = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        source.requestedTimeToleranceBefore = .zero; source.requestedTimeToleranceAfter = .zero
        let untouched = try await pixel(source, time: 0)
        precondition(zip(previews[0.0]!, untouched).allSatisfy { abs($0-$1) < 0.06 },
            "Zero-opacity keyframe still drew text")
        // The animation actually moves: sampled frames must not all be identical.
        precondition(previews[0.5]! != previews[1.75]!, "Animated frames are identical; nothing animated")

        // A static clip with the same base values must NOT match the animated one mid-span,
        // proving the renderer is evaluating keyframes rather than the authored value.
        let (staticProject, _) = makeProject { clip in
            clip.transform.positionX = 0.2; clip.transform.scale = 0.6; clip.opacity = 0
        }
        let staticSequence = try await SequenceComposition.build(project: staticProject, context: context)
        let staticPreview = AVAssetImageGenerator(asset: staticSequence.source.asset)
        staticPreview.videoComposition = staticSequence.source.videoComposition
        let staticFrame = try await pixel(staticPreview, time: 1.75)
        precondition(staticFrame != previews[1.75]!,
            "Animated and static clips render the same; keyframes are being ignored")

        // Splitting through an eased span must not change any retained frame.
        var split = project
        let rightID = try OverlayEditing.split(clipID, at: try .seconds(1.5), in: &split)
        precondition(rightID != clipID)
        let splitSequence = try await SequenceComposition.build(project: split, context: context)
        let splitPreview = AVAssetImageGenerator(asset: splitSequence.source.asset)
        splitPreview.videoComposition = splitSequence.source.videoComposition
        splitPreview.requestedTimeToleranceBefore = .zero; splitPreview.requestedTimeToleranceAfter = .zero
        for time in [0.25, 1.0, 1.4, 1.75, 2.5] {
            let after = try await pixel(splitPreview, time: time)
            precondition(zip(previews[time]!, after).allSatisfy { abs($0-$1) < 0.06 },
                "A split through an eased span changed the frame at \(time)s: \(previews[time]!) vs \(after)")
        }

        // Two overlapping animated layers both animate and stay in sync with audio.
        var layered = project
        var second = TextClip(placement: .init(id: UUID(), trackID: UUID(), timelineStart: .zero, duration: try .seconds(3)))
        second.text = "BB"; second.style.fontSize = 44; second.color = .init(red: 0, green: 1, blue: 0)
        second.transform.positionY = 0.8
        var secondAnimation = ClipAnimation()
        secondAnimation.update(.opacity) { track in
            track.set(.number(1), at: .zero)
            track.set(.number(0), at: try! .seconds(2))
        }
        second.animation = secondAnimation
        layered.timeline.tracks.insert(.init(id: second.placement.trackID, name: "Text 2", kind: .text,
                                             items: [.text(second)]), at: 0)
        let layeredURL = try await exporter.export(asset: asset, settings: .neutral, configuration: .init(codec: .h264),
                                                   project: layered, outputURL: root.appendingPathComponent("animated-layers.mov"))
        let layeredReader = AVAssetImageGenerator(asset: AVURLAsset(url: layeredURL))
        layeredReader.requestedTimeToleranceBefore = .zero; layeredReader.requestedTimeToleranceAfter = .zero
        // Compare against the single-layer export at the SAME times: the synthetic source
        // changes colour over its own timeline, so an early-versus-late comparison on one
        // export would measure the background rather than the layer.
        let singleEarly = try await pixel(exported, time: 0.1)
        let layeredEarly = try await pixel(layeredReader, time: 0.1)
        let singleLate = try await pixel(exported, time: 1.9)
        let layeredLate = try await pixel(layeredReader, time: 1.9)
        precondition(layeredEarly[1] > singleEarly[1] + 0.02,
            "The second animated layer is missing while fully opaque: \(layeredEarly) vs \(singleEarly)")
        precondition(abs(layeredLate[1] - singleLate[1]) < 0.02,
            "The second animated layer did not fade out in export: \(layeredLate) vs \(singleLate)")
        let rms = try await audioRMS(AVURLAsset(url: layeredURL), at: 1.0)
        let originalRMS = try await audioRMS(AVURLAsset(url: url), at: 1.0)
        precondition(abs(rms - originalRMS) < 0.05, "Animated layers disturbed audio: \(rms) vs \(originalRMS)")

        // Evaluating for playback must never dirty the authored project.
        precondition(split.timeline.item(id: clipID) != nil)
        let reencoded = try JSONDecoder().decode(VideoProject.self, from: try JSONEncoder().encode(project))
        precondition(reencoded.timeline == project.timeline, "Rendering mutated the authored timeline")
        // The SAME engine drives video/image transforms.
        var videoAnimated = VideoProject(sourceURL: url, displayName: "Animated video", metadata: asset.metadata,
                                         sourceRange: asset.sourceRange, frameDuration: asset.frameDuration)
        var movingClip = videoAnimated.timeline.firstVideoClip!
        var videoAnimation = ClipAnimation()
        videoAnimation.update(.scale) { track in
            track.set(.number(1), at: .zero)
            track.set(.number(0.35), at: try! .seconds(2))
        }
        movingClip.animation = videoAnimation
        try TimelineEditing.replace(movingClip.id, with: [movingClip], in: &videoAnimated)
        precondition(videoAnimated.needsLayerCompositor, "an animated video clip fell back to the non-compositing path")
        let videoSequence = try await SequenceComposition.build(project: videoAnimated, context: context)
        let videoPreview = AVAssetImageGenerator(asset: videoSequence.source.asset)
        videoPreview.videoComposition = videoSequence.source.videoComposition
        videoPreview.requestedTimeToleranceBefore = .zero; videoPreview.requestedTimeToleranceAfter = .zero
        let videoURL = try await exporter.export(asset: asset, settings: .neutral, configuration: .init(codec: .h264),
                                                 project: videoAnimated, outputURL: root.appendingPathComponent("animated-video.mov"))
        let videoExported = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        videoExported.requestedTimeToleranceBefore = .zero; videoExported.requestedTimeToleranceAfter = .zero
        var shrinking: [[Double]] = []
        for time in [0.1, 1.0, 1.9] {
            let composed = try await pixel(videoPreview, time: time)
            let written = try await pixel(videoExported, time: time)
            precondition(zip(composed, written).allSatisfy { abs($0-$1) < 0.06 },
                "Animated video preview and export disagree at \(time)s: \(composed) vs \(written)")
            shrinking.append(composed)
        }
        // Shrinking the picture reveals more black canvas, so the frame must get darker.
        let brightness = shrinking.map { ($0[0] + $0[1] + $0[2]) / 3 }
        precondition(brightness[0] > brightness[2] + 0.05,
            "The video clip did not shrink over time: \(brightness)")

        // Cost of animating a property that forces text re-rasterisation, versus a
        // transform-only animation that reuses the cached glyph raster.
        func measure(_ label: String, _ build: (inout TextClip) -> Void) async throws -> Double {
            let (measured, _) = makeProject(build)
            let sequence = try await SequenceComposition.build(project: measured, context: context)
            let generator = AVAssetImageGenerator(asset: sequence.source.asset)
            generator.videoComposition = sequence.source.videoComposition
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let started = Date()
            for step in 0..<20 { _ = try await pixel(generator, time: Double(step) * 0.1) }
            let elapsed = Date().timeIntervalSince(started) / 20 * 1000
            log(String(format: "  %@: %.1f ms/frame", label, elapsed))
            return elapsed
        }
        let cached = try await measure("transform animation (cached glyph raster)") { clip in
            var animation = ClipAnimation()
            animation.update(.scale) { track in
                track.set(.number(0.5), at: .zero); track.set(.number(2), at: try! .seconds(2))
            }
            clip.animation = animation
        }
        let rasterised = try await measure("font-size animation (re-rasterised each frame)") { clip in
            var animation = ClipAnimation()
            animation.update(.fontSize) { track in
                track.set(.number(20), at: .zero); track.set(.number(60), at: try! .seconds(2))
            }
            clip.animation = animation
        }
        precondition(cached < 250 && rasterised < 250,
            "Animated text frame cost is unreasonable: cached \(cached) ms, rasterised \(rasterised) ms")

        print("PASS: animated text position/scale/rotation/opacity matches between composed preview and H.264 export at keyframe and intermediate times, a split through an eased span is frame-identical, overlapping animated layers export correctly, audio is unaffected, animated video transforms match preview and export, and both cached and re-rasterised animated text stay within budget")
    }

    static func tryData(_ url: URL) -> Data { try! Data(contentsOf: url) }

    static func validateExportScheduling(asset: VideoAsset, context: MetalContext,
                                         exporter: VideoExporter, root: URL) async throws {
        var cuts = VideoProject(sourceURL: asset.url, displayName: "Eleven cuts", metadata: asset.metadata,
            sourceRange: asset.sourceRange, frameDuration: asset.frameDuration)
        var tail = cuts.timeline.firstVideoClip!.id
        for index in 1...10 {
            tail = try TimelineEditing.split(tail, at: TimelineTime(CMTime(value: Int64(index * 8), timescale: 30)), in: &cuts)
        }
        for (index, clip) in try TimelineEditing.clips(in: cuts).enumerated() {
            var grade = GradeSettings.neutral
            grade.exposure = index.isMultiple(of: 2) ? 0 : -2
            cuts.timeline.setGrade(grade, for: clip.id)
        }
        cuts.timeline.tracks.append(.init(id: UUID(), name: "Overlay", kind: .videoOverlay))
        cuts.canvas.frameDuration = try TimelineTime(CMTime(value: 1, timescale: 60))
        let sequence = try await SequenceComposition.build(project: cuts, context: context)
        precondition(sequence.source.compositionVideoTracks?.count == 1,
                     "Eleven sequential cuts of the same source must share one decoder track")
        let instructions = sequence.source.videoComposition!.instructions.compactMap { $0 as? LayerInstruction }
        precondition(instructions.allSatisfy { $0.requiredSourceTrackIDs?.count == 1 })

        var configuration = ExportConfiguration(codec: .h264)
        configuration.container = .mp4
        configuration.frameRate = .fps30
        let url = try await exporter.export(asset: asset, settings: .neutral, configuration: configuration,
            project: cuts, outputURL: root.appendingPathComponent("eleven-cuts.mp4"))
        let movie = AVURLAsset(url: url)
        let track = try await movie.loadTracks(withMediaType: .video).first!
        let reader = try AVAssetReader(asset: movie)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        precondition(reader.startReading())
        var frameCount = 0
        while let sample = output.copyNextSampleBuffer() {
            let actual = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            precondition(abs(actual - Double(frameCount) / 30) < 0.0001, "Incorrect output frame cadence")
            frameCount += 1
        }
        precondition(reader.status == .completed && frameCount == 90, "Export must contain all 90 scheduled frames")
        let generator = AVAssetImageGenerator(asset: movie)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        for index in 0...10 {
            let color = try await pixel(generator, time: Double(index * 8 + 4) / 30)
            let intensity = color.prefix(3).max()!
            precondition(index.isMultiple(of: 2) ? intensity > 0.65 : intensity < 0.5,
                         "Per-clip grade lost at cut \(index): \(color)")
        }

        // Overlapping clips from the SAME file need different source times.
        var overlap = cuts
        let trackID = overlap.timeline.tracks[1].id
        let overlay = VideoClip(placement: .init(id: UUID(), trackID: trackID, timelineStart: .zero,
            duration: try .seconds(1)), assetID: overlap.primaryAssetID,
            sourceRange: .init(start: try .seconds(1), duration: try .seconds(1)))
        overlap.timeline.tracks[1].items = [.video(overlay)]
        let overlapped = try await SequenceComposition.build(project: overlap, context: context)
        let firstInstruction = overlapped.source.videoComposition!.instructions.first as! LayerInstruction
        precondition(Set(firstInstruction.trackIDs.values).count == 2, "Overlapping source frames cannot share a decoder")

        var transitioned = cuts
        _ = try TimelineTransitionEditing.apply(.crossDissolve, at: .seconds(8.0 / 30),
            preferredTrackID: nil, in: &transitioned)
        let transitionSequence = try await SequenceComposition.build(project: transitioned, context: context)
        let transitionInstructions = transitionSequence.source.videoComposition!.instructions.compactMap { $0 as? LayerInstruction }
        precondition(transitionInstructions.contains { Set($0.trackIDs.values).count == 2 },
                     "Transition handles must preserve both source frames")

        var smoothed = VideoProject(sourceURL: asset.url, displayName: "Retimed cuts", metadata: asset.metadata,
            sourceRange: asset.sourceRange, frameDuration: asset.frameDuration)
        _ = try TimelineEditing.split(smoothed.timeline.firstVideoClip!.id, at: .seconds(1), in: &smoothed)
        for clip in try TimelineEditing.clips(in: smoothed) {
            try TimelineEditing.setSpeed(clip.id, to: 0.5, in: &smoothed)
        }
        smoothed.timeline.tracks[0].items = smoothed.timeline.tracks[0].items.map { item in
            guard case .video(var clip) = item else { return item }
            clip.smoothsMotion = true
            return .video(clip)
        }
        let smoothSequence = try await SequenceComposition.build(project: smoothed, context: context)
        precondition(smoothSequence.source.compositionVideoTracks?.count == 2,
                     "Sequential smoothed clips must reuse a primary and a next-frame decoder")
        let smoothURL = try await exporter.export(asset: asset, settings: .neutral, configuration: configuration,
            project: smoothed, outputURL: root.appendingPathComponent("smoothed-cuts.mp4"))
        let smoothDuration = try await AVURLAsset(url: smoothURL).load(.duration)
        precondition(abs(smoothDuration.seconds - 6) < 0.05, "Reusing a retimed track changed the timeline duration")
        log("PASS: 11 cuts share one decoder; 60 fps composition exports 90 frames at 30 fps with per-cut grades; overlaps, transitions and smoothed retiming preserve their source frames and duration")
    }

    static func generateSource(_ url: URL, portraitPattern: Bool = false) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90])
        if portraitPattern { video.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 90, ty: 0) }
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128000])
        writer.add(video); writer.add(audio)
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        var index = 0, audioIndex = 0
        let deadline = Date().addingTimeInterval(30)
        while index < 90 || audioIndex < 90 {
            guard Date() < deadline else { throw TimelineError.invalid("Synthetic writer stalled at video \(index), audio \(audioIndex)") }
            if let error = writer.error { throw error }
            var progressed = false
            if audioIndex < 90, audio.isReadyForMoreMediaData {
                guard audio.append(try audioSample(frame: audioIndex)) else { throw writer.error! }
                audioIndex += 1; progressed = true
                if audioIndex == 90 { audio.markAsFinished() }
            }
            if index < 90, video.isReadyForMoreMediaData {
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixel = buffer!
            CVPixelBufferLockBaseAddress(pixel, [])
            let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixel)
            for y in 0..<90 { for x in 0..<160 {
                let base = y*stride+x*4
                bytes[base] = index >= 30 && index < 60 ? 180 : 30
                bytes[base+1] = index >= 60 ? 180 : 30
                bytes[base+2] = index < 30 ? 180 : 30
                bytes[base+3] = 255
                if portraitPattern {
                    bytes[base] = y < 45 ? 20 : 190
                    bytes[base+1] = 20
                    bytes[base+2] = y < 45 ? 190 : 20
                }
            } }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 30)) else { throw writer.error! }
            index += 1; progressed = true
            if index == 90 { video.markAsFinished() }
            }
            if !progressed { try await Task.sleep(for: .milliseconds(1)) }
        }
        writer.endSession(atSourceTime: CMTime(value: 3, timescale: 1))
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }

    static func log(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }

    static func audioSample(frame: Int) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
            mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: 6400,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: 6400, flags: 0, blockBufferOut: &block)
        let samples = (0..<1600).map { Float(sin(Double(frame*1600+$0) * 2 * .pi * 440 / 48000) * 0.2) }
        samples.withUnsafeBytes { data in _ = CMBlockBufferReplaceDataBytes(with: data.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: 6400) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
            presentationTimeStamp: CMTime(value: Int64(frame*1600), timescale: 48000), decodeTimeStamp: .invalid)
        var size = 4
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block!, formatDescription: description!, sampleCount: 1600,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        return sample!
    }

    static func pixel(_ generator: AVAssetImageGenerator, time: Double) async throws -> [Double] {
        let image = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { ptr in
            let context = CGContext(data: ptr.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes.map { Double($0) / 255 }
    }

    static func pixelAt(_ generator: AVAssetImageGenerator, x: Double, y: Double) async throws -> [Double] {
        let image = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        let crop = image.cropping(to: CGRect(x: Double(image.width)*x, y: Double(image.height)*y, width: 2, height: 2))!
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { ptr in
            let context = CGContext(data: ptr.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes.map { Double($0)/255 }
    }

    static func audioRMS(_ asset: AVAsset, at seconds: Double, mix: AVAudioMix? = nil) async throws -> Double {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: seconds, preferredTimescale: 48000), duration: CMTime(value: 1, timescale: 10))
        let output: AVAssetReaderOutput
        if let mix {
            let mixed = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: ExportMediaSettings.audioReaderSettings())
            mixed.audioMix = mix; output = mixed
        } else { output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: ExportMediaSettings.audioReaderSettings()) }
        reader.add(output); reader.startReading()
        var sum = 0.0, count = 0
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            let size = CMBlockBufferGetDataLength(block)
            var values = [Float](repeating: 0, count: size/4)
            values.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!) }
            for value in values { sum += Double(value*value); count += 1 }
        }
        if let error = reader.error { throw error }
        return count == 0 ? 0 : sqrt(sum / Double(count))
    }
}
