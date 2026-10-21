import SwiftUI
import AppKit

/// Text fields give up keyboard focus when the user commits (Return) or clicks the empty background,
/// the way native macOS forms do, instead of staying in edit mode.
enum Focus {
    @MainActor static func resign() { NSApp.keyWindow?.makeFirstResponder(nil) }
}

extension View {
    /// Runs `action` on Return, then releases focus.
    func commitsAndResigns(_ action: @escaping () -> Void = {}) -> some View {
        onSubmit { action(); Focus.resign() }
    }

    /// Clicking the empty background releases focus from any text field.
    func resignsFocusOnBackgroundTap() -> some View {
        background { Color.clear.contentShape(Rectangle()).onTapGesture { Focus.resign() } }
    }
}
