import Combine
import SwiftUI
import UIKit

/// Every keyboard equivalent in the app is described exactly once, here. Home,
/// the two editors and the Settings list all read these definitions, so a key
/// that moves cannot end up documented as the one it used to be.
///
/// Titles are `String(localized:)` rather than `LocalizedStringKey`, because a
/// key is also needed as a plain `String` for the Settings rows — see the note
/// on rendering below.
struct WorkspaceShortcut: Identifiable {
    enum Group: CaseIterable {
        case project, playback, editing, tools, view

        var title: String {
            switch self {
            case .project: String(localized: "Project")
            case .playback: String(localized: "Playback")
            case .editing: String(localized: "Editing")
            case .tools: String(localized: "Tools")
            case .view: String(localized: "View")
            }
        }
    }

    /// Where a shortcut is offered. Home and the two editors are separate
    /// responders, so the same key can mean different things in each without
    /// colliding — ⌘O imports on Home and adds a clip in the video editor.
    struct Scope: OptionSet {
        let rawValue: Int
        static let home = Scope(rawValue: 1 << 0)
        static let videoEditor = Scope(rawValue: 1 << 1)
        static let photoEditor = Scope(rawValue: 1 << 2)
        static let editors: Scope = [.videoEditor, .photoEditor]

        var title: String {
            switch self {
            case .home: String(localized: "Home")
            case .videoEditor: String(localized: "Video editor")
            case .photoEditor: String(localized: "Photo editor")
            default: ""
            }
        }
    }

    /// The identity of an action, independent of whether a screen is currently
    /// offering it. `EditorView` and `ImageEditorView` attach the work; the
    /// Settings list reads the same cases without needing any of it.
    enum Action: String, CaseIterable, Identifiable {
        case importVideos, importPhoto
        case addVideo, addImageOverlay, addAudio, saveProject, export
        case playPause, previousFrame, nextFrame, backTenFrames, forwardTenFrames
        case undo, redo, cutClip, copyClip, pasteClip, duplicateClip
        case splitAtPlayhead, deleteClips, toggleMarker
        case toggleSnapping, compareOriginal, zoomInTimeline, zoomOutTimeline, toggleMediaBin
        case toolTimeline, toolText, toolShape, toolAudio, toolColor
        case toolTransform, toolMask, toolMatte, toolBackground, toolSpeed

        var id: String { rawValue }

        // One switch, so a new action cannot be half-described.
        private var definition: (title: String, key: KeyEquivalent, modifiers: EventModifiers, group: Group, scope: Scope) {
            switch self {
            case .importVideos:
                (String(localized: "Import Videos"), "o", .command, .project, .home)
            case .importPhoto:
                (String(localized: "Import Photo"), "o", [.command, .shift], .project, .home)
            case .addVideo:
                (String(localized: "Add Video"), "o", .command, .project, .videoEditor)
            case .addImageOverlay:
                (String(localized: "Add Image Overlay"), "o", [.command, .shift], .project, .videoEditor)
            case .addAudio:
                (String(localized: "Add Audio"), "o", [.command, .option], .project, .videoEditor)
            case .saveProject:
                (String(localized: "Save Project"), "s", .command, .project, .editors)
            case .export:
                (String(localized: "Export"), "e", .command, .project, .editors)
            case .playPause:
                (String(localized: "Play / Pause"), .space, [], .playback, .videoEditor)
            case .previousFrame:
                (String(localized: "Previous Frame"), .leftArrow, [], .playback, .videoEditor)
            case .nextFrame:
                (String(localized: "Next Frame"), .rightArrow, [], .playback, .videoEditor)
            case .backTenFrames:
                (String(localized: "Back 10 Frames"), .leftArrow, .shift, .playback, .videoEditor)
            case .forwardTenFrames:
                (String(localized: "Forward 10 Frames"), .rightArrow, .shift, .playback, .videoEditor)
            case .undo:
                (String(localized: "Undo"), "z", .command, .editing, .editors)
            case .redo:
                (String(localized: "Redo"), "z", [.command, .shift], .editing, .editors)
            case .cutClip:
                (String(localized: "Cut Clip"), "x", .command, .editing, .videoEditor)
            case .copyClip:
                (String(localized: "Copy Clip"), "c", .command, .editing, .videoEditor)
            case .pasteClip:
                (String(localized: "Paste Clip"), "v", .command, .editing, .videoEditor)
            case .duplicateClip:
                (String(localized: "Duplicate Clip"), "d", .command, .editing, .videoEditor)
            case .splitAtPlayhead:
                (String(localized: "Split at Playhead"), "b", .command, .editing, .videoEditor)
            case .deleteClips:
                (String(localized: "Delete Selected Clips"), .delete, [], .editing, .videoEditor)
            case .toggleMarker:
                (String(localized: "Add / Remove Marker"), "m", [], .editing, .videoEditor)
            case .toggleSnapping:
                (String(localized: "Toggle Snapping"), "n", [], .view, .videoEditor)
            case .compareOriginal:
                (String(localized: "Compare Original"), "\\", [], .view, .editors)
            case .zoomInTimeline:
                (String(localized: "Zoom In Timeline"), "=", [], .view, .videoEditor)
            case .zoomOutTimeline:
                (String(localized: "Zoom Out Timeline"), "-", [], .view, .videoEditor)
            case .toggleMediaBin:
                (String(localized: "Show / Hide Media Bin"), "m", [.command, .shift], .view, .videoEditor)

            // Numbered in mode-bar order, so the bar itself teaches the keys:
            // the third tab is ⌘3. Text also answers to ⌘T, which is what a Mac
            // user reaches for without counting.
            case .toolTimeline:
                (String(localized: "Timeline Tool"), "1", .command, .tools, .videoEditor)
            case .toolText:
                (String(localized: "Text Tool"), "2", .command, .tools, .videoEditor)
            case .toolShape:
                (String(localized: "Shape Tool"), "3", .command, .tools, .videoEditor)
            case .toolAudio:
                (String(localized: "Audio Tool"), "4", .command, .tools, .videoEditor)
            case .toolColor:
                (String(localized: "Color Tool"), "5", .command, .tools, .videoEditor)
            case .toolTransform:
                (String(localized: "Transform Tool"), "6", .command, .tools, .videoEditor)
            case .toolMask:
                (String(localized: "Mask Tool"), "7", .command, .tools, .videoEditor)
            case .toolMatte:
                (String(localized: "Matte Tool"), "8", .command, .tools, .videoEditor)
            case .toolBackground:
                (String(localized: "Remove Background Tool"), "9", .command, .tools, .videoEditor)
            case .toolSpeed:
                (String(localized: "Speed Tool"), "0", .command, .tools, .videoEditor)
            }
        }

        /// A second key for the same action, where one key is the memorable one
        /// and another is the systematic one. Both are bound, and the Settings
        /// list prints both, so neither is a secret.
        var alternate: (key: KeyEquivalent, modifiers: EventModifiers)? {
            switch self {
            // ⌘T is what a Mac user reaches for; the numbers make every tool
            // reachable the same way.
            case .toolText: ("t", .command)
            // The blade is the most-used key in an edit, and the two NLE
            // conventions disagree: Premiere cuts with ⌘B, Final Cut and
            // Resolve with ⌘K. Answering to both costs nothing and means
            // nobody has to unlearn the one they already have.
            case .splitAtPlayhead: ("k", .command)
            default: nil
            }
        }

        var title: String { definition.title }
        var key: KeyEquivalent { definition.key }
        var modifiers: EventModifiers { definition.modifiers }
        var group: Group { definition.group }
        var scope: Scope { definition.scope }

        /// "⇧⌘O", in the order the system prints modifiers in a menu. An action
        /// with a second key prints both, separated by a space.
        var displayEquivalent: String {
            let primary = Self.display(key: key, modifiers: modifiers)
            guard let alternate else { return primary }
            return primary + "  " + Self.display(key: alternate.key, modifiers: alternate.modifiers)
        }

        private static func display(key: KeyEquivalent, modifiers: EventModifiers) -> String {
            var text = ""
            if modifiers.contains(.control) { text += "⌃" }
            if modifiers.contains(.option) { text += "⌥" }
            if modifiers.contains(.shift) { text += "⇧" }
            if modifiers.contains(.command) { text += "⌘" }
            return text + label(for: key)
        }

        /// SwiftUI carries the function keys as AppKit's private-use scalars
        /// (`NSLeftArrowFunctionKey` and friends), which have no glyph of their
        /// own — printing one directly draws an empty box. Each is mapped to
        /// the symbol the system prints in a menu.
        private static func label(for key: KeyEquivalent) -> String {
            switch key.character.unicodeScalars.first?.value {
            case 0x20: String(localized: "Space")
            case 0x08, 0x7F: "\u{232B}"          // ⌫
            case 0x1B: "esc"
            case 0x0D, 0x0A: "\u{21A9}"          // ↩
            case 0x09: "\u{21E5}"                // ⇥
            case 0xF700: "\u{2191}"              // ↑
            case 0xF701: "\u{2193}"              // ↓
            case 0xF702: "\u{2190}"              // ←
            case 0xF703: "\u{2192}"              // →
            case 0xF728: "\u{2326}"              // ⌦
            case 0xF729: "\u{2196}"              // ↖ Home
            case 0xF72B: "\u{2198}"              // ↘ End
            case 0xF72C: "\u{21DE}"              // ⇞ Page Up
            case 0xF72D: "\u{21DF}"              // ⇟ Page Down
            case 0xF739: "\u{2327}"              // ⌧ Clear
            default: String(key.character).uppercased()
            }
        }

        static func all(in scope: Scope) -> [Action] {
            allCases.filter { !$0.scope.intersection(scope).isEmpty }
        }
    }

    let action: Action
    var isEnabled = true
    let run: () -> Void

    var id: String { action.id }

    init(_ action: Action, isEnabled: Bool = true, run: @escaping () -> Void) {
        self.action = action
        self.isEnabled = isEnabled
        self.run = run
    }
}

extension View {
    /// Binds a catalogue equivalent to a button that spells itself out, so a
    /// screen with its own layout still cannot disagree with the Settings list.
    func workspaceShortcut(_ action: WorkspaceShortcut.Action) -> some View {
        keyboardShortcut(action.key, modifiers: action.modifiers)
    }
}

/// The keyboard icon in an editor header: a menu listing what is available
/// right now, plus the buttons that actually own the key equivalents.
///
/// The equivalents deliberately do **not** live on the menu's own buttons.
/// SwiftUI builds menu content lazily, so nothing inside it is registered with
/// UIKit until the menu has been opened — measured on Mac Catalyst, a menu of
/// three shortcuts produced zero `UIKeyCommand`s, which is why none of the
/// editor keys did anything on Mac. They ride on `keyOwners` instead, which is
/// always in the view hierarchy. Each key still has exactly one owner, so the
/// menu shows the equivalent as a subtitle rather than binding it a second time.
struct WorkspaceShortcutMenu: View {
    let shortcuts: [WorkspaceShortcut]
    var isEnabled = true
    @State private var isEditingText = false

    /// Leave Space, arrows, Delete and the standard editing equivalents to the
    /// field's responder while entering text or a numeric value.
    private var isActive: Bool { isEnabled && !isEditingText }

    var body: some View {
        Menu {
            ForEach(WorkspaceShortcut.Group.allCases, id: \.self) { group in
                let entries = shortcuts.filter { $0.action.group == group }
                if !entries.isEmpty {
                    Section(group.title) {
                        ForEach(entries) { shortcut in
                            // `Text(_: String)` deliberately: the title is
                            // already translated, and `LocalizedStringKey` on a
                            // translated string is a lookup that always misses.
                            Button(action: shortcut.run) {
                                Text(shortcut.action.title)
                                Text(shortcut.action.displayEquivalent)
                            }
                            .disabled(!shortcut.isEnabled)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "keyboard").frame(width: 36, height: 44)
        }
        .accessibilityLabel("Keyboard shortcuts")
        .help("Keyboard shortcuts")
        .disabled(!isActive)
        .background { keyOwners }
        .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)
            .merge(with: NotificationCenter.default.publisher(for: UITextView.textDidBeginEditingNotification))) { _ in
                isEditingText = true
            }
        .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidEndEditingNotification)
            .merge(with: NotificationCenter.default.publisher(for: UITextView.textDidEndEditingNotification))) { _ in
                isEditingText = false
            }
    }

    /// Zero-size and never drawn, but present, which is the whole point — a
    /// button has to be in the hierarchy for its equivalent to reach UIKit.
    /// `disabled` still suppresses registration, so an unavailable action's key
    /// stays inert exactly as its menu entry is greyed out.
    private var keyOwners: some View {
        ZStack {
            ForEach(shortcuts) { shortcut in
                Button(action: shortcut.run) { Color.clear }
                    .keyboardShortcut(shortcut.action.key, modifiers: shortcut.action.modifiers)
                    .disabled(!shortcut.isEnabled)
                if let alternate = shortcut.action.alternate {
                    Button(action: shortcut.run) { Color.clear }
                        .keyboardShortcut(alternate.key, modifiers: alternate.modifiers)
                        .disabled(!shortcut.isEnabled)
                }
            }
        }
        .frame(width: 0, height: 0)
        .disabled(!isActive)
        .accessibilityHidden(true)
    }
}

/// The reference list, shown in Settings. It reads the same `Action` cases the
/// editors attach their work to, so it cannot drift from the live equivalents.
struct WorkspaceShortcutList: View {
    private let scopes: [WorkspaceShortcut.Scope] = [.home, .videoEditor, .photoEditor]

    var body: some View {
        List {
            ForEach(scopes, id: \.rawValue) { scope in
                Section {
                    ForEach(WorkspaceShortcut.Action.all(in: scope)) { action in
                        LabeledContent {
                            // Monospaced so ⌘/⇧/⌥ line up down the column.
                            Text(action.displayEquivalent)
                                .font(.callout.monospaced())
                                .foregroundStyle(AppColors.textSecondary)
                        } label: {
                            Text(action.title).foregroundStyle(AppColors.textPrimary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: { Text(scope.title) }
            }
            Section {
                Text("A text field keeps its own typing, selection and cut, copy and paste while you are in it. Editor shortcuts resume when you leave the field.")
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
            }
        }
        .navigationTitle("Keyboard shortcuts")
        .navigationBarTitleDisplayMode(.inline)
    }
}
