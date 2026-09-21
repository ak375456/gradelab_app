import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a still image actually is, read from the file rather than assumed.
///
/// Every value here comes from `CGImageSource`. Anything the file does not
/// declare stays nil and is reported as unknown, in the same spirit as
/// `VideoMetadata`: an app that invents a bit depth or a colour space is worse
/// than one that admits it does not know.
struct ImageMetadata: Codable, Equatable, Sendable {
    let fileName: String
    /// The stored pixel dimensions, before the EXIF orientation is applied.
    let pixelWidth: Int
    let pixelHeight: Int
    /// EXIF orientation, 1...8. 1 when the file declares none.
    let orientation: Int
    /// The container's uniform type identifier, e.g. `public.jpeg`.
    let typeIdentifier: String?
    let fileSize: Int64?
    let bitsPerComponent: Int?
    let colorModel: String?
    /// The embedded profile's name, when it has one.
    let colorProfileName: String?
    let hasEmbeddedProfile: Bool
    /// True when the profile is outside sRGB/Rec.709 — Display P3, Adobe RGB,
    /// ProPhoto and the rest.
    let isWideGamut: Bool
    /// True when the **primary image itself** is HDR-encoded — a PQ or HLG
    /// transfer function.
    ///
    /// Deliberately *not* set by the presence of a gain map. Those are two very
    /// different things, and conflating them refuses almost every photograph an
    /// iPhone takes: an Adaptive HDR file is an ordinary SDR picture plus a gain
    /// map, and the SDR picture is what every viewer shows by default. Only a
    /// file whose primary image is genuinely encoded in an HDR transfer has no
    /// SDR picture to grade.
    let isHDR: Bool
    let hasAlpha: Bool
    let dpi: Double?
    let creationDate: Date?
    /// True when the source is a camera raw file.
    let isRAW: Bool
    /// True when an HDR gain map is attached. Optional so an image project
    /// written before this was recorded decodes unchanged.
    let hdrGainMap: Bool?

    /// Whether the file carries an HDR gain map alongside its SDR picture.
    /// Informational: it does not stop the picture from being graded.
    var hasHDRGainMap: Bool { hdrGainMap ?? false }

    /// Dimensions as the picture is meant to be seen, with the EXIF orientation
    /// applied. This is the size the editor, the preview and the export all use.
    var displayWidth: Int { isSideways ? pixelHeight : pixelWidth }
    var displayHeight: Int { isSideways ? pixelWidth : pixelHeight }

    /// Orientations 5...8 exchange the axes.
    var isSideways: Bool { (5...8).contains(orientation) }

    var displaySize: CGSize { CGSize(width: displayWidth, height: displayHeight) }

    var megapixels: Double { Double(pixelWidth) * Double(pixelHeight) / 1_000_000 }

    var resolutionLabel: String { "\(displayWidth) × \(displayHeight)" }

    var megapixelLabel: String {
        megapixels >= 10 ? String(format: "%.0f MP", locale: .current, megapixels) : String(format: "%.1f MP", locale: .current, megapixels)
    }

    /// A short name for the container: JPEG, HEIF, PNG.
    var formatLabel: String {
        guard let typeIdentifier, let type = UTType(typeIdentifier) else {
            return (fileName as NSString).pathExtension.uppercased()
        }
        switch type {
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .heic: return "HEIC"
        case .heif: return "HEIF"
        case .tiff: return "TIFF"
        case .gif: return "GIF"
        case .webP: return "WebP"
        default:
            return type.preferredFilenameExtension?.uppercased()
                ?? type.localizedDescription?.uppercased()
                ?? (fileName as NSString).pathExtension.uppercased()
        }
    }

    var fileSizeLabel: String? {
        guard let fileSize, fileSize > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var orientationLabel: String {
        switch orientation {
        case 1: String(localized: "Normal")
        case 2: String(localized: "Mirrored")
        case 3: String(localized: "Rotated 180°")
        case 4: String(localized: "Mirrored, rotated 180°")
        case 5: String(localized: "Mirrored, rotated 90° CCW")
        case 6: String(localized: "Rotated 90° CW")
        case 7: String(localized: "Mirrored, rotated 90° CW")
        case 8: String(localized: "Rotated 90° CCW")
        default: String(localized: "Unknown")
        }
    }

    /// The colour facts, for the Source Information panel.
    var colorSummary: [String] {
        var values: [String] = []
        if let colorProfileName { values.append(colorProfileName) }
        else if hasEmbeddedProfile { values.append("Embedded profile") }
        if let bitsPerComponent { values.append("\(bitsPerComponent)-bit") }
        if isWideGamut { values.append("Wide gamut") }
        if hasHDRGainMap { values.append("Gain map") }
        if isHDR { values.append("HDR") }
        return values
    }
}

/// Reads real metadata out of an image file. Nothing here guesses.
enum ImageMetadataReader {
    static func read(url: URL) throws -> ImageMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw GradeLabError.unableToReadImage
        }
        return try read(source: source, url: url)
    }

    static func read(source: CGImageSource, url: URL) throws -> ImageMetadata {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            throw GradeLabError.unableToReadImage
        }

        let typeIdentifier = CGImageSourceGetType(source) as String?
        let type = typeIdentifier.flatMap { UTType($0) }
        let isRAW = type.map { $0.conforms(to: .rawImage) } ?? false

        let orientationValue = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let orientation = (1...8).contains(orientationValue) ? orientationValue : 1

        let profileName = (properties[kCGImagePropertyProfileName] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        let colorModel = (properties[kCGImagePropertyColorModel] as? String)?
            .replacingOccurrences(of: "kCGImagePropertyColorModel", with: "")

        // A file is wide-gamut when its own profile says so. Guessing from the
        // container would call every HEIC wide and every JPEG narrow, and both
        // are wrong often enough to matter.
        let wideNames = ["display p3", "dci-p3", "p3", "adobe rgb", "prophoto", "rec. 2020",
                         "rec2020", "bt.2020", "itu-r bt.2020", "scrgb"]
        let lowered = profileName?.lowercased() ?? ""
        let isWideGamut = wideNames.contains { lowered.contains($0) }

        // A gain map and an HDR-encoded primary image are different things, and
        // treating them as one refuses almost every photograph an iPhone takes.
        //
        // An Adaptive HDR file is an SDR picture plus a gain map that an HDR
        // display can use to lift it. The SDR picture is a real, complete,
        // fully-graded-able image — it is what every viewer shows by default —
        // so the file is graded, and the gain map is reported and left behind.
        //
        // A primary image encoded in PQ or HLG is the case with no SDR picture
        // inside it, and that is what stays refused.
        let hasGainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
        let isHDR = ["pq", "hlg", "2100", "2084"].contains { lowered.contains($0) }

        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let creationDate = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            .flatMap(exifDateFormatter.date(from:))
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String).flatMap(exifDateFormatter.date(from:))

        return ImageMetadata(
            fileName: url.lastPathComponent,
            pixelWidth: width,
            pixelHeight: height,
            orientation: orientation,
            typeIdentifier: typeIdentifier,
            fileSize: fileSize,
            bitsPerComponent: properties[kCGImagePropertyDepth] as? Int,
            colorModel: colorModel,
            colorProfileName: profileName,
            hasEmbeddedProfile: profileName != nil,
            isWideGamut: isWideGamut,
            isHDR: isHDR,
            hasAlpha: properties[kCGImagePropertyHasAlpha] as? Bool ?? false,
            dpi: properties[kCGImagePropertyDPIWidth] as? Double,
            creationDate: creationDate,
            isRAW: isRAW,
            hdrGainMap: hasGainMap
        )
    }

    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()
}
