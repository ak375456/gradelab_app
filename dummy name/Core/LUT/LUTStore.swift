import Foundation

/// Stores `.cube` looks the user imports from Files or iCloud Drive.
///
/// Imported looks live as plain files in Application Support, so the store needs
/// no database and no sidecar metadata: the directory listing *is* the list, and
/// a look's identifier is its stored filename. That keeps `AdvancedGrade.lut`
/// unchanged — it holds a filename whether the look is bundled or imported — and
/// means a project still resolves its look after the app restarts.
enum LUTStore {
    /// `Application Support/Looks`. Created on demand.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Looks", isDirectory: true)
    }

    /// Every look the user has imported, newest name order, cheap enough to call
    /// when the picker is rebuilt.
    static func installedLooks() -> [LUTAsset] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { $0.pathExtension.lowercased() == "cube" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map(LUTAsset.imported(resourceName:))
    }

    /// Copies a picked file in after checking that it will actually work.
    ///
    /// Validation happens *before* the copy so a file that cannot be applied
    /// never reaches the picker: a look that appears but silently does nothing
    /// is worse than a clear refusal at the moment of import.
    @discardableResult
    static func importLook(from source: URL) throws -> LUTAsset {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        guard source.pathExtension.lowercased() == "cube" else {
            throw GradeLabError.invalidLUT(
                "\(source.lastPathComponent) is not a .cube file. Looks must be 3D .cube LUTs."
            )
        }
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= LookValidation.maximumFileSize else {
            throw GradeLabError.invalidLUT("\(source.lastPathComponent) is too large to be a look LUT.")
        }

        let text = try String(contentsOf: source, encoding: .utf8)
        let cube = try CubeLUTParser().parse(text)
        try LookValidation.check(cube)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = try uniqueDestination(for: source.deletingPathExtension().lastPathComponent)
        try text.write(to: destination, atomically: true, encoding: .utf8)
        return LUTAsset.imported(resourceName: destination.deletingPathExtension().lastPathComponent)
    }

    static func remove(_ asset: LUTAsset) throws {
        guard asset.origin == .device else { return }
        try FileManager.default.removeItem(at: directory.appendingPathComponent(asset.filename))
    }

    /// Picks a filename that collides with neither a bundled look nor an existing
    /// import, so an identifier always points at exactly one file.
    private static func uniqueDestination(for preferredName: String) throws -> URL {
        let sanitized = preferredName
            .components(separatedBy: CharacterSet(charactersIn: "/\\:").union(.controlCharacters))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = sanitized.isEmpty ? "Imported Look" : sanitized
        let taken = Set(LUTAsset.bundledLooks.map(\.resourceName))

        for attempt in 1...100 {
            let candidate = attempt == 1 ? base : "\(base) \(attempt)"
            let url = directory.appendingPathComponent("\(candidate).cube")
            if !taken.contains(candidate), !FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        throw GradeLabError.invalidLUT("Too many looks share the name “\(base)”. Rename the file and try again.")
    }
}
