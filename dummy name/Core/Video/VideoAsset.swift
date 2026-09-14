import Foundation

struct VideoAsset: Identifiable, Equatable, Sendable {
    let id: UUID
    let url: URL
    let metadata: VideoMetadata
    let sourceRange: TimelineRange?
    let frameDuration: TimelineTime?

    init(id: UUID = UUID(), url: URL, metadata: VideoMetadata,
         sourceRange: TimelineRange? = nil, frameDuration: TimelineTime? = nil) {
        self.id = id
        self.url = url
        self.metadata = metadata
        self.sourceRange = sourceRange
        self.frameDuration = frameDuration
    }
}
