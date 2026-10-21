import ApplicationServices
import CoreGraphics
import Foundation
import MacHIDApplication
import MacHIDDomain

/// What macOS lets this process do with the keyboard, and what the user must grant.
public enum RemapPermissions {
    public static var inputMonitoring: Bool { CGPreflightListenEventAccess() }
    public static var accessibility: Bool { AXIsProcessTrusted() }
    public static var allGranted: Bool { inputMonitoring && accessibility }

    public static func request() {
        _ = CGRequestListenEventAccess()
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

/// A Quartz event tap that asks the remap engine what to do with each key and mouse button event.
///
/// It only sees key presses, modifier-key changes and the extra mouse buttons (not left/right clicks or movement), and it never looks at
/// text: events are reduced to a key code, modifiers and up/down before the engine sees them. Events MacHID sent
/// itself are ignored, and Command-Option-Escape (Force Quit) is never touched.
public final class RemapEventTap: @unchecked Sendable {
    public typealias Handler = @Sendable (InputEvent) -> RemapDecision

    private let handler: Handler
    private let poster: QuartzEventPoster
    private let runMacro: @Sendable (String) -> Void
    private let switchProfile: @Sendable (String) -> Void
    private let cycleProfile: @Sendable (Int) -> Void
    private let runSystem: @Sendable (String) -> Void
    /// Pointer motion (dx, dy in pixels). Set only when shift gestures exist; the tap then also watches movement.
    public typealias MotionHandler = @Sendable (Double, Double) -> MotionDecision
    private let motion: MotionHandler?
    /// Modifier flags of modifier keys whose press was consumed; removed from later events so apps never see them held.
    private var consumedFlags: CGEventFlags = []
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    public init(poster: QuartzEventPoster = QuartzEventPoster(),
                handler: @escaping Handler,
                runMacro: @escaping @Sendable (String) -> Void,
                switchProfile: @escaping @Sendable (String) -> Void = { _ in },
                cycleProfile: @escaping @Sendable (Int) -> Void = { _ in },
                runSystem: @escaping @Sendable (String) -> Void = { SystemActionRunner().run(id: $0) },
                motion: MotionHandler? = nil) {
        self.runSystem = runSystem
        self.motion = motion
        self.switchProfile = switchProfile
        self.cycleProfile = cycleProfile
        self.poster = poster
        self.handler = handler
        self.runMacro = runMacro
    }

    /// Starts watching. Returns false when the permissions are missing or the system refuses the tap.
    @discardableResult
    public func start() -> Bool {
        guard tap == nil, RemapPermissions.allGranted else { return false }
        var types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .otherMouseDown, .otherMouseUp]
        // Movement is observed only when gestures are configured: it is the highest-volume event stream.
        if motion != nil { types += [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged] }
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            return Unmanaged<RemapEventTap>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
        }, userInfo: refcon) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    public var isRunning: Bool { tap != nil }

    deinit { stop() }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system turns a slow or interrupted tap off; turn it back on instead of leaving the keyboard unmapped.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData) != QuartzEventPoster.marker else { return Unmanaged.passUnretained(event) }

        if type == .flagsChanged { return handleModifier(event) }
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard let motion else { return Unmanaged.passUnretained(event) }
            let decision = motion(event.getDoubleValueField(.mouseEventDeltaX), event.getDoubleValueField(.mouseEventDeltaY))
            if let fired = decision.fired { _ = apply(fired, to: event) }
            return decision.suppress ? nil : Unmanaged.passUnretained(event)
        default: break
        }

        let isKey = type == .keyDown || type == .keyUp
        let code = isKey ? Int(event.getIntegerValueField(.keyboardEventKeycode)) : Int(event.getIntegerValueField(.mouseEventButtonNumber))
        // Force Quit is checked on the real flags, before any consumed modifier is removed.
        let real = QuartzEventPoster.modifiers(from: event.flags)
        if isKey, code == 53, real.contains(.command), real.contains(.option) { return Unmanaged.passUnretained(event) }
        if !consumedFlags.isEmpty { event.flags.subtract(consumedFlags) }
        let modifiers = QuartzEventPoster.modifiers(from: event.flags)

        let input = InputEvent(kind: isKey ? .keyboard : .mouseButton, code: code, modifiers: modifiers,
                               isDown: type == .keyDown || type == .otherMouseDown,
                               isRepeat: isKey && event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        return apply(handler(input), to: event)
    }

    /// A modifier key changed: the flags say whether the key that moved is now down. Only keys that a rule or shift
    /// mode asks for are consumed; any other modifier change goes through unchanged.
    private func handleModifier(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard let info = Self.modifierKeys[code] else { return Unmanaged.passUnretained(event) }
        let raw = event.flags.rawValue
        let isDown = info.device != 0 ? (raw & info.device) != 0 : event.flags.contains(info.flag)
        // The key's own bit is left out so a trigger written with no modifiers matches.
        let flags = event.flags.subtracting(info.flag)
        let input = InputEvent(kind: .keyboard, code: code, modifiers: QuartzEventPoster.modifiers(from: flags), isDown: isDown)
        let decision = handler(input)
        if case .passthrough = decision { return Unmanaged.passUnretained(event) }
        if isDown { consumedFlags.insert(info.flag) } else { consumedFlags.remove(info.flag) }
        return apply(decision, to: event)
    }

    private func apply(_ decision: RemapDecision, to event: CGEvent) -> Unmanaged<CGEvent>? {
        switch decision {
        case .passthrough: return Unmanaged.passUnretained(event)
        case .suppress: return nil
        case .emit(let events):
            events.forEach(poster.postNow)
            return nil
        case .runMacro(let id):
            runMacro(id)
            return nil
        case .switchProfile(let id):
            switchProfile(id)
            return nil
        case .cycleProfile(let step):
            cycleProfile(step)
            return nil
        case .runSystem(let id):
            runSystem(id)
            return nil
        }
    }

    /// Modifier key codes: generic flag plus the device-dependent bit that tells left from right (0 when there is none).
    private static let modifierKeys: [Int: (flag: CGEventFlags, device: UInt64)] = [
        54: (.maskCommand, 0x10), 55: (.maskCommand, 0x08),
        56: (.maskShift, 0x02), 60: (.maskShift, 0x04),
        58: (.maskAlternate, 0x20), 61: (.maskAlternate, 0x40),
        59: (.maskControl, 0x01), 62: (.maskControl, 0x2000),
        63: (.maskSecondaryFn, 0), 57: (.maskAlphaShift, 0),
    ]
}
