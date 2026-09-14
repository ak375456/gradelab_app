import Foundation

/// Persistence for still-image projects.
///
/// A separate file from `projects.json` rather than a new case inside it. Video
/// documents already carry a migration history and a version gate that refuses
/// anything it does not recognise; adding a second document shape to that file
/// would mean an older build hitting a project it cannot decode and refusing the
/// whole library. Two files means an older build sees no image projects and
/// every video project it has always seen.
///
/// Storage layout matches the video store: imported sources under `Imports`,
/// card thumbnails under `Thumbnails`.
actor ImageProjectStore {
    private struct Database: Codable {
        var projects: [ImageProject]
    }

    private let fileManager: FileManager
    private let rootURL: URL
    private let databaseURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default, rootURL customRootURL: URL? = nil) {
        self.fileManager = fileManager
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        rootURL = customRootURL ?? applicationSupport.appendingPathComponent("GradeLab", isDirectory: true)
        databaseURL = rootURL.appendingPathComponent("image-projects.json")
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadProjects() throws -> [ImageProject] {
        guard let database = try ProjectLibraryStorage.load(
            Database.self, at: databaseURL, decoder: decoder, fileManager: fileManager
        ) else { return [] }
        return database.projects.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Every media file the stored photo projects still point at. The video
    /// store asks this before it deletes anything, and vice versa: the two
    /// libraries are separate documents but share one `Imports` folder.
    func referencedMediaURLs() throws -> Set<URL> {
        Set(try loadProjects().map(\.asset.url.standardizedFileURL))
    }

    func save(_ project: ImageProject) throws {
        try project.validate()
        var projects = try loadProjects()
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.append(project)
        }
        try persist(projects)
    }

    /// Removes a photo project, and the media only it was using.
    ///
    /// - Parameter mediaReferencedElsewhere: media the *video* library still
    ///   points at, or nil when that library could not be read, which removes no
    ///   media at all. Previously this deleted the imported copy unconditionally;
    ///   both libraries import into the same folder, so "this project had it"
    ///   was never on its own a reason to believe nothing else did.
    func delete(_ id: UUID, mediaReferencedElsewhere: Set<URL>?) throws {
        var projects = try loadProjects()
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        let removed = projects.remove(at: index)
        try persist(projects)

        let stillReferenced = mediaReferencedElsewhere.map { elsewhere in
            elsewhere.union(projects.map(\.asset.url.standardizedFileURL))
        }
        for url in ProjectLibraryStorage.removableMedia(
            candidates: [removed.asset.url], referencedElsewhere: stillReferenced
        ) {
            // Only the app's own copy is removed. The picture in the photo
            // library is never touched.
            try? fileManager.removeItem(at: url)
        }
        if let thumbnail = removed.thumbnailFileName {
            try? fileManager.removeItem(at: URL(fileURLWithPath: thumbnail))
        }
    }

    private func persist(_ projects: [ImageProject]) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try encoder.encode(Database(projects: projects)).write(to: databaseURL, options: .atomic)
    }

    func sourceImportURL(fileExtension: String) throws -> URL {
        let imports = rootURL.appendingPathComponent("Imports", isDirectory: true)
        try fileManager.createDirectory(at: imports, withIntermediateDirectories: true)
        return imports
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension.isEmpty ? "jpg" : fileExtension)
    }

    func thumbnailURL(for projectID: UUID) throws -> URL {
        let thumbnails = rootURL.appendingPathComponent("Thumbnails", isDirectory: true)
        try fileManager.createDirectory(at: thumbnails, withIntermediateDirectories: true)
        return thumbnails.appendingPathComponent("image-\(projectID.uuidString)").appendingPathExtension("jpg")
    }
}
