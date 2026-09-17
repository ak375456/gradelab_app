@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// What an exported file actually contains, read back from the file itself.
///
/// Requested settings are not results. An encoder can accept a configuration and
/// produce something else — a different profile, a different bit depth, missing
/// colour tags — and the only way to know is to open the output and look.
struct ExportOutputReport: Equatable, Sendable {
    var codec: String
    var bitDepth: Int?
    var colorPrimaries: String?
    var transferFunction: String?
    var yCbCrMatrix: String?
    var width: Int
    var height: Int

    var isHLGBT2020: Bool {
        transferFunction == "HLG" && colorPrimaries == "BT.2020" && yCbCrMatrix == "BT.2020"
    }

    var summary: String {
        let depth = bitDepth.map { "\($0)-bit" } ?? String(localized: "unknown depth")
        let colour = [colorPrimaries, transferFunction, yCbCrMatrix]
            .compactMap { $0 }.joined(separator: " / ")
        return "\(codec) \(depth) \(width)×\(height) · \(colour.isEmpty ? String(localized: "untagged") : colour)"
    }
}

enum ExportOutputInspector {
    static func inspect(_ url: URL) async throws -> ExportOutputReport {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              let description = try await track.load(.formatDescriptions).first else {
            throw GradeLabError.exportFailed(String(localized: "The exported file has no readable video track."))
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        let extensions = CMFormatDescriptionGetExtensions(description).map { $0 as NSDictionary }

        func tag(_ key: CFString) -> String? {
            extensions?[key].map { String(describing: $0) }
        }
        func label(_ raw: String?, _ mapping: [(String, String)]) -> String? {
            guard let raw else { return nil }
            return mapping.first { raw.contains($0.0) }?.1 ?? raw
        }

        return ExportOutputReport(
            codec: fourCC(CMFormatDescriptionGetMediaSubType(description)),
            bitDepth: (extensions?[kCMFormatDescriptionExtension_BitsPerComponent] as? NSNumber)?.intValue
                ?? hevcBitDepth(extensions),
            colorPrimaries: label(tag(kCMFormatDescriptionExtension_ColorPrimaries),
                                  [("ITU_R_2020", "BT.2020"), ("ITU_R_709", "BT.709"), ("P3_D65", "Display P3")]),
            transferFunction: label(tag(kCMFormatDescriptionExtension_TransferFunction),
                                    [("ITU_R_2100_HLG", "HLG"), ("SMPTE_ST_2084", "PQ"), ("ITU_R_709", "BT.709")]),
            yCbCrMatrix: label(tag(kCMFormatDescriptionExtension_YCbCrMatrix),
                               [("ITU_R_2020", "BT.2020"), ("ITU_R_709", "BT.709")]),
            width: Int(dimensions.width),
            height: Int(dimensions.height)
        )
    }

    /// Confirms the file matches what was asked for, so a mismatch is reported
    /// rather than shipped as a success.
    static func verify(_ url: URL, expecting colorMode: ProjectColorMode) async throws -> ExportOutputReport {
        let report = try await inspect(url)
        guard colorMode.isHDR else { return report }
        guard report.isHLGBT2020 else {
            throw GradeLabError.exportFailed(
                String(localized: "The exported file is not tagged as HLG BT.2020 — it reports \(report.summary). The file was written but its colour would be misread, so it is being reported as a failure rather than a success.")
            )
        }
        if let depth = report.bitDepth, depth < 10 {
            throw GradeLabError.exportFailed(
                String(localized: "The exported file reports \(depth)-bit precision, not 10-bit. Reported as a failure rather than a silent quality reduction.")
            )
        }
        return report
    }

    /// HEVCDecoderConfigurationRecord carries the exact luma/chroma depth when
    /// the format description does not expose BitsPerComponent directly.
    private static func hevcBitDepth(_ extensions: NSDictionary?) -> Int? {
        guard let atoms = extensions?[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] as? NSDictionary,
              let configuration = atoms["hvcC"] as? Data, configuration.count > 18 else {
            return nil
        }
        let luma = 8 + Int(configuration[configuration.startIndex + 17] & 0x07)
        let chroma = 8 + Int(configuration[configuration.startIndex + 18] & 0x07)
        return max(luma, chroma)
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .macOSRoman) ?? "\(value)"
    }
}
