import Foundation
import UIKit

/// Where saved presets live on disk.
///
/// Presets are application-level data, not project data: they have to survive
/// switching projects, opening new videos and restarting the app, so they sit
/// beside the project database rather than inside any one project.
///
///     Application Support/GradePresets/
///         presets.json
///         thumbnails/<UUID>.jpg
///
/// Plain JSON and plain files, the same strategy `ProjectStore` and `LUTStore`
/// already use. Nothing here needs a database.
struct GradePresetStore {
    private struct Database: Codable {
        var presets: [GradePreset]
    }

    let rootURL: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default, rootURL customRootURL: URL? = nil) {
        self.fileManager = fileManager
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        rootURL = customRootURL ?? applicationSupport.appendingPathComponent("GradePresets", isDirectory: true)
    }

    private var databaseURL: URL { rootURL.appendingPathComponent("presets.json") }
    private var thumbnailsURL: URL { rootURL.appendingPathComponent("thumbnails", isDirectory: true) }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Every saved preset, in display order. A missing file is an empty
    /// library, not an error: that is simply what a first launch looks like.
    func load() throws -> [GradePreset] {
        guard fileManager.fileExists(atPath: databaseURL.path) else { return [] }
        let data = try Data(contentsOf: databaseURL)
        return try decoder.decode(Database.self, from: data).presets.sortedForDisplay
    }

    func save(_ presets: [GradePreset]) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let data = try encoder.encode(Database(presets: presets))
        try data.write(to: databaseURL, options: .atomic)
    }

    // MARK: - Thumbnails

    func thumbnailURL(named filename: String) -> URL {
        thumbnailsURL.appendingPathComponent(filename)
    }

    /// Writes a preset's thumbnail and returns the file name to store on it.
    /// The image is already small by the time it gets here; the JPEG is only to
    /// keep the directory from growing faster than it needs to.
    @discardableResult
    func writeThumbnail(_ image: UIImage, for id: UUID) throws -> String {
        try fileManager.createDirectory(at: thumbnailsURL, withIntermediateDirectories: true)
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            throw GradeLabError.presetThumbnailFailed
        }
        let filename = "\(id.uuidString).jpg"
        try data.write(to: thumbnailURL(named: filename), options: .atomic)
        return filename
    }

    /// Copies one preset's thumbnail for another, used when duplicating so the
    /// copy does not share a file the original could later overwrite.
    func copyThumbnail(_ filename: String, to id: UUID) -> String? {
        let source = thumbnailURL(named: filename)
        guard fileManager.fileExists(atPath: source.path) else { return nil }
        let destination = thumbnailURL(named: "\(id.uuidString).jpg")
        try? fileManager.removeItem(at: destination)
        do {
            try fileManager.createDirectory(at: thumbnailsURL, withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: destination)
            return destination.lastPathComponent
        } catch {
            return nil
        }
    }

    func removeThumbnail(_ filename: String?) {
        guard let filename else { return }
        try? fileManager.removeItem(at: thumbnailURL(named: filename))
    }

    func loadThumbnail(_ filename: String?) -> UIImage? {
        guard let filename else { return nil }
        return UIImage(contentsOfFile: thumbnailURL(named: filename).path)
    }
}
