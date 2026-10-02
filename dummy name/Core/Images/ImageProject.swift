import CoreGraphics
import Foundation

/// One imported still, with everything the app knows about it.
///
/// Kept separate from `ProjectMediaAsset` on purpose. That type describes media
/// on a timeline — it has a source range, a frame duration and a place in a
/// track — and a photograph has none of those. Giving a still a fake three-second
/// duration so it could pretend to be a clip is exactly the kind of thing that
/// leaks into the UI later as a play button that does nothing.
struct ImageAsset: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    /// The copy inside the app's own storage. The picture the user chose is
    /// never opened for writing.
    var url: URL
    var metadata: ImageMetadata

    var displaySize: CGSize { metadata.displaySize }
}

/// A still-image grading document.
///
/// It holds a source image and a `GradeSettings` — the same `GradeSettings` a
/// video clip holds, not a still-specific variant of it. That is what makes a
/// preset saved on a video apply to a photograph, and a grade copied from a
/// photograph paste onto a video: there is one description of a grade in this
/// app, and both kinds of document store it.
///
/// There is no timeline, no canvas, no duration and no frame rate, because a
/// photograph has none of those things.
struct ImageProject: Codable, Identifiable, Equatable, Sendable {
    static let currentVersion = 1

    let documentVersion: Int
    let id: UUID
    var displayName: String
    var asset: ImageAsset
    /// The grade. Non-destructive: the source file is never rewritten, and this
    /// is the only thing an edit changes.
    var gradeSettings: GradeSettings
    /// Optional for backwards compatibility with every photo document written
    /// before non-destructive cutouts existed.
    var backgroundRemoval: BackgroundRemovalSettings?
    var thumbnailFileName: String?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        asset: ImageAsset,
        gradeSettings: GradeSettings = .neutral,
        backgroundRemoval: BackgroundRemovalSettings? = nil,
        thumbnailFileName: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        documentVersion = Self.currentVersion
        self.id = id
        self.displayName = displayName
        self.asset = asset
        self.gradeSettings = gradeSettings
        self.backgroundRemoval = backgroundRemoval
        self.thumbnailFileName = thumbnailFileName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var metadata: ImageMetadata { asset.metadata }
    var sourceURL: URL { asset.url }
    var colorSupport: ImageColorSupport { ImageColorSupport(metadata: metadata) }

    /// Repairs app-owned absolute paths after iOS moves the app's data
    /// container, the same repair `GradeProject.relocateManagedFiles` makes for
    /// video. Photo projects never had it, so every install of a new build left
    /// them pointing at the previous container: "Image Unavailable" and a blank
    /// card, with the picture still sitting in `Imports`.
    ///
    /// Only a missing path with a same-named file in GradeLab's current managed
    /// folder is changed, so this never substitutes unrelated external media.
    @discardableResult
    mutating func relocateManagedFiles(to rootURL: URL, fileManager: FileManager = .default) -> Bool {
        var changed = false
        if !fileManager.fileExists(atPath: asset.url.path) {
            let candidate = rootURL
                .appendingPathComponent("Imports", isDirectory: true)
                .appendingPathComponent(asset.url.lastPathComponent)
            if fileManager.fileExists(atPath: candidate.path) {
                asset.url = candidate
                changed = true
            }
        }

        if let thumbnailFileName,
           !fileManager.fileExists(atPath: thumbnailFileName) {
            let candidate = rootURL
                .appendingPathComponent("Thumbnails", isDirectory: true)
                .appendingPathComponent(URL(fileURLWithPath: thumbnailFileName).lastPathComponent)
            if fileManager.fileExists(atPath: candidate.path) {
                self.thumbnailFileName = candidate.path
                changed = true
            }
        }
        return changed
    }

    func validate() throws {
        guard documentVersion <= Self.currentVersion else {
            throw TimelineError.unsupportedVersion("This photo project was made by a newer version of GradeLab. Update the app to open it.")
        }
        guard asset.url.isFileURL else {
            throw TimelineError.invalid(String(localized: "The image project references a source that is not a file."))
        }
        guard asset.metadata.pixelWidth > 0, asset.metadata.pixelHeight > 0 else {
            throw TimelineError.invalid(String(localized: "The image project has no pixel dimensions."))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case documentVersion, id, displayName, asset, gradeSettings, backgroundRemoval
        case thumbnailFileName, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Read and judged before anything else, the way the video document does
        // it. A newer document's other keys are shapes this build has never
        // seen, and failing on one of those would report a file that is simply
        // too new as a damaged one — which is the difference between leaving it
        // alone and moving it aside.
        let version = try c.decodeIfPresent(Int.self, forKey: .documentVersion) ?? 1
        guard version <= Self.currentVersion else {
            throw TimelineError.unsupportedVersion("This photo project was made by a newer version of GradeLab. Update the app to open it.")
        }
        documentVersion = version
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        asset = try c.decode(ImageAsset.self, forKey: .asset)
        // Absent means neutral, which is what a project saved before a grading
        // control existed meant.
        gradeSettings = try c.decodeIfPresent(GradeSettings.self, forKey: .gradeSettings) ?? .neutral
        backgroundRemoval = try c.decodeIfPresent(BackgroundRemovalSettings.self, forKey: .backgroundRemoval)
        thumbnailFileName = try c.decodeIfPresent(String.self, forKey: .thumbnailFileName)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(documentVersion, forKey: .documentVersion)
        try c.encode(id, forKey: .id)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(asset, forKey: .asset)
        try c.encode(gradeSettings, forKey: .gradeSettings)
        try c.encodeIfPresent(backgroundRemoval, forKey: .backgroundRemoval)
        try c.encodeIfPresent(thumbnailFileName, forKey: .thumbnailFileName)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}
