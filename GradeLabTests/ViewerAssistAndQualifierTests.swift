import simd
import XCTest
@testable import GradeLab

/// False colour and zebras.
///
/// The property that matters most is negative: an assist must never reach a
/// rendered file. It is enforced structurally — the assist lives in
/// `GradeUniforms.viewerAssist`, which `GradeUniforms.init` always zeroes and
/// only the renderer's preview path fills in — so these tests guard that
/// structure rather than trying to inspect an exported frame.
final class ViewerAssistTests: XCTestCase {
    func testTheGradeNeverCarriesAnAssist() {
        var settings = GradeSettings.neutral
        settings.exposure = 1
        settings.advanced = AdvancedGrade(vignette: 40)
        let uniforms = GradeUniforms(settings: settings, bypass: false)
        XCTAssertEqual(uniforms.viewerAssist, .zero,
                       "Only the preview renderer may switch an assist on")
    }

    func testModesMatchTheShader() {
        XCTAssertEqual(ViewerAssist.off.shaderMode, 0)
        XCTAssertEqual(ViewerAssist.falseColor.shaderMode, 1)
        XCTAssertEqual(ViewerAssist.zebras.shaderMode, 2)
    }

    func testTheThresholdReachesTheShaderAsAFraction() {
        var settings = ViewerAssistSettings()
        settings.mode = .zebras
        settings.zebraThreshold = 90
        XCTAssertEqual(settings.uniform.x, 2)
        XCTAssertEqual(settings.uniform.y, 0.9, accuracy: 0.0001)
    }

    func testOffIsInert() {
        XCTAssertEqual(ViewerAssistSettings().uniform.x, 0)
        XCTAssertFalse(ViewerAssistSettings().isEnabled)
    }

    func testPreferencesSurviveARelaunch() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "viewer-assist-tests"))
        defaults.removePersistentDomain(forName: "viewer-assist-tests")
        var settings = ViewerAssistSettings()
        settings.mode = .falseColor
        settings.zebraThreshold = 72
        settings.save(to: defaults)

        let loaded = ViewerAssistSettings.load(from: defaults)
        XCTAssertEqual(loaded.mode, .falseColor)
        XCTAssertEqual(loaded.zebraThreshold, 72)
        defaults.removePersistentDomain(forName: "viewer-assist-tests")
    }

    /// An out-of-range stored value must not reach the shader.
    func testAStoredThresholdIsClamped() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "viewer-assist-clamp"))
        defaults.removePersistentDomain(forName: "viewer-assist-clamp")
        defaults.set(400.0, forKey: "viewerAssist.zebraThreshold")
        XCTAssertEqual(ViewerAssistSettings.load(from: defaults).zebraThreshold, 100)
        defaults.removePersistentDomain(forName: "viewer-assist-clamp")
    }
}

/// The offset wheel.
final class OffsetWheelTests: XCTestCase {
    func testTheFourthWheelReachesItsOwnUniformSlot() {
        var advanced = AdvancedGrade.neutral
        advanced.wheels[3] = GradingWheel(hue: 180, strength: 50, brightness: -25)
        var settings = GradeSettings.neutral
        settings.advanced = advanced

        let uniforms = GradeUniforms(settings: settings, bypass: false)
        XCTAssertEqual(uniforms.offsetWheel.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(uniforms.offsetWheel.y, 0.5, accuracy: 0.0001)
        XCTAssertEqual(uniforms.offsetWheel.z, -0.25, accuracy: 0.0001)
    }

    func testBypassDropsTheOffset() {
        var advanced = AdvancedGrade.neutral
        advanced.wheels[3] = GradingWheel(hue: 90, strength: 80, brightness: 40)
        var settings = GradeSettings.neutral
        settings.advanced = advanced
        XCTAssertEqual(GradeUniforms(settings: settings, bypass: true).offsetWheel, .zero,
                       "The Original comparison must show no offset")
    }

    /// A project written before the fourth wheel existed has three, and must
    /// decode as three plus a neutral offset rather than failing or shifting.
    func testAThreeWheelProjectDecodesWithANeutralOffset() throws {
        let json = #"{"wheels":[{"hue":10,"strength":20,"brightness":30},"#
            + #"{"hue":0,"strength":0,"brightness":0},"#
            + #"{"hue":0,"strength":0,"brightness":0}],"hsl":[],"curves":[],"#
            + #""vignette":0,"vignetteMidpoint":50,"vignetteFeather":70}"#
        let advanced = try JSONDecoder().decode(AdvancedGrade.self, from: Data(json.utf8))
        XCTAssertEqual(advanced.wheels.count, 3)
        XCTAssertEqual(advanced.wheel(3), GradingWheel(), "The missing fourth wheel must read neutral")
        XCTAssertEqual(advanced.wheel(0).hue, 10, "The wheels it did have must be untouched")

        var settings = GradeSettings.neutral
        settings.advanced = advanced
        XCTAssertEqual(GradeUniforms(settings: settings, bypass: false).offsetWheel, .zero)
    }

    func testNormalizingKeepsFourWheels() {
        var advanced = AdvancedGrade.neutral
        advanced.wheels = [GradingWheel()]
        advanced.normalizeCollections()
        XCTAssertEqual(advanced.wheels.count, 4)
    }

    /// Writing the offset wheel must actually land.
    ///
    /// `editWheel` guarded `0..<3`, so every write to wheel 3 returned without
    /// doing anything: the slider moved, the model never changed, and the
    /// picture never updated.
    func testTheOffsetWheelCanBeWritten() {
        var advanced = AdvancedGrade.neutral
        advanced.editWheel(3) { $0.hue = 210; $0.strength = 60; $0.brightness = -30 }
        XCTAssertEqual(advanced.wheel(3).hue, 210)
        XCTAssertEqual(advanced.wheel(3).strength, 60)
        XCTAssertEqual(advanced.wheel(3).brightness, -30)
    }

    /// The same on a grade decoded with only three wheels, which is every
    /// project saved before the offset existed.
    func testTheOffsetWheelCanBeWrittenOnAThreeWheelGrade() {
        var advanced = AdvancedGrade.neutral
        advanced.wheels = [GradingWheel(), GradingWheel(), GradingWheel()]
        advanced.editWheel(3) { $0.brightness = 40 }
        XCTAssertEqual(advanced.wheels.count, 4, "The array must grow to hold it")
        XCTAssertEqual(advanced.wheel(3).brightness, 40)

        var settings = GradeSettings.neutral
        settings.advanced = advanced
        XCTAssertEqual(GradeUniforms(settings: settings, bypass: false).offsetWheel.z,
                       0.4, accuracy: 0.0001, "and must reach the shader")
    }

    /// A write past the last wheel must still be refused.
    func testThereIsNoFifthWheel() {
        var advanced = AdvancedGrade.neutral
        advanced.editWheel(4) { $0.brightness = 100 }
        XCTAssertEqual(advanced.wheels.count, 4)
    }

    func testTheOffsetWheelIsNamed() {
        XCTAssertEqual(GradingWheel.name(3), "Offset")
    }

    /// A local layer has no offset wheel — there is no word left for one in the
    /// 4096-byte stack — so nothing may offer the control while a mask grade is
    /// being edited. If this goes red, the Offset segment is back and moving it
    /// changes nothing, which is what the user reported the first time.
    func testALocalLayerCarriesNoOffsetWheel() {
        var advanced = AdvancedGrade.neutral
        advanced.wheels[3] = GradingWheel(hue: 200, strength: 90, brightness: 50)
        var grade = GradeSettings.neutral
        grade.advanced = advanced
        let layer = MaskedGradeLayer(name: "Mask", geometry: .default, localGrade: grade)

        let uniforms = LocalGradeUniforms(layer: layer, curveRow: 0, pointOffset: 0)
        XCTAssertEqual(uniforms.words.count, LocalGradeUniforms.wordCount)
        // Every word the layer does carry must be unaffected by wheel 3 having
        // been set, which is what proves it reaches the GPU nowhere.
        var withoutOffset = advanced
        withoutOffset.wheels[3] = GradingWheel()
        var bare = GradeSettings.neutral
        bare.advanced = withoutOffset
        let neutralLayer = MaskedGradeLayer(name: "Mask", geometry: .default, localGrade: bare)
        let neutralUniforms = LocalGradeUniforms(layer: neutralLayer, curveRow: 0, pointOffset: 0)
        XCTAssertEqual(uniforms.words, neutralUniforms.words,
                       "Setting a local layer's fourth wheel must change nothing it sends")
    }
}

/// The colour qualifier.
final class ColorQualifierTests: XCTestCase {
    func testADisabledQualifierIsInert() {
        let layer = MaskedGradeLayer(name: "Mask", geometry: .default)
        let uniforms = LocalGradeUniforms(layer: layer, curveRow: 0, pointOffset: 0)
        XCTAssertEqual(uniforms.qualifier, .zero)
        XCTAssertEqual(uniforms.options.y, 0, "Flags of zero tells the shader not to key")
        XCTAssertEqual(uniforms.options.x, 0, "Softness")
        XCTAssertEqual(uniforms.lightB.z, 0, "Luma min")
        XCTAssertEqual(uniforms.lightB.w, 0, "Luma max")
    }

    func testFlagsPackAsTheShaderReadsThem() {
        var key = ColorQualifier.skin
        key.isEnabled = true
        key.isInverted = true
        key.ignoresShape = true
        let layer = MaskedGradeLayer(name: "Mask", geometry: .default, qualifier: key)
        let uniforms = LocalGradeUniforms(layer: layer, curveRow: 0, pointOffset: 0)
        XCTAssertEqual(uniforms.options.y, 7, "1 enabled + 2 inverted + 4 whole frame")
    }

    func testHueReachesTheShaderAsATurn() {
        var key = ColorQualifier.skin
        key.isEnabled = true
        key.hueCenter = 180
        key.hueRange = 36
        let layer = MaskedGradeLayer(name: "Mask", geometry: .default, qualifier: key)
        let uniforms = LocalGradeUniforms(layer: layer, curveRow: 0, pointOffset: 0)
        XCTAssertEqual(uniforms.qualifier.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(uniforms.qualifier.y, 0.1, accuracy: 0.0001)
    }

    /// A reversed range would select nothing, which reads as a broken control.
    func testReversedRangesAreOrderedRatherThanEmptied() {
        var key = ColorQualifier.skin
        key.saturationMin = 0.8
        key.saturationMax = 0.2
        key.lumaMin = 0.9
        key.lumaMax = 0.1
        let clamped = key.clamped
        XCTAssertEqual(clamped.saturationMin, 0.2, accuracy: 0.0001)
        XCTAssertEqual(clamped.saturationMax, 0.8, accuracy: 0.0001)
        XCTAssertEqual(clamped.lumaMin, 0.1, accuracy: 0.0001)
        XCTAssertEqual(clamped.lumaMax, 0.9, accuracy: 0.0001)
    }

    func testANegativeHueWrapsOntoTheCircle() {
        var key = ColorQualifier.skin
        key.hueCenter = -30
        XCTAssertEqual(key.clamped.hueCenter, 330, accuracy: 0.0001)
    }

    /// The reading a picked colour is measured with must match the shader's
    /// `rgbToHSL`, or picking a colour would key on a slightly different one.
    func testPickedComponentsMatchTheShaderReading() {
        let red = ColorQualifier.components(of: SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(red.hue, 0, accuracy: 0.001)
        XCTAssertEqual(red.saturation, 1, accuracy: 0.001)
        XCTAssertEqual(red.luma, 0.5, accuracy: 0.001)

        let cyan = ColorQualifier.components(of: SIMD3<Float>(0, 1, 1))
        XCTAssertEqual(cyan.hue, 180, accuracy: 0.001)

        let grey = ColorQualifier.components(of: SIMD3<Float>(repeating: 0.5))
        XCTAssertEqual(grey.saturation, 0, accuracy: 0.001,
                       "A neutral pixel must report no saturation so the picker can refuse it")
    }

    func testPickingCentresTheKeyWithoutDiscardingItsWidths() {
        var key = ColorQualifier.skin
        key.hueRange = 12
        key.center(on: 200, saturation: 0.5, luma: 0.4)
        XCTAssertTrue(key.isEnabled)
        XCTAssertEqual(key.hueCenter, 200, accuracy: 0.001)
        XCTAssertEqual(key.hueRange, 12, accuracy: 0.001, "A pick re-aims the key, it does not retune it")
        XCTAssertLessThan(key.saturationMin, 0.5)
        XCTAssertGreaterThan(key.saturationMax, 0.5)
        XCTAssertLessThan(key.lumaMin, 0.4)
        XCTAssertGreaterThan(key.lumaMax, 0.4)
    }

    /// A mask authored before qualifiers existed must decode as the purely
    /// geometric mask it was, and render identically.
    func testAMaskSavedBeforeQualifiersDecodesWithoutOne() throws {
        let json = #"{"id":"2C7F1F52-6E49-4C3E-9B8E-3F4C1D2A5B60","name":"Mask","#
            + #""isEnabled":true,"strength":1,"createdAt":0}"#
        let layer = try JSONDecoder().decode(MaskedGradeLayer.self, from: Data(json.utf8))
        XCTAssertNil(layer.qualifier)
        let uniforms = LocalGradeUniforms(layer: layer, curveRow: 0, pointOffset: 0)
        XCTAssertEqual(uniforms.options.y, 0, "No qualifier must mean no keying")
    }

    /// The key shares two words with the light controls and the curve indices.
    /// Those must keep their own values.
    func testPackingDoesNotDisturbTheValuesItSharesAWordWith() {
        var key = ColorQualifier.skin
        key.isEnabled = true
        key.lumaMin = 0.2
        key.lumaMax = 0.8
        key.softness = 0.5
        var grade = GradeSettings.neutral
        grade.whites = 40
        grade.blacks = -20
        let layer = MaskedGradeLayer(name: "Mask", geometry: .default,
                                     localGrade: grade, qualifier: key)
        let uniforms = LocalGradeUniforms(layer: layer, curveRow: 7, pointOffset: 0)

        XCTAssertEqual(uniforms.lightB.x, 0.4, accuracy: 0.0001, "Whites")
        XCTAssertEqual(uniforms.lightB.y, -0.2, accuracy: 0.0001, "Blacks")
        XCTAssertEqual(uniforms.lightB.z, 0.2, accuracy: 0.0001, "Luma min")
        XCTAssertEqual(uniforms.lightB.w, 0.8, accuracy: 0.0001, "Luma max")
        XCTAssertEqual(uniforms.options.x, 0.5, accuracy: 0.0001, "Softness")
        XCTAssertEqual(uniforms.options.w, 7, "The curve row must survive the packing")
    }

    func testAQualifierSurvivesASaveAndReload() throws {
        var key = ColorQualifier.skin
        key.isEnabled = true
        key.hueCenter = 210
        key.softness = 0.6
        let layer = MaskedGradeLayer(name: "Sky", geometry: .default, qualifier: key)
        let data = try JSONEncoder().encode(layer)
        let restored = try JSONDecoder().decode(MaskedGradeLayer.self, from: data)
        XCTAssertEqual(restored.qualifier?.hueCenter, 210)
        XCTAssertEqual(restored.qualifier?.softness, 0.6)
        XCTAssertEqual(restored.qualifier?.isEnabled, true)
    }
}


/// The Swift and Metal sides of the masked-grade stack.
///
/// Written after shipping a crash: three fields were added to
/// `LocalGradeUniforms` while `wordCount` stayed the literal 18, so every Swift
/// stack was 384 bytes shorter than the shader's struct. Nothing caught it until
/// a dispatch, where Metal aborted inside whichever kernel bound the stack
/// first — for the editor, `scopeSampleYUV` the moment Open Editor was pressed.
///
/// Reflection is what makes this checkable without running a frame: the compiled
/// kernel reports the size it expects for each buffer, so the two sides can be
/// compared directly.
final class LocalGradeStackLayoutTests: XCTestCase {
    /// The whole stack travels as ONE `setBytes`, which Metal caps at 4096
    /// bytes. Going over is not a slow path or a warning — the encoder aborts,
    /// which is how a 4240-byte stack took the editor down on launch.
    ///
    /// This is the budget that bounds `MaskedGradeLayer.maximumPerClip`, so a
    /// new per-layer field is spent against it. If this fails, the choice is a
    /// spare slot in an existing word, fewer layers, or moving the stack off
    /// `setBytes` and into a real buffer.
    func testTheStackFitsOneSetBytes() {
        XCTAssertLessThanOrEqual(
            LocalGradeStack.empty.byteCount, 4096,
            "The stack is \(LocalGradeStack.empty.byteCount) bytes; setBytes aborts above 4096"
        )
    }

    /// A full stack is the same size as an empty one — the block is fixed and
    /// zero-padded — so the budget cannot be blown by what a project contains.
    func testAFullStackIsTheSameSize() {
        let layers = (0..<MaskedGradeLayer.maximumPerClip).map { index in
            MaskedGradeLayer(name: "Mask \(index)", geometry: .default,
                             qualifier: ColorQualifier.skin)
        }
        let full = LocalGradeStack(layers: layers, aspect: 1.78)
        XCTAssertEqual(full.byteCount, LocalGradeStack.empty.byteCount)
        XCTAssertLessThanOrEqual(full.byteCount, 4096)
    }

    /// Encodes the bind that aborted on device.
    ///
    /// Exercises the path, and is NOT the guard — measured: with the stack
    /// deliberately grown to 4368 bytes this still passed. The 4096-byte abort
    /// comes from Metal's validation layer, which the test run does not enable,
    /// so an oversized `setBytes` goes through here and only fails in a real
    /// debug build. `testTheStackFitsOneSetBytes` above is what actually holds
    /// the line; this only proves the binding is otherwise well formed.
    func testTheStackActuallyEncodes() throws {
        let context = try MetalContext()
        let function = try XCTUnwrap(context.library.makeFunction(name: "scopeSampleYUV"))
        let pipeline = try context.device.makeComputePipelineState(function: function)
        let queue = try XCTUnwrap(context.device.makeCommandQueue())
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(buffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)

        let layers = (0..<MaskedGradeLayer.maximumPerClip).map { index in
            MaskedGradeLayer(name: "Mask \(index)", geometry: .default,
                             qualifier: ColorQualifier.skin)
        }
        LocalGradeStack(layers: layers, aspect: 1.78).bind(encoder)
        encoder.endEncoding()
    }

    func testWordCountFollowsTheFields() {
        let uniforms = LocalGradeUniforms(
            layer: MaskedGradeLayer(name: "", geometry: .default),
            curveRow: 0, pointOffset: 0
        )
        XCTAssertEqual(LocalGradeUniforms.wordCount, uniforms.words.count,
                       "wordCount must be derived from the fields, never written as a literal")
    }

    /// Every compute kernel that takes the stack must expect exactly the number
    /// of bytes Swift sends.
    func testEveryKernelAgreesWithTheStackSize() throws {
        let context = try MetalContext()
        let expected = LocalGradeStack.empty.byteCount
        let stackIndices = [LocalGradeStack.bufferIndex, LocalGradeStack.incomingBufferIndex]
        var checked: [String] = []

        for name in context.library.functionNames {
            guard let function = context.library.makeFunction(name: name),
                  function.functionType == .kernel,
                  // A function with constants must be specialised before it can
                  // build a pipeline, and asking anyway ABORTS rather than
                  // returning an error, so these are skipped rather than caught.
                  function.functionConstantsDictionary.isEmpty else { continue }
            var reflection: MTLComputePipelineReflection?
            guard (try? context.device.makeComputePipelineState(
                function: function, options: [.bindingInfo], reflection: &reflection)) != nil,
                  let bindings = reflection?.bindings else { continue }

            for binding in bindings where binding.type == .buffer && stackIndices.contains(binding.index) {
                guard let buffer = binding as? MTLBufferBinding,
                      // Other things live at these indices in kernels that take
                      // no stack; only a struct of the stack's shape is ours.
                      buffer.bufferDataSize == expected || buffer.bufferDataSize > 3_000
                else { continue }
                XCTAssertEqual(
                    buffer.bufferDataSize, expected,
                    "\(name) expects \(buffer.bufferDataSize) bytes for the local grade stack "
                    + "but Swift sends \(expected) — a field was added to one side only"
                )
                checked.append(name)
            }
        }

        XCTAssertFalse(checked.isEmpty, "No kernel was checked; the reflection query found nothing")
        XCTAssertTrue(checked.contains("scopeSampleYUV"),
                      "The kernel that actually crashed must be among those checked")
    }
}
