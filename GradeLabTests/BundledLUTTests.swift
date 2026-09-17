import simd
import XCTest
@testable import GradeLab

/// Verifies the generated `.cube` files against the app's real `CubeLUTParser`,
/// so the generator in `Tools/LUTGenerator` can never drift from what the app
/// will actually accept.
final class BundledLUTTests: XCTestCase {
    private static let expectedSize = 33
    private static var expectedCount: Int { expectedSize * expectedSize * expectedSize }

    /// Resolved from the test source location so the check does not depend on
    /// how the resources happen to be bundled.
    private func lutURL(_ asset: LUTAsset) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LUTSources")
            .appendingPathComponent(asset.filename)
    }

    func testEveryBundledLookParsesAndIsInRange() throws {
        for asset in LUTAsset.bundledCreativeLooks {
            let cube = try CubeLUTParser().parse(contentsOf: lutURL(asset))

            XCTAssertEqual(cube.title, asset.name, "\(asset.filename) title")
            XCTAssertEqual(cube.kind, .threeDimensional(size: Self.expectedSize), "\(asset.filename) size")
            XCTAssertEqual(cube.domainMinimum, SIMD3<Float>(repeating: 0), "\(asset.filename) domain min")
            XCTAssertEqual(cube.domainMaximum, SIMD3<Float>(repeating: 1), "\(asset.filename) domain max")
            XCTAssertEqual(cube.values.count, Self.expectedCount, "\(asset.filename) entry count")

            for (index, value) in cube.values.enumerated() {
                for channel in [value.x, value.y, value.z] {
                    XCTAssertTrue(channel.isFinite, "\(asset.filename) entry \(index) is not finite")
                    XCTAssertTrue(
                        channel >= 0 && channel <= 1,
                        "\(asset.filename) entry \(index) is out of range: \(channel)"
                    )
                }
            }
        }
    }

    /// Black and white must survive untouched so the LUT cannot clip the
    /// endpoints of otherwise well-exposed footage. With red-fastest ordering,
    /// black is the first entry and white is the last.
    func testEndpointsArePreserved() throws {
        for asset in LUTAsset.bundledCreativeLooks where asset.name != "Soft Film" {
            let cube = try CubeLUTParser().parse(contentsOf: lutURL(asset))
            XCTAssertEqual(cube.values.first!, SIMD3<Float>(repeating: 0), "\(asset.filename) black")
            XCTAssertEqual(cube.values.last!, SIMD3<Float>(repeating: 1), "\(asset.filename) white")
        }

        // Soft Film intentionally lifts the deepest blacks; white still holds.
        let softFilm = try CubeLUTParser().parse(
            contentsOf: lutURL(LUTAsset.bundledCreativeLooks[2])
        )
        XCTAssertEqual(softFilm.values.last!, SIMD3<Float>(repeating: 1))
        let liftedBlack = softFilm.values.first!
        XCTAssertGreaterThan(liftedBlack.x, 0.01)
        XCTAssertLessThan(liftedBlack.x, 0.08)
    }

    /// Guards against banding: no neighbouring pair of samples along any axis
    /// may jump more than a few input steps' worth of output.
    func testTransformsAreContinuous() throws {
        let size = Self.expectedSize
        let limit: Float = 4 / Float(size - 1)

        for asset in LUTAsset.bundledCreativeLooks {
            let values = try CubeLUTParser().parse(contentsOf: lutURL(asset)).values
            func sample(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> {
                values[r + g * size + b * size * size]
            }
            for b in 0..<size {
                for g in 0..<size {
                    for r in 0..<size {
                        let here = sample(r, g, b)
                        var neighbours: [SIMD3<Float>] = []
                        if r + 1 < size { neighbours.append(sample(r + 1, g, b)) }
                        if g + 1 < size { neighbours.append(sample(r, g + 1, b)) }
                        if b + 1 < size { neighbours.append(sample(r, g, b + 1)) }
                        for neighbour in neighbours {
                            let delta = abs(neighbour - here).max()
                            XCTAssertLessThanOrEqual(
                                delta, limit,
                                "\(asset.filename) jumps \(delta) at (\(r),\(g),\(b))"
                            )
                        }
                    }
                }
            }
        }
    }

    func testBundledLooksAreCreativeAndSDR() {
        for asset in LUTAsset.bundledCreativeLooks {
            XCTAssertEqual(asset.kind, .creative)
            XCTAssertEqual(asset.inputColorSpace, "Rec.709 / working SDR")
        }
    }
}

/// The stored side of the look stage: selection, strength, and staying
/// compatible with projects saved before looks existed.
final class LookSettingsTests: XCTestCase {
    func testNoLookMeansNoStrength() {
        XCTAssertEqual(AdvancedGrade.neutral.lutStrength, 0)
        var advanced = AdvancedGrade.neutral
        advanced.lutIntensity = 100
        XCTAssertEqual(advanced.lutStrength, 0, "Strength without a look must stay off")
    }

    func testSelectedLookDefaultsToFullStrengthAndClamps() {
        var advanced = AdvancedGrade.neutral
        advanced.lut = LUTAsset.bundledCreativeLooks[0].id
        XCTAssertEqual(advanced.lutStrength, 100)
        advanced.lutIntensity = 55
        XCTAssertEqual(advanced.lutStrength, 55)
        advanced.lutIntensity = 400
        XCTAssertEqual(advanced.lutStrength, 100)
        advanced.lutIntensity = -20
        XCTAssertEqual(advanced.lutStrength, 0)
    }

    func testUniformsCarryStrengthWithoutChangingLayout() {
        // 352 since finishing effects added two SIMD4s. The number is the point:
        // Swift and Metal declare this struct separately, and a field added to
        // one and not the other reads uniforms off by that many bytes, which
        // shows up as a grade that is subtly wrong rather than as a crash.
        XCTAssertEqual(MemoryLayout<GradeUniforms>.stride, 352, "Uniform layout must not drift from the shader")
        var settings = GradeSettings.neutral
        var advanced = AdvancedGrade.neutral
        advanced.lut = LUTAsset.bundledCreativeLooks[1].id
        advanced.lutIntensity = 50
        settings.advanced = advanced
        XCTAssertEqual(GradeUniforms(settings: settings, bypass: false).options.y, 0.5, accuracy: 0.0001)
        XCTAssertEqual(GradeUniforms(settings: .neutral, bypass: false).options.y, 0)
    }

    func testProjectsSavedBeforeLooksStillDecode() throws {
        let legacy = """
        {"exposure":0,"contrast":0,"highlights":0,"shadows":0,"whites":0,"blacks":0,
        "temperature":0,"tint":0,"saturation":0,"vibrance":0,
        "advanced":{"curves":[],"hsl":[],"wheels":[],"vignette":0,"vignetteMidpoint":50,"vignetteFeather":70}}
        """
        let settings = try JSONDecoder().decode(GradeSettings.self, from: Data(legacy.utf8))
        XCTAssertNil(settings.advanced?.lut)
        XCTAssertEqual(settings.advanced?.lutStrength, 0)
    }

    func testALookSurvivesASaveAndReload() throws {
        var settings = GradeSettings.neutral
        var advanced = AdvancedGrade.neutral
        advanced.lut = LUTAsset.bundledCreativeLooks[2].id
        advanced.lutIntensity = 70
        settings.advanced = advanced
        let decoded = try JSONDecoder().decode(GradeSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.advanced?.lutStrength, 70)
    }

    /// Every bundled look must resolve to a file inside the built app bundle,
    /// otherwise the picker would offer a look that silently does nothing.
    ///
    /// Compiled form specifically: shipping the `.cube` instead would still
    /// work and so would pass a weaker check, while quietly putting the 73 MB
    /// of text back into the download.
    func testBundledLooksResolveInsideTheAppBundle() throws {
        for asset in LUTAsset.bundledCreativeLooks {
            let url = try XCTUnwrap(asset.url(), "\(asset.filename) is missing from the app bundle")
            XCTAssertEqual(
                url.pathExtension, LUTBinary.fileExtension,
                "\(asset.filename) shipped uncompiled"
            )
            XCTAssertNoThrow(try LUTBinary.decode(contentsOf: url), "\(asset.filename) does not decode")
        }
    }

    /// Discovery is the whole contract for `Resources/LUTs/Imported`: drop a
    /// `.cube` in, rebuild, and it shows up. If this breaks, imported looks
    /// silently stop appearing in the picker.
    func testEveryBundledCubeIsOfferedAsALook() {
        let bundle = Bundle.lutResources
        // Looks ship compiled, as `<name>.cube.gclut`. Removing that suffix
        // recovers the `.cube` filename that is the look's identity and that
        // every project using it has saved.
        let onDisk = Set(
            ((bundle.resourceURL.flatMap {
                try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
            }) ?? [])
                .map(\.lastPathComponent)
                .filter { $0.hasSuffix(".\(LUTBinary.fileExtension)") }
                .map { String($0.dropLast(LUTBinary.fileExtension.count + 1)) }
        )
        let offered = Set(LUTAsset.bundledLooks.map(\.filename))
        XCTAssertFalse(onDisk.isEmpty, "No compiled looks were bundled")
        XCTAssertEqual(onDisk, offered, "Bundled looks and offered looks disagree")

        // A technical transform must never reach the creative list. Nothing on
        // the exclusion list ships any more — `Apple_Log_1` is a 1D curve the
        // look stage cannot apply at all, so the compiler refuses it and it is
        // no longer weight in the bundle — but the guard stays, because the
        // looks folder is a drop-in and one could be added again tomorrow.
        XCTAssertTrue(
            offered.allSatisfy {
                !LUTAsset.technicalTransformResourceNames.contains(($0 as NSString).deletingPathExtension)
            },
            "A technical transform appeared in the creative look list"
        )
        XCTAssertTrue(
            onDisk.allSatisfy {
                !LUTAsset.technicalTransformResourceNames.contains(($0 as NSString).deletingPathExtension)
            },
            "A LUT the app cannot apply is still being shipped"
        )

        for asset in LUTAsset.bundledLooks {
            XCTAssertNotNil(asset.url(), "\(asset.filename) does not resolve")
        }
        XCTAssertEqual(
            Array(LUTAsset.bundledLooks.prefix(3)).map(\.name),
            LUTAsset.bundledCreativeLooks.map(\.name),
            "Built-in looks come first in the picker"
        )
    }

    func testImportedLookNamesComeFromTheFilename() {
        for asset in LUTAsset.bundledLooks where !asset.isBuiltIn {
            XCTAssertFalse(asset.name.contains("_"), "\(asset.filename) name still has underscores")
            XCTAssertFalse(asset.name.hasSuffix(".cube"), "\(asset.filename) name kept its extension")
            XCTAssertEqual(asset.category, "Imported")
        }
    }

    func testTheEditorOffersALookTool() {
        XCTAssertTrue(EditorViewModel.Panel.allCases.contains(.lut))
        XCTAssertEqual(EditorViewModel.Panel.lut.rawValue, "Look")
    }
}


/// The runtime importer: what it accepts, what it refuses, and whether an
/// imported look survives well enough to be applied and then removed.
final class LookImportTests: XCTestCase {
    private var imported: [LUTAsset] = []

    override func tearDown() {
        for asset in imported { try? LUTStore.remove(asset) }
        imported = []
        super.tearDown()
    }

    private func write(_ text: String, named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A tiny but genuinely valid 2×2×2 look: identity with the blue channel
    /// pulled down, so it is distinguishable from a pass-through.
    private func makeCube(size: Int = 2, domainMax: String = "1.0 1.0 1.0", title: String = "Test") -> String {
        var lines = ["TITLE \"\(title)\"", "LUT_3D_SIZE \(size)", "DOMAIN_MIN 0.0 0.0 0.0", "DOMAIN_MAX \(domainMax)"]
        let last = Float(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    lines.append(String(
                        format: "%.6f %.6f %.6f",
                        Float(r) / last, Float(g) / last, Float(b) / last * 0.8
                    ))
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    func testImportingAValidCubeMakesItSelectable() throws {
        let source = try write(makeCube(), named: "My_Look.cube")
        let asset = try LUTStore.importLook(from: source)
        imported.append(asset)

        XCTAssertEqual(asset.name, "My Look", "Underscores read as spaces")
        XCTAssertEqual(asset.origin, .device)
        XCTAssertNotNil(asset.url(), "An imported look must resolve to a file")
        XCTAssertTrue(
            LUTAsset.allLooks.contains { $0.id == asset.id },
            "An imported look must appear alongside the bundled ones"
        )
        XCTAssertFalse(
            LUTAsset.bundledLooks.contains { $0.id == asset.id },
            "An imported look is not a bundled one"
        )

        // It must parse back through the real parser exactly as stored.
        let cube = try CubeLUTParser().parse(contentsOf: asset.url()!)
        XCTAssertEqual(cube.kind, .threeDimensional(size: 2))
        XCTAssertEqual(cube.values.last!, SIMD3<Float>(1, 1, 0.8))
    }

    func testRemovingAnImportedLookDeletesIt() throws {
        let asset = try LUTStore.importLook(from: try write(makeCube(), named: "Temporary.cube"))
        XCTAssertNotNil(asset.url())
        try LUTStore.remove(asset)
        XCTAssertNil(asset.url(), "The file must be gone")
        XCTAssertFalse(LUTAsset.allLooks.contains { $0.id == asset.id })
    }

    func testBuiltInLooksCannotBeRemoved() throws {
        let builtIn = LUTAsset.bundledCreativeLooks[0]
        try LUTStore.remove(builtIn)
        XCTAssertNotNil(builtIn.url(), "Removing a built-in look must do nothing")
    }

    func testNameCollisionsGetTheirOwnFile() throws {
        let first = try LUTStore.importLook(from: try write(makeCube(), named: "Same.cube"))
        imported.append(first)
        let second = try LUTStore.importLook(from: try write(makeCube(), named: "Same.cube"))
        imported.append(second)

        XCTAssertNotEqual(first.id, second.id, "A second import must not overwrite the first")
        XCTAssertNotNil(first.url())
        XCTAssertNotNil(second.url())
    }

    func testAnImportCannotShadowABuiltInLook() throws {
        let asset = try LUTStore.importLook(from: try write(makeCube(), named: "Warm_Cinema.cube"))
        imported.append(asset)
        XCTAssertNotEqual(asset.id, "Warm_Cinema.cube", "An import must not claim a built-in identifier")
        XCTAssertEqual(
            LUTAsset.allLooks.filter { $0.id == "Warm_Cinema.cube" }.count, 1,
            "Exactly one look owns each identifier"
        )
    }

    func testAOneDimensionalLUTIsRefused() throws {
        let source = try write("LUT_1D_SIZE 2\n0 0 0\n1 1 1", named: "OneD.cube")
        XCTAssertThrowsError(try LUTStore.importLook(from: source)) { error in
            XCTAssertTrue("\(error)".contains("1D"), "The reason must name the actual problem: \(error)")
        }
    }

    /// The case that would otherwise render from the wrong place in the cube.
    func testALogStyleDomainIsRefused() throws {
        let source = try write(makeCube(domainMax: "4.0 4.0 4.0"), named: "LogLike.cube")
        XCTAssertThrowsError(try LUTStore.importLook(from: source)) { error in
            XCTAssertTrue("\(error)".contains("domain"), "The reason must mention the domain: \(error)")
        }
    }

    func testNonCubeFilesAreRefused() throws {
        let source = try write("not a lut", named: "Notes.txt")
        XCTAssertThrowsError(try LUTStore.importLook(from: source))
    }

    func testAMalformedCubeIsRefusedAndNotStored() throws {
        let source = try write("LUT_3D_SIZE 2\n0 0 0\n1 1 1", named: "Broken.cube")
        XCTAssertThrowsError(try LUTStore.importLook(from: source))
        XCTAssertFalse(
            LUTAsset.allLooks.contains { $0.name == "Broken" },
            "A refused file must never reach the picker"
        )
    }
}

/// The look strip's thumbnails have to be honest: they are rendered with the
/// same shader kernel the preview and export use, so a tile must actually match
/// what applying that look does. A decorative swatch would mislead the choice.
final class LookPreviewTests: XCTestCase {
    /// Reads a look from whichever form actually shipped, the way `LUTLibrary`
    /// does, so the comparison is against the bytes on the device rather than
    /// against a source file the app never opens.
    static func storedValues(of asset: LUTAsset) throws -> (size: Int, values: [SIMD3<Float>]) {
        let url = try XCTUnwrap(asset.url(), "\(asset.filename) does not resolve")
        if url.pathExtension.lowercased() == LUTBinary.fileExtension {
            let compiled = try LUTBinary.decode(contentsOf: url)
            let values = (0..<(compiled.samples.count / 3)).map { index in
                SIMD3<Float>(
                    Float(compiled.samples[index * 3]) / Float(UInt16.max),
                    Float(compiled.samples[index * 3 + 1]) / Float(UInt16.max),
                    Float(compiled.samples[index * 3 + 2]) / Float(UInt16.max)
                )
            }
            return (compiled.size, values)
        }
        let cube = try CubeLUTParser().parse(contentsOf: url)
        guard case .threeDimensional(let size) = cube.kind else {
            throw GradeLabError.invalidLUT("\(asset.filename) is not a 3D LUT")
        }
        return (size, cube.values)
    }

    private func makeSolidImage(_ value: UInt8, size: Int = 16) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { context in
            let channel = CGFloat(value) / 255
            context.cgContext.setFillColor(
                UIColor(red: channel, green: channel, blue: channel, alpha: 1).cgColor
            )
            context.cgContext.fill(CGRect(x: 0, y: 0, width: size, height: size))
        }
    }

    private func centerPixel(_ image: UIImage) throws -> SIMD3<Float> {
        let cgImage = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(
            cgImage,
            in: CGRect(x: -cgImage.width / 2, y: -cgImage.height / 2,
                       width: cgImage.width, height: cgImage.height)
        )
        return SIMD3(Float(bytes[0]) / 255, Float(bytes[1]) / 255, Float(bytes[2]) / 255)
    }

    func testAPreviewTileMatchesWhatTheLookActuallyDoes() throws {
        let context = try MetalContext()
        let renderer = try LookPreviewRenderer(context: context)
        // 128/255 lands on grid point 16 of a 33-point cube, so the expected
        // value is a stored entry rather than an interpolation.
        let source = try XCTUnwrap(renderer.makeSourceTexture(from: makeSolidImage(128)))

        for asset in LUTAsset.bundledCreativeLooks {
            let (size, values) = try Self.storedValues(of: asset)
            let grid = Int((128.0 / 255.0 * Double(size - 1)).rounded())
            let expected = values[grid + grid * size + grid * size * size]

            let tile = try XCTUnwrap(renderer.render(look: asset, source: source), asset.name)
            let actual = try centerPixel(tile)

            for channel in 0..<3 {
                XCTAssertEqual(
                    actual[channel], expected[channel], accuracy: 0.02,
                    "\(asset.name) preview channel \(channel) does not match the LUT"
                )
            }
        }
    }

    func testTheNoneTileIsTheUntouchedFrame() throws {
        let context = try MetalContext()
        let renderer = try LookPreviewRenderer(context: context)
        let source = try XCTUnwrap(renderer.makeSourceTexture(from: makeSolidImage(90)))
        let tile = try XCTUnwrap(renderer.render(look: nil, source: source))
        let actual = try centerPixel(tile)
        for channel in 0..<3 {
            XCTAssertEqual(actual[channel], 90.0 / 255.0, accuracy: 0.01)
        }
    }

    func testDifferentLooksProduceDifferentTiles() throws {
        let context = try MetalContext()
        let renderer = try LookPreviewRenderer(context: context)
        let source = try XCTUnwrap(renderer.makeSourceTexture(from: makeSolidImage(140)))
        let pixels = try LUTAsset.bundledCreativeLooks.map {
            try centerPixel(try XCTUnwrap(renderer.render(look: $0, source: source)))
        }
        for first in 0..<pixels.count {
            for second in (first + 1)..<pixels.count {
                let delta = abs(pixels[first] - pixels[second]).max()
                XCTAssertGreaterThan(delta, 0.004, "Two looks render an identical tile")
            }
        }
    }

    func testTheSourceTextureIsScaledDownForThumbnails() throws {
        let context = try MetalContext()
        let renderer = try LookPreviewRenderer(context: context)
        let large = UIGraphicsImageRenderer(size: CGSize(width: 1920, height: 1080)).image { context in
            context.cgContext.setFillColor(UIColor.gray.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 1920, height: 1080))
        }
        let texture = try XCTUnwrap(renderer.makeSourceTexture(from: large, maximumEdge: 240))
        XCTAssertEqual(texture.width, 240)
        XCTAssertEqual(texture.height, 135, "Aspect ratio must be preserved")
    }

    /// The fallback used when a frame cannot be read from the clip.
    func testTheReferenceImageIsDrawn() {
        let image = LookReferenceImage.make()
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
        XCTAssertNotNil(image.cgImage)
    }
}
