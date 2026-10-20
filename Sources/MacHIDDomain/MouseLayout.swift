/// Physical buttons of a mouse, described as pure data so the UI can bind software remap rules to them.
public struct MouseButton: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// Seen by an event tap as a mouse button event; `macOSButton` is the `CGEventField.mouseEventButtonNumber`.
        case button
        /// A scroll wheel direction: seen as scroll events, not button events, so it cannot be an `InputTrigger`.
        case scroll
        /// Handled inside the mouse (onboard); the host never sees an event for it.
        case onboard
    }

    public let id: String
    public let title: String
    public let kind: Kind
    /// macOS button number (0 left, 1 right, 2 middle, 3 back, 4 forward) when `kind == .button`.
    public let macOSButton: Int?
    /// Normalized position (0...1, origin top-left, top view of the mouse) for drawing a hotspot.
    public let x: Double
    public let y: Double

    /// The trigger a remap rule would use for this button; nil when the host cannot see it.
    public var trigger: InputTrigger? {
        guard kind == .button, let macOSButton else { return nil }
        return InputTrigger(kind: .mouseButton, code: macOSButton)
    }

    public init(id: String, title: String, kind: Kind, macOSButton: Int? = nil, x: Double, y: Double) {
        self.id = id
        self.title = title
        self.kind = kind
        self.macOSButton = macOSButton
        self.x = x
        self.y = y
    }
}

public struct MouseLayout: Sendable, Equatable {
    public let buttons: [MouseButton]

    public init(buttons: [MouseButton]) { self.buttons = buttons }

    /// Buttons a software remap rule can use.
    public var remappable: [MouseButton] { buttons.filter { $0.trigger != nil } }

    public func button(id: String) -> MouseButton? { buttons.first { $0.id == id } }

    /// Layout for a device definition id, or nil when none is described.
    public static func layout(forDefinition id: String) -> MouseLayout? {
        switch id {
        case "logitech-g203-lightsync": return .logitechG203
        default: return nil
        }
    }

    /// Logitech G203 LIGHTSYNC: six physical controls. Left, right, wheel click and the two side buttons are
    /// standard HID buttons 1...5 (macOS numbers 0, 1, 2, 3 = back, 4 = forward). The DPI button is onboard
    /// (libratbag lists no host-visible usage for it), and the wheel only produces scroll events.
    /// Which side button is "back" is the usual HID mapping (button 4 = back, button 5 = forward); it is not
    /// confirmed on hardware, and `machid` should be checked with an event monitor before relying on it.
    public static let logitechG203 = MouseLayout(buttons: [
        MouseButton(id: "left", title: "Left", kind: .button, macOSButton: 0, x: 0.28, y: 0.22),
        MouseButton(id: "right", title: "Right", kind: .button, macOSButton: 1, x: 0.72, y: 0.22),
        MouseButton(id: "middle", title: "Wheel click", kind: .button, macOSButton: 2, x: 0.5, y: 0.2),
        MouseButton(id: "wheel_up", title: "Wheel up", kind: .scroll, x: 0.5, y: 0.14),
        MouseButton(id: "wheel_down", title: "Wheel down", kind: .scroll, x: 0.5, y: 0.26),
        MouseButton(id: "dpi", title: "DPI button", kind: .onboard, x: 0.5, y: 0.4),
        MouseButton(id: "back", title: "Back", kind: .button, macOSButton: 3, x: 0.12, y: 0.45),
        MouseButton(id: "forward", title: "Forward", kind: .button, macOSButton: 4, x: 0.12, y: 0.35),
    ])
}

/// Host-side DPI stage list ("400,800,1600"), cycled by the app in software.
public struct DPIStages: Sendable, Equatable {
    public static let maxStages = 5
    public let values: [Int]

    public init?(values: [Int]) {
        guard (1...Self.maxStages).contains(values.count), values.allSatisfy({ $0 > 0 }) else { return nil }
        self.values = values
    }

    public init?(text: String) {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.contains(where: { $0 == nil }) else { return nil }
        self.init(values: parts.compactMap { $0 })
    }

    public var text: String { values.map(String.init).joined(separator: ",") }

    /// The stage after `current`; the first stage when `current` is not in the list; wraps around.
    public func next(after current: Int) -> Int {
        guard let index = values.firstIndex(of: current) else { return values[0] }
        return values[(index + 1) % values.count]
    }
}
