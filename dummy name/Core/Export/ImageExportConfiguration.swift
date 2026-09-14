import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The output formats offered for a graded still.
///
/// Three, deliberately. Each one is here because it answers a question someone
/// actually has — smallest file, best quality per byte, or nothing thrown away —
/// and nothing obscure is offered for the sake of a longer list.
enum ImageExportFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case jpeg
    case heic
    case png

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .png: "PNG"
        }
    }

    var detail: String {
        switch self {
        case .jpeg: "Universally readable. Lossy, with a quality setting."
        case .heic: "About half the size of JPEG at the same quality. Lossy."
        case .png: "Lossless, and much larger. For a master copy."
        }
    }

    var utType: UTType {
        switch self {
        case .jpeg: .jpeg
        case .heic: .heic
        case .png: .png
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .heic: "heic"
        case .png: "png"
        }
    }

    /// Whether the quality control means anything for this format.
    var isLossy: Bool { self != .png }

    /// Whether this device can actually write the format.
    ///
    /// Checked against ImageIO rather than assumed from the OS version: HEIC
    /// encoding is hardware-dependent, and offering it where it cannot be
    /// written would produce a failure at the end of an export instead of an
    /// honest absence at the start of one.
    var isAvailable: Bool {
        guard self == .heic else { return true }
        let supported = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return supported.contains(UTType.heic.identifier)
    }

    static var available: [ImageExportFormat] { allCases.filter(\.isAvailable) }
}

/// What the export writes.
///
/// There is no size option. Resolution is the source's, always: an app that
/// silently shrank a 48 megapixel photograph on the way out would be taking a
/// decision that is not its to take.
struct ImageExportConfiguration: Equatable, Sendable {
    var format: ImageExportFormat = .jpeg
    /// 0...1, as ImageIO wants it. Ignored for PNG.
    var quality: Double = 0.92

    static let qualityRange: ClosedRange<Double> = 0.4...1.0

    var qualityLabel: String {
        switch quality {
        case 1.0: "Maximum"
        case 0.9..<1.0: "High"
        case 0.75..<0.9: "Good"
        default: "Smaller file"
        }
    }

    /// A sensible default for a source: keep HEIC sources as HEIC when the
    /// device can write it, and send everything else to JPEG.
    static func `default`(for metadata: ImageMetadata) -> ImageExportConfiguration {
        var configuration = ImageExportConfiguration()
        if let identifier = metadata.typeIdentifier, let type = UTType(identifier) {
            if type.conforms(to: .png) {
                configuration.format = .png
            } else if (type.conforms(to: .heic) || type.conforms(to: .heif)),
                      ImageExportFormat.heic.isAvailable {
                configuration.format = .heic
            }
        }
        return configuration
    }
}
