import XCTest
import Foundation
@testable import GradeLab

/// Exercise the compiled resources, including argument reordering and Japanese
/// plural rules. Catalog syntax checks alone cannot catch a missing .lproj.
final class JapaneseLocalizationTests: XCTestCase {
    private func japaneseBundle() throws -> Bundle {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "ja", withExtension: "lproj"))
        return try XCTUnwrap(Bundle(url: url))
    }

    func testJapaneseResourcesIncludePreviouslyIndirectDisplayText() throws {
        let bundle = try japaneseBundle()
        for (key, expected) in [
            ("Straight out of the camera", "撮ったままの映像"),
            ("Curves", "カーブ"),
            ("Volume", "音量"),
            ("Your Pro access has been restored.", "Proの購入を復元しました。"),
            ("Lifetime Pro", "Pro 買い切り")
        ] {
            XCTAssertEqual(bundle.localizedString(forKey: key, value: nil, table: nil), expected)
        }
    }

    func testReorderedArgumentsKeepTheirOriginalTypesAndMeaning() throws {
        let bundle = try japaneseBundle()
        let format = bundle.localizedString(forKey: "%lld%% off the %@ standard lifetime price. %@", value: nil, table: nil)
        XCTAssertEqual(String(format: format, locale: Locale(identifier: "ja_JP"),
                              arguments: [Int64(57), "$34.99", "購入済み"]),
                       "買い切り通常価格$34.99から57%オフ。購入済み")
    }

    func testJapanesePluralResourcesWorkForOneAndSeveralFrames() throws {
        let bundle = try japaneseBundle()
        let format = bundle.localizedString(forKey: "%lld frames", value: nil, table: nil)
        for count in [Int64(1), Int64(12)] {
            XCTAssertEqual(String(format: format, locale: Locale(identifier: "ja_JP"), arguments: [count]),
                           "\(count)フレーム")
        }
    }

    func testBundlePermissionIsJapaneseAndBrandNameIsPreserved() throws {
        let bundle = try japaneseBundle()
        XCTAssertEqual(bundle.localizedString(forKey: "CFBundleDisplayName", value: nil, table: "InfoPlist"), "GradeLab")
        let permission = bundle.localizedString(forKey: "NSPhotoLibraryAddUsageDescription", value: nil, table: "InfoPlist")
        XCTAssertTrue(permission.contains("写真"))
        XCTAssertTrue(permission.contains("許可"))
    }
}
