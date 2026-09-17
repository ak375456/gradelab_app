import XCTest
@testable import GradeLab

/// The paywall's rules, tested at the policy rather than through the UI.
///
/// `ProAccessPolicy` is the single place that decides whether a file may be
/// written for free, and it is consulted from four screens. A quiet mistake
/// here either gives away the product or blocks a paying customer, and neither
/// shows up in a build log — so every rule in the feature table gets a case.
final class ProAccessPolicyTests: XCTestCase {

    // MARK: - Fixtures

    private func project(
        width: Int = 1_920,
        height: Int = 1_080,
        log: String? = nil,
        hdr: Bool? = false,
        transfer: String? = "BT.709"
    ) -> VideoProject {
        VideoProject(
            sourceURL: URL(fileURLWithPath: "/tmp/pro-access.mov"),
            displayName: "Pro Access",
            metadata: makeVideoMetadata(
                encodedWidth: width, encodedHeight: height,
                displayWidth: width, displayHeight: height,
                transferFunction: transfer,
                logTransferFunction: log,
                isHDR: hdr))
    }

    private func withGrade(_ base: VideoProject, _ grade: GradeSettings) -> VideoProject {
        var copy = base
        for (trackIndex, track) in copy.timeline.tracks.enumerated() {
            for (itemIndex, item) in track.items.enumerated() {
                guard case .video(var clip) = item else { continue }
                clip.gradeSettings = grade
                copy.timeline.tracks[trackIndex].items[itemIndex] = .video(clip)
            }
        }
        return copy
    }

    private func grade(_ build: (inout AdvancedGrade) -> Void) -> GradeSettings {
        var advanced = AdvancedGrade()
        build(&advanced)
        var settings = GradeSettings()
        settings.advanced = advanced
        return settings
    }

    private var free: ExportConfiguration {
        ExportConfiguration(resolution: .fullHD, frameRate: .original, codec: .hevc)
    }

    // MARK: - The free tier really is free

    func testAFreeGradeAt1080pNeedsNothing() {
        XCTAssertNil(ProAccessPolicy.exportRequirement(project(), configuration: free))
    }

    /// The basic light and colour sliders are free, and must stay that way even
    /// when every one of them is pushed to its limit.
    func testEveryBasicSliderStaysFree() {
        var settings = GradeSettings()
        settings.exposure = 2
        settings.contrast = 100
        settings.highlights = -100
        settings.shadows = 100
        settings.whites = 50
        settings.blacks = -50
        settings.temperature = 100
        settings.tint = -100
        settings.saturation = 100
        settings.vibrance = 100
        XCTAssertNil(ProAccessPolicy.gradeRequirement(settings))
    }

    func testTheMasterToneCurveIsFree() {
        let settings = grade { advanced in
            var curves = AdvancedCurves()
            curves[.master] = AdvancedCurve(
                type: .master,
                points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.62), CurvePoint(x: 1, y: 1)])
            advanced.advancedCurves = curves
        }
        XCTAssertNil(ProAccessPolicy.gradeRequirement(settings))
    }

    /// Fade and sharpening were never listed as Pro, so gating them would be
    /// taking away something nobody asked to take away.
    func testFadeAndSharpenStayFree() {
        let settings = grade { advanced in
            var effects = FilmEffects()
            effects.fade = 80
            effects.sharpness = 60
            advanced.effects = effects
        }
        XCTAssertNil(ProAccessPolicy.gradeRequirement(settings))
    }

    // MARK: - Looks

    func testTheExpandedFreeLookSelectionShipsInTheBundle() {
        XCTAssertEqual(ProAccessPolicy.freeLookIDs.count, 10)
        XCTAssertTrue(
            Set(LUTAsset.bundledCreativeLooks.map(\.id)).isSubset(of: ProAccessPolicy.freeLookIDs),
            "the original free looks must remain free")
        XCTAssertTrue(
            ProAccessPolicy.freeLookIDs.isSubset(of: Set(LUTAsset.bundledLooks.map(\.id))),
            "every free look must resolve to a bundled asset, including its exact filename case")
    }

    func testEveryFreeLookAllowsPhotoAndVideoExport() throws {
        var photoConfiguration = ImageExportConfiguration()
        photoConfiguration.format = .jpeg
        for id in ProAccessPolicy.freeLookIDs {
            let look = try XCTUnwrap(LUTAsset.bundledLooks.first { $0.id == id })
            let settings = grade { $0.lut = id; $0.lutIntensity = 100 }
            XCTAssertFalse(ProAccessPolicy.requiresPro(look), "\(id) must not show a Pro badge")
            XCTAssertNil(ProAccessPolicy.gradeRequirement(settings), id)
            XCTAssertNil(
                ProAccessPolicy.exportRequirement(withGrade(project(), settings), configuration: free), id)
            XCTAssertTrue(
                ProAccessPolicy.exportRequirements(project(), configuration: free, settings: settings).isEmpty,
                "\(id) must also be free when supplied as the export grade")
            XCTAssertNil(
                ProAccessPolicy.imageExportRequirement(
                    imageProject(grade: settings), configuration: photoConfiguration), id)
        }
    }

    func testAPremiumLookBlocksExport() throws {
        let premium = try XCTUnwrap(LUTAsset.bundledLooks.first { ProAccessPolicy.requiresPro($0) })
        let settings = grade { $0.lut = premium.id; $0.lutIntensity = 100 }
        XCTAssertEqual(ProAccessPolicy.gradeRequirement(settings), .premiumLook)
    }

    /// A look identifier that is not in the bundle came off the user's device,
    /// which is the custom-LUT feature rather than the premium-look one.
    func testAnImportedLookReportsCustomLUTImport() {
        let settings = grade { $0.lut = "Someones_Own_Look.cube"; $0.lutIntensity = 100 }
        XCTAssertEqual(ProAccessPolicy.gradeRequirement(settings), .lutImport)
    }

    /// A stored preset, a pasted grade or an old project must not be a way
    /// around look gating, and a look at zero strength is not being used.
    func testALookAtZeroStrengthIsNotGated() {
        let settings = grade { $0.lut = "Cinematic.cube"; $0.lutIntensity = 0 }
        XCTAssertNil(ProAccessPolicy.gradeRequirement(settings))
    }

    // MARK: - Pro grading tools

/// The whole ten-curve split in one place: the four tone curves are free and
    /// unlimited, the six colour curves are Pro.
    func testEveryCurveIsOnTheRightSideOfThePaywall() {
        for type in CurveType.toneCurves {
            XCTAssertFalse(ProAccessPolicy.curveRequiresPro(type), "\(type.title) must stay free")
        }
        for type in CurveType.colorCurves {
            XCTAssertTrue(ProAccessPolicy.curveRequiresPro(type), "\(type.title) must be Pro")
        }
    }

    /// Master, Red, Green and Blue are free however far they are pushed —
    /// there is no point limit on them.
    func testToneCurvesAreFreeAtAnyComplexity() {
        for type in CurveType.toneCurves {
            var points = [CurvePoint(x: 0, y: 0.05)]
            for index in 1...8 {
                let x = Float(index) / 9
                points.append(CurvePoint(x: x, y: min(1, x + 0.08)))
            }
            points.append(CurvePoint(x: 1, y: 0.95))
            let settings = grade { advanced in
                var curves = AdvancedCurves()
                curves[type] = AdvancedCurve(type: type, points: points)
                advanced.advancedCurves = curves
            }
            XCTAssertNil(
                ProAccessPolicy.gradeRequirement(settings),
                "a 10-point \(type.title) curve should still be free")
        }
    }

    func testEachColourCurveGatesTheExport() {
        for type in CurveType.colorCurves {
            let settings = grade { advanced in
                var curves = AdvancedCurves()
                curves[type] = AdvancedCurve(
                    type: type,
                    points: [CurvePoint(x: 0.3, y: type.isMapping ? 0.55 : 0.4)])
                advanced.advancedCurves = curves
            }
            XCTAssertEqual(
                ProAccessPolicy.gradeRequirement(settings), .colorCurves,
                "\(type.title) should be Pro")
        }
    }

    /// The legacy three-slider curves only ever produced tone curves, so no
    /// project saved before advanced curves existed becomes newly gated.
    func testLegacyToneCurvesStayFree() {
        for index in 0..<4 {
            let settings = grade { $0.curves[index].midtones = 0.72 }
            XCTAssertNil(
                ProAccessPolicy.gradeRequirement(settings),
                "legacy curve \(index) should stay free")
        }
    }

    /// Eight-band HSL and the colour wheels are free.
    func testHSLAndWheelsAreFree() {
        let hsl = grade { $0.hsl[3].saturation = 40 }
        XCTAssertNil(ProAccessPolicy.gradeRequirement(hsl))
        let wheels = grade { $0.wheels[1].strength = 25 }
        XCTAssertNil(ProAccessPolicy.gradeRequirement(wheels))
        let both = grade { advanced in
            advanced.hsl[0].hue = -20
            advanced.wheels[2].brightness = 30
        }
        XCTAssertNil(ProAccessPolicy.gradeRequirement(both))
    }

    func testBloomGlowHalationAndGrainAreGated() {
        for parameter in FilmEffectParameter.all
        where ProAccessPolicy.proEffectIDs.contains(parameter.id) {
            let settings = grade { advanced in
                var effects = FilmEffects()
                effects[keyPath: parameter.keyPath] = 50
                advanced.effects = effects
            }
            XCTAssertEqual(
                ProAccessPolicy.gradeRequirement(settings), .filmEffects,
                "\(parameter.name) should be Pro")
        }
    }

    // MARK: - Export settings

    func testFourKIsGated() {
        let configuration = ExportConfiguration(resolution: .ultraHD, codec: .hevc)
        XCTAssertEqual(
            ProAccessPolicy.exportRequirement(project(), configuration: configuration),
            .exportResolution)
    }

    /// "Original" is not a fixed size. On a 1080p source it is free; on a 4K
    /// source it is the same thing as asking for 4K.
    func testOriginalResolutionIsJudgedAgainstTheCanvas() {
        let configuration = ExportConfiguration(resolution: .original, codec: .hevc)
        XCTAssertNil(
            ProAccessPolicy.exportRequirement(project(), configuration: configuration),
            "1080p source at Original is within the free tier")
        XCTAssertEqual(
            ProAccessPolicy.exportRequirement(
                project(width: 3_840, height: 2_160), configuration: configuration),
            .exportResolution,
            "4K source at Original is a 4K export")
    }

    func testSevenTwentyPStaysFree() {
        let configuration = ExportConfiguration(resolution: .hd, codec: .hevc)
        XCTAssertNil(ProAccessPolicy.exportRequirement(
            project(width: 3_840, height: 2_160), configuration: configuration))
    }

    func testProResIsGated() {
        for codec in [ExportConfiguration.Codec.proRes422, .proRes422HQ] {
            let configuration = ExportConfiguration(resolution: .fullHD, codec: codec)
            XCTAssertEqual(
                ProAccessPolicy.exportRequirement(project(), configuration: configuration),
                .proResExport, "\(codec.rawValue) should be Pro")
        }
    }

    func testACustomFrameRateIsGated() {
        let configuration = ExportConfiguration(resolution: .fullHD, frameRate: .fps60, codec: .hevc)
        XCTAssertEqual(
            ProAccessPolicy.exportRequirement(project(), configuration: configuration),
            .exportControls)
    }

    func testAManualBitrateIsGated() {
        let configuration = ExportConfiguration(
            resolution: .fullHD, frameRate: .original, codec: .hevc, videoBitRate: 40_000_000)
        XCTAssertEqual(
            ProAccessPolicy.exportRequirement(project(), configuration: configuration),
            .exportControls)
    }

    /// The quality presets are three named choices, not a custom bitrate, so
    /// they stay free.
    func testQualityPresetsStayFree() {
        for preset in ExportConfiguration.QualityPreset.allCases {
            let configuration = ExportConfiguration(
                resolution: .fullHD, frameRate: .original, codec: .hevc, qualityPreset: preset)
            XCTAssertNil(
                ProAccessPolicy.exportRequirement(project(), configuration: configuration),
                "\(preset.rawValue) should stay free")
        }
    }

    // MARK: - Colour workflows are free

    /// Apple Log and HLG are not Pro, and these two cases are the guard on
    /// that. They are the reason a lot of people open a grading app at all, and
    /// gating them put the paywall in front of the work instead of in front of
    /// the delivery. A Log or HLG source now exports on the free tier at the
    /// free tier's own limits, exactly like any Rec.709 clip.
    func testAppleLogExportIsFree() {
        XCTAssertNil(
            ProAccessPolicy.exportRequirement(project(log: "AppleLog"), configuration: free))
    }

    func testHLGExportIsFree() {
        XCTAssertNil(
            ProAccessPolicy.exportRequirement(
                project(hdr: true, transfer: "HLG"), configuration: free))
    }

    /// The colour of the source changes nothing about how its delivery settings
    /// are judged. A 4K Log export is Pro for the 4K — which is a reason the
    /// person can act on by choosing 1080p and keeping their Log grade.
    func testALogSourceIsJudgedOnlyOnItsDeliverySettings() {
        let configuration = ExportConfiguration(resolution: .ultraHD, codec: .hevc)
        XCTAssertEqual(
            ProAccessPolicy.exportRequirement(project(log: "AppleLog"), configuration: configuration),
            .exportResolution)
    }

    /// 4K60 is the headline Pro export, and it stays Pro on every source —
    /// free HDR must not become a side door to it.
    func test4K60StaysProOnEverySource() {
        let configuration = ExportConfiguration(
            resolution: .ultraHD, frameRate: .fps60, codec: .hevc)
        for source in [project(), project(log: "AppleLog"), project(hdr: true, transfer: "HLG")] {
            XCTAssertEqual(
                ProAccessPolicy.exportRequirements(
                    source, configuration: configuration, settings: .neutral),
                [.exportResolution, .exportControls])
        }
    }

    /// ProRes is likewise unaffected: it was never the HDR rule that gated it.
    func testProResStaysProOnAnHDRSource() {
        let configuration = ExportConfiguration(resolution: .fullHD, codec: .proRes422)
        XCTAssertEqual(
            ProAccessPolicy.exportRequirement(
                project(hdr: true, transfer: "HLG"), configuration: configuration),
            .proResExport)
    }

    // MARK: - Timeline content

    func testEveryBlendModeOnAClipIsFree() {
        let base = project()
        for mode in VisualBlendMode.allCases {
            var candidate = base
            for (trackIndex, track) in candidate.timeline.tracks.enumerated() {
                for (itemIndex, item) in track.items.enumerated() {
                    guard case .video(var clip) = item else { continue }
                    clip.blendMode = mode
                    candidate.timeline.tracks[trackIndex].items[itemIndex] = .video(clip)
                }
            }
            XCTAssertNil(ProAccessPolicy.exportRequirement(candidate, configuration: free),
                         "\(mode.rawValue) blending must not add a Pro export requirement")

            var title = TextClip(placement: .init(
                id: UUID(), trackID: UUID(), timelineStart: .zero, duration: .zero
            ))
            title.blendMode = mode
            XCTAssertNil(ProAccessPolicy.textRequirement(title),
                         "\(mode.rawValue) text blending must remain free")
        }
    }

    func testNormalVideoOverlayIsFreeToExport() throws {
        var base = project()
        let source = try XCTUnwrap(base.timeline.firstVideoClip)
        let overlayTrackID = UUID()
        var overlay = source
        overlay.placement = .init(
            id: UUID(), trackID: overlayTrackID, timelineStart: .zero,
            duration: source.placement.duration
        )
        base.timeline.tracks.insert(
            .init(id: overlayTrackID, name: "Free overlay", kind: .videoOverlay,
                  items: [.video(overlay)]),
            at: 0
        )

        XCTAssertNil(ProAccessPolicy.clipRequirement(overlay))
        XCTAssertNil(ProAccessPolicy.contentRequirement(base))
        XCTAssertNil(ProAccessPolicy.exportRequirement(base, configuration: free),
                     "a normal overlay must not add a Pro export requirement")
    }

    func testVideoMaskAndTextKeyframesDoNotRestrictFreeExport() throws {
        var base = project()
        for (trackIndex, track) in base.timeline.tracks.enumerated() {
            for (itemIndex, item) in track.items.enumerated() {
                guard case .video(var clip) = item else { continue }
                clip.animation = ClipAnimation(tracks: [
                    AnimationTrack(property: .layerMaskPositionX, keyframes: [
                        Keyframe(time: .zero, value: .number(0)),
                        Keyframe(time: try .seconds(1), value: .number(1))
                    ])
                ])
                base.timeline.tracks[trackIndex].items[itemIndex] = .video(clip)
            }
        }

        let textTrackID = UUID()
        var title = TextClip(placement: .init(
            id: UUID(), trackID: textTrackID, timelineStart: .zero,
            duration: try .seconds(2)
        ))
        title.animation = ClipAnimation(tracks: [
            AnimationTrack(property: .opacity, keyframes: [
                Keyframe(time: .zero, value: .number(0)),
                Keyframe(time: try .seconds(1), value: .number(1))
            ])
        ])
        base.timeline.tracks.insert(
            .init(id: textTrackID, name: "Animated title", kind: .text,
                  items: [.text(title)]),
            at: 0
        )

        XCTAssertNil(ProAccessPolicy.clipRequirement(base.timeline.firstVideoClip!))
        XCTAssertNil(ProAccessPolicy.textRequirement(title))
        XCTAssertNil(ProAccessPolicy.exportRequirement(base, configuration: free),
                     "keyframes must never add a Pro export requirement")
    }

    func testAGradedClipIsGatedThroughTheTimeline() {
        let graded = withGrade(project(), grade { advanced in
                var curves = AdvancedCurves()
                curves[.hueVsSaturation] = AdvancedCurve(
                    type: .hueVsSaturation, points: [CurvePoint(x: 0.4, y: 0.35)])
                advanced.advancedCurves = curves
            })
        XCTAssertEqual(ProAccessPolicy.exportRequirement(graded, configuration: free), .colorCurves)
    }

    // MARK: - Stills

    func testFullResolutionJPEGOfAFreeGradeIsFree() {
        let still = imageProject()
        var configuration = ImageExportConfiguration()
        configuration.format = .jpeg
        XCTAssertNil(ProAccessPolicy.imageExportRequirement(still, configuration: configuration))
    }

    func testHEICAndPNGAreGated() {
        let still = imageProject()
        for format in [ImageExportFormat.heic, .png] {
            var configuration = ImageExportConfiguration()
            configuration.format = format
            XCTAssertEqual(
                ProAccessPolicy.imageExportRequirement(still, configuration: configuration),
                .photoFormat, "\(format.title) should be Pro")
        }
    }

    func testAProGradeBlocksAJPEGStillToo() {
        let still = imageProject(grade: grade { advanced in
                var curves = AdvancedCurves()
                curves[.hueVsSaturation] = AdvancedCurve(
                    type: .hueVsSaturation, points: [CurvePoint(x: 0.4, y: 0.35)])
                advanced.advancedCurves = curves
            })
        var configuration = ImageExportConfiguration()
        configuration.format = .jpeg
        XCTAssertEqual(
            ProAccessPolicy.imageExportRequirement(still, configuration: configuration),
            .colorCurves)
    }

    /// A still graded only with the free tools exports as a free JPEG.
    func testAFreeGradeDoesNotBlockAJPEGStill() {
        let still = imageProject(grade: grade { advanced in
            advanced.hsl[1].saturation = 25
            advanced.wheels[0].strength = 30
        })
        var configuration = ImageExportConfiguration()
        configuration.format = .jpeg
        XCTAssertNil(ProAccessPolicy.imageExportRequirement(still, configuration: configuration))
    }

    private func imageProject(grade: GradeSettings = .neutral) -> ImageProject {
        ImageProject(
            displayName: "Still",
            asset: ImageAsset(
                id: UUID(),
                url: URL(fileURLWithPath: "/tmp/pro-access.heic"),
                metadata: ImageMetadata(
                    fileName: "IMG_0001.HEIC", pixelWidth: 4_032, pixelHeight: 3_024,
                    orientation: 1, typeIdentifier: "public.heic", fileSize: 2_400_000,
                    bitsPerComponent: 8, colorModel: "RGB", colorProfileName: "Display P3",
                    hasEmbeddedProfile: true, isWideGamut: true, isHDR: false, hasAlpha: false,
                    dpi: 72, creationDate: Date(timeIntervalSince1970: 1_700_000_000),
                    isRAW: false, hdrGainMap: false)),
            gradeSettings: grade)
    }

    // MARK: - Each control is judged on itself

    /// The regression this exists for: asking the whole-configuration question
    /// per menu row meant that on a 4K project — where the resolution alone is
    /// Pro — every codec came back "Pro", HEVC included. A codec is Pro only if
    /// the codec is Pro.
    func testACodecIsJudgedOnItsOwnAndNotOnTheResolution() {
        XCTAssertFalse(ProAccessPolicy.codecRequiresPro(.hevc))
        XCTAssertFalse(ProAccessPolicy.codecRequiresPro(.h264))
        XCTAssertTrue(ProAccessPolicy.codecRequiresPro(.proRes422))
        XCTAssertTrue(ProAccessPolicy.codecRequiresPro(.proRes422HQ))

        // And the whole configuration still reports both reasons on a 4K
        // ProRes export, so nothing was lost by separating the questions.
        let fourK = project(width: 3_840, height: 2_160)
        let configuration = ExportConfiguration(resolution: .original, codec: .proRes422)
        let requirements = ProAccessPolicy.exportRequirements(
            fourK, configuration: configuration, settings: .neutral)
        XCTAssertTrue(requirements.contains(.proResExport))
        XCTAssertTrue(requirements.contains(.exportResolution))
    }

    func testResolutionIsJudgedPerOptionAgainstTheCanvas() {
        let fourK = project(width: 3_840, height: 2_160).canvas
        let hd = project().canvas
        for (resolution, expected) in [
            (ExportConfiguration.Resolution.hd, false),
            (.fullHD, false),
            (.ultraHD, true),
            (.original, true)
        ] {
            XCTAssertEqual(
                ProAccessPolicy.resolutionRequiresPro(resolution, canvas: fourK, customLongEdge: 1_920),
                expected, "\(resolution.rawValue) on a 4K canvas")
        }
        XCTAssertFalse(
            ProAccessPolicy.resolutionRequiresPro(.original, canvas: hd, customLongEdge: 1_920),
            "Original on a 1080p canvas is within the free tier")
        XCTAssertTrue(
            ProAccessPolicy.resolutionRequiresPro(.custom, canvas: hd, customLongEdge: 3_000),
            "a custom long edge above 1080p is a Pro export")
    }

    func testOnlyANonOriginalFrameRateIsPro() {
        XCTAssertFalse(ProAccessPolicy.frameRateRequiresPro(.original))
        XCTAssertTrue(ProAccessPolicy.frameRateRequiresPro(.fps60))
    }

    // MARK: - Fonts

    func testDisplayFacesAreProAndWorkhorseTextFacesAreNot() {
        for family in ["Roboto", "Inter", "Open Sans", "Lato", "Montserrat",
                       "Oswald", "DM Sans", "Nunito", "Arimo", "Raleway",
                       "Playfair Display", "Google Sans"] {
            XCTAssertFalse(ProAccessPolicy.fontRequiresPro(family: family), "\(family) should stay free")
        }
        for family in ["Knewave", "Mea Culpa", "Imperial Script", "Rubik Beastly",
                       "Doto", "Chango", "MedievalSharp", "Black Ops One",
                       "Pinyon Script", "Bitcount Prop Single"] {
            XCTAssertTrue(ProAccessPolicy.fontRequiresPro(family: family), "\(family) should be Pro")
        }
    }

    /// Width and optical variants follow their family rather than escaping it.
    func testFamilyVariantsFollowTheFamily() {
        XCTAssertTrue(ProAccessPolicy.fontRequiresPro(family: "Asap Sharp Condensed"))
        XCTAssertTrue(ProAccessPolicy.fontRequiresPro(family: "Doto Rounded"))
        XCTAssertTrue(ProAccessPolicy.fontRequiresPro(family: "Playwrite BR"))
        XCTAssertFalse(ProAccessPolicy.fontRequiresPro(family: "Roboto Condensed"))
        XCTAssertFalse(ProAccessPolicy.fontRequiresPro(family: "Open Sans SemiCondensed"))
    }

    /// The system's own faces are not ours to sell.
    func testSystemFontsAreNotGated() {
        for family in ["Helvetica", "Helvetica Neue", "Times New Roman", "Menlo", "Georgia"] {
            XCTAssertFalse(ProAccessPolicy.fontRequiresPro(family: family), "\(family) is not ours")
        }
    }

    // MARK: - Listing every reason

    /// An export blocked for several independent reasons has to report all of
    /// them, so nobody pays for one and then meets the next.
    func testExportListsEveryProFeatureInUse() {
        let graded = withGrade(
            project(width: 3_840, height: 2_160),
            grade { advanced in
                var curves = AdvancedCurves()
                curves[.hueVsHue] = AdvancedCurve(
                    type: .hueVsHue, points: [CurvePoint(x: 0.2, y: 0.3)])
                advanced.advancedCurves = curves
                var effects = FilmEffects()
                effects.halation = 40
                advanced.effects = effects
            })
        let configuration = ExportConfiguration(
            resolution: .ultraHD, frameRate: .fps60, codec: .proRes422)
        let requirements = ProAccessPolicy.exportRequirements(
            graded, configuration: configuration, settings: .neutral)

        XCTAssertTrue(requirements.contains(.proResExport))
        XCTAssertTrue(requirements.contains(.exportResolution))
        XCTAssertTrue(requirements.contains(.exportControls))
        XCTAssertTrue(requirements.contains(.colorCurves))
        XCTAssertTrue(requirements.contains(.filmEffects))
        XCTAssertEqual(requirements.count, Set(requirements.map(\.id)).count, "no duplicates")
    }

    func testAFreeExportListsNothing() {
        XCTAssertTrue(ProAccessPolicy.exportRequirements(
            project(), configuration: free, settings: .neutral).isEmpty)
    }

    // MARK: - Pricing

    /// The badge derives its percentage from the two prices, so this fails if
    /// either one is changed without the other being considered.
    func testTheFoundingDiscountMatchesThePrices() {
        XCTAssertEqual(ProConfiguration.foundingUSD, 1.99)
        XCTAssertEqual(ProConfiguration.standardLifetimeUSD, 34.99)
        XCTAssertEqual(ProConfiguration.foundingDiscountPercent, 94)
    }

    // MARK: - Plan comparison

    /// The weekly-equivalent figures shown beside each plan.
    func testWeeklyEquivalentPricing() throws {
        let weekly = try XCTUnwrap(ProPricing.weeklyPrice(1.99, weeksInPeriod: 1))
        let monthly = try XCTUnwrap(ProPricing.weeklyPrice(4.99, weeksInPeriod: ProPricing.weeksPerMonth))
        let yearly = try XCTUnwrap(ProPricing.weeklyPrice(14.99, weeksInPeriod: ProPricing.weeksPerYear))

        func rounded(_ value: Decimal) -> Double {
            (NSDecimalNumber(decimal: value).doubleValue * 100).rounded() / 100
        }
        XCTAssertEqual(rounded(weekly), 1.99)
        XCTAssertEqual(rounded(monthly), 1.15, "a month is 4.348 weeks, not 4")
        XCTAssertEqual(rounded(yearly), 0.29)
    }

    /// The percentages printed on the badges. These are price claims shown to
    /// every customer, so they are asserted rather than eyeballed.
    func testSavingsBadgesAgainstTheWeeklyPlan() throws {
        let weekly = try XCTUnwrap(ProPricing.weeklyPrice(1.99, weeksInPeriod: 1))
        let monthly = try XCTUnwrap(ProPricing.weeklyPrice(4.99, weeksInPeriod: ProPricing.weeksPerMonth))
        let yearly = try XCTUnwrap(ProPricing.weeklyPrice(14.99, weeksInPeriod: ProPricing.weeksPerYear))

        XCTAssertEqual(ProPricing.savingsPercent(candidate: monthly, baseline: weekly), 42)
        XCTAssertEqual(ProPricing.savingsPercent(candidate: yearly, baseline: weekly), 86)
        XCTAssertNil(
            ProPricing.savingsPercent(candidate: weekly, baseline: weekly),
            "the baseline plan cannot save against itself")
    }

    /// A badge must never claim a saving that is not real.
    func testNoSavingsClaimedWhenThereIsNone() {
        XCTAssertNil(ProPricing.savingsPercent(candidate: 3.00, baseline: 1.99),
                     "a dearer plan must not claim a saving")
        XCTAssertNil(ProPricing.savingsPercent(candidate: 1.95, baseline: 1.99),
                     "a 2% difference is not worth a badge")
        XCTAssertNil(ProPricing.savingsPercent(candidate: 1.00, baseline: 0),
                     "no baseline means no claim")
        XCTAssertNil(ProPricing.weeklyPrice(4.99, weeksInPeriod: 0),
                     "a zero-length period has no weekly price")
    }

    /// `ProStore.purchase()` refuses every purchase while either legal link is
    /// missing, and Apple will not approve a subscription app without both. So
    /// an empty value here is not a cosmetic gap — it is a dead paywall.
    func testTheLegalLinksArePublished() throws {
        XCTAssertTrue(
            ProConfiguration.legalLinksReady,
            "purchases are blocked until the privacy policy and terms URLs are set")

        let links: [(String, URL?)] = [
            ("privacy policy", ProConfiguration.privacyPolicyURL),
            ("terms", ProConfiguration.termsURL),
            ("support", ProConfiguration.supportURL),
            ("community", ProConfiguration.communityURL)
        ]
        for (name, value) in links {
            let url = try XCTUnwrap(value, "\(name) URL is missing")
            XCTAssertEqual(url.scheme, "https", "\(name) must be served over HTTPS")
            XCTAssertFalse(url.host?.isEmpty ?? true, "\(name) has no host")
        }
        XCTAssertEqual(
            Set(links.compactMap { $0.1 }).count, links.count,
            "each link should point somewhere different")
    }

    /// The percentage claim must not follow the price into another currency, or
    /// survive App Store Connect raising it.
    func testTheFoundingPercentageIsUSDAndExactPriceOnly() {
        XCTAssertTrue(ProConfiguration.canStateFoundingDiscount(price: 1.99, currency: "USD"))
        XCTAssertFalse(ProConfiguration.canStateFoundingDiscount(price: 1.99, currency: "EUR"),
                       "the standard price is only known in dollars")
        XCTAssertFalse(ProConfiguration.canStateFoundingDiscount(price: 4.99, currency: "USD"),
                       "the claim must stop when App Store Connect raises the price")
    }

    /// The campaign itself is a date, not a currency. Someone buying in Karachi
    /// during launch week is as much a founding user as someone in California,
    /// and the badge went missing for them because the two questions had been
    /// collapsed into one.
    func testTheFoundingCampaignRunsInEveryStorefront() {
        XCTAssertEqual(
            ProConfiguration.isFoundingCampaignRunning,
            ProConfiguration.foundingCampaignEnabled,
            "campaign visibility must not depend on the customer's currency")
        // The badge is shown on this, so it has to stay true where the
        // percentage cannot be stated.
        XCTAssertTrue(ProConfiguration.isFoundingCampaignRunning)
        XCTAssertFalse(ProConfiguration.canStateFoundingDiscount(price: 500, currency: "PKR"))
    }
}
