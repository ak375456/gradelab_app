import AVFoundation
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

    /// Effects ship compiled, from `SoundSources/` via
    /// `Scripts/compile-sound-effects.sh`. Shipping the sources instead would
    /// still play correctly and so would pass every check above, while quietly
    /// putting 25 MB back into the download.
    func testEffectsShipCompiled() {
        let effects = SoundEffectCatalog.all
        XCTAssertFalse(effects.isEmpty)
        XCTAssertTrue(
            effects.allSatisfy { $0.fileExtension == "m4a" },
            "Some effects ship in their source format rather than compiled"
        )
    }

    /// The manifest describes the audio it ships with: a duration that came
    /// from the source rather than from the compiled file would show one length
    /// in the browser and play another.
    func testManifestDurationsMatchTheAudio() throws {
        for effect in SoundEffectCatalog.all.prefix(40) {
            let url = try XCTUnwrap(effect.url(), effect.id)
            let asset = AVURLAsset(url: url)
            let duration = CMTimeGetSeconds(asset.duration)
            XCTAssertEqual(
                duration, effect.duration, accuracy: 0.05,
                "\(effect.id) claims \(effect.duration)s but the file is \(duration)s"
            )
        }
    }
}
