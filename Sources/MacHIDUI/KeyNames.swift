import AppKit
import MacHIDDomain

/// Readable names for macOS virtual key codes (ANSI layout) and mouse buttons.
public enum KeyNames {
    private static let keys: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E",
        15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-",
        28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return", 37: "L", 38: "J", 39: "'",
        40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`",
        51: "Delete", 53: "Esc", 71: "Clear", 76: "Enter", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 105: "F13", 107: "F14", 109: "F10", 111: "F12", 113: "F15", 115: "Home", 116: "Page Up", 117: "Forward Delete",
        118: "F4", 119: "End", 120: "F2", 121: "Page Down", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
        82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6",
        89: "Keypad 7", 91: "Keypad 8", 92: "Keypad 9",
        54: "Right ⌘", 55: "Left ⌘", 56: "Left ⇧", 57: "Caps Lock", 58: "Left ⌥", 59: "Left ⌃", 60: "Right ⇧", 61: "Right ⌥", 62: "Right ⌃", 63: "fn",
    ]

    /// The modifier flag a lone modifier key sets (nil for ordinary keys).
    static func modifierFlag(forCode code: Int) -> NSEvent.ModifierFlags? {
        switch code {
        case 54, 55: .command
        case 56, 60: .shift
        case 57: .capsLock
        case 58, 61: .option
        case 59, 62: .control
        case 63: .function
        default: nil
        }
    }

    public static func key(_ code: Int) -> String { keys[code] ?? "Key \(code)" }

    public static func modifiers(_ modifiers: Modifiers) -> String {
        (modifiers.contains(.function) ? "fn " : "") + (modifiers.contains(.control) ? "⌃" : "")
            + (modifiers.contains(.option) ? "⌥" : "") + (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "")
    }

    public static func combination(code: Int, modifiers mods: Modifiers) -> String {
        let prefix = modifiers(mods)
        return prefix.isEmpty ? key(code) : prefix + " " + key(code)
    }

    /// Button numbers follow Quartz: 0 left, 1 right, 2 middle, 3 and up are extra buttons.
    public static func mouseButton(_ button: Int) -> String {
        switch button {
        case 0: "Left button"
        case 1: "Right button"
        case 2: "Middle button"
        default: "Button \(button + 1)"
        }
    }

    public static func trigger(_ trigger: InputTrigger) -> String {
        trigger.kind == .keyboard ? combination(code: trigger.code, modifiers: trigger.modifiers) : mouseButton(trigger.code)
    }

    public static func modifiers(from flags: NSEvent.ModifierFlags) -> Modifiers {
        var result: Modifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.function) { result.insert(.function) }
        return result
    }
}
