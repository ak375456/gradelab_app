@preconcurrency import Metal
import Foundation

/// Loads bundled `.cube` looks and keeps their GPU textures ready.
///
/// Parsing a 33-point cube means reading ~36,000 lines of text, so it never
/// happens on the render thread: `prepare` does the work up front, and
/// `texture(for:)` is a lock-guarded cache read that always returns something
/// bindable. Until a look finishes loading, the identity texture stands in,
/// which is a mathematical no-op rather than a wrong-looking frame.
final class LUTLibrary: @unchecked Sendable {
    private let device: MTLDevice
    private let lock = NSLock()
    private var textures: [String: MTLTexture] = [:]
    private var unavailable: Set<String> = []
    private var identityTexture: MTLTexture?

    init(device: MTLDevice) {
        self.device = device
        identityTexture = try? LUTTextureFactory.makeIdentity(device: device)
    }

    /// Render-thread safe: never parses, never blocks on I/O.
    func texture(for identifier: String?) -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        guard let identifier else { return identityTexture }
        return textures[identifier] ?? identityTexture
    }

    /// True once the look is on the GPU. A caller can use this to avoid showing
    /// a strength that is not being applied yet.
    func isReady(_ identifier: String?) -> Bool {
        guard let identifier else { return true }
        lock.lock(); defer { lock.unlock() }
        return textures[identifier] != nil
    }

    /// Loads one look. Safe to call repeatedly; work happens once.
    @discardableResult
    func prepare(_ identifier: String) -> Bool {
        guard let asset = LUTAsset.allLooks.first(where: { $0.id == identifier }) else {
            markUnavailable(identifier, reason: "not bundled")
            return false
        }
        return prepare(asset)
    }

    /// The same, for a caller that already has the asset.
    ///
    /// `LUTAsset.allLooks` scans the imported-looks directory every time it is
    /// read, so resolving an identifier once per look turned filling the look
    /// strip into one directory scan per thumbnail.
    @discardableResult
    func prepare(_ asset: LUTAsset) -> Bool {
        let identifier = asset.id
        lock.lock()
        if textures[identifier] != nil { lock.unlock(); return true }
        if unavailable.contains(identifier) { lock.unlock(); return false }
        lock.unlock()

        guard let url = asset.url() else {
            markUnavailable(identifier, reason: "not bundled")
            return false
        }
        do {
            let cube = try CubeLUTParser().parse(contentsOf: url)
            let texture = try LUTTextureFactory.makeTexture(from: cube, device: device)
            texture.label = "LUT \(asset.name)"
            lock.lock(); textures[identifier] = texture; lock.unlock()
            return true
        } catch {
            markUnavailable(identifier, reason: "\(error)")
            return false
        }
    }

    /// Apple's published Apple Log to Rec.709 rendering LUT, used as the output
    /// transform for Apple Log projects.
    ///
    /// Deliberately not part of the creative look list: it is a technical
    /// conversion, not a look, and offering it next to Warm Cinema would invite
    /// applying it to footage it means nothing for.
    private var renderingTextures: [String: MTLTexture] = [:]

    /// Render-thread safe: a lock-guarded cache read that never parses. Returns
    /// nil until `prepareRenderingLUT` has finished. Callers refuse a missing
    /// LUT: there is no substitute display transform.
    func renderingTexture(named resourceName: String) -> MTLTexture? {
        lock.lock(); defer { lock.unlock() }
        return renderingTextures[resourceName]
    }

    /// Loads a technical transform. Call off the render thread: Apple's
    /// Log-to-Rec.709 cube is 65³, about 275,000 lines of text.
    @discardableResult
    func prepareRenderingLUT(named resourceName: String) -> MTLTexture? {
        lock.lock()
        if let existing = renderingTextures[resourceName] { lock.unlock(); return existing }
        if unavailable.contains(resourceName) { lock.unlock(); return nil }
        lock.unlock()

        guard let url = Bundle.lutResources.url(forResource: resourceName, withExtension: "cube") else {
            markUnavailable(resourceName, reason: "not bundled")
            return nil
        }
        do {
            let cube = try CubeLUTParser().parse(contentsOf: url)
            let texture = try LUTTextureFactory.makeTexture(from: cube, device: device)
            texture.label = "Rendering LUT \(resourceName)"
            lock.lock(); renderingTextures[resourceName] = texture; lock.unlock()
            return texture
        } catch {
            markUnavailable(resourceName, reason: "\(error)")
            return nil
        }
    }

    /// Loads every bundled look. A 33-point LUT costs about 287 KB of GPU
    /// memory, so preloading the built-in three is cheaper than the bookkeeping
    /// needed to load them one at a time. Imported looks are loaded on first
    /// selection instead, since there is no bound on how many there might be.
    func preloadBundledLooks() {
        for asset in LUTAsset.bundledLooks where asset.isBuiltIn {
            prepare(asset.id)
        }
    }

    /// Drops a look from the cache, so re-importing a file under the same name
    /// loads the new contents instead of serving the old texture.
    func forget(_ identifier: String) {
        lock.lock(); textures[identifier] = nil; unavailable.remove(identifier); lock.unlock()
    }

    private func markUnavailable(_ identifier: String, reason: String) {
        lock.lock(); unavailable.insert(identifier); lock.unlock()
        #if DEBUG
        print("LUT unavailable (\(identifier)): \(reason)")
        #endif
    }
}
