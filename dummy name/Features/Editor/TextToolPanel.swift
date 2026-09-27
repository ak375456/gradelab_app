import SwiftUI
import UniformTypeIdentifiers

struct TextToolPanel: View {
    @ObservedObject var model: EditorViewModel
    let editContent: () -> Void
    // Owned by EditorView so a redraw of this panel cannot bounce the user back to Style.
    @Binding var section: String
    @Binding var appearance: String
    @Binding var animationSlot: TextAnimationSlot
    @State private var fonts = false
    @State private var importer = false
    @State private var fontError: String?
    @State private var activeProperty: AnimatableProperty?
    @State private var selectedKeyframe: TimelineTime?
    @State private var keyframeHelp = false
    @State private var confirmsRemoveAll = false
    private let sections = ["Style", "Font", "Format", "Transform", "Animation", "Appearance"]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.selectedTextCount > 1 {
                Label("\(model.selectedTextCount) text layers selected", systemImage: "square.stack.3d.up.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.accent)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppColors.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            } else {
                Button(action: editContent) {
                    HStack { Text(model.selectedText.flatMap { $0.text.isEmpty ? nil : $0.text } ?? "Enter text").lineLimit(2); Spacer(); Image(systemName: "pencil") }
                        .font(.subheadline).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                }.accessibilityLabel("Edit text")
            }
            tabs(sections, selection: $section, badged: model.hasTextAnimation ? ["Animation"] : [])
            if let clip = model.selectedText {
                switch section {
                case "Style":
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64, maximum: 84), spacing: 10)], spacing: 10) {
                        ForEach(TextStylePreset.builtIn) { preset in
                            Button { model.applyTextPreset(preset) } label: {
                                TextPresetTile(preset: preset, selected: clip.gradient == preset.gradient && clip.color == preset.color && clip.strokeColor == preset.strokeColor && clip.strokeWidth == preset.strokeWidth && clip.backgroundColor == preset.backgroundColor && clip.backgroundOpacity == preset.backgroundOpacity)
                            }.accessibilityLabel(preset.name)
                        }
                    }
                case "Font":
                    HStack(spacing: 8) {
                        Button { fonts.toggle() } label: {
                            HStack {
                                Text(FontRegistry.shared.familyName(clip.style.fontName))
                                    .font(clip.style.fontName.map { .custom($0, size: 16) } ?? .body)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: fonts ? "chevron.up" : "chevron.down")
                                    .font(.caption.weight(.semibold))
                            }
                            .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 44)
                            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                        }
                        .accessibilityLabel(fonts ? "Close font menu" : "Choose font")
                        .popover(isPresented: $fonts, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                            FontMenu(selected: model.selectedText?.style.fontName) { name in
                                model.editText("Font") { $0.style.fontName = name }
                            }
                            .presentationCompactAdaptation(.popover)
                        }
                        VStack(spacing: 0) {
                            Button { cycleFont(-1) } label: {
                                Image(systemName: "chevron.up").frame(width: 38, height: 22)
                            }.accessibilityLabel("Previous font")
                            Button { cycleFont(1) } label: {
                                Image(systemName: "chevron.down").frame(width: 38, height: 22)
                            }.accessibilityLabel("Next font")
                        }
                        .font(.caption.weight(.bold))
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                    }
                    Button { importer = true } label: {
                        HStack(spacing: 6) {
                            Label("Import TTF font", systemImage: "square.and.arrow.down")
                                .foregroundStyle(ProStore.shared.hasPro ? AppColors.accent : ProStyle.gold)
                            if !ProStore.shared.hasPro { ProInlineTag() }
                        }.frame(minHeight: 44)
                    }
                    keyframeHeader
                    animated(.fontSize, 6...2048)
                case "Format":
                    HStack {
                        toggle(String(localized: "Bold"), symbol: "bold", \.style.isBold)
                            .disabled(FontRegistry.shared.variant(clip.style.fontName, bold: !clip.style.isBold, italic: clip.style.isItalic) == nil)
                            .opacity(FontRegistry.shared.variant(clip.style.fontName, bold: !clip.style.isBold, italic: clip.style.isItalic) == nil ? 0.3 : 1)
                        toggle(String(localized: "Italic"), symbol: "italic", \.style.isItalic)
                            .disabled(FontRegistry.shared.variant(clip.style.fontName, bold: clip.style.isBold, italic: !clip.style.isItalic) == nil)
                            .opacity(FontRegistry.shared.variant(clip.style.fontName, bold: clip.style.isBold, italic: !clip.style.isItalic) == nil ? 0.3 : 1)
                        toggle(String(localized: "Underline"), symbol: "underline", \.style.isUnderlined)
                    }
                    Text("Bold and Italic are available only when this font includes that variation.").font(.caption2).foregroundStyle(.secondary)
                    Picker("Capitalization", selection: binding(\.style.caseMode)) { ForEach(TextStyle.CaseMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                    Picker("Alignment", selection: binding(\.style.alignment)) { ForEach(TextStyle.Alignment.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                    keyframeHeader
                    animated(.characterSpacing, -20...100)
                    animated(.lineSpacing, 0...300)
                    animated(.layoutWidth, 0.05...1.5)
                case "Animation":
                    TextAnimationPanel(model: model, slot: $animationSlot)
                case "Transform":
                    keyframeHeader
                    number(String(localized: "Duration (s)"), Binding(get: { model.selectedText?.placement.duration.seconds ?? 3 }, set: model.setTextDuration), 0.1...600, reset: 3)
                    CanvasAlignmentRow(model: model)
                    animated(.positionX, -1...2)
                    animated(.positionY, -1...2)
                    animated(.scale, 0.05...6)
                    Toggle("Lock aspect ratio", isOn: binding(\.transform.locksAspectRatio))
                    animated(.widthScale, 0.1...6)
                    animated(.heightScale, 0.1...6)
                    // Wide enough for two full turns by dragging; type more for further spins.
                    animated(.rotation, -720...720)
                    number(String(localized: "Anchor X"), value(\.transform.anchorX), 0...1, reset: 0.5)
                    number(String(localized: "Anchor Y"), value(\.transform.anchorY), 0...1, reset: 0.5)
                    animated(.opacity, 0...1)
                    Picker("Blend", selection: binding(\.blendMode)) { ForEach(VisualBlendMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                    // Written out twice rather than as a ternary inside `Text`:
                    // only a plain literal is reliably extracted for translation.
                    if model.selectedTextCount > 1 {
                        Text("Position moves every selected title together, so they keep their spacing.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Drag text in the preview. Pinch to resize; turn with two fingers to rotate.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                default:
                    tabs(["Fill", "Gradient", "Stroke", "Background", "Shadow", "Glow", "Curve"], selection: $appearance)
                    keyframeHeader
                    switch appearance {
                    case "Fill": animatedColor(.textColor); animated(.opacity, 0...1)
                    case "Gradient":
                        Toggle("Gradient fill", isOn: Binding(get: { clip.gradient != nil }, set: { on in
                            model.editText { c in c.gradient = on ? (c.gradient ?? .init(start: c.color, end: GradientFill().end)) : nil }
                        })).font(.caption).frame(minHeight: 44)
                        if clip.gradient != nil {
                            ColorPicker("Start color", selection: colorBinding(gradient(\.start)), supportsOpacity: true).font(.caption).frame(minHeight: 44)
                            ColorPicker("End color", selection: colorBinding(gradient(\.end)), supportsOpacity: true).font(.caption).frame(minHeight: 44)
                            number(String(localized: "Angle"), gradient(\.angleDegrees), -180...180, reset: 90)
                        } else {
                            Text("A gradient replaces the flat text color. Stroke, background, shadow and glow keep their own colors.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    case "Stroke": animatedColor(.strokeColor); animated(.strokeWidth, 0...64)
                    case "Background":
                        animatedColor(.backgroundColor)
                        animated(.backgroundOpacity, 0...1)
                        animated(.backgroundPadding, 0...150)
                        animated(.cornerRadius, 0...150)
                    case "Shadow":
                        animatedColor(.shadowColor)
                        animated(.shadowOpacity, 0...1)
                        animated(.shadowRadius, 0...100)
                        animated(.shadowOffsetX, -150...150)
                        animated(.shadowOffsetY, -150...150)
                    case "Glow":
                        animatedColor(.glowColor)
                        animated(.glowOpacity, 0...1)
                        animated(.glowRadius, 0...100)
                    default: animated(.curve, -1...1)
                    }
                }
            }
        }.padding(.horizontal, 20).padding(.bottom, 20)
        .onChange(of: model.selectedClipID) { _, _ in activeProperty = nil; selectedKeyframe = nil }
        .sheet(isPresented: $keyframeHelp) { KeyframeHelp() }
        .confirmationDialog("Remove all animation from this text?", isPresented: $confirmsRemoveAll, titleVisibility: .visible) {
            Button("Remove All Animation", role: .destructive) { model.removeAllAnimation(); activeProperty = nil; selectedKeyframe = nil }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Every animated property keeps the value you can see now.") }
        .fileImporter(isPresented: $importer, allowedContentTypes: [UTType(filenameExtension: "ttf") ?? .font]) { result in
            do { let name = try FontRegistry.shared.importFont(result.get()); model.editText { $0.style.fontName = name } }
            catch { fontError = error.localizedDescription }
        }
        .alert("Font import", isPresented: Binding(get: { fontError != nil }, set: { if !$0 { fontError = nil } })) { Button("OK") { fontError = nil } } message: { Text(fontError ?? "") }
    }
    private var keyframeHeader: some View {
        KeyframeSectionHeader(model: model, help: $keyframeHelp, confirmsRemoveAll: $confirmsRemoveAll)
    }

    private func cycleFont(_ direction: Int) {
        var choices: [String?] = [nil]
        choices.append(contentsOf: FontRegistry.shared.entries().map { Optional($0.id) })
        guard !choices.isEmpty else { return }
        let selected = model.selectedText?.style.fontName
        let current = choices.firstIndex { choice in
            switch (choice, selected) {
            case (nil, nil): return true
            case (.some(let choice), .some(let selected)):
                return FontRegistry.shared.familyName(choice) == FontRegistry.shared.familyName(selected)
            default: return false
            }
        } ?? 0
        let next = (current + direction + choices.count) % choices.count
        model.editText("Font", immediate: true) { $0.style.fontName = choices[next] }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func animated(_ property: AnimatableProperty, _ range: ClosedRange<Double>) -> some View {
        KeyframePropertyRow(model: model, property: property, range: range,
                            activeProperty: $activeProperty, selectedKeyframe: $selectedKeyframe)
    }

    private func animatedColor(_ property: AnimatableProperty) -> some View {
        KeyframeColorRow(model: model, property: property,
                         activeProperty: $activeProperty, selectedKeyframe: $selectedKeyframe)
    }

    private func binding<T>(_ key: WritableKeyPath<TextClip, T>) -> Binding<T> {
        let selected = model.selectedText ?? TextClip(placement: .init(id: UUID(), trackID: UUID(), timelineStart: .zero, duration: .zero))
        return Binding(get: { (model.selectedText ?? selected)[keyPath: key] }, set: { v in
            guard model.selectedText?.id == selected.id else { return }
            model.editText { $0[keyPath: key] = v }
        })
    }
    private func value(_ key: WritableKeyPath<TextClip, Double>) -> Binding<Double> { binding(key) }
    private func gradient<T>(_ key: WritableKeyPath<GradientFill, T>) -> Binding<T> {
        Binding(get: { (model.selectedText?.gradient ?? .init())[keyPath: key] }, set: { v in model.editText { c in
            var g = c.gradient ?? .init(); g[keyPath: key] = v; c.gradient = g
        } })
    }
    private func decoration<T>(_ key: WritableKeyPath<TextDecoration, T>) -> Binding<T> {
        Binding(get: { (model.selectedText?.decoration ?? .init())[keyPath: key] }, set: { v in model.editText { c in
            var d = c.decoration ?? .init(); d[keyPath: key] = v; c.decoration = d
        } })
    }
    private func number(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, reset: Double) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.caption); Spacer()
                // Presented entry, not an inline field: an inline one writes the parsed
                // value back on focus, which republishes the project and rebuilds this
                // panel before the keyboard finishes presenting.
                NumericEntryLabel(title: title, text: value.wrappedValue.formatted(.number.precision(.fractionLength(0...2))),
                                  value: value.wrappedValue, range: range, tint: .primary) { typed in
                    value.wrappedValue = typed; model.flushGradeHistory()
                }.font(.caption.monospacedDigit())
            }
            ResettableSlider(value: value, range: range, resetValue: reset, label: title,
                             onEditingChanged: { if !$0 { model.flushGradeHistory() } })
        }
    }
    private func toggle(_ title: String, symbol: String, _ key: WritableKeyPath<TextClip, Bool>) -> some View {
        Button { model.editText { $0[keyPath: key].toggle() } } label: { Image(systemName: symbol).frame(width: 44, height: 44)
            .background(model.selectedText?[keyPath: key] == true ? Color.cyan.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 8))
            // Off, the background is clear, which takes no clicks — so the
            // whole 44x44 has to be asked for or only the glyph answers.
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }.accessibilityLabel(title).accessibilityValue(model.selectedText?[keyPath: key] == true ? "On" : "Off")
    }
    /// Display only. The tab's identity stays the English string — `section` is
    /// switched on and bound from outside this view — so localizing the array
    /// itself would break the switch.
    private static func tabLabel(_ value: String) -> String {
        switch value {
        case "Style": String(localized: "Style")
        case "Font": String(localized: "Font")
        case "Format": String(localized: "Format")
        case "Transform": String(localized: "Transform")
        case "Animation": String(localized: "Animation")
        case "Appearance": String(localized: "Appearance")
        default: value
        }
    }
    /// `badged` marks a tab that has something set behind it - one dot, rather
    /// than another icon on the timeline.
    private func tabs(_ values: [String], selection: Binding<String>, badged: Set<String> = []) -> some View {
        ScrollView(.horizontal) { HStack(spacing: 16) { ForEach(values, id: \.self) { v in
            Button { selection.wrappedValue = v } label: {
                HStack(spacing: 3) {
                    Text(Self.tabLabel(v))
                    if badged.contains(v) { Circle().fill(Color.cyan).frame(width: 4, height: 4) }
                }
            }
            .font(.caption.weight(.medium)).frame(minHeight: 36)
            .foregroundStyle(selection.wrappedValue == v ? Color.cyan : .secondary)
        } } }.scrollIndicators(.hidden)
    }
    private func color(_ title: String, _ key: WritableKeyPath<TextClip, RGBAColor>) -> some View { ColorPicker(title, selection: colorBinding(binding(key)), supportsOpacity: true).font(.caption).frame(minHeight: 44) }
    private func decorationColor(_ title: String, _ key: WritableKeyPath<TextDecoration, RGBAColor>) -> some View { ColorPicker(title, selection: colorBinding(decoration(key)), supportsOpacity: true).font(.caption).frame(minHeight: 44) }
    private func colorBinding(_ value: Binding<RGBAColor>) -> Binding<Color> {
        Binding(get: { let c = value.wrappedValue; return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha) }, set: { color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
            value.wrappedValue = .init(red: r, green: g, blue: b, alpha: a)
        })
    }
}

private struct FontMenu: View {
    let selected: String?
    let choose: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var choices: [FontChoice] = []
    @State private var isLoading = true

    /// A row's search text and Pro status, worked out once when the list loads.
    /// Both used to be recomputed for every row on every keystroke - the Pro
    /// check against 35 prefixes, the selection check by creating a `CTFont` -
    /// which is what made typing in the search field stall.
    private struct FontChoice: Identifiable {
        let id: String
        let family: String
        let name: String
        let searchKey: String
        let requiresPro: Bool
    }

    /// Resolved once per redraw rather than once per row.
    private var selectedFamily: String? { selected.map { FontRegistry.shared.familyName($0) } }

    private var matches: [FontChoice] {
        guard !query.isEmpty else { return choices }
        let needle = Self.searchKey(query)
        return choices.filter { $0.searchKey.contains(needle) }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search fonts", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 12).frame(height: 42)
            .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 9))
            if isLoading {
                Spacer()
                ProgressView().accessibilityLabel("Loading fonts")
                Spacer()
            } else {
                ScrollView {
                    let family = selectedFamily
                    LazyVStack(spacing: 4) {
                        fontRow(name: String(localized: "System"), fontName: nil, needsPro: false, isSelected: selected == nil)
                        // Every face stays choosable: the point is to see the title
                        // set in it. The badge says which ones need Pro to export.
                        ForEach(matches) { font in
                            fontRow(name: font.name, fontName: font.id, needsPro: font.requiresPro,
                                    isSelected: family == font.family)
                        }
                    }
                }
            }
        }
        .padding(12).frame(width: 330, height: 440)
        .background(AppColors.surface)
        .task { await load() }
        .preferredColorScheme(.dark)
    }

    /// CoreText enumerates every installed face to build this list. Off the main
    /// actor, so opening the menu cannot freeze the editor behind it.
    private func load() async {
        guard isLoading else { return }
        let entries = await Task.detached(priority: .userInitiated) { FontRegistry.shared.entries() }.value
        let hasPro = ProStore.shared.hasPro
        choices = entries.map { entry in
            FontChoice(id: entry.id, family: entry.family, name: entry.name,
                       searchKey: Self.searchKey(entry.name + " " + entry.family),
                       requiresPro: !hasPro && ProAccessPolicy.fontRequiresPro(family: entry.family))
        }
        isLoading = false
    }

    /// Case- and accent-insensitive, matching what `localizedCaseInsensitiveContains`
    /// did per row, but folded once instead of once per comparison.
    private static func searchKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func fontRow(name: String, fontName: String?, needsPro: Bool, isSelected: Bool) -> some View {
        Button {
            if isSelected { dismiss() }
            else { choose(fontName) }
        } label: {
            HStack(spacing: 8) {
                Text(name).font(fontName.map { .custom($0, size: 18) } ?? .body)
                    .lineLimit(1)
                if needsPro { ProBadge(compact: true) }
                Spacer()
                if isSelected { Image(systemName: "checkmark").foregroundStyle(AppColors.accent) }
            }
            .padding(.horizontal, 10).frame(minHeight: 42)
            .background(isSelected ? AppColors.accent.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
