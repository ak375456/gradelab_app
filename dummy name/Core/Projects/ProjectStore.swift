import Foundation

actor ProjectStore {
    private struct Database: Codable {
        var projects: [GradeProject]
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
        databaseURL = rootURL.appendingPathComponent("projects.json")
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadProjects() throws -> [GradeProject] {
        guard let database = try ProjectLibraryStorage.load(
            Database.self, at: databaseURL, decoder: decoder, fileManager: fileManager
        ) else { return [] }
        var projects = database.projects
        var repairedContainerPaths = false
        for index in projects.indices {
            repairedContainerPaths = projects[index].relocateManagedFiles(
                to: rootURL,
                fileManager: fileManager
            ) || repairedContainerPaths
        }
        // Persist the repair immediately. Otherwise a project opens for this
        // session but fails again if the app is stopped before its next edit.
        if repairedContainerPaths { try persist(projects) }
        return projects.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Every media file the stored projects still point at.
    ///
    /// Video and photo projects share one `Imports` folder, so deleting either
    /// kind has to ask the other what it is still using before it removes
    /// anything. This is that question.
    func referencedMediaURLs() throws -> Set<URL> {
        Set(try loadProjects().flatMap(\.assets).map(\.url.standardizedFileURL))
    }

    /// Removes a project, and the media only it was using.
    ///
    /// - Parameter mediaReferencedElsewhere: media the *photo* library still
    ///   points at, or nil when that library could not be read. Nil removes no
    ///   media at all — see `ProjectLibraryStorage.removableMedia`.
    ///
    /// The document goes first and the files second, so a failure part-way
    /// through leaves orphaned bytes rather than a project pointing at media
    /// that is no longer there.
    func delete(_ id: UUID, mediaReferencedElsewhere: Set<URL>?) throws {
        var projects = try loadProjects()
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        let removed = projects.remove(at: index)
        try persist(projects)

        let stillReferenced = mediaReferencedElsewhere.map { elsewhere in
            elsewhere.union(projects.flatMap(\.assets).map(\.url.standardizedFileURL))
        }
        for url in ProjectLibraryStorage.removableMedia(
            candidates: removed.assets.map(\.url), referencedElsewhere: stillReferenced
        ) {
            // Only the app's own imported copy. The clip in the photo library is
            // never touched.
            try? fileManager.removeItem(at: url)
        }
        // Thumbnails are named for the project, so nothing else can be using it.
        if let thumbnail = removed.thumbnailFileName {
            try? fileManager.removeItem(at: URL(fileURLWithPath: thumbnail))
        }
    }

    func save(_ project: GradeProject) throws {
        try project.validate()
        var projects = try loadProjects()
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.append(project)
        }
        try persist(projects)
    }

    func sourceImportURL(fileExtension: String) throws -> URL {
        let imports = rootURL.appendingPathComponent("Imports", isDirectory: true)
        try fileManager.createDirectory(at: imports, withIntermediateDirectories: true)
        return imports
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension.isEmpty ? "mov" : fileExtension)
    }

    func thumbnailURL(for projectID: UUID) throws -> URL {
        let thumbnails = rootURL.appendingPathComponent("Thumbnails", isDirectory: true)
        try fileManager.createDirectory(at: thumbnails, withIntermediateDirectories: true)
        return thumbnails.appendingPathComponent(projectID.uuidString).appendingPathExtension("jpg")
    }

    private func persist(_ projects: [GradeProject]) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let data = try encoder.encode(Database(projects: projects))
        // Preserve the exact legacy JSON before its first V2 write. Loading alone
        // migrates in memory; source movies are never copied or modified here.
        if fileManager.fileExists(atPath: databaseURL.path) {
            let previous = try Data(contentsOf: databaseURL)
            let object = try JSONSerialization.jsonObject(with: previous) as? [String: Any]
            let storedProjects = object?["projects"] as? [[String: Any]] ?? []
            if storedProjects.contains(where: { ($0["projectVersion"] as? Int ?? 1) == 1 }) {
                let backup = rootURL.appendingPathComponent("projects-v1-backup.json")
                if !fileManager.fileExists(atPath: backup.path) {
                    try fileManager.copyItem(at: databaseURL, to: backup)
                }
            }
        }
        try data.write(to: databaseURL, options: .atomic)
    }
}
