import CoreTransferable
import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ImportedVideo: Equatable, Sendable {
    let url: URL
    let displayName: String
    let originalFilename: String?
    let contentType: UTType?
}

enum VideoImportError: LocalizedError, Equatable, Sendable {
    case unsupportedSelection
    case itemUnavailable
    case unableToStoreVideo
    /// The copy finished without an error but did not produce the whole file.
    case incompleteCopy(copied: Int64, expected: Int64)
    /// Out of space, with the numbers. A 4K ProRes clip is several gigabytes, so
    /// this is the ordinary failure for large footage rather than an exotic one,
    /// and it deserves to say what it needs instead of "couldn't copy".
    case insufficientStorage(needed: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .unsupportedSelection:
            String(localized: "Please choose a supported video file.")
        case .itemUnavailable:
            String(localized: "The selected video is no longer available.")
        case .unableToStoreVideo:
            String(localized: "GradeLab couldn’t copy the selected video into its project storage.")
        case .incompleteCopy(let copied, let expected):
            String(localized: """
            GradeLab could only read \(ByteCountFormatter.string(fromByteCount: copied, countStyle: .file)) of this \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)) video.

            If it is stored in iCloud Drive, open it once in the Files app so it downloads in full, then import it again.
            """)
        case .insufficientStorage(let needed, let available):
            String(localized: """
            This video needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) of free space, but only \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) is available.

            Free up space and try again.
            """)
        }
    }

    /// True when a failure from the file system was actually a full disk.
    /// Checked for both Cocoa's error and the POSIX one underneath it, because
    /// a stream reports whichever it was given.
    static func isOutOfSpace(_ error: Error) -> Bool {
        var candidates: [NSError] = [error as NSError]
        if let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError {
            candidates.append(underlying)
        }
        return candidates.contains { candidate in
            (candidate.domain == NSCocoaErrorDomain && candidate.code == NSFileWriteOutOfSpaceError)
                || (candidate.domain == NSPOSIXErrorDomain && candidate.code == Int(ENOSPC))
        }
    }
}

/// Imports the representation supplied by `PhotosPicker` into durable app storage.
///
/// `PhotosPicker` grants access only to the item the user selected, so importing a
/// video does not require read access to the user's full photo library.
actor VideoImportService {
    private let projectStore: ProjectStore
    private let fileManager: FileManager

    init(projectStore: ProjectStore, fileManager: FileManager = .default) {
        self.projectStore = projectStore
        self.fileManager = fileManager
    }

    func importVideo(from source: MediaImportSource) async throws -> ImportedVideo {
        switch source {
        case .photos(let item): return try await importVideo(from: item)
        case .file(let url): return try await importVideo(from: url)
        }
    }

    /// Copy the chosen file; never move or modify the user's original.
    func importVideo(from url: URL) async throws -> ImportedVideo {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey])
        let contentType = values.contentType ?? UTType(filenameExtension: url.pathExtension)
        guard values.isRegularFile == true, contentType?.conforms(to: .movie) == true else {
            throw VideoImportError.unsupportedSelection
        }
        let destination = try await projectStore.sourceImportURL(
            fileExtension: Self.fileExtension(sourceExtension: url.pathExtension, contentType: contentType))
        do {
            try Self.copyCoordinated(from: url, to: destination, fileManager: fileManager)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as VideoImportError {
            // Already says what went wrong - an incomplete read in particular
            // must not be flattened into the generic "couldn't copy".
            throw error
        } catch {
            if VideoImportError.isOutOfSpace(error) {
                throw VideoImportError.insufficientStorage(
                    needed: Self.fileSize(of: url), available: Self.availableCapacity(near: destination))
            }
            throw VideoImportError.unableToStoreVideo
        }
        return ImportedVideo(url: destination, displayName: Self.displayName(from: url.lastPathComponent),
                             originalFilename: url.lastPathComponent, contentType: contentType)
    }

    func importVideo(from item: PhotosPickerItem) async throws -> ImportedVideo {
        let advertisedMovieTypes = item.supportedContentTypes.filter { $0.conforms(to: .movie) }
        guard item.supportedContentTypes.isEmpty || !advertisedMovieTypes.isEmpty else {
            throw VideoImportError.unsupportedSelection
        }

        let transferredFile: TransferredMovieFile
        do {
            guard let loadedFile = try await item.loadTransferable(type: TransferredMovieFile.self) else {
                throw VideoImportError.itemUnavailable
            }
            transferredFile = loadedFile
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as VideoImportError {
            throw error
        } catch {
            // The staging copy is the first thing a large import can run out of
            // room for. Reporting that as "no longer available" sent people
            // looking for a missing file instead of at their storage.
            if VideoImportError.isOutOfSpace(error) {
                throw VideoImportError.insufficientStorage(
                    needed: 0,
                    available: Self.availableCapacity(near: FileManager.default.temporaryDirectory)
                )
            }
            throw VideoImportError.itemUnavailable
        }

        defer { transferredFile.removeStagedFile() }
        try Task.checkCancellation()

        let contentType = transferredFile.contentType
            ?? advertisedMovieTypes.first
        let fileExtension = Self.fileExtension(
            sourceExtension: transferredFile.fileExtension,
            contentType: contentType
        )

        let destinationURL: URL
        do {
            destinationURL = try await projectStore.sourceImportURL(fileExtension: fileExtension)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw VideoImportError.unableToStoreVideo
        }

        let stagedSize = Self.fileSize(of: transferredFile.stagedURL)
        do {
            try FileStreamCopier.install(
                from: transferredFile.stagedURL,
                to: destinationURL,
                fileManager: fileManager
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if VideoImportError.isOutOfSpace(error) {
                throw VideoImportError.insufficientStorage(
                    needed: stagedSize,
                    available: Self.availableCapacity(near: destinationURL)
                )
            }
            throw VideoImportError.unableToStoreVideo
        }

        return ImportedVideo(
            url: destinationURL,
            displayName: Self.displayName(from: transferredFile.originalFilename),
            originalFilename: transferredFile.originalFilename,
            contentType: contentType
        )
    }

    /// Copies the picked file through a file coordinator.
    ///
    /// A `fileImporter` hands back a URL that may be an iCloud Drive item the
    /// device has not materialised. Reading such a placeholder with a plain
    /// `InputStream` opens successfully and reports EOF immediately, so the
    /// copy "succeeds" and writes an empty file - which then fails much later,
    /// as `AVAsset.isPlayable == false`, and is reported as an unsupported
    /// format. The Files app plays the same clip because tapping it downloads
    /// it first, which is exactly the step this was missing.
    ///
    /// A coordinated read triggers that download and blocks until the file is
    /// local, so the copy sees real bytes. `FileStreamCopier` then checks the
    /// byte count, because a short read must never pass for a finished import.
    private static func copyCoordinated(from url: URL, to destination: URL,
                                        fileManager: FileManager) throws {
        var coordinationError: NSError?
        var thrown: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            do {
                try FileStreamCopier.copy(from: readable, to: destination,
                                          expecting: fileSize(of: readable), fileManager: fileManager)
            } catch {
                thrown = error
            }
        }
        if let thrown { throw thrown }
        if let coordinationError { throw coordinationError }
    }

    static func fileSize(of url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    /// Space the system will let the app use for something it is expected to
    /// keep. `forImportantUsage` includes storage the system can purge on
    /// demand, which is what an import can actually count on.
    static func availableCapacity(near url: URL) -> Int64 {
        let directory = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        let values = try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    private static func fileExtension(sourceExtension: String, contentType: UTType?) -> String {
        if !sourceExtension.isEmpty {
            return sourceExtension.lowercased()
        }
        return contentType?.preferredFilenameExtension ?? "mov"
    }

    private static func displayName(from originalFilename: String?) -> String {
        guard let originalFilename else { return String(localized: "Imported Video") }
        let name = URL(fileURLWithPath: originalFilename)
            .deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(localized: "Imported Video") : name
    }
}

/// Owns a stable staging copy before the system invalidates the picker-provided URL.
private final class TransferredMovieFile: Transferable, @unchecked Sendable {
    let stagedURL: URL
    let originalFilename: String?
    let contentType: UTType?
    let fileExtension: String

    init(
        stagedURL: URL,
        originalFilename: String?,
        contentType: UTType?,
        fileExtension: String
    ) {
        self.stagedURL = stagedURL
        self.originalFilename = originalFilename
        self.contentType = contentType
        self.fileExtension = fileExtension
    }

    deinit {
        removeStagedFile()
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { receivedFile in
            let sourceURL = receivedFile.file
            let resourceValues = try? sourceURL.resourceValues(forKeys: [.contentTypeKey, .nameKey])
            let contentType = resourceValues?.contentType
                ?? UTType(filenameExtension: sourceURL.pathExtension)
            let fileExtension = sourceURL.pathExtension.isEmpty
                ? (contentType?.preferredFilenameExtension ?? "mov")
                : sourceURL.pathExtension
            let originalFilename = normalizedFilename(
                resourceValues?.name ?? sourceURL.lastPathComponent
            )

            let fileManager = FileManager.default
            let stagingDirectory = fileManager.temporaryDirectory
                .appendingPathComponent("GradeLabIncoming", isDirectory: true)
            try fileManager.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true
            )
            let stagedURL = stagingDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(fileExtension)

            try FileStreamCopier.copy(
                from: sourceURL,
                to: stagedURL,
                fileManager: fileManager
            )

            return TransferredMovieFile(
                stagedURL: stagedURL,
                originalFilename: originalFilename,
                contentType: contentType,
                fileExtension: fileExtension
            )
        }
    }

    func removeStagedFile() {
        try? FileManager.default.removeItem(at: stagedURL)
    }

    private static func normalizedFilename(_ filename: String) -> String? {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed).lastPathComponent
    }
}

private enum FileStreamCopier {
    /// Puts the staged file at its final location.
    ///
    /// A move first, because both paths live inside the app container and so on
    /// the same volume: renaming is instant and needs no extra space. Importing
    /// a 5 GB ProRes clip used to copy it a second time, which meant the device
    /// had to have 10 GB free for one video and spent minutes writing bytes it
    /// already had. Copying stays as the fallback for the case where the two
    /// really are on different volumes.
    static func install(from sourceURL: URL, to destinationURL: URL, fileManager: FileManager) throws {
        try Task.checkCancellation()
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            return
        } catch {
            // A move that failed for lack of space would fail the same way as a
            // copy, so there is nothing to gain by trying again the slow way.
            if VideoImportError.isOutOfSpace(error) { throw error }
        }
        try copy(from: sourceURL, to: destinationURL, fileManager: fileManager)
    }

    /// `expectedSize` is checked against what was actually read. Passing nil
    /// skips the check, for a source whose size is not known up front.
    static func copy(from sourceURL: URL, to destinationURL: URL,
                     expecting expectedSize: Int64? = nil, fileManager: FileManager) throws {
        try Task.checkCancellation()

        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        var copySucceeded = false
        defer {
            if !copySucceeded {
                try? fileManager.removeItem(at: destinationURL)
            }
        }

        guard
            let inputStream = InputStream(url: sourceURL),
            let outputStream = OutputStream(url: destinationURL, append: false)
        else {
            throw CocoaError(.fileReadUnknown)
        }

        inputStream.open()
        outputStream.open()
        defer {
            inputStream.close()
            outputStream.close()
        }

        var copiedBytes: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let bytesRead = inputStream.read(&buffer, maxLength: buffer.count)
            if bytesRead < 0 {
                throw inputStream.streamError ?? CocoaError(.fileReadUnknown)
            }
            if bytesRead == 0 {
                break
            }

            var bytesWritten = 0
            while bytesWritten < bytesRead {
                try Task.checkCancellation()
                let writeCount = buffer.withUnsafeBufferPointer { pointer in
                    outputStream.write(
                        pointer.baseAddress!.advanced(by: bytesWritten),
                        maxLength: bytesRead - bytesWritten
                    )
                }
                if writeCount <= 0 {
                    throw outputStream.streamError ?? CocoaError(.fileWriteUnknown)
                }
                bytesWritten += writeCount
            }
            copiedBytes += Int64(bytesRead)
        }

        // A zero-byte or truncated read is not an error the streams report, so
        // it has to be caught here or it ships as a corrupt import.
        if let expectedSize, expectedSize > 0, copiedBytes < expectedSize {
            throw VideoImportError.incompleteCopy(copied: copiedBytes, expected: expectedSize)
        }

        copySucceeded = true
    }
}
