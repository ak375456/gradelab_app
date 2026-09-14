import Foundation
import CoreText

@main struct ValidateFonts {
    static func main() {
        let root = URL(fileURLWithPath: "dummy name/Resources/Fonts")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            if ["ttf", "otf"].contains(file.pathExtension.lowercased()) {
                CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
            }
        }
        let registry = FontRegistry.shared
        let entries = registry.entries()
        precondition(!entries.isEmpty && Set(entries.map(\.family)).count == entries.count, "Duplicate family rows")
        var supported = 0, unavailable = 0
        for entry in entries {
            for bold in [false, true] { for italic in [false, true] {
                if let font = registry.variant(entry.id, bold: bold, italic: italic) {
                    let traits = CTFontGetSymbolicTraits(font)
                    precondition(traits.contains(.boldTrait) == bold && traits.contains(.italicTrait) == italic)
                    precondition(CTFontCopyFamilyName(font) as String == entry.family, "Variant changed font family")
                    supported += 1
                } else { unavailable += 1 }
                var style = TextStyle(fontName: entry.id, isBold: bold, isItalic: italic)
                registry.normalize(&style)
                let actual = registry.variant(entry.id, bold: style.isBold, italic: style.isItalic) ?? registry.baseFont(entry.id, size: 32)
                let traits = CTFontGetSymbolicTraits(actual)
                precondition(traits.contains(.boldTrait) == style.isBold && traits.contains(.italicTrait) == style.isItalic)
            } }
        }
        precondition(supported > 0 && unavailable > 0)
        print("PASS: \(entries.count) unique font families; \(supported) exact supported combinations, \(unavailable) unsupported combinations disabled; selection normalization matches rendered traits.")
    }
}
