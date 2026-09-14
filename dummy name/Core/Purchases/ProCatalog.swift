import Foundation

enum ProPlan: String, CaseIterable, Identifiable, Sendable {
    case lifetime, weekly, monthly, yearly
    var id: String { "com.aftab.gradelab.pro.\(rawValue)" }
    var title: String {
        switch self {
        case .lifetime: "Lifetime Pro"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .yearly: "Yearly"
        }
    }
    var billingLabel: String {
        switch self {
        case .lifetime: "one-time payment"
        case .weekly: "per week · auto-renews"
        case .monthly: "per month · auto-renews"
        case .yearly: "per year · auto-renews"
        }
    }
}

enum ProConfiguration {
    // The published legal pages. Apple requires both to be reachable from
    // inside a subscription app, and `legalLinksReady` refuses every purchase
    // while either is missing — so these are load-bearing, not decoration.
    static let privacyPolicyURL = URL(string: "https://ak375456.github.io/gradelab/privacy.html")
    static let termsURL = URL(string: "https://ak375456.github.io/gradelab/terms.html")
    static let supportURL = URL(string: "https://ak375456.github.io/gradelab/support.html")
    static var legalLinksReady: Bool { privacyPolicyURL != nil && termsURL != nil }
    // No timer. Change this in the update ending the founding campaign AND
    // change the existing lifetime product's price in App Store Connect.
    static let foundingCampaignEnabled = true
    static let foundingUSD: Decimal = 1.99
    /// What Lifetime is worth at its settled price, and the only number the
    /// founding saving is ever measured against.
    static let standardLifetimeUSD: Decimal = 34.99
    /// What Lifetime actually costs the week after the founding campaign ends.
    ///
    /// Kept separate from `standardLifetimeUSD` because the two are different
    /// claims, and only one of them is imminent. The launch plan steps Lifetime
    /// up over weeks — $4.99, then $9.99, then $14.99 — before it settles at
    /// the $34.99 standard. Paywall copy may anchor the saving to $34.99, but
    /// it must not tell anyone the price becomes $34.99 next week, because it
    /// does not.
    static let nextLifetimeUSD: Decimal = 4.99
    /// Whether the founding campaign is running.
    ///
    /// True in every storefront. The campaign is a date, not a currency: someone
    /// buying in Karachi during launch week is as much a founding user as
    /// someone buying in California, and hiding the badge from them was a bug.
    static var isFoundingCampaignRunning: Bool { foundingCampaignEnabled }

    /// Whether the exact saving can be stated as a percentage.
    ///
    /// Only where the standard price is known in the same currency the customer
    /// is being charged in — which is USD, because `standardLifetimeUSD` is the
    /// only standard price this app knows. Everywhere else the campaign is
    /// announced without a number rather than with an invented one. The price
    /// check also suppresses the claim after App Store Connect raises the price,
    /// including for customers who have not installed the newest build.
    static func canStateFoundingDiscount(price: Decimal, currency: String) -> Bool {
        foundingCampaignEnabled && currency == "USD" && price == foundingUSD
    }
    /// Whole-percent saving against the standard lifetime price, derived rather
    /// than written down so the badge cannot drift away from the two numbers
    /// above when either of them changes.
    static var foundingDiscountPercent: Int {
        guard standardLifetimeUSD > 0 else { return 0 }
        let ratio = (standardLifetimeUSD - foundingUSD) / standardLifetimeUSD
        return Int((NSDecimalNumber(decimal: ratio).doubleValue * 100).rounded())
    }
}

/// The arithmetic behind the plan comparison.
///
/// Separated from `ProStore` so it can be tested without StoreKit. A wrong
/// percentage here is not a cosmetic bug — it is a false price claim shown to
/// every customer, so it is worth being able to assert on directly.
enum ProPricing {
    /// Average weeks per period, not calendar ones: a subscription "month" is a
    /// twelfth of a year, and treating it as a flat 4 weeks would overstate
    /// every saving by about 8%.
    static let weeksPerMonth = Decimal(string: "4.348")!
    static let weeksPerYear = Decimal(string: "52.178")!

    static func weeklyPrice(_ price: Decimal, weeksInPeriod: Decimal) -> Decimal? {
        guard weeksInPeriod > 0, price >= 0 else { return nil }
        return price / weeksInPeriod
    }

    /// Whole-percent saving of `candidate` against `baseline`, both per week.
    ///
    /// Nil when there is nothing honest to claim: a candidate that is not
    /// actually cheaper, or a difference too small to deserve a badge.
    static func savingsPercent(candidate: Decimal, baseline: Decimal) -> Int? {
        guard baseline > 0, candidate >= 0, candidate < baseline else { return nil }
        let ratio = (baseline - candidate) / baseline
        let percent = Int((NSDecimalNumber(decimal: ratio).doubleValue * 100).rounded())
        return percent >= 5 ? percent : nil
    }
}

enum ProFeature: String, Identifiable, Sendable {
    case membership
    case premiumLook
    case lutImport
    case fontImport
    case proResExport
    case exportResolution
    case exportControls
    case photoFormat
    case colorCurves
    case filmEffects
    case gradePresets
    case scopes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .membership: "Your color. Without limits."
        case .premiumLook: "Make this look yours."
        case .lutImport: "Bring your signature look."
        case .fontImport: "Bring your own typography."
        case .proResExport: "Finish in ProRes."
        case .exportResolution: "Export at full resolution."
        case .exportControls: "Take the encoder's controls."
        case .photoFormat: "Deliver in any format."
        case .colorCurves: "Grade like a colorist."
        case .filmEffects: "Give it the texture of film."
        case .gradePresets: "Keep the look you built."
        case .scopes: "Read the picture, don't guess."
        }
    }

    var detail: String {
        switch self {
        case .membership:
            "Unlock premium looks, custom imports and full-resolution delivery."
        case .premiumLook:
            "Preview Pro looks freely. Unlock Pro to export them, or remove the look to keep exporting free."
        case .lutImport:
            "Import your own .cube LUTs and carry your style from one project to the next."
        case .fontImport:
            "Import custom TTF fonts for titles that feel like you. Bundled fonts remain free."
        case .proResExport:
            "Unlock ProRes 422 and ProRes 422 HQ export on supported devices."
        case .exportResolution:
            "Free export runs up to 1080p with no watermark. Pro exports 4K and your source's own resolution."
        case .exportControls:
            "Choose the frame rate and bitrate yourself instead of taking the defaults."
        case .photoFormat:
            "Export stills as HEIC or lossless PNG. Full-resolution JPEG stays free."
        case .colorCurves:
            "Hue vs Hue, Hue vs Sat, Hue vs Luma, Luma vs Sat, Sat vs Sat and Sat vs Luma \u{2014} the curves that target one colour without touching the rest. Master, Red, Green and Blue stay free."
        case .filmEffects:
            "Bloom, glow, halation and grain. Fade and sharpening stay free."
        case .gradePresets:
            "Save a grade you like and bring it to any other project."
        case .scopes:
            "Waveform, RGB parade and vectorscope. The histogram stays free."
        }
    }
}

/// One policy shared by previews, photo export, whole timelines and clip export.
///
/// Nearly every rule here answers the same question — *would writing this file
/// use something Pro?* — because that is where the paywall sits. Free users can
/// open every Pro control and watch it work on their own footage; export is
/// what asks them to pay. That is deliberate: someone who has seen the grade
/// they want on their own clip has a far better reason to buy than someone who
/// met a locked button.
///
/// The scopes are the one exception, and they have to be: a scope never reaches
/// the exported file, so there is no export to gate. They are shown behind an
/// obscuring layer instead — the trace is there, but not readable.
enum ProAccessPolicy {

    // MARK: - Looks

    /// Ten free looks spanning cinematic, film, portrait and cooler styles.
    ///
    /// Written as the free list rather than the Pro list on purpose. Any
    /// `.cube` dropped into `Resources/LUTs/Imported` before a build is
    /// discovered automatically at runtime, and a look added that way should
    /// arrive as Pro rather than quietly widening the free tier.
    static let freeLookIDs: Set<String> = [
        "Warm_Cinema.cube", "Teal_Orange.cube", "Soft_Film.cube",
        "Cinematic.cube", "Vintage_Fox.cube", "Portrait_160.cube",
        "Moody_Aqua.cube", "Palm_Springs.cube", "Bold_Film.cube",
        "Serenity.CUBE"
    ]

    static func requiresPro(_ look: LUTAsset) -> Bool { !freeLookIDs.contains(look.id) }

    // MARK: - Fonts

    /// The bundled display and script faces, which are Pro.
    ///
    /// A Pro list rather than a free one, because `FontRegistry` also reports
    /// every font iOS itself provides. Gating "everything not on a free list"
    /// would put Helvetica behind the paywall, which is neither ours to sell
    /// nor something anyone would pay for. The workhorse text families that
    /// ship with the app — Roboto, Inter, Open Sans, Lato, Montserrat, Oswald,
    /// DM Sans, Nunito, Arimo, Raleway, Playfair Display, Google Sans — stay
    /// free, so a free user can always set a title that reads well.
    ///
    /// Matched as a prefix on the normalised family name, so the width and
    /// optical variants a family ships with ("Asap Sharp Condensed", "Doto
    /// Rounded", "Bitcount Prop Single Cursive") follow the family itself.
    static let proFontFamilyKeys: Set<String> = [
        "aguafinascript", "asapsharp", "astloch", "bitcountpropsingle",
        "blackopsone", "brunoace", "caacupeone", "carterone", "chango",
        "doppioone", "doto", "dynalight", "freckleface", "gloock",
        "hennypenny", "holtwoodonesc", "imperialscript", "kenia", "knewave",
        "londrinasketch", "margarine", "matemasie", "meaculpa",
        "medievalsharp", "mrdafoe", "pinyonscript", "playwrite",
        "racingsansone", "ranchers", "rubikbeastly", "scoutiesans",
        "slabo13px", "spicyrice", "tacone", "valleysans", "winkysans"
    ]

    /// Family names arrive from CoreText with spaces and occasional digits, so
    /// they are reduced to letters and numbers before matching.
    static func normalizedFamilyKey(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func fontRequiresPro(family: String) -> Bool {
        let key = normalizedFamilyKey(family)
        return proFontFamilyKeys.contains { key.hasPrefix($0) }
    }

    /// Whether this face — bundled or the user's own import — is Pro.
    static func fontRequiresPro(postScriptName: String?) -> Bool {
        guard let postScriptName else { return false }
        if FontRegistry.shared.isImported(postScriptName) { return true }
        return fontRequiresPro(family: FontRegistry.shared.familyName(postScriptName))
    }

    // MARK: - Export limits

    /// The longest edge a free export may write. 1080p, and no watermark.
    static let freeLongEdge = 1920

    /// Which of the ten curves are Pro.
    ///
    /// The split is the one the panel already draws a rule down the middle of:
    /// the four tone curves — Master, Red, Green, Blue — are free and unlimited,
    /// and the six colour curves are Pro. Those six are the ones that target a
    /// single colour without touching the rest of the picture, which is the
    /// part of grading people come to a colour app for.
    static func curveRequiresPro(_ type: CurveType) -> Bool {
        CurveType.colorCurves.contains(type)
    }

    // MARK: - Per-control questions
    //
    // Each of these asks about one control in isolation, which is what a menu
    // row or a slider label needs. Asking the whole-configuration question
    // instead would mark every codec as Pro the moment the resolution happened
    // to be 4K, which says nothing about the codec and reads as a mistake.

    static func codecRequiresPro(_ codec: ExportConfiguration.Codec) -> Bool {
        !codec.usesBitRate
    }

    static func resolutionRequiresPro(
        _ resolution: ExportConfiguration.Resolution,
        canvas: ProjectCanvas,
        customLongEdge: Int
    ) -> Bool {
        var probe = ExportConfiguration(resolution: resolution)
        probe.customLongEdge = customLongEdge
        let size = probe.dimensions(width: canvas.width, height: canvas.height)
        return max(size.width, size.height) > freeLongEdge
    }

    static func frameRateRequiresPro(_ frameRate: ExportConfiguration.FrameRate) -> Bool {
        frameRate != .original
    }

    // MARK: - One grade

    /// Everything this grade needs, in the order it is worth explaining.
    static func gradeRequirements(_ grade: GradeSettings) -> [ProFeature] {
        guard let advanced = grade.advanced else { return [] }
        var found: [ProFeature] = []
        if let look = lookRequirement(advanced) { found.append(look) }
        // Reading the resolved curves rather than the stored ones means a
        // project saved against the old three-slider tone curves is judged on
        // the picture it actually renders. Those legacy curves only ever
        // produced tone curves, which are free, so no old project is newly
        // gated by this.
        //
        // Eight-band HSL and the colour wheels are free.
        if advanced.resolvedCurves.active.contains(where: { curveRequiresPro($0.type) }) {
            found.append(.colorCurves)
        }
        let effects = advanced.resolvedEffects
        if FilmEffectParameter.all.contains(where: {
            proEffectIDs.contains($0.id) && effects[keyPath: $0.keyPath] > 0
        }) {
            found.append(.filmEffects)
        }
        return found
    }

    static func gradeRequirement(_ grade: GradeSettings) -> ProFeature? {
        gradeRequirements(grade).first
    }

    /// The finishing effects that are Pro. Fade and sharpening are not: neither
    /// was listed as Pro, and quietly taking away a control nobody asked to
    /// take away is worse than leaving it.
    static let proEffectIDs: Set<String> = ["bloom", "glow", "halation", "grain"]

    /// A stored preset, clipboard or project must not bypass look gating, so
    /// this resolves the identifier rather than trusting where it came from.
    private static func lookRequirement(_ advanced: AdvancedGrade) -> ProFeature? {
        guard advanced.lutStrength > 0, let id = advanced.lut else { return nil }
        // Not among the looks that ship in the bundle, so it came off the
        // device: someone's own `.cube`, which is its own Pro feature.
        guard let bundled = LUTAsset.bundledLooks.first(where: { $0.id == id }) else {
            return .lutImport
        }
        return requiresPro(bundled) ? .premiumLook : nil
    }

    // MARK: - One clip

    static func clipRequirements(_ clip: VideoClip) -> [ProFeature] {
        // Overlays, animation and every blend mode are part of the free editor.
        // Only an actually premium grade applied to this clip can gate export.
        gradeRequirements(clip.gradeSettings)
    }

    static func textRequirements(_ clip: TextClip) -> [ProFeature] {
        var found: [ProFeature] = []
        if fontRequiresPro(postScriptName: clip.style.fontName) { found.append(.fontImport) }
        return found
    }

    static func clipRequirement(_ clip: VideoClip) -> ProFeature? { clipRequirements(clip).first }
    static func textRequirement(_ clip: TextClip) -> ProFeature? { textRequirements(clip).first }

    // MARK: - The whole project

    // A project's colour handling is not a Pro question. HDR (HLG) and Apple
    // Log sources import, preview, grade and export on the free tier, at the
    // free tier's own limits — 1080p, the source's frame rate, an HEVC encode.
    // What someone pays for is the delivery: 4K and original resolution, a
    // chosen frame rate or bitrate, and ProRes. Those are asked about in
    // `configurationRequirements`, and they are asked in exactly the same way
    // whether the source is Log, HLG or ordinary Rec.709.
    //
    // Deliberately not a `workflowRequirement` that returns nil: a rule that
    // always answers "free" is indistinguishable from a rule someone forgot to
    // finish, and would invite the gate being wired back by accident.

    /// What the timeline's own contents need, ignoring the export settings.
    static func contentRequirements(_ project: VideoProject) -> [ProFeature] {
        var found: [ProFeature] = []
        for track in project.timeline.tracks where track.isEnabled {
            let live = track.items.filter(\.placement.isEnabled)
            guard !live.isEmpty else { continue }
            for item in live {
                switch item {
                case .video(let clip): found.append(contentsOf: clipRequirements(clip))
                case .text(let clip): found.append(contentsOf: textRequirements(clip))
                case .audio: continue
                }
            }
        }
        return found
    }

    static func contentRequirement(_ project: VideoProject) -> ProFeature? {
        contentRequirements(project).first
    }

    /// Everything the project needs regardless of how it is exported. Used to
    /// badge the editor before anyone opens the export screen.
    static func projectRequirement(_ project: VideoProject) -> ProFeature? {
        contentRequirement(project)
    }

    // MARK: - Export

    /// What the chosen delivery settings need on their own.
    static func configurationRequirements(
        _ configuration: ExportConfiguration, canvas: ProjectCanvas
    ) -> [ProFeature] {
        var found: [ProFeature] = []
        if codecRequiresPro(configuration.codec) { found.append(.proResExport) }
        // Measured after the resolution is resolved, so "Original" on a 4K
        // source is caught while "Original" on a 1080p source is not.
        if resolutionRequiresPro(configuration.resolution, canvas: canvas,
                                 customLongEdge: configuration.customLongEdge) {
            found.append(.exportResolution)
        }
        if frameRateRequiresPro(configuration.frameRate) || configuration.videoBitRate != nil {
            found.append(.exportControls)
        }
        return found
    }

    static func configurationRequirement(
        _ configuration: ExportConfiguration, canvas: ProjectCanvas
    ) -> ProFeature? {
        configurationRequirements(configuration, canvas: canvas).first
    }

    /// Every Pro feature this export would use, deduplicated and in a sensible
    /// reading order.
    ///
    /// The whole list rather than the first one, because someone looking at a
    /// locked export button deserves to know everything standing in the way —
    /// being told about the 4K, paying, and then discovering the ProRes codec
    /// was also a reason would be a worse experience than being told both at
    /// once.
    static func exportRequirements(
        _ project: VideoProject, configuration: ExportConfiguration, settings: GradeSettings
    ) -> [ProFeature] {
        // Delivery settings first: they are the reasons the person can act on
        // without undoing any of their work.
        var found: [ProFeature] = []
        found.append(contentsOf: configurationRequirements(configuration, canvas: project.canvas))
        found.append(contentsOf: contentRequirements(project))
        found.append(contentsOf: gradeRequirements(settings))
        return deduplicated(found)
    }

    static func exportRequirement(
        _ project: VideoProject, configuration: ExportConfiguration
    ) -> ProFeature? {
        exportRequirements(project, configuration: configuration, settings: .neutral).first
    }

    static func imageExportRequirements(
        _ project: ImageProject, configuration: ImageExportConfiguration
    ) -> [ProFeature] {
        var found: [ProFeature] = []
        if configuration.format != .jpeg { found.append(.photoFormat) }
        found.append(contentsOf: gradeRequirements(project.gradeSettings))
        return deduplicated(found)
    }

    static func imageExportRequirement(
        _ project: ImageProject, configuration: ImageExportConfiguration
    ) -> ProFeature? {
        imageExportRequirements(project, configuration: configuration).first
    }

    /// First occurrence wins, so the order above is the order shown.
    static func deduplicated(_ features: [ProFeature]) -> [ProFeature] {
        var seen: Set<String> = []
        return features.filter { seen.insert($0.id).inserted }
    }
}
