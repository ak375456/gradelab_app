import Foundation
import XCTest
@testable import GradeLab

final class TraditionalChineseLocalizationTests: XCTestCase {
    private func chineseBundle() throws -> Bundle {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "zh-Hant", withExtension: "lproj"))
        return try XCTUnwrap(Bundle(url: url))
    }

    func testEditorCameraAndPaywallResourcesAreTraditionalChinese() throws {
        let bundle = try chineseBundle()
        for (key, expected) in [
            ("Exposure", "曝光"), ("Curves", "曲線"), ("Masks", "遮罩"),
            ("Stabilization", "影片防手震"), ("Open Camera", "開啟相機"),
            ("Lifetime Pro", "Pro 終身版"), ("Weekly", "週訂閱"),
            ("Monthly", "月訂閱"), ("Yearly", "年訂閱"),
            ("Color strength", "色彩強度"), ("Lightness", "明度"),
            ("Brightness", "亮度"), ("Parade", "RGB 分量"),
            ("GRADELAB PRO", "GRADELAB PRO"), ("workflow.step.grade", "調色"),
            ("Hue range", "色相範圍"), ("Spill", "溢色抑制"),
            ("Brush Size", "畫筆大小"), ("noisePreset.light", "輕度"),
            ("per week · auto-renews", "每週 · 自動續訂"),
            ("Your Pro access has been restored.", "已回復你的 Pro 使用權限。")
        ] {
            XCTAssertEqual(bundle.localizedString(forKey: key, value: nil, table: nil), expected, key)
        }
    }

    func testAllFourStoreKitProductsHaveChineseNamesAndDescriptions() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("GradeLab.storekit"))
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var products = try XCTUnwrap(config["products"] as? [[String: Any]])
        let groups = try XCTUnwrap(config["subscriptionGroups"] as? [[String: Any]])
        for group in groups { products += try XCTUnwrap(group["subscriptions"] as? [[String: Any]]) }
        XCTAssertEqual(Set(products.compactMap { $0["productID"] as? String }), Set(ProPlan.allCases.map(\.id)))
        for product in products {
            let localizations = try XCTUnwrap(product["localizations"] as? [[String: String]])
            let chinese = try XCTUnwrap(localizations.first { $0["locale"] == "zh_TW" })
            let name = try XCTUnwrap(chinese["displayName"])
            let description = try XCTUnwrap(chinese["description"])
            XCTAssertFalse(name.isEmpty); XCTAssertLessThanOrEqual(name.count, 30)
            XCTAssertTrue(description.contains("Pro")); XCTAssertLessThanOrEqual(description.count, 45)
        }
    }

    func testDiscountArgumentReorderingAndPluralFrames() throws {
        let bundle = try chineseBundle()
        let format = bundle.localizedString(forKey: "%lld%% off the %@ standard lifetime price. %@", value: nil, table: nil)
        XCTAssertEqual(String(format: format, locale: Locale(identifier: "zh_Hant_TW"),
            arguments: [Int64(57), "$34.99", "已購買"]), "買斷標準價 $34.99，現省 57%。已購買")
        let frames = bundle.localizedString(forKey: "%lld frames", value: nil, table: nil)
        for count in [Int64(1), Int64(24)] {
            XCTAssertEqual(String(format: frames, locale: Locale(identifier: "zh_Hant_TW"), arguments: [count]), "\(count) 影格")
        }
    }

    func testAllPrivacyPromptsAreChineseAndKeepTheBrand() throws {
        let bundle = try chineseBundle()
        XCTAssertEqual(bundle.localizedString(forKey: "CFBundleDisplayName", value: nil, table: "InfoPlist"), "GradeLab")
        for (key, word) in [("NSCameraUsageDescription", "相機"),
                            ("NSMicrophoneUsageDescription", "麥克風"),
                            ("NSPhotoLibraryAddUsageDescription", "照片")] {
            let value = bundle.localizedString(forKey: key, value: nil, table: "InfoPlist")
            XCTAssertTrue(value.contains(word)); XCTAssertTrue(value.contains("GradeLab"))
        }
    }

    func testSourceCatalogHasCompleteCoverageAndExistingLanguages() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("dummy name/Localizable.xcstrings"))
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        for (key, entry) in strings where entry["shouldTranslate"] as? Bool != false {
            let locales = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            XCTAssertNotNil(locales["zh-Hant"], key)
        }
        let exposure = try XCTUnwrap(strings["Exposure"]?["localizations"] as? [String: Any])
        for locale in ["de", "es", "fi", "fr", "it", "ja", "sv", "zh-Hans"] { XCTAssertNotNil(exposure[locale]) }
    }
}
