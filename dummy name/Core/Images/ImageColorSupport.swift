import CoreGraphics
import Foundation

/// What the app can honestly do with a given still image.
///
/// Written in the same spirit as `ColorPipelineSupport`: a source is either
/// inside a validated path or it is refused with a reason, and nothing is
/// silently reinterpreted as something it is not.
///
/// The working space is the one the whole app grades in — Rec.709 SDR. An image
/// that declares a different profile is **converted** into it by CoreGraphics,
/// which is a real, colour-managed transform, not a reinterpretation of the same
/// numbers. What it cannot do is invent gamut: a Display P3 photograph converted
/// to Rec.709 loses the colours that lie outside Rec.709, and that is stated
/// rather than hidden.
///
/// The distinction that matters most in practice is between an **HDR gain map**
/// and an **HDR-encoded picture**. Almost every photograph a recent iPhone takes
/// is the first: an ordinary SDR image with a gain map attached that an HDR
/// display can use to lift it. That SDR image is complete and is what every
/// viewer shows by default, so it is graded, and the gain map is reported and
/// left behind. Refusing those would refuse nearly every photograph on the
/// device, which is not caution — it is just being wrong about what the file is.
enum ImageColorSupport: Equatable, Sendable {
    /// The picture can be graded. `notes` records anything the import converts
    /// or leaves behind, and is empty when there is nothing to say.
    case supported(notes: [String])
    /// No validated path.
    case unsupported(reason: String)

    init(metadata: ImageMetadata) {
        if metadata.isRAW {
            self = .unsupported(reason: """
                Camera raw files are not supported.

                Raw is not a picture yet — it needs demosaicing, a camera-specific \
                colour transform and its own highlight handling, none of which \
                GradeLab implements. It will not be run through the sRGB path and \
                called a photograph.

                Export a JPEG or HEIF from your raw processor and grade that.
                """)
            return
        }
        // Only a primary image encoded in PQ or HLG. A gain map is handled below
        // as a note, not a refusal.
        if metadata.isHDR {
            self = .unsupported(reason: """
                This image's picture data is encoded in an HDR transfer function \
                (PQ or HLG), and GradeLab has no validated still-image HDR path yet.

                Unlike a photograph with a gain map, there is no SDR picture inside \
                this file to grade, so there is nothing to fall back to. It will not \
                be converted to SDR by guesswork.
                """)
            return
        }
        if let depth = metadata.bitsPerComponent, depth > 16 {
            self = .unsupported(reason: "This image stores \(depth) bits per component, which GradeLab cannot decode without an unverified precision conversion.")
            return
        }
        if let model = metadata.colorModel, model != "RGB" {
            self = .unsupported(reason: "This is a \(model) image. GradeLab grades RGB images only, and will not guess a conversion.")
            return
        }

        var notes: [String] = []
        if metadata.isWideGamut {
            let profile = metadata.colorProfileName ?? "a wide-gamut profile"
            notes.append("""
                This image is tagged \(profile). GradeLab grades in Rec.709, so it is \
                colour-managed into that space on the way in and the exported file is \
                tagged to match — the picture stays correct, but colours outside \
                Rec.709 are brought inside it and are not recoverable afterwards.
                """)
        }
        if metadata.hasHDRGainMap {
            notes.append("""
                This photograph carries an HDR gain map. GradeLab grades the SDR \
                picture the file is built around — the one every viewer shows by \
                default — and exports SDR. The gain map is not carried into the \
                export, so the result will not brighten on an HDR display the way \
                the original does.
                """)
        }
        if !notes.isEmpty {
            notes.append("The original file is never modified.")
        }
        self = .supported(notes: notes)
    }

    var allowsGrading: Bool {
        switch self {
        case .supported: true
        case .unsupported: false
        }
    }

    var allowsEditor: Bool { allowsGrading }

    var isBlocking: Bool {
        if case .unsupported = self { return true }
        return false
    }

    var notice: String? {
        switch self {
        case .supported(let notes):
            notes.isEmpty ? nil : notes.joined(separator: "\n\n")
        case .unsupported(let reason):
            reason
        }
    }
}
