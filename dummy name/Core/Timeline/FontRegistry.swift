import Foundation
import CoreText

/// Uses public CoreText registration and stable PostScript names in documents.
/// Bundled fonts register at runtime; no UIAppFonts list is required.
/// User imports are copied into Application Support before registration.
final class FontRegistry: @unchecked Sendable {
    static let shared = FontRegistry()
    struct Entry: Identifiable, Sendable { let id: String; let family: String; let name: String }
    private let lock = NSLock()
    private var loaded = false
    private var registered = Set<URL>()
    /// PostScript names that came from a font the user imported, rather than
    /// one bundled with the app. Needed because the two are indistinguishable
    /// once CoreText has registered them, and only the imported ones are Pro.
    private var importedNames = Set<String>()
    /// The one-face-per-family list, which is stable until a font is
    /// registered. Building it walks every face CoreText knows about - several
    /// hundred on an iPad - so recomputing it per keystroke of the font search,
    /// and again on every tap of the next/previous arrows, is what made the
    /// Font panel hang.
    private var cachedEntries: [Entry]?
    /// Bumped by every registration, so a list built outside the lock can tell
    /// whether a font arrived while it was working.
    private var registrations = 0
    /// PostScript name to family. `familyName` is called from view bodies - the
    /// Font panel's button, the selected row in the font list - and each miss
    /// instantiates a `CTFont` just to read one string off it.
    private var familyNames: [String: String] = [:]
    private var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("GradeLab/Fonts", isDirectory: true)
    }
    func prepare() {
        lock.lock(); defer { lock.unlock() }
        guard !loaded else { return }; loaded = true
        let bundled = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.resourceURL : nil
        let userDirectory = directory
        for root in [bundled, userDirectory].compactMap({ $0 }) {
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            while let url = files?.nextObject() as? URL {
                if ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
                    registerUnlocked(url, imported: root == userDirectory)
                }
            }
        }
    }
    private func registerUnlocked(_ url: URL, imported: Bool = false) {
        guard registered.insert(url).inserted else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        // A new face means a new family list. Always called under the lock.
        cachedEntries = nil; registrations += 1
        // A name resolved before this face was registered resolved to a
        // fallback family, so those answers are dropped too.
        familyNames.removeAll()
        guard imported else { return }
        let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
        for descriptor in descriptors {
            if let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String {
                importedNames.insert(name)
            }
        }
    }
    /// Whether this face came from the user's own font file.
    ///
    /// `prepare()` runs first and takes the lock itself, so it is called before
    /// this one locks rather than inside it - `NSLock` is not recursive.
    func isImported(_ name: String?) -> Bool {
        guard let name else { return false }
        prepare()
        lock.lock(); defer { lock.unlock() }
        return importedNames.contains(name)
    }
    /// Safe to call off the main thread, and worth doing: the first build is the
    /// slow one and everything after it is served from the cache.
    func entries() -> [Entry] {
        prepare()
        lock.lock()
        if let cachedEntries { lock.unlock(); return cachedEntries }
        let generation = registrations
        lock.unlock()
        // Built OUTSIDE the lock. It walks every installed face, and a main-thread
        // `prepare()` or `isImported()` must not have to queue behind it.
        let computed = availableFamilies()
        lock.lock(); defer { lock.unlock() }
        // A font registered while this was building leaves the new list already
        // stale, so it is returned but not kept; the next call rebuilds.
        if registrations == generation { cachedEntries = computed }
        return computed
    }
    /// One basic face per family, not a separate row for every weight and style.
    ///
    /// Every face is ranked ONCE. Ranking inside a sort comparator, as this used
    /// to, asked CoreText for the same face's traits over and over.
    private func availableFamilies() -> [Entry] {
        let collection = CTFontCollectionCreateFromAvailableFonts(nil)
        let descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? []
        var basic: [String: (rank: Double, name: String)] = [:]
        for descriptor in descriptors {
            guard let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String,
                  !name.hasPrefix(".") else { continue }
            let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String ?? name
            let rank = basicRank(descriptor, name: name)
            if let held = basic[family], (held.rank, held.name) <= (rank, name) { continue }
            basic[family] = (rank, name)
        }
        return basic.map { Entry(id: $0.value.name, family: $0.key, name: $0.key) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    /// Ranks a face without instantiating the font. The descriptor already
    /// carries the traits dictionary, and creating a `CTFont` for every installed
    /// face just to read two numbers out of it is the expensive half of the list.
    private func basicRank(_ descriptor: CTFontDescriptor, name: String) -> Double {
        guard let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? NSDictionary else {
            return basicRank(name)
        }
        let symbolic = CTFontSymbolicTraits(rawValue: traits[kCTFontSymbolicTrait] as? UInt32 ?? 0)
        let weight = traits[kCTFontWeightTrait] as? Double ?? 0
        return (symbolic.contains(.italicTrait) ? 10 : 0) + (symbolic.contains(.boldTrait) ? 10 : 0) + abs(weight)
    }
    private func basicRank(_ name: String) -> Double {
        let font = CTFontCreateWithName(name as CFString, 32, nil)
        let traits = CTFontGetSymbolicTraits(font)
        let weight = (CTFontCopyTraits(font) as NSDictionary)[kCTFontWeightTrait] as? Double ?? 0
        return (traits.contains(.italicTrait) ? 10 : 0) + (traits.contains(.boldTrait) ? 10 : 0) + abs(weight)
    }
    func familyName(_ name: String?) -> String {
        guard let name else { return "System" }
        lock.lock()
        if let cached = familyNames[name] { lock.unlock(); return cached }
        lock.unlock()
        let family = CTFontCopyFamilyName(CTFontCreateWithName(name as CFString, 32, nil)) as String
        lock.lock(); familyNames[name] = family; lock.unlock()
        return family
    }
    func baseFont(_ name: String?, size: Double) -> CTFont {
        prepare()
        return name.map { CTFontCreateWithName($0 as CFString, size, nil) } ?? CTFontCreateUIFontForLanguage(.system, size, nil)!
    }
    func variant(_ name: String?, size: Double = 32, bold: Bool, italic: Bool) -> CTFont? {
        let base = baseFont(name, size: size)
        let mask: CTFontSymbolicTraits = [.boldTrait, .italicTrait]
        var requested: CTFontSymbolicTraits = []
        if bold { requested.insert(.boldTrait) }; if italic { requested.insert(.italicTrait) }
        guard let result = CTFontCreateCopyWithSymbolicTraits(base, size, nil, requested, mask),
              CTFontGetSymbolicTraits(result).intersection(mask) == requested,
              CTFontCopyFamilyName(result) == CTFontCopyFamilyName(base) else { return nil }
        return result
    }
    func normalize(_ style: inout TextStyle) {
        if variant(style.fontName, bold: style.isBold, italic: style.isItalic) != nil { return }
        if style.isBold, variant(style.fontName, bold: true, italic: false) != nil { style.isItalic = false; return }
        if style.isItalic, variant(style.fontName, bold: false, italic: true) != nil { style.isBold = false; return }
        let traits = CTFontGetSymbolicTraits(baseFont(style.fontName, size: style.fontSize))
        style.isBold = traits.contains(.boldTrait); style.isItalic = traits.contains(.italicTrait)
    }
    func importFont(_ url: URL) throws -> String {
        guard url.pathExtension.lowercased() == "ttf" else { throw TimelineError.invalid(String(localized: "Choose a .ttf font file.")) }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard data.count <= 32_000_000,
              let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],
              let descriptor = descriptors.first,
              let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String else {
            throw TimelineError.invalid(String(localized: "This file is not a readable TrueType font."))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("ttf")
        try data.write(to: target, options: .atomic)
        lock.lock(); defer { lock.unlock() }
        registerUnlocked(target, imported: true)
        return name
    }
}
