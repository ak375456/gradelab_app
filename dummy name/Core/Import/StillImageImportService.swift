import Foundation
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Brings a photograph in from the system picker and turns it into a project.
///
/// Reuses `TransferredStill`, the transferable the overlay import already uses,
/// so there is one definition of "a still arriving from Photos".
///
/// Everything it reports about the file is read from the file. Nothing is
/// inferred from the extension, and a format the grading path cannot handle is
/// refused here, with the reason, rather than opening an editor that would then
/// show something wrong.
enum StillImageImportService {
    struct Imported: Sendable {
        let asset: ImageAsset
        let displayName: String
    }

    static func load(_ source: MediaImportSource, store: ImageProjectStore = ImageProjectStore()) async throws -> Imported {
        switch source {
        case .photos(let item): return try await load(item, store: store)
        case .file(let url): return try await load(url: url, store: store, displayName: url.lastPathComponent)
        }
    }

    static func load(_ item: PhotosPickerItem, store: ImageProjectStore = ImageProjectStore()) async throws -> Imported {
        guard let file = try await item.loadTransferable(type: TransferredStill.self) else {
            throw TimelineError.invalid(String(localized: "The image could not be imported."))
        }
        defer { try? FileManager.default.removeItem(at: file.url) }
        return try await load(url: file.url, store: store,
                              displayName: item.itemIdentifier.map { _ in file.url.lastPathComponent })
    }

    /// - Parameter displayName: what to call the project. Photos does not hand
    ///   over the original file name for every asset, so the caller passes one
    ///   when it has it and a dated name is used when it does not.
    static func load(
        url: URL,
        store: ImageProjectStore = ImageProjectStore(),
        displayName: String? = nil
    ) async throws -> Imported {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let metadata = try ImageMetadataReader.read(url: url)
        let support = ImageColorSupport(metadata: metadata)
        guard support.allowsEditor else {
            throw GradeLabError.unsupportedExport(support.notice ?? "This image is outside GradeLab’s validated colour pipeline.")
        }
        // Decoded once here, before anything is copied or a project is written.
        // A file that reports plausible metadata but cannot actually be decoded
        // should fail at import, not at the first slider move.
        _ = try ImageDecoder.decode(url: url, maximumLongEdge: 256)
        try Task.checkCancellation()

        let destination = try await store.sourceImportURL(fileExtension: url.pathExtension)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        var stored = metadata
        // The metadata records the file inside the app, but is named for the
        // picture the user chose.
        stored = ImageMetadata(
            fileName: displayName ?? metadata.fileName,
            pixelWidth: metadata.pixelWidth, pixelHeight: metadata.pixelHeight,
            orientation: metadata.orientation, typeIdentifier: metadata.typeIdentifier,
            fileSize: metadata.fileSize, bitsPerComponent: metadata.bitsPerComponent,
            colorModel: metadata.colorModel, colorProfileName: metadata.colorProfileName,
            hasEmbeddedProfile: metadata.hasEmbeddedProfile, isWideGamut: metadata.isWideGamut,
            isHDR: metadata.isHDR, hasAlpha: metadata.hasAlpha, dpi: metadata.dpi,
            creationDate: metadata.creationDate, isRAW: metadata.isRAW,
            hdrGainMap: metadata.hdrGainMap)

        let name = (displayName.map { ($0 as NSString).deletingPathExtension })
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? defaultName(for: stored)
        return Imported(
            asset: ImageAsset(id: UUID(), url: destination, metadata: stored),
            displayName: name)
    }

    private static func defaultName(for metadata: ImageMetadata) -> String {
        let date = metadata.creationDate ?? .now
        return String(localized: "Photo \(date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)))")
    }
}
