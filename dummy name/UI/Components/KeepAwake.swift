//
//  KeepAwake.swift
//  GradeLab
//

import SwiftUI

/// Holds the screen awake while `isActive` is true.
///
/// An export is a long job with nothing on screen to touch, so the idle timer
/// runs out part way through and the display locks behind a running encode.
/// The flag belongs to the process rather than to a view, so it is cleared
/// both when the job ends and when the view goes away — a sheet torn down
/// mid-export must not leave the device unable to sleep.
private struct KeepAwakeModifier: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: isActive, initial: true) { _, active in
                UIApplication.shared.isIdleTimerDisabled = active
            }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

extension View {
    /// Keeps the display from sleeping for as long as `isActive` is true.
    func keepsScreenAwake(_ isActive: Bool) -> some View {
        modifier(KeepAwakeModifier(isActive: isActive))
    }
}
