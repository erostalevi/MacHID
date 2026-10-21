/// macOS navigation and system actions that a button, key or gesture can trigger (`RemapAction.system`).
/// Pure data: the Quartz adapter (`SystemActionRunner`) turns each `Implementation` into real events.
public struct SystemAction: Sendable, Equatable, Identifiable {
    public enum Category: String, Sendable, CaseIterable, Codable {
        case navigation, desktops, system, media, display

        public var title: String {
            switch self {
            case .navigation: "Navigation"
            case .desktops: "Desktops"
            case .system: "System"
            case .media: "Media"
            case .display: "Display and sound"
            }
        }
    }

    /// How the action is carried out.
    public enum Implementation: Sendable, Equatable {
        /// A synthesized key combination. Relies on the matching macOS keyboard shortcut being enabled
        /// (System Settings > Keyboard > Keyboard Shortcuts).
        case key(code: Int, modifiers: Modifiers)
        /// A media/system key (NX_KEYTYPE_*), sent as a system-defined event. Needs no shortcut setting.
        case media(Int)
        /// Opens the first of these apps that exists. Independent of keyboard shortcut settings.
        case app([String])
    }

    public let id: String
    public let title: String
    public let symbol: String
    public let category: Category
    public let implementation: Implementation
    /// True when the action depends on a macOS keyboard shortcut that the user could have disabled.
    public var needsSystemShortcut: Bool { if case .key = implementation { true } else { false } }
}

public enum SystemActionCatalog {
    /// NX_KEYTYPE_* values from IOKit `ev_keymap.h`.
    public enum MediaKey {
        public static let soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
        public static let play = 16, next = 17, previous = 18
        public static let keyboardBrightnessUp = 21, keyboardBrightnessDown = 22
    }

    private static func key(_ id: String, _ title: String, _ symbol: String, _ category: SystemAction.Category,
                            _ code: Int, _ modifiers: Modifiers = []) -> SystemAction {
        SystemAction(id: id, title: title, symbol: symbol, category: category, implementation: .key(code: code, modifiers: modifiers))
    }
    private static func media(_ id: String, _ title: String, _ symbol: String, _ category: SystemAction.Category, _ type: Int) -> SystemAction {
        SystemAction(id: id, title: title, symbol: symbol, category: category, implementation: .media(type))
    }

    /// Key codes: 123/124 left/right arrow, 125 down, 126 up, 49 space, 12 Q, 2 D, 23 5, 103 F11, 131 Launchpad key, 45 N.
    public static let all: [SystemAction] = [
        // Mission Control and Launchpad open their apps: that works even if the keyboard shortcut was changed.
        SystemAction(id: "mission-control", title: "Mission Control", symbol: "rectangle.3.group", category: .navigation,
                     implementation: .app(["/System/Applications/Mission Control.app"])),
        key("app-expose", "App Exposé", "square.stack.3d.down.right", .navigation, 125, .control),
        key("show-desktop", "Show Desktop", "menubar.dock.rectangle", .navigation, 103),
        SystemAction(id: "launchpad", title: "Launchpad / Apps", symbol: "square.grid.3x3", category: .navigation,
                     implementation: .app(["/System/Applications/Apps.app", "/System/Applications/Launchpad.app"])),
        key("spotlight", "Spotlight", "magnifyingglass", .navigation, 49, .command),
        key("notification-center", "Notification Center", "bell", .navigation, 45, .function),
        key("show-dock", "Show or hide Dock", "dock.rectangle", .navigation, 2, [.command, .option]),
        key("desktop-left", "Switch desktop left", "arrow.left.square", .desktops, 123, .control),
        key("desktop-right", "Switch desktop right", "arrow.right.square", .desktops, 124, .control),
        key("screenshot", "Screenshot", "camera.viewfinder", .system, 23, [.command, .shift]),
        key("lock-screen", "Lock screen", "lock", .system, 12, [.command, .control]),
        media("play-pause", "Play / Pause", "playpause", .media, MediaKey.play),
        media("next-track", "Next track", "forward.end", .media, MediaKey.next),
        media("previous-track", "Previous track", "backward.end", .media, MediaKey.previous),
        media("volume-up", "Volume up", "speaker.plus", .display, MediaKey.soundUp),
        media("volume-down", "Volume down", "speaker.minus", .display, MediaKey.soundDown),
        media("mute", "Mute", "speaker.slash", .display, MediaKey.mute),
        media("brightness-up", "Brightness up", "sun.max", .display, MediaKey.brightnessUp),
        media("brightness-down", "Brightness down", "sun.min", .display, MediaKey.brightnessDown),
    ]

    public static func action(id: String) -> SystemAction? { all.first { $0.id == id } }

    /// Actions grouped by category, in display order, for building submenus.
    public static var grouped: [(category: SystemAction.Category, actions: [SystemAction])] {
        SystemAction.Category.allCases.compactMap { category in
            let items = all.filter { $0.category == category }
            return items.isEmpty ? nil : (category, items)
        }
    }

    /// "Run Shortcut" is not here on purpose: a Shortcuts step is a macro (`MacroStep.shortcut`), which already goes
    /// through the approval flow. Create a one-step macro and use `RemapAction.macro`.
}
