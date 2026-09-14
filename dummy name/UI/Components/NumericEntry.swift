//
//  NumericEntry.swift
//  GradeLab
//
//  Typing an exact value for any slider in the app.
//
//  Deliberately NOT an inline TextField bound to the model. Those write the parsed
//  value back as soon as the field takes focus, which mutates the project, republishes
//  it and re-renders the panel while the keyboard is still presenting — the keyboard is
//  cancelled and the control loses its state. Entry is presented instead, so it survives
//  any redraw of the panel underneath and never covers the control it belongs to.
//

import SwiftUI

struct NumericEntryRequest: Identifiable {
    let id = UUID()
    var title: String
    var value: Double
    var range: ClosedRange<Double>
    /// Receives a value already clamped to `range`.
    var apply: (Double) -> Void
}

struct NumericEntryAction {
    fileprivate var handler: (NumericEntryRequest) -> Void
    func callAsFunction(_ title: String, value: Double, range: ClosedRange<Double>, apply: @escaping (Double) -> Void) {
        handler(.init(title: title, value: value, range: range, apply: apply))
    }
    var isAvailable: Bool { available }
    fileprivate var available = true
}

private struct NumericEntryKey: EnvironmentKey {
    static let defaultValue = NumericEntryAction(handler: { _ in }, available: false)
}

extension EnvironmentValues {
    /// Ask the nearest `numericEntryHost()` to collect an exact value from the user.
    var requestNumericEntry: NumericEntryAction {
        get { self[NumericEntryKey.self] }
        set { self[NumericEntryKey.self] = newValue }
    }
}

extension View {
    /// Hosts numeric entry for everything below it. Attach once per presented screen:
    /// a sheet has its own presentation context and needs its own host.
    func numericEntryHost() -> some View { modifier(NumericEntryHost()) }
}

private struct NumericEntryHost: ViewModifier {
    @State private var request: NumericEntryRequest?
    @State private var draft = ""

    func body(content: Content) -> some View {
        content
            .environment(\.requestNumericEntry, NumericEntryAction(handler: { request in
                draft = NumericEntryFormat.plain(request.value)
                self.request = request
            }))
            .alert(request?.title ?? "Value",
                   isPresented: Binding(get: { request != nil }, set: { if !$0 { request = nil } }),
                   presenting: request) { pending in
                TextField("Value", text: $draft)
                    .keyboardType(.numbersAndPunctuation)
                    .submitLabel(.done)
                Button("Cancel", role: .cancel) { request = nil }
                Button("Set") {
                    if let typed = NumericEntryFormat.parse(draft) {
                        pending.apply(min(pending.range.upperBound, max(pending.range.lowerBound, typed)))
                    }
                    request = nil
                }
            } message: { pending in
                Text("Enter a value between \(NumericEntryFormat.plain(pending.range.lowerBound)) and \(NumericEntryFormat.plain(pending.range.upperBound)).")
            }
    }
}

enum NumericEntryFormat {
    /// Plain digits to edit, never the decorated read-out (which carries + and % signs).
    static func plain(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        return rounded == rounded.rounded() && abs(rounded) < 1e15 ? String(Int(rounded)) : String(rounded)
    }
    static func parse(_ text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: ",", with: ".").filter { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(cleaned)
    }
}

/// The tappable read-out shared by every slider row.
struct NumericEntryLabel: View {
    @Environment(\.requestNumericEntry) private var requestNumericEntry
    let title: String
    let text: String
    let value: Double
    let range: ClosedRange<Double>
    var tint: Color = AppColors.accent
    let apply: (Double) -> Void

    var body: some View {
        Button { requestNumericEntry(title, value: value, range: range, apply: apply) } label: {
            Text(text).foregroundStyle(tint).contentTransition(.numericText(value: value))
                .frame(minHeight: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!requestNumericEntry.isAvailable)
        .accessibilityLabel("\(title) value")
        .accessibilityHint("Enter an exact value")
    }
}
