import simd
import XCTest
@testable import GradeLab

final class CubeLUTParserTests: XCTestCase {
    func testParsesAValidThreeDimensionalCube() throws {
        let cube = """
        # A compact identity cube
        TITLE "Identity 2"
        LUT_3D_SIZE 2
        DOMAIN_MIN 0.0 0.0 0.0
        DOMAIN_MAX 1.0 1.0 1.0
        0 0 0
        0 0 1
        0 1 0
        0 1 1
        1 0 0
        1 0 1
        1 1 0
        1 1 1
        """

        let result = try CubeLUTParser().parse(cube)

        XCTAssertEqual(result.title, "Identity 2")
        XCTAssertEqual(result.kind, .threeDimensional(size: 2))
        XCTAssertEqual(result.domainMinimum, SIMD3<Float>(repeating: 0))
        XCTAssertEqual(result.domainMaximum, SIMD3<Float>(repeating: 1))
        XCTAssertEqual(result.values.count, 8)
    }

    func testParsesAValidOneDimensionalCube() throws {
        let cube = """
        LUT_1D_SIZE 3
        0.0 0.0 0.0
        0.5 0.5 0.5
        1.0 1.0 1.0
        """

        let result = try CubeLUTParser().parse(cube)

        XCTAssertEqual(result.kind, .oneDimensional(size: 3))
        XCTAssertEqual(result.values[1], SIMD3<Float>(repeating: 0.5))
    }

    func testRejectsUnsupportedOrAmbiguousCubeDeclarations() {
        XCTAssertThrowsError(try CubeLUTParser().parse("LUT_3D_SIZE 66"))
        XCTAssertThrowsError(
            try CubeLUTParser().parse(
                """
                LUT_1D_SIZE 2
                LUT_3D_SIZE 2
                0 0 0
                1 1 1
                """
            )
        )
    }

    /// The parser reads UTF-8 bytes directly rather than going through String,
    /// so it has to absorb a byte-order mark itself. Editors on Windows write
    /// one routinely and those looks imported fine before.
    func testParsesACubeCarryingAUTF8ByteOrderMark() throws {
        let cube = "\u{FEFF}LUT_1D_SIZE 2\n0 0 0\n1 1 1\n"
        let result = try CubeLUTParser().parse(cube)
        XCTAssertEqual(result.kind, .oneDimensional(size: 2))
        XCTAssertEqual(result.values.count, 2)
    }

    /// Real looks are not all tidy: CRLF line endings, blank lines, comments
    /// after the header, mixed-case keywords and extra indentation all occur in
    /// files people import. The byte parser handles each without allocating.
    func testParsesUntidyButValidFormatting() throws {
        let cube = "# comment\r\n  title \"Messy\"\r\n\r\nlut_3d_size 2\r\n"
            + (0..<8).map { _ in "  0.5   0.25\t0.125  \r\n" }.joined()
        let result = try CubeLUTParser().parse(cube)
        XCTAssertEqual(result.title, "Messy")
        XCTAssertEqual(result.kind, .threeDimensional(size: 2))
        XCTAssertEqual(result.values.count, 8)
        XCTAssertEqual(result.values[0], SIMD3<Float>(0.5, 0.25, 0.125))
    }

    /// A field that only starts as a number is malformed, not a rounded value —
    /// `strtof` would happily stop early and return 0.5 for "0.5x".
    func testRejectsATrailingGarbageSample() {
        XCTAssertThrowsError(
            try CubeLUTParser().parse("LUT_1D_SIZE 2\n0 0 0\n1 1x 1\n")
        )
    }

    func testRejectsAnIncompleteCube() {
        XCTAssertThrowsError(
            try CubeLUTParser().parse(
                """
                LUT_3D_SIZE 2
                0 0 0
                1 1 1
                """
            )
        ) { error in
            XCTAssertEqual(
                error as? GradeLabError,
                .invalidLUT("Expected 8 entries but found 2.")
            )
        }
    }
}
