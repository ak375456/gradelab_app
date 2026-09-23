import XCTest
import AVFoundation
@testable import GradeLab

/// Measures what a timeline of image overlays actually costs, because the
/// arithmetic alone kept being wrong about it.
final class OverlayMemoryProfileTests: XCTestCase {
    /// Resident size of this process, in bytes.
    private func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    private func overlayURL() throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "overlay_test", withExtension: "heic"))
    }

    private func videoURL() throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "uhd_test", withExtension: "mov"))
    }

    /// Splits the main track into `count` clips, the way an edited timeline is.
    private func split(_ project: inout VideoProject, into count: Int) throws {
        guard count > 1,
              let track = project.timeline.tracks.firstIndex(where: { $0.kind == .mainVideo }),
              case .video(let first)? = project.timeline.tracks[track].items.first else { return }
        let whole = first.placement.duration.seconds
        let piece = whole / Double(count)
        var items: [TimelineItem] = []
        for index in 0..<count {
            var clip = first
            clip.placement = .init(id: UUID(), trackID: first.placement.trackID,
                                   timelineStart: try .seconds(piece * Double(index)),
                                   duration: try .seconds(piece))
            clip.sourceRange = .init(start: try .seconds(first.sourceRange.start.seconds + piece * Double(index)),
                                     duration: try .seconds(piece))
            items.append(.video(clip))
        }
        project.timeline.tracks[track].items = items
    }

    /// The project from the report: a video with nine image overlays over it.
    private func project(overlays: Int, clips: Int = 1, titles: Int = 0) async throws -> VideoProject {
        let video = try videoURL()
        let asset = try await VideoMetadataReader().read(from: video, originalFileName: "retime_test.mov")
        var project = VideoProject(sourceURL: video, displayName: "Overlays", metadata: asset.metadata)

        let image = try overlayURL()
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(image as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try XCTUnwrap(props[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(props[kCGImagePropertyPixelHeight] as? Int)
        for index in 0..<overlays {
            let media = ProjectMediaAsset(
                id: UUID(), url: image,
                sourceRange: .init(start: .zero, duration: try .seconds(4)),
                videoMetadata: nil, frameDuration: nil,
                stillImage: .init(width: width, height: height))
            project.addAsset(media)
            let trackID = UUID()
            let clip = VideoClip(
                placement: .init(id: UUID(), trackID: trackID,
                                 timelineStart: .zero, duration: try .seconds(4)),
                assetID: media.id, sourceRange: .init(start: .zero, duration: try .seconds(4)))
            project.timeline.tracks.insert(
                .init(id: trackID, name: "Overlay \(index)", kind: .videoOverlay, items: [.video(clip)]), at: 0)
        }
        for index in 0..<titles {
            let trackID = UUID()
            var clip = TextClip(placement: .init(id: UUID(), trackID: trackID,
                                                 timelineStart: try .seconds(Double(index) * 0.4),
                                                 duration: try .seconds(0.4)), text: "Title \(index)")
            clip.style.fontSize = 180
            project.timeline.tracks.insert(
                .init(id: trackID, name: "Text \(index)", kind: .text, items: [.text(clip)]), at: 0)
        }
        try split(&project, into: clips)
        return project
    }

    /// Renders a handful of frames the way playback does and reports the cost.
    private func render(_ project: VideoProject, frames: Int = 6) async throws -> Int {
        let sequence = try await SequenceComposition.buildLayers(project: project, forExport: false)
        let generator = AVAssetImageGenerator(asset: sequence.source.asset)
        generator.videoComposition = sequence.source.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let before = footprint()
        var peak = before
        var rendered = 0
        var failure: String?
        var frameSize: CGSize?
        for index in 0..<frames {
            let time = CMTime(seconds: Double(index) * 0.4, preferredTimescale: 600)
            do {
                let result = try await generator.image(at: time)
                rendered += 1
                if frameSize == nil {
                    frameSize = CGSize(width: result.image.width, height: result.image.height)
                }
            } catch {
                if failure == nil { failure = "\(error)" }
            }
            peak = max(peak, footprint())
        }
        withExtendedLifetime(sequence) {}
        if rendered == 0 { throw Failure.noFrames(failure ?? "unknown") }
        Self.lastFrameSize = frameSize
        Self.lastInstructions = sequence.source.videoComposition?.instructions.count ?? -1
        Self.lastRenderSize = sequence.source.videoComposition?.renderSize ?? .zero
        return peak - before
    }
    nonisolated(unsafe) static var lastFrameSize: CGSize?
    nonisolated(unsafe) static var lastInstructions = 0
    nonisolated(unsafe) static var lastRenderSize = CGSize.zero

    enum Failure: Error { case noFrames(String) }

    /// The reported timeline, measured: eleven 4K clips, nine 24-megapixel
    /// image overlays and eleven titles.
    ///
    /// Before the decode was sized to the canvas, the nine overlays alone were
    /// nine 4032x3024 BGRA surfaces — about 440 MB — against a cache that held
    /// four and emptied itself on the fifth, so most of them were re-decoded
    /// from a 24-megapixel file on every frame. The budget here is deliberately
    /// far above what it now costs and far below what it used to.
    func testAFullTimelineCompositesWithinABudget() async throws {
        let cost = try await render(try await project(overlays: 9, clips: 11, titles: 11))
        XCTAssertLessThan(cost, 250 << 20, "layered compositing cost \(cost >> 20)MB")
    }

    /// Overlays specifically: adding eight more must not add hundreds of
    /// megabytes, which is the regression this guards.
    func testExtraOverlaysAreNearlyFree() async throws {
        let one = try await render(try await project(overlays: 1))
        let nine = try await render(try await project(overlays: 9))
        let perOverlay = max(0, nine - one) / 8
        XCTAssertLessThan(perOverlay, 24 << 20,
                          "each extra overlay cost \(perOverlay >> 20)MB; it used to be ~48MB decoded plus a re-decode per frame")
    }
}
