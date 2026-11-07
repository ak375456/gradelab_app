import AVFoundation
import CoreVideo
import SwiftUI
import XCTest
@testable import GradeLab

final class StabilizationWorkflowTests: XCTestCase {
    func testRealAnalysisPreviewAndEncodedExportReduceKnownShake() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stabilization-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("source.mov")
        try await writeShakyVideo(url)
        let source = try await VideoMetadataReader().read(from: url)
        var project = VideoProject(sourceURL: url, displayName: "Shake", metadata: source.metadata)
        var clip = try XCTUnwrap(project.timeline.firstVideoClip)
        clip.stabilization = try await StabilizationAnalysis.analyze(url: url, range: clip.sourceRange, progress: { _ in })
            .adjustingStrength(1)
        let solved = try XCTUnwrap(clip.stabilization)
        XCTAssertGreaterThan(solved.samples.count, 80)
        XCTAssertLessThan(solved.unreliableFrames, 8)
        var rawEnergy = 0.0, remainingEnergy = 0.0
        for sample in solved.samples.dropFirst(15).dropLast(15) {
            let shake = Self.shake(at: sample.seconds)
            rawEnergy += shake.x*shake.x+shake.y*shake.y
            remainingEnergy += pow(shake.x+sample.x*384,2)+pow(shake.y+sample.y*216,2)
        }
        XCTAssertLessThan(remainingEnergy/rawEnergy, 0.15, "Actual registered motion must cancel the known shake.")
        try TimelineEditing.replace(clip.id, with: [clip], in: &project)
        let context = try MetalContext()
        let preview = try await SequenceComposition.build(project: project, forExport: false, context: context)
        let previewFrames = try await frames(preview.source)
        let originalFrames = try await frames(try await ExportSourceInspector.inspect(source))
        let exporter = try VideoExporter(context: context)
        let exportedURL = try await exporter.export(asset: source, settings: .neutral,
            configuration: .init(codec: .h264), project: project, outputURL: folder.appendingPathComponent("result.mov"))
        let exportedAsset = try await VideoMetadataReader().read(from: exportedURL)
        let exportedFrames = try await frames(try await ExportSourceInspector.inspect(exportedAsset))
        XCTAssertEqual(previewFrames.count, originalFrames.count)
        XCTAssertEqual(exportedFrames.count, previewFrames.count)
        let rawMovement = movement(originalFrames), previewMovement = movement(previewFrames)
        print("STABILIZATION_MOVEMENT original=\(rawMovement) preview=\(previewMovement) export=\(movement(exportedFrames))")
        XCTAssertLessThan(previewMovement, rawMovement*0.4)
        XCTAssertLessThan(movement(exportedFrames), rawMovement*0.4)
        var difference = 0.0, count = 0
        for index in stride(from: 15, to: min(previewFrames.count,exportedFrames.count)-15, by: 7) {
            for pixel in stride(from: 0, to: previewFrames[index].count, by: 11) {
                difference += abs(Double(previewFrames[index][pixel])-Double(exportedFrames[index][pixel])); count += 1
            }
        }
        XCTAssertLessThan(difference/Double(max(1,count)), 3, "Preview/export must agree within encoder tolerance.")
        XCTAssertEqual(exportedAsset.metadata.durationSeconds, source.metadata.durationSeconds, accuracy: 1/30)
    }

    func testCancellationDoesNotReturnPartialAnalysis() async throws {
        let task = Task {
            try Task.checkCancellation()
            return try await StabilizationAnalysis.analyze(url: URL(fileURLWithPath: "/tmp/unused-stabilization.mov"),
                range: .init(start: .zero, duration: try .seconds(1)), progress: { _ in })
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled analysis must not produce a document result.") }
        catch is CancellationError {} // expected
    }

    private static func shake(at seconds: Double) -> CGPoint {
        CGPoint(x: (7*sin(seconds*2 * .pi*5)).rounded(), y: (4*cos(seconds*2 * .pi*4)).rounded())
    }

    private func writeShakyVideo(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 384, AVVideoHeightKey: 216,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 384, kCVPixelBufferHeightKey as String: 216])
        writer.add(input)
        guard writer.startWriting() else { throw try XCTUnwrap(writer.error) }
        writer.startSession(atSourceTime: .zero)
        let converter = TrackingLuminance()
        for index in 0..<90 {
            let time = Double(index)/30, offset = Self.shake(at: time)
            let frame = StabilizationTests.patternFrame(dx: Int(offset.x),dy: Int(offset.y))
            let pixel = try converter.pixelBuffer(frame)
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData, Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(index),timescale: 30)) else {
                throw try XCTUnwrap(writer.error)
            }
        }
        input.markAsFinished(); writer.endSession(atSourceTime: CMTime(value: 3,timescale: 1))
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }

    private func frames(_ source: ExportSourceInfo) async throws -> [Data] {
        let reader = try AVAssetReader(asset: source.asset)
        let settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let output: AVAssetReaderOutput
        if let composition = source.videoComposition {
            let video = AVAssetReaderVideoCompositionOutput(videoTracks: source.compositionVideoTracks ?? [source.videoTrack],videoSettings: settings)
            video.videoComposition = composition; output = video
        } else { output = AVAssetReaderTrackOutput(track: source.videoTrack,outputSettings: settings) }
        reader.add(output)
        guard reader.startReading() else { throw try XCTUnwrap(reader.error) }
        var result: [Data] = []
        while let sample = output.copyNextSampleBuffer() {
            let pixel = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            CVPixelBufferLockBaseAddress(pixel,.readOnly)
            let w = CVPixelBufferGetWidth(pixel), h = CVPixelBufferGetHeight(pixel)
            let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(pixel)
            var values = Data(count: w*h)
            for y in 0..<h { for x in 0..<w { values[y*w+x] = bytes[y*row+x*4] } }
            CVPixelBufferUnlockBaseAddress(pixel,.readOnly)
            result.append(values)
        }
        if let error = reader.error { throw error }
        return result
    }

    private func movement(_ frames: [Data]) -> Double {
        guard frames.count > 30 else { return .infinity }
        var difference = 0.0, count = 0
        for i in 15..<(frames.count-15) {
            for pixel in stride(from: 0,to: frames[i].count,by: 23) {
                difference += abs(Double(frames[i][pixel])-Double(frames[i-1][pixel])); count += 1
            }
        }
        return difference/Double(max(1,count))
    }
}

@MainActor
final class StabilizationPanelTests: XCTestCase {
    func testFreeAnalysisShowsPaywallWithoutChangingTheProject() throws {
        let model = try modelForEditing(hasAccess: { false })
        let before = model.project
        let analysis = StabilizationAnalysisController()
        analysis.analyze(model)
        XCTAssertFalse(analysis.isAnalyzing)
        XCTAssertEqual(model.stabilizationPaywallFeature, .stabilization)
        XCTAssertEqual(model.project, before)
        XCTAssertTrue(model.history.undoEntries.isEmpty)
    }

    func testFreeEditingAndRevokedAnalysisCannotApplyButDisablingIsAllowed() throws {
        var hasAccess = true
        let model = try modelForEditing(hasAccess: { hasAccess })
        let before = model.project
        let original = try XCTUnwrap(model.selectedClip)
        let result = try XCTUnwrap(original.stabilization).adjustingStrength(1)
        hasAccess = false
        XCTAssertFalse(model.applyStabilization(result, analyzedClip: original))
        model.setStabilizationStrength(0.2)
        XCTAssertEqual(model.project, before)
        XCTAssertTrue(model.history.undoEntries.isEmpty)
        XCTAssertEqual(model.stabilizationPaywallFeature, .stabilization)
        model.setStabilizationEnabled(false)
        XCTAssertFalse(try XCTUnwrap(model.selectedClip?.stabilization?.isEnabled))
        XCTAssertEqual(model.history.undoEntries.count, 1)
        model.stabilizationPaywallFeature = nil
        model.setStabilizationEnabled(true)
        XCTAssertFalse(try XCTUnwrap(model.selectedClip?.stabilization?.isEnabled))
        XCTAssertEqual(model.stabilizationPaywallFeature, .stabilization)
        hasAccess = true
        model.stabilizationPaywallFeature = nil
        model.setStabilizationEnabled(true)
        XCTAssertTrue(try XCTUnwrap(model.selectedClip?.stabilization?.isEnabled))
        XCTAssertTrue(model.applyStabilization(result, analyzedClip: original))
        XCTAssertEqual(model.selectedClip?.stabilization?.strength, 1)
        XCTAssertNil(model.stabilizationPaywallFeature)
    }

    func testSmoothnessDragHasOneUndoEntryEvenWhenPausedAndBeforeIsTransient() async throws {
        let model = try modelForEditing()
        let before = model.project
        model.unstabilizedPreviewClipID = model.selectedClipID
        XCTAssertEqual(model.project,before)
        XCTAssertTrue(model.history.undoEntries.isEmpty)
        model.unstabilizedPreviewClipID = nil
        model.stabilizationGestureChanged(true)
        model.setStabilizationStrength(0.3)
        try await Task.sleep(for: .milliseconds(750))
        XCTAssertTrue(model.history.undoEntries.isEmpty,"Pausing while dragging must not split the undo gesture.")
        model.setStabilizationStrength(0.6)
        model.stabilizationGestureChanged(false)
        XCTAssertEqual(model.history.undoEntries.count,1)
        model.undo()
        XCTAssertEqual(model.selectedClip?.stabilization,before.timeline.firstVideoClip?.stabilization)
    }

    func testCancelAnalysisKeepsTheDocumentAndHistoryUntouched() async throws {
        let model = try modelForEditing()
        let before = model.project
        let analysis = StabilizationAnalysisController()
        analysis.analyze(model)
        XCTAssertTrue(analysis.isAnalyzing)
        analysis.cancel()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(analysis.isAnalyzing)
        XCTAssertEqual(model.project,before)
        XCTAssertTrue(model.history.undoEntries.isEmpty)
    }

    private func modelForEditing(hasAccess: @escaping @MainActor () -> Bool = { true }) throws -> EditorViewModel {
        var project = VideoProject(sourceURL: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("retime_test.mov"),
            displayName: "Stabilization",metadata: makeVideoMetadata(durationSeconds: 2))
        var clip = project.timeline.firstVideoClip!
        clip.stabilization = VideoStabilization(encodedWidth: 1920,encodedHeight: 1080,
            analyzedRange: clip.sourceRange,samples: [
                .init(seconds: 0,x: 0.01,y: 0,rotation: 0,segment: 0),
                .init(seconds: 2,x: -0.01,y: 0,rotation: 0,segment: 0)
            ]).adjustingStrength(0.8)
        try TimelineEditing.replace(clip.id,with: [clip],in: &project)
        let model = try EditorViewModel(project: project, stabilizationAccess: hasAccess)
        model.suspendPreviewForExport()
        return model
    }

    func testPanelFitsNarrowAndWideWithLargeText() throws {
        for (width,height,large,paid) in [(320.0,540.0,false,true),(640.0,660.0,false,true),(320.0,540.0,true,true),(320.0,540.0,false,false)] {
            var project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/stabilization-layout.mov"),
                displayName: "Stabilization", metadata: makeVideoMetadata(durationSeconds: 2))
            var clip = project.timeline.firstVideoClip!
            clip.stabilization = VideoStabilization(encodedWidth: 1920,encodedHeight: 1080,
                analyzedRange: clip.sourceRange, samples: [
                    .init(seconds: 0,x: 0.01,y: 0,rotation: 0,segment: 0),
                    .init(seconds: 2,x: -0.01,y: 0,rotation: 0,segment: 0)
                ],limitedCorrection: true,unreliableFrames: 2).adjustingStrength(0.8)
            try TimelineEditing.replace(clip.id,with: [clip],in: &project)
            let model = try EditorViewModel(project: project, stabilizationAccess: { paid })
            model.suspendPreviewForExport()
            let panel = StabilizationPanel(model: model).preferredColorScheme(.dark)
                .environment(\.dynamicTypeSize,large ? .accessibility2 : .large)
                .background(AppColors.background)
            let host = UIHostingController(rootView: panel)
            let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
            let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
            window.frame = CGRect(x: 0,y: 0,width: width,height: height)
            window.rootViewController = host; window.makeKeyAndVisible()
            host.view.frame = window.bounds; window.layoutIfNeeded()
            let deadline = Date().addingTimeInterval(0.25)
            while Date() < deadline { RunLoop.current.run(mode: .default,before: Date().addingTimeInterval(0.02)) }
            func scrolls(_ view: UIView) -> [UIScrollView] {
                (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
            }
            let scroll = try XCTUnwrap(scrolls(host.view).first)
            XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width+1)
            let image = UIGraphicsImageRenderer(size: window.bounds.size).image { host.view.layer.render(in: $0.cgContext) }
            let attachment = XCTAttachment(image: image); attachment.name = "Stabilization \(width) large=\(large) paid=\(paid)"
            attachment.lifetime = .keepAlways; add(attachment)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("stabilization-panel-\(Int(width))-\(large)-\(paid).png")
            try image.pngData()?.write(to: url)
            print("STABILIZATION_PANEL_SHOT \(url.path)")
            window.isHidden = true
        }
    }
}
