import AppKit
import CoreGraphics
import Foundation
import MacHIDDomain

/// Carries out `SystemActionCatalog` actions with synthesized events.
///
/// - Key based actions (App Exposé, switch desktop, Show Desktop, Spotlight...) post the key combination that macOS binds
///   by default. They work only while that shortcut is enabled in System Settings > Keyboard > Keyboard Shortcuts
///   (Mission Control: "Move left/right a space", "Application windows"; Spotlight; Show Desktop). If the user disabled or
///   changed one, the action does nothing. Reading the real binding (`com.apple.symbolichotkeys`) would be more robust but
///   is an undocumented format, so it is deliberately not done.
/// - Media actions send system-defined events (the same ones the F-row keys produce) and need no shortcut setting.
/// - Mission Control and Launchpad open their apps, so they do not depend on shortcuts either.
/// Every synthesized event carries the poster marker so MacHID's own tap ignores it.
public struct SystemActionRunner: Sendable {
    private let poster: QuartzEventPoster

    public init(poster: QuartzEventPoster = QuartzEventPoster()) { self.poster = poster }

    /// Returns false when the id is unknown or nothing could be opened.
    @discardableResult
    public func run(id: String) -> Bool {
        guard let action = SystemActionCatalog.action(id: id) else { return false }
        return run(action)
    }

    @discardableResult
    public func run(_ action: SystemAction) -> Bool {
        switch action.implementation {
        case .key(let code, let modifiers):
            poster.postNow(.key(code: code, modifiers: modifiers, down: true))
            poster.postNow(.key(code: code, modifiers: modifiers, down: false))
            return true
        case .media(let type):
            Self.postMediaKey(type, down: true)
            Self.postMediaKey(type, down: false)
            return true
        case .app(let paths):
            guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) else { return false }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return true
        }
    }

    /// data1 = keyType << 16 | (0xA << 8 for down, 0xB << 8 for up), subtype 8 (NX_SUBTYPE_AUX_CONTROL_BUTTONS).
    static func mediaData(type: Int, down: Bool) -> Int { (type << 16) | ((down ? 0xA : 0xB) << 8) }

    private static func postMediaKey(_ type: Int, down: Bool) {
        guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00),
                                             timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                             data1: mediaData(type: type, down: down), data2: -1),
              let cg = event.cgEvent else { return }
        cg.setIntegerValueField(.eventSourceUserData, value: QuartzEventPoster.marker)
        cg.post(tap: .cgSessionEventTap)
    }
}
