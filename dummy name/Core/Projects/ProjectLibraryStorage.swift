import Foundation

/// Why a project library could not be read, and what was done about the file.
///
/// The distinction matters to the caller, not just to the message: one of these
/// leaves the app working with an empty library and one leaves it refusing to
/// touch anything, and a screen that showed "No projects yet" for either would
/// be telling the user their work is gone.
enum LibraryLoadError: LocalizedError, Equatable {
    /// The database exists but cannot be decoded. The bytes have been moved to
    /// `recoveredURL` — nothing is deleted — so the library can start again
    /// empty instead of failing every read and every save from here on.
    case unreadable(recoveredURL: URL?, underlying: String)
    /// The database was written by a newer build. The file is left exactly where
    /// it is: it is not damaged, and this version of the app is simply too old
    /// to read it.
    case newerVersion(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let recoveredURL, _):
            if let recoveredURL {
                return String(localized: "GradeLab couldn’t read its saved projects. The unreadable file has been kept as “\(recoveredURL.lastPathComponent)” in the app’s Recovered folder, and the library has started again empty.")
            }
            return String(localized: "GradeLab couldn’t read its saved projects, and couldn’t set the unreadable file aside. Reinstalling the app will clear it.")
        case .newerVersion(let reason):
            return reason
        }
    }
}

/// The read half of a project database, shared by the video and photo stores.
///
/// Both keep a single JSON file and both have the same three failures to tell
/// apart, so the decision about which of them destroys data lives in one place
/// rather than being made twice.
enum ProjectLibraryStorage {
    /// Decodes a library database, setting a corrupt one aside.
    ///
    /// - Returns: nil when no database has been written yet, which is an empty
    ///   library rather than a failure.
    ///
    /// Three failures, deliberately handled three different ways:
    ///
    /// * **The read fails.** Rethrown untouched and nothing is moved. This is
    ///   very often not corruption at all — a file protected while the device is
    ///   locked reads as an error — and quarantining on it would set aside a
    ///   perfectly good library.
    /// * **The document is too new.** Rethrown as `.newerVersion`, file
    ///   untouched, for the reason on `TimelineError.unsupportedVersion`.
    /// * **Anything else in the decode.** The file is damaged. It is moved to a
    ///   `Recovered` folder and the caller gets `.unreadable` naming it. This is
    ///   what stops a corrupt database from also breaking every future save:
    ///   both stores read-modify-write, so a file that will not decode otherwise
    ///   makes new imports impossible for good.
    static func load<Database: Decodable>(
        _ type: Database.Type,
        at databaseURL: URL,
        decoder: JSONDecoder,
        fileManager: FileManager
    ) throws -> Database? {
        guard fileManager.fileExists(atPath: databaseURL.path) else { return nil }
        let data = try Data(contentsOf: databaseURL)
        do {
            return try decoder.decode(type, from: data)
        } catch let error as TimelineError {
            if case .unsupportedVersion(let reason) = error {
                throw LibraryLoadError.newerVersion(reason)
            }
            throw quarantining(databaseURL, fileManager: fileManager, because: error)
        } catch {
            throw quarantining(databaseURL, fileManager: fileManager, because: error)
        }
    }

    /// Moves an unreadable database into `Recovered` and describes the result.
    ///
    /// Never throws: a failure to move is reported through the error it is
    /// already building, because the caller's problem is that the library did
    /// not load and that is true either way.
    private static func quarantining(
        _ databaseURL: URL,
        fileManager: FileManager,
        because error: Error
    ) -> LibraryLoadError {
        let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        let folder = databaseURL.deletingLastPathComponent()
            .appendingPathComponent("Recovered", isDirectory: true)
        let base = databaseURL.deletingPathExtension().lastPathComponent
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let stamp = formatter.string(from: .now)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            var destination = folder.appendingPathComponent("\(base)-\(stamp)").appendingPathExtension("json")
            // Two failures in the same second must not overwrite each other; the
            // whole point of this folder is that nothing in it is lost.
            if fileManager.fileExists(atPath: destination.path) {
                destination = folder
                    .appendingPathComponent("\(base)-\(stamp)-\(UUID().uuidString.prefix(8))")
                    .appendingPathExtension("json")
            }
            try fileManager.moveItem(at: databaseURL, to: destination)
            return .unreadable(recoveredURL: destination, underlying: reason)
        } catch {
            return .unreadable(recoveredURL: nil, underlying: reason)
        }
    }

    /// Media files to remove when a project is deleted.
    ///
    /// - Parameters:
    ///   - candidates: every file the deleted project pointed at.
    ///   - referencedElsewhere: files that other documents still point at, or
    ///     nil when that is unknown — because another library failed to load,
    ///     say — in which case nothing is removed. An orphaned file wastes
    ///     storage; a file deleted out from under a project that still needs it
    ///     breaks that project, so "unknown" resolves to keeping it.
    static func removableMedia(
        candidates: [URL],
        referencedElsewhere: Set<URL>?
    ) -> [URL] {
        guard let referencedElsewhere else { return [] }
        let retained = Set(referencedElsewhere.map(\.standardizedFileURL))
        var seen = Set<URL>()
        return candidates.filter { url in
            let key = url.standardizedFileURL
            guard !retained.contains(key), seen.insert(key).inserted else { return false }
            return true
        }
    }
}
