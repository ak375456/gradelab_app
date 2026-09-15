import Foundation

struct SoundEffectAsset: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let category: String
    let pack: String
    let resource: String
    let duration: Double

    var resourceName: String { (resource as NSString).deletingPathExtension }
    var fileExtension: String { (resource as NSString).pathExtension }

    func url(in bundle: Bundle = .soundEffectResources) -> URL? {
        if let direct = bundle.url(forResource: resourceName, withExtension: fileExtension) {
            return direct
        }
        guard let nested = bundle.resourceURL?
            .appendingPathComponent("SoundEffects", isDirectory: true)
            .appendingPathComponent(resource),
              FileManager.default.fileExists(atPath: nested.path) else { return nil }
        return nested
    }
}

enum SoundEffectCatalog {
    private struct Manifest: Decodable {
        let version: Int
        let effects: [SoundEffectAsset]
    }

    static let all: [SoundEffectAsset] = load()

    static func load(in bundle: Bundle = .soundEffectResources) -> [SoundEffectAsset] {
        let direct = bundle.url(forResource: "SoundEffects", withExtension: "json")
        let nested = bundle.resourceURL?
            .appendingPathComponent("SoundEffects", isDirectory: true)
            .appendingPathComponent("SoundEffects.json")
        guard let url = direct ?? nested,
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.version == 1 else { return [] }
        return manifest.effects
    }
}

private final class SoundEffectBundleToken {}

extension Bundle {
    static let soundEffectResources = Bundle(for: SoundEffectBundleToken.self)
}
