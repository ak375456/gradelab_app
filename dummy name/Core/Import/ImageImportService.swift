import CoreTransferable
import PhotosUI
import SwiftUI
import Foundation
import UniformTypeIdentifiers
import ImageIO

struct TransferredStill: Transferable, Sendable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}

enum ImageImportService {
    static func thumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 192, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
    }
    static func load(_ item: PhotosPickerItem) async throws -> ProjectMediaAsset {
        guard let file = try await item.loadTransferable(type: TransferredStill.self) else { throw TimelineError.invalid(String(localized: "The image could not be imported.")) }
        defer { try? FileManager.default.removeItem(at: file.url) }
        guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw TimelineError.invalid(String(localized: "Choose a supported still image.")) }
        let destination = try await ProjectStore().sourceImportURL(fileExtension: file.url.pathExtension)
        try FileManager.default.copyItem(at: file.url, to: destination)
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let sideways = (5...8).contains(orientation)
        return .init(id: UUID(), url: destination, sourceRange: .init(start: .zero, duration: try .seconds(3)), videoMetadata: nil,
                     frameDuration: nil, stillImage: .init(width: sideways ? height : width, height: sideways ? width : height))
    }
}
