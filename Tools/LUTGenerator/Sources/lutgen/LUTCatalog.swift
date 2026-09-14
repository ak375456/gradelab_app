import Foundation

/// The LUTs this tool ships. Add a definition here and it is generated,
/// validated and reported automatically.
enum LUTCatalog {
    static let size = 33

    static let definitions: [LUTDefinition] = [
        WarmCinema.definition,
        TealOrange.definition,
        SoftFilm.definition
    ]

    /// Used only for verification. Never written to the app resources folder.
    static let identity = LUTDefinition(
        name: "Identity",
        filename: "Identity.cube",
        category: "Debug",
        summary: "Pass-through LUT used to verify ordering and sampling. Not shipped.",
        inputColorSpace: "Rec.709 / working SDR",
        type: "debug",
        transform: { $0 }
    )
}
