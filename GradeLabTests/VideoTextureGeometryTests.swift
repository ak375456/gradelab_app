import CoreGraphics
import simd
import XCTest
@testable import GradeLab

final class VideoTextureGeometryTests: XCTestCase {
    private let size = CGSize(width: 4, height: 2)

    func testAllEightRotationAndReflectionOrientations() {
        assertCoordinates(.identity, equal: [(0, 1), (1, 1), (0, 0), (1, 0)])
        assertCoordinates(
            CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 2, ty: 0),
            equal: [(1, 1), (1, 0), (0, 1), (0, 0)]
        )
        assertCoordinates(
            CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 4, ty: 2),
            equal: [(1, 0), (0, 0), (1, 1), (0, 1)]
        )
        assertCoordinates(
            CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 4),
            equal: [(0, 0), (0, 1), (1, 0), (1, 1)]
        )
        assertCoordinates(
            CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 4, ty: 0),
            equal: [(1, 1), (0, 1), (1, 0), (0, 0)]
        )
        assertCoordinates(
            CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 2),
            equal: [(0, 0), (1, 0), (0, 1), (1, 1)]
        )
        assertCoordinates(
            CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0),
            equal: [(1, 0), (1, 1), (0, 0), (0, 1)]
        )
        assertCoordinates(
            CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: 2, ty: 4),
            equal: [(0, 1), (0, 0), (1, 1), (1, 0)]
        )
    }

    func testInvalidGeometryFallsBackWithoutNaNCoordinates() {
        let coordinates = VideoTextureGeometry.textureCoordinates(
            encodedSize: .zero,
            preferredTransform: .identity
        )

        XCTAssertEqual(coordinates, [SIMD2(0, 1), SIMD2(1, 1), SIMD2(0, 0), SIMD2(1, 0)])
    }

    private func assertCoordinates(
        _ transform: CGAffineTransform,
        equal expected: [(Float, Float)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = VideoTextureGeometry.textureCoordinates(
            encodedSize: size,
            preferredTransform: transform
        )
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (actual, expected) in zip(actual, expected) {
            XCTAssertEqual(actual.x, expected.0, accuracy: 0.0001, file: file, line: line)
            XCTAssertEqual(actual.y, expected.1, accuracy: 0.0001, file: file, line: line)
        }
    }
}
