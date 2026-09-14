import AVFoundation
import VideoToolbox
import XCTest
@testable import GradeLab

/// End-to-end checks against a real tagged 10-bit HLG file rather than a
/// synthesised `VideoMetadata`.
///
/// `GradeLabTests/hlg_test.mov` is BT.2020 / HLG / BT.2020-matrix, HEVC Main 10,
/// video range, with known 10-bit code values per band. It exists because a
/// hand-built metadata fixture cannot catch the class of bug these tests cover:
/// a stage that reads the file itself and refuses it.
final class HLGSourceIntegrationTests: XCTestCase {
    private var hlgURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("hlg_test.mov")
    }

    private func readMetadata() async throws -> VideoAsset {
        try await VideoMetadataReader().read(from: hlgURL)
    }

    func testTheFixtureIsPresentAndTagged() async throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: hlgURL.path), "HLG fixture missing")
        let asset = try await readMetadata()
        XCTAssertEqual(asset.metadata.transferFunction, "HLG")
        XCTAssertEqual(asset.metadata.colorPrimaries, "BT.2020")
        XCTAssertEqual(asset.metadata.yCbCrMatrix, "BT.2020")
        XCTAssertEqual(asset.metadata.bitDepth, 10)
        XCTAssertEqual(asset.metadata.isHDR, true)
        XCTAssertNil(asset.metadata.logTransferFunction, "HLG is not a log format")
    }

    func testTheEditorAndGradingAcceptTheSource() async throws {
        let support = ColorPipelineSupport(metadata: try await readMetadata().metadata)
        XCTAssertEqual(support, .hdrSupported(transfer: "HLG"))
        XCTAssertTrue(support.allowsEditor)
        XCTAssertTrue(support.allowsGrading, "HLG grading is enabled")
    }

    /// Regression: the preview inspection path used `allowsGrading` as a proxy
    /// for "can this be opened", so building a preview composition for an HLG
    /// source threw "This video format is not supported" and the editor showed a
    /// black frame. Opening and grading are separate capabilities.
    func testPreviewInspectionAcceptsHLG() async throws {
        let asset = try await readMetadata()
        _ = try await ExportSourceInspector.inspect(asset, requireExportColorTags: false)
    }

    /// Export now accepts HLG and resolves it to an HDR project, which is what
    /// routes it to the Main 10 encoder rather than the 8-bit Rec.709 one.
    func testExportInspectionAcceptsHLGAsHDR() async throws {
        let asset = try await readMetadata()
        let source = try await ExportSourceInspector.inspect(asset, requireExportColorTags: true)
        XCTAssertTrue(source.colorMode.isHDR, "HLG must export as HDR, not be flattened to SDR")
    }

    /// Strictness is unchanged for everything without a validated path. A PQ
    /// source must still be refused, and the reason must name PQ rather than
    /// blaming the bit depth.
    func testExportInspectionStillRefusesNonHLGHDR() async throws {
        let asset = try await readMetadata()
        let pretendPQ = VideoAsset(
            id: asset.id,
            url: asset.url,
            metadata: makeVideoMetadata(
                colorPrimaries: "BT.2020", transferFunction: "PQ", isHDR: true, bitDepth: 10
            ),
            sourceRange: asset.sourceRange,
            frameDuration: asset.frameDuration
        )
        do {
            _ = try await ExportSourceInspector.inspect(pretendPQ, requireExportColorTags: true)
            XCTFail("PQ export must stay refused")
        } catch {
            XCTAssertTrue("\(error)".contains("PQ"), "the reason must name PQ: \(error)")
        }
    }

    func testAProjectForThisSourceIsHDRAndSurvivesReload() async throws {
        let asset = try await readMetadata()
        let project = VideoProject(sourceURL: asset.url, displayName: "hlg", metadata: asset.metadata)
        XCTAssertEqual(project.colorMode, .hdrHLG)
        let reloaded = try JSONDecoder().decode(
            VideoProject.self, from: try JSONEncoder().encode(project)
        )
        XCTAssertEqual(reloaded.colorMode, .hdrHLG)
    }

    /// The decoder must hand back extended-range half-float, not 8-bit. If this
    /// regresses, precision is lost before Metal ever sees a frame - which is
    /// exactly what the original pipeline did.
    func testHDROutputSettingsDecodeToExtendedRangeHalfFloat() async throws {
        let settings = VideoPlaybackController.outputSettings(for: .hdrHLG)
        XCTAssertEqual(
            settings[kCVPixelBufferPixelFormatTypeKey as String] as? OSType,
            kCVPixelFormatType_64RGBAHalf
        )
        let colorProperties = try XCTUnwrap(settings[AVVideoColorPropertiesKey] as? [String: Any])
        // Asking for HLG - not linear - is what makes AVFoundation convert every
        // source into a correctly referenced HLG signal, mapping an SDR white
        // onto BT.2408 reference white. That is the mixed-timeline policy.
        XCTAssertEqual(
            colorProperties[AVVideoTransferFunctionKey] as? String,
            AVVideoTransferFunction_ITU_R_2100_HLG
        )
        XCTAssertEqual(
            colorProperties[AVVideoColorPrimariesKey] as? String,
            AVVideoColorPrimaries_ITU_R_2020
        )

        let asset = AVURLAsset(url: hlgURL)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        XCTAssertTrue(reader.canAdd(output), "the decoder rejected the HDR output settings")
        reader.add(output)
        reader.startReading()
        // The iOS Simulator has no HEVC Main 10 decoder: it accepts the output
        // settings and then returns no frames. The conversion itself is verified
        // on real hardware by Scripts/ValidateHDRDecode.swift, whose measured
        // values HDRColorSpaceTests asserts against. Skipping here keeps that
        // limitation visible instead of turning it into a red test that says
        // nothing about the code.
        guard let sample = output.copyNextSampleBuffer() else {
            throw XCTSkip(
                """
                This runtime decoded no frames from HEVC Main 10 \
                (reader status \(reader.status.rawValue)). Expected in the \
                Simulator; run on a device or use Scripts/ValidateHDRDecode.swift.
                """
            )
        }
        let buffer = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_64RGBAHalf)

        // And Metal must be able to wrap it, which is what the renderer needs.
        let context = try MetalContext()
        let textures = try XCTUnwrap(PixelBufferTextures(pixelBuffer: buffer, context: context))
        guard case .linearHalf(_, let texture) = textures.storage else {
            return XCTFail("expected the extended-range linear storage case")
        }
        XCTAssertEqual(texture.pixelFormat, .rgba16Float)
    }

    /// The SDR path must be untouched: still 8-bit NV12, exactly as before.
    func testSDROutputSettingsAreUnchanged() {
        let settings = VideoPlaybackController.outputSettings(for: .sdr)
        XCTAssertEqual(
            settings[kCVPixelBufferPixelFormatTypeKey as String] as? OSType,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        XCTAssertNil(settings[AVVideoColorPropertiesKey], "SDR must not request a colour conversion")
    }
}

/// Phase 4: the export configuration for an HDR project.
///
/// These assert the settings dictionaries the writer is handed. The encode
/// itself, the resulting file's measured metadata and the pixel round trip are
/// covered by `Scripts/ValidateHDRExport.swift`, which needs a Main 10 codec
/// the Simulator does not have.
final class HDRExportSettingsTests: XCTestCase {
    /// Built from the real HLG fixture through the real inspector, so these
    /// exercise the path the app takes rather than a hand-made stand-in.
    private func hlgSource() async throws -> ExportSourceInfo {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("hlg_test.mov")
        let asset = try await VideoMetadataReader().read(from: url)
        return try await ExportSourceInspector.inspect(asset)
    }

    /// The HLG fixture must reach the export path as an HDR project at all -
    /// this is the gate that used to say "HDR export is not supported yet".
    func testTheHLGSourcePassesExportInspectionAsHDR() async throws {
        let source = try await hlgSource()
        XCTAssertTrue(source.colorMode.isHDR, "an HLG source must resolve to an HDR export")
    }

    func testHDRRequestsMain10AndHLGBT2020Tags() async throws {
        let settings = ExportMediaSettings.videoWriterSettings(
            source: try await hlgSource(), configuration: .maximumQuality
        )
        let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any]
        XCTAssertEqual(
            compression?[AVVideoProfileLevelKey] as? String,
            kVTProfileLevel_HEVC_Main10_AutoLevel as String,
            "HDR must be encoded as Main 10; 8-bit Main cannot carry it"
        )
        let colour = settings[AVVideoColorPropertiesKey] as? [String: Any]
        XCTAssertEqual(colour?[AVVideoColorPrimariesKey] as? String, AVVideoColorPrimaries_ITU_R_2020)
        XCTAssertEqual(colour?[AVVideoTransferFunctionKey] as? String, AVVideoTransferFunction_ITU_R_2100_HLG)
        XCTAssertEqual(colour?[AVVideoYCbCrMatrixKey] as? String, AVVideoYCbCrMatrix_ITU_R_2020)
        XCTAssertEqual(settings[AVVideoCodecKey] as? AVVideoCodecType, .hevc)
    }

    /// No 8-bit stage anywhere in the HDR path: the reader gives extended-range
    /// half float and the writer receives 10-bit 4:2:0 directly.
    func testHDRHasNoEightBitIntermediate() async throws {
        XCTAssertEqual(
            ExportMediaSettings.videoReaderSettings(colorMode: .hdrHLG)[kCVPixelBufferPixelFormatTypeKey as String] as? OSType,
            kCVPixelFormatType_64RGBAHalf
        )
        let attributes = ExportMediaSettings.writerPixelBufferAttributes(
            source: try await hlgSource(), configuration: .maximumQuality
        )
        XCTAssertEqual(
            attributes[kCVPixelBufferPixelFormatTypeKey as String] as? OSType,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            "an 8-bit BGRA intermediate would discard the precision the path exists to keep"
        )
    }

    /// The SDR export path must be exactly what it was.
    func testSDRExportSettingsAreUnchanged() async throws {
        var sdr = try await hlgSource()
        sdr.colorMode = .sdr
        let settings = ExportMediaSettings.videoWriterSettings(source: sdr, configuration: .maximumQuality)
        let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any]
        XCTAssertEqual(compression?[AVVideoProfileLevelKey] as? String,
                       kVTProfileLevel_HEVC_Main_AutoLevel as String)
        let colour = settings[AVVideoColorPropertiesKey] as? [String: Any]
        XCTAssertEqual(colour?[AVVideoTransferFunctionKey] as? String, AVVideoTransferFunction_ITU_R_709_2)
        let sdrAttributes = ExportMediaSettings.writerPixelBufferAttributes(
            source: sdr, configuration: .maximumQuality
        )
        XCTAssertEqual(sdrAttributes[kCVPixelBufferPixelFormatTypeKey as String] as? OSType,
                       kCVPixelFormatType_32BGRA)
    }

    /// Frame cadence must survive: 59.94 must not become 60.
    /// Frame cadence must survive rather than being rounded to a nominal value.
    func testTheSourceFrameRateIsCarriedThroughUnrounded() async throws {
        let source = try await hlgSource()
        let settings = ExportMediaSettings.videoWriterSettings(source: source, configuration: .maximumQuality)
        let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any]
        XCTAssertEqual(
            compression?[AVVideoExpectedSourceFrameRateKey] as? Double ?? 0,
            source.nominalFrameRate ?? 0, accuracy: 0.0001,
            "the encoder must be told the source cadence, not a rounded one"
        )
    }

    /// An export that produced the wrong thing must be reported as a failure,
    /// not as a success with different settings.
    func testAMismatchedOutputIsReportedAsAFailure() {
        let sdrReport = ExportOutputReport(
            codec: "hvc1", bitDepth: 8, colorPrimaries: "BT.709",
            transferFunction: "BT.709", yCbCrMatrix: "BT.709", width: 1920, height: 1080
        )
        XCTAssertFalse(sdrReport.isHLGBT2020)
        let hdrReport = ExportOutputReport(
            codec: "hvc1", bitDepth: 10, colorPrimaries: "BT.2020",
            transferFunction: "HLG", yCbCrMatrix: "BT.2020", width: 3840, height: 2160
        )
        XCTAssertTrue(hdrReport.isHLGBT2020)
        XCTAssertTrue(hdrReport.summary.contains("10-bit"))
    }
}

/// A >8-bit Rec.709 source — ProRes 422, the case that used to say "12-bit
/// grading and export are not enabled".
///
/// The point of these is that nothing about the *colour* changes: this is the
/// same Rec.709 path 8-bit SDR has always used. Only the containers widen.
final class WidePrecisionSDRTests: XCTestCase {
    private var proResURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("prores_test.mov")
    }

    /// Matches the real source that prompted this: ProRes 422, fully tagged
    /// Rec.709, above 8 bits. The bundled `prores_test.mov` carries no `colr`
    /// atom (the encoder that produced it omits one), so the gate assertions use
    /// this rather than depending on a fixture that is missing the very tags
    /// under test.
    private func proResMetadata(
        primaries: String? = "BT.709",
        transfer: String? = "BT.709",
        bitDepth: Int? = 12
    ) -> VideoMetadata {
        makeVideoMetadata(
            encodedWidth: 3_840, encodedHeight: 2_160,
            displayWidth: 3_840, displayHeight: 2_160,
            nominalFrameRate: 24, minimumFrameDurationSeconds: 1.0 / 24.0,
            codec: "ProRes 422", codecFourCC: "apcn",
            hasAudio: false, audioTrackCount: 0,
            colorPrimaries: primaries, transferFunction: transfer,
            yCbCrMatrix: "BT.709", isHDR: false, bitDepth: bitDepth
        )
    }

    /// The gate that produced "12-bit grading and export are not enabled".
    func testAboveEightBitRec709OpensAndGrades() {
        let support = ColorPipelineSupport(metadata: proResMetadata())
        guard case .sdrWideSupported(let depth) = support else {
            return XCTFail("expected wide SDR support, got \(support)")
        }
        XCTAssertEqual(depth, 12)
        XCTAssertTrue(support.allowsEditor)
        XCTAssertTrue(support.allowsGrading)
        XCTAssertFalse(support.isBlocking)
        XCTAssertEqual(support.colorMode, .sdrWide)
        XCTAssertFalse(support.colorMode.isHDR, "this is SDR colour at wide precision")
        XCTAssertTrue(support.colorMode.isWidePrecision)
    }

    /// Wide precision is not HDR. A 12-bit Rec.709 file must never be tagged or
    /// treated as one.
    func testWidePrecisionIsNotTreatedAsHDR() throws {
        let m = proResMetadata()
        XCTAssertFalse(ProjectColorMode.canPreserveHDR(for: m))
        XCTAssertEqual(ProjectColorMode.default(for: m), .sdrWide)
        let project = VideoProject(sourceURL: proResURL, displayName: "prores", metadata: m)
        XCTAssertEqual(project.colorMode, .sdrWide)
        let reloaded = try JSONDecoder().decode(
            VideoProject.self, from: try JSONEncoder().encode(project))
        XCTAssertEqual(reloaded.colorMode, .sdrWide, "the choice must survive save and reopen")
    }

    /// A wide-gamut or HDR transfer at high bit depth is a different problem and
    /// must stay blocked rather than being waved through as "just precision".
    func testWideGamutAboveEightBitIsStillBlocked() {
        let p3 = proResMetadata(primaries: "Display P3")
        XCTAssertFalse(ColorPipelineSupport(metadata: p3).allowsEditor)
        XCTAssertTrue(ColorPipelineSupport(metadata: p3).isBlocking)
    }

    /// Export writes 10-bit rather than reducing to 8, and stays Rec.709.
    func testExportsAtTenBitWithoutBecomingHDR() async throws {
        // Built from the real HLG fixture only to obtain a valid
        // ExportSourceInfo; the colour mode under test is set explicitly.
        let hlg = try await VideoMetadataReader().read(
            from: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().appendingPathComponent("hlg_test.mov"))
        var source = try await ExportSourceInspector.inspect(hlg)
        source.colorMode = .sdrWide
        let settings = ExportMediaSettings.videoWriterSettings(source: source, configuration: .maximumQuality)
        let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any]
        XCTAssertEqual(compression?[AVVideoProfileLevelKey] as? String,
                       kVTProfileLevel_HEVC_Main10_AutoLevel as String,
                       "a >8-bit source must not be silently reduced to 8-bit Main")
        let colour = settings[AVVideoColorPropertiesKey] as? [String: Any]
        XCTAssertEqual(colour?[AVVideoTransferFunctionKey] as? String, AVVideoTransferFunction_ITU_R_709_2,
                       "wide precision is not HDR: the tags stay Rec.709")
        XCTAssertEqual(colour?[AVVideoColorPrimariesKey] as? String, AVVideoColorPrimaries_ITU_R_709_2)

        let attributes = ExportMediaSettings.writerPixelBufferAttributes(source: source, configuration: .maximumQuality)
        XCTAssertEqual(attributes[kCVPixelBufferPixelFormatTypeKey as String] as? OSType,
                       kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                       "an 8-bit BGRA intermediate would throw the precision away")
    }

    /// 4:2:2 at 10 bits, decoded natively so chroma is never resampled on the
    /// way in, and wrapped by the existing bi-planar texture path unchanged.
    func testDecodesNativelyAtFullPrecision() async throws {
        let settings = VideoPlaybackController.outputSettings(for: .sdrWide)
        XCTAssertEqual(
            settings[kCVPixelBufferPixelFormatTypeKey as String] as? OSType,
            kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        )
        let asset = AVURLAsset(url: proResURL)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        XCTAssertTrue(reader.canAdd(output))
        reader.add(output)
        reader.startReading()
        guard let sample = output.copyNextSampleBuffer(),
              let buffer = CMSampleBufferGetImageBuffer(sample) else {
            throw XCTSkip("this runtime has no ProRes decoder; run on a device")
        }
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer),
                       kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
        // Chroma keeps full height in 4:2:2 - that is the point of asking for it.
        XCTAssertEqual(CVPixelBufferGetHeightOfPlane(buffer, 1),
                       CVPixelBufferGetHeightOfPlane(buffer, 0))

        let context = try MetalContext()
        let textures = try XCTUnwrap(PixelBufferTextures(pixelBuffer: buffer, context: context))
        guard case .biPlanar(_, let luma, _, let chroma) = textures.storage else {
            return XCTFail("expected the bi-planar storage the existing shader path uses")
        }
        XCTAssertEqual(luma.pixelFormat, .r16Unorm)
        XCTAssertEqual(chroma.pixelFormat, .rg16Unorm)
    }

    /// CoreMedia reports the depth for ProRes, so it no longer has to be refused
    /// on the codec name alone.
    func testProResReportsItsDepth() async throws {
        // The Simulator has no ProRes decoder, so AVAsset reports the file as
        // unplayable and the reader refuses it before reading anything. That is
        // a runtime limitation, not a code failure.
        guard let m = try? await VideoMetadataReader().read(from: proResURL).metadata else {
            throw XCTSkip("this runtime cannot open ProRes; run on a device")
        }
        XCTAssertEqual(m.codec, "ProRes 422")
        XCTAssertEqual(try XCTUnwrap(m.bitDepth), 12)
        XCTAssertNotEqual(m.isHDR, true, "ProRes 422 Rec.709 is not HDR")
    }

    /// The 8-bit SDR path must be completely untouched by all of this.
    func testEightBitSDRIsUnchanged() {
        let m = makeVideoMetadata()
        XCTAssertEqual(ProjectColorMode.default(for: m), .sdr)
        XCTAssertEqual(ColorPipelineSupport(metadata: m), .supported)
        XCTAssertEqual(
            VideoPlaybackController.outputSettings(for: .sdr)[kCVPixelBufferPixelFormatTypeKey as String] as? OSType,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
    }
}
