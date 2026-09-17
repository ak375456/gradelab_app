import Metal
import simd
import XCTest
@testable import GradeLab

/// The compiled look format.
///
/// The format exists to make the app smaller, and it is only allowed to do that
/// if it changes nothing about what renders. That is the claim these tests are
/// here to hold: not "close enough", but the same bytes on the GPU.
final class LUTBinaryTests: XCTestCase {

    /// A small but genuinely non-trivial cube: identity with blue pulled down,
    /// so a channel swap or an ordering mistake cannot pass.
    private func makeCube(size: Int = 5) -> CubeLUT {
        var values: [SIMD3<Float>] = []
        let last = Float(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    values.append(SIMD3(Float(r) / last, Float(g) / last, Float(b) / last * 0.8))
                }
            }
        }
        return CubeLUT(
            title: "Test",
            kind: .threeDimensional(size: size),
            domainMinimum: SIMD3(repeating: 0),
            domainMaximum: SIMD3(repeating: 1),
            values: values
        )
    }

    func testEncodingThenDecodingPreservesEverySample() throws {
        let cube = makeCube()
        let decoded = try LUTBinary.decode(LUTBinary.encode(cube))

        XCTAssertEqual(decoded.size, 5)
        XCTAssertEqual(decoded.samples.count, cube.values.count * 3)
        for (index, value) in cube.values.enumerated() {
            XCTAssertEqual(decoded.samples[index * 3], LUTBinary.quantize(value.x), "entry \(index) red")
            XCTAssertEqual(decoded.samples[index * 3 + 1], LUTBinary.quantize(value.y), "entry \(index) green")
            XCTAssertEqual(decoded.samples[index * 3 + 2], LUTBinary.quantize(value.z), "entry \(index) blue")
        }
    }

    func testTheFileIsTheSizeTheFormatSays() throws {
        let data = try LUTBinary.encode(makeCube(size: 5))
        XCTAssertEqual(data.count, LUTBinary.headerSize + 5 * 5 * 5 * 3 * 2)
        XCTAssertEqual(Array(data.prefix(4)), Array("GLUT".utf8))
    }

    /// Ordering is the mistake that would look like a plausible grade rather
    /// than like a bug, so it is asserted directly: red fastest, blue slowest.
    func testOrderingIsRedFastest() throws {
        let size = 5
        let decoded = try LUTBinary.decode(LUTBinary.encode(makeCube(size: size)))
        // The entry at (r: 4, g: 0, b: 0) is pure red; at (r: 0, g: 0, b: 4)
        // blue is at its pulled-down maximum.
        let red = 4
        XCTAssertEqual(decoded.samples[red * 3], UInt16.max)
        XCTAssertEqual(decoded.samples[red * 3 + 2], 0)
        let blue = 4 * size * size
        XCTAssertEqual(decoded.samples[blue * 3], 0)
        XCTAssertEqual(decoded.samples[blue * 3 + 2], LUTBinary.quantize(0.8))
    }

    // MARK: - Refusals

    func testAFileThatIsNotALookIsRefused() {
        XCTAssertThrowsError(try LUTBinary.decode(Data("not a look at all, just text".utf8)))
    }

    func testATruncatedFileIsRefused() throws {
        let data = try LUTBinary.encode(makeCube())
        XCTAssertThrowsError(try LUTBinary.decode(data.dropLast(2))) { error in
            XCTAssertTrue("\(error)".contains("bytes"), "The reason must name the length: \(error)")
        }
    }

    func testAFileTooShortForAHeaderIsRefused() {
        XCTAssertThrowsError(try LUTBinary.decode(Data([0x47, 0x4C, 0x55, 0x54])))
    }

    func testAFutureVersionIsRefused() throws {
        var data = try LUTBinary.encode(makeCube())
        data[4] = 99
        XCTAssertThrowsError(try LUTBinary.decode(data)) { error in
            XCTAssertTrue("\(error)".contains("version"), "The reason must name the version: \(error)")
        }
    }

    /// A header claiming a size its payload cannot support would otherwise
    /// build a texture out of whatever followed the file in memory.
    func testAMismatchedEntryCountIsRefused() throws {
        var data = try LUTBinary.encode(makeCube())
        data[8] = 0xFF
        XCTAssertThrowsError(try LUTBinary.decode(data))
    }

    func testAOneDimensionalLUTCannotBeCompiled() {
        let oneD = CubeLUT(
            title: nil, kind: .oneDimensional(size: 2),
            domainMinimum: SIMD3(repeating: 0), domainMaximum: SIMD3(repeating: 1),
            values: [SIMD3(repeating: 0), SIMD3(repeating: 1)]
        )
        XCTAssertThrowsError(try LUTBinary.encode(oneD)) { error in
            XCTAssertTrue("\(error)".contains("1D"), "The reason must name the problem: \(error)")
        }
    }

    // MARK: - The claim that matters

    /// The compiled look and the `.cube` it came from must upload the same
    /// texture, byte for byte.
    ///
    /// Compared by reading both textures back rather than by comparing the
    /// arrays that built them, so the check covers the upload path too — the
    /// row and image strides are where a 3D texture goes quietly wrong.
    func testACompiledLookUploadsTheSameTextureAsItsSource() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let cube = makeCube(size: 9)

        let fromText = try LUTTextureFactory.makeTexture(from: cube, device: device)
        let fromCompiled = try LUTTextureFactory.makeTexture(
            from: try LUTBinary.decode(LUTBinary.encode(cube)), device: device
        )

        XCTAssertEqual(readBack(fromText), readBack(fromCompiled), "Compiled and text forms diverged")
    }

    /// Every look the app actually ships, held to the same standard against the
    /// source it was compiled from. This is what would catch a stale `.gclut`
    /// committed after its `.cube` changed.
    func testEveryShippedLookMatchesItsSource() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LUTSources")

        // Sources keep their folder structure; the bundle flattens them, so the
        // filename is what ties a shipped look back to the file it came from.
        var sourceByName: [String: URL] = [:]
        if let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension.lowercased() == "cube" {
                sourceByName[url.lastPathComponent] = url
            }
        }
        XCTAssertFalse(sourceByName.isEmpty, "No look sources found at \(sources.path)")

        for asset in LUTAsset.bundledLooks {
            let compiledURL = try XCTUnwrap(asset.url(), "\(asset.filename) does not resolve")
            guard compiledURL.pathExtension == LUTBinary.fileExtension else { continue }
            let source = try XCTUnwrap(sourceByName[asset.filename], "No source for \(asset.filename)")

            let cube = try CubeLUTParser().parse(contentsOf: source)
            let compiled = try LUTBinary.decode(contentsOf: compiledURL)
            XCTAssertEqual(
                compiled.samples.count, cube.values.count * 3,
                "\(asset.filename) is compiled from a different source than the one on disk"
            )
            for (index, value) in cube.values.enumerated() {
                guard compiled.samples[index * 3] == LUTBinary.quantize(value.x),
                      compiled.samples[index * 3 + 1] == LUTBinary.quantize(value.y),
                      compiled.samples[index * 3 + 2] == LUTBinary.quantize(value.z) else {
                    return XCTFail("\(asset.filename) entry \(index) does not match its source")
                }
            }
        }
    }

    private func readBack(_ texture: MTLTexture) -> [UInt16] {
        let size = texture.width
        var bytes = [UInt16](repeating: 0, count: size * size * size * 4)
        let bytesPerPixel = MemoryLayout<UInt16>.size * 4
        bytes.withUnsafeMutableBytes { buffer in
            texture.getBytes(
                buffer.baseAddress!,
                bytesPerRow: size * bytesPerPixel,
                bytesPerImage: size * size * bytesPerPixel,
                from: MTLRegionMake3D(0, 0, 0, size, size, size),
                mipmapLevel: 0,
                slice: 0
            )
        }
        return bytes
    }
}
