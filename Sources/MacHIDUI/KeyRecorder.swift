import SwiftUI
import AppKit
import MacHIDDomain

/// A button that records the next key press (or extra mouse button) made inside MacHID's own window.
/// It listens only while recording, and only to MacHID's own events, so it needs no system permission.
struct KeyRecorder: View {
    enum Capture { case keyOnly, keyOrMouse }

    let capture: Capture
    let current: InputTrigger?
    /// Also record a lone modifier key (fn, right Option, Caps Lock...). Used for shift mode triggers.
    var allowsModifierKeys = false
    let onRecord: (InputTrigger) -> Void

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button { recording ? stop() : start() } label: {
            Group {
                if recording { Text("Press a key…") }
                else if let current { Text(verbatim: KeyNames.trigger(current)) }
                else { Text("Record") }
            }
            .frame(minWidth: 110)
        }
        .buttonStyle(PillButtonStyle(selected: recording))
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        var mask: NSEvent.EventTypeMask = capture == .keyOrMouse ? [.keyDown, .otherMouseDown] : [.keyDown]
        if allowsModifierKeys { mask.insert(.flagsChanged) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            if event.type == .flagsChanged {
                // Only a press counts (the flag for that key is now set), not its release.
                guard let flag = KeyNames.modifierFlag(forCode: Int(event.keyCode)), event.modifierFlags.contains(flag) else { return nil }
                onRecord(InputTrigger(kind: .keyboard, code: Int(event.keyCode)))
            } else if event.type == .keyDown {
                if event.keyCode == 53 && event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                    stop()                                 // a bare Escape cancels the recording
                    return nil
                }
                onRecord(InputTrigger(kind: .keyboard, code: Int(event.keyCode), modifiers: KeyNames.modifiers(from: event.modifierFlags)))
            } else {
                onRecord(InputTrigger(kind: .mouseButton, code: event.buttonNumber))
            }
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}
