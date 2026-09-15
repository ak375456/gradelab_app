import XCTest
@testable import GradeLab

final class SoundEffectCatalogTests: XCTestCase {
    func testBundledCatalogIsCompleteAndResolvable() {
        let effects = SoundEffectCatalog.all
        XCTAssertEqual(effects.count, 624)
        XCTAssertEqual(Set(effects.map(\.id)).count, effects.count)
        XCTAssertEqual(Set(effects.map(\.resource)).count, effects.count)
        XCTAssertTrue(effects.allSatisfy { $0.duration > 0 })
        XCTAssertTrue(effects.allSatisfy { $0.url() != nil })
    }
}
