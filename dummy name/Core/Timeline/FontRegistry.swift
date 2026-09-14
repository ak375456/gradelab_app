import Foundation
import CoreText

/// Uses public CoreText registration and stable PostScript names in documents.
/// Bundled fonts register at runtime; no UIAppFonts list is required.
/// User imports are copied into Application Support before registration.
final class FontRegistry: @unchecked Sendable {
    static let shared = FontRegistry()
    struct Entry: Identifiable { let id: String; let family: String; let name: String }
    private let lock = NSLock()
    private var loaded = false
    private var registered = Set<URL>()
    /// PostScript names that came from a font the user imported, rather than
    /// one bundled with the app. Needed because the two are indistinguishable
    /// once CoreText has registered them, and only the imported ones are Pro.
    private var importedNames = Set<String>()
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
    func entries() -> [Entry] {
        prepare()
        let collection = CTFontCollectionCreateFromAvailableFonts(nil)
        let descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? []
        let faces: [Entry] = descriptors.compactMap { descriptor in
            guard let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String, !name.hasPrefix(".") else { return nil }
            return Entry(id: name, family: CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String ?? name,
                name: CTFontDescriptorCopyAttribute(descriptor, kCTFontDisplayNameAttribute) as? String ?? name)
        }
        // One basic face per family, not a separate row for every weight/style.
        return Dictionary(grouping: faces, by: \.family).values.compactMap { family in
            family.sorted { a, b in
                let ar = basicRank(a.id), br = basicRank(b.id)
                return ar == br ? a.id < b.id : ar < br
            }.first.map { Entry(id: $0.id, family: $0.family, name: $0.family) }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private func basicRank(_ name: String) -> Double {
        let font = CTFontCreateWithName(name as CFString, 32, nil)
        let traits = CTFontGetSymbolicTraits(font)
        let weight = (CTFontCopyTraits(font) as NSDictionary)[kCTFontWeightTrait] as? Double ?? 0
        return (traits.contains(.italicTrait) ? 10 : 0) + (traits.contains(.boldTrait) ? 10 : 0) + abs(weight)
    }
    func familyName(_ name: String?) -> String {
        guard let name else { return "System" }
        return CTFontCopyFamilyName(CTFontCreateWithName(name as CFString, 32, nil)) as String
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
        guard url.pathExtension.lowercased() == "ttf" else { throw TimelineError.invalid("Choose a .ttf font file.") }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard data.count <= 32_000_000,
              let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],
              let descriptor = descriptors.first,
              let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String else {
            throw TimelineError.invalid("This file is not a readable TrueType font.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("ttf")
        try data.write(to: target, options: .atomic)
        lock.lock(); defer { lock.unlock() }
        registerUnlocked(target, imported: true)
        return name
    }
}
