import CoreGraphics
import Foundation
import MacHIDApplication
import MacHIDDomain

/// Sends synthetic key and mouse events. Every event carries `marker`, so the remapping tap recognizes and ignores
/// what MacHID itself sent (otherwise a remap could trigger itself in a loop).
public struct QuartzEventPoster: EventPoster {
    /// Value stored in the event's user data field ("MCHD").
    public static let marker: Int64 = 0x4D43_4844

    public init() {}

    public func post(_ event: OutputEvent) async { postNow(event) }

    public func type(_ text: String) async {
        // Unicode typing keeps accents and symbols exact, whatever the keyboard layout.
        for scalarChunk in text.unicodeScalars.chunked(into: 16) {
            let units = Array(String(String.UnicodeScalarView(scalarChunk)).utf16)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
                event.post(tap: .cgSessionEventTap)
            }
        }
    }

    /// Synchronous variant, used by the event tap callback.
    public func postNow(_ event: OutputEvent) {
        switch event {
        case .key(let code, let modifiers, let down):
            guard let key = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(truncatingIfNeeded: code), keyDown: down) else { return }
            key.flags = Self.flags(for: modifiers)
            key.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            key.post(tap: .cgSessionEventTap)
        case .mouse(let button, let down):
            let location = CGEvent(source: nil)?.location ?? .zero
            let (type, cgButton) = Self.mouse(button: button, down: down)
            guard let mouse = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: cgButton) else { return }
            mouse.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
            mouse.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            mouse.post(tap: .cgSessionEventTap)
        }
    }

    static func flags(for modifiers: Modifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    static func modifiers(from flags: CGEventFlags) -> Modifiers {
        var modifiers: Modifiers = []
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskSecondaryFn) { modifiers.insert(.function) }
        return modifiers
    }

    /// Button 0 is left, 1 right, 2 and up are "other" buttons.
    static func mouse(button: Int, down: Bool) -> (CGEventType, CGMouseButton) {
        switch button {
        case 0: (down ? .leftMouseDown : .leftMouseUp, .left)
        case 1: (down ? .rightMouseDown : .rightMouseUp, .right)
        default: (down ? .otherMouseDown : .otherMouseUp, .center)
        }
    }
}

private extension Sequence {
    func chunked(into size: Int) -> [[Element]] {
        var chunks: [[Element]] = []
        var current: [Element] = []
        for element in self {
            current.append(element)
            if current.count == size { chunks.append(current); current = [] }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
