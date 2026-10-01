import CoreGraphics
import Foundation
import simd

// ---------------------------------------------------------------------------
// Where a clip's depth comes from
//
// Depth is a property of SOURCE FRAMES, not of timeline positions. Two clips
// cut from one file share it, a split clip keeps it, a speed ramp reads it at
// whatever source frame the time map lands on, and a reversed clip reads it
// backwards — all for free, because every lookup goes through the clip's own
// `sourceTime(at:)` and arrives here as a source time. Nothing in Relight is
// ever keyed by a timeline frame index.
// ---------------------------------------------------------------------------

/// The affine map from encoded, top-left source UVs to the upright picture's
/// UVs: the one rotation or reflection a camera stored the frame with.
///
/// Grading runs on encoded pixels (see `MaskTrackingCoordinates`), while a
/// light is placed on the picture a person sees. This is the bridge, and the
/// shader uses it per pixel so "light from the right" stays on the right of
/// the screen for a portrait clip recorded sideways.
struct RelightOrientation: Equatable, Sendable {
    /// display u = row0.x * u + row0.y * v + row0.z
    var row0: SIMD3<Float>
    /// display v = row1.x * u + row1.y * v + row1.z
    var row1: SIMD3<Float>

    static let identity = RelightOrientation(row0: SIMD3(1, 0, 0), row1: SIMD3(0, 1, 0))

    init(row0: SIMD3<Float>, row1: SIMD3<Float>) {
        self.row0 = row0
        self.row1 = row1
    }

    /// Read off the same coordinate boundary the mask tools and tracking use,
    /// so there is one answer in the app to "which way up is this clip".
    init(coordinates: MaskTrackingCoordinates) {
        let origin = coordinates.sourceToDisplay(.zero)
        let alongU = coordinates.sourceToDisplay(CGPoint(x: 1, y: 0))
        let alongV = coordinates.sourceToDisplay(CGPoint(x: 0, y: 1))
        row0 = SIMD3(Float(alongU.x - origin.x), Float(alongV.x - origin.x), Float(origin.x))
        row1 = SIMD3(Float(alongU.y - origin.y), Float(alongV.y - origin.y), Float(origin.y))
    }

    func display(fromEncoded uv: CGPoint) -> CGPoint {
        CGPoint(x: CGFloat(row0.x) * uv.x + CGFloat(row0.y) * uv.y + CGFloat(row0.z),
                y: CGFloat(row1.x) * uv.x + CGFloat(row1.y) * uv.y + CGFloat(row1.z))
    }
}

/// Everything the renderers need to find and orient one asset's depth.
struct RelightSourceInfo: Equatable, Sendable {
    let assetID: UUID
    /// The media identity the cache is filed under. See `RelightCacheIdentity`.
    let cacheIdentifier: String
    /// Frame indices count from the asset's own first frame, not the clip's,
    /// so two clips of one file agree about which stored frame is which.
    let assetStart: TimelineTime
    let frameDurationSeconds: Double
    let encodedSize: CGSize
    let displaySize: CGSize
    let orientation: RelightOrientation

    /// Width over height of the upright picture.
    var displayAspect: Double {
        guard displaySize.width > 0, displaySize.height > 0 else { return 16.0 / 9.0 }
        return Double(displaySize.width / displaySize.height)
    }

    /// The fractional source frame a source time falls on, counted from the
    /// asset's first frame.
    func framePosition(sourceTime: TimelineTime) -> Double {
        let elapsed = sourceTime.seconds - assetStart.seconds
        let position = elapsed / max(frameDurationSeconds, 1.0 / 240.0)
        return position.isFinite ? position : 0
    }

    func frameIndex(sourceTime: TimelineTime) -> Int64 {
        Int64(framePosition(sourceTime: sourceTime).rounded())
    }

    /// Nil for a still image or for media whose geometry cannot be read —
    /// Relight is a video tool, and a picture it cannot orient is one it
    /// cannot light correctly.
    static func make(asset: ProjectMediaAsset) -> RelightSourceInfo? {
        guard asset.stillImage == nil, let metadata = asset.videoMetadata,
              let identifier = RelightCacheIdentity.identifier(for: asset.url) else { return nil }
        let coordinates = try? MaskTrackingCoordinates(
            encodedSize: metadata.encodedSize,
            preferredTransform: metadata.preferredTransform.cgTransform)
        let frameSeconds = asset.frameDuration?.seconds
            ?? metadata.bestFrameRate.map { 1 / $0 }
            ?? (1.0 / 30.0)
        return RelightSourceInfo(
            assetID: asset.id,
            cacheIdentifier: identifier,
            assetStart: asset.sourceRange.start,
            frameDurationSeconds: frameSeconds.isFinite && frameSeconds > 0 ? frameSeconds : 1.0 / 30.0,
            encodedSize: metadata.encodedSize,
            displaySize: metadata.displaySize,
            orientation: coordinates.map(RelightOrientation.init(coordinates:)) ?? .identity)
    }

    /// One entry per video asset in a project, for a renderer to hold.
    static func table(for project: VideoProject) -> [UUID: RelightSourceInfo] {
        var table: [UUID: RelightSourceInfo] = [:]
        for asset in project.assets {
            if let info = make(asset: asset) { table[asset.id] = info }
        }
        return table
    }
}

/// The identity a piece of media's depth is cached under.
///
/// Built from the file's name, size and modification date rather than from its
/// path or from the project: the app relocates imported files when its data
/// container moves, two projects can share one import, and the same file in
/// two clips should be analysed once. A replaced file — a re-import, a new
/// export over the old name — has a different size or date and therefore a
/// different identity, which is what makes stale depth impossible to read
/// back for it.
enum RelightCacheIdentity {
    private static let lock = NSLock()
    private static var memo: [String: String] = [:]

    static func identifier(for url: URL) -> String? {
        let path = url.standardizedFileURL.path
        lock.lock()
        if let cached = memo[path] { lock.unlock(); return cached }
        lock.unlock()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let stem = url.deletingPathExtension().lastPathComponent
            .unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }
            .joined()
        let identifier = "\(stem.prefix(48))-\(size)-\(Int64(modified))"
        lock.lock()
        memo[path] = identifier
        lock.unlock()
        return identifier
    }

    /// Forgets what was measured, for a file that was replaced in place.
    static func invalidate(_ url: URL) {
        lock.lock()
        memo.removeValue(forKey: url.standardizedFileURL.path)
        lock.unlock()
    }
}
