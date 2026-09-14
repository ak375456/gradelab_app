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
