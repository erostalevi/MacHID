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
/// It only sees key presses and the extra mouse buttons (not left/right clicks or movement), and it never looks at
/// text: events are reduced to a key code, modifiers and up/down before the engine sees them. Events MacHID sent
/// itself are ignored, and Command-Option-Escape (Force Quit) is never touched.
public final class RemapEventTap: @unchecked Sendable {
    public typealias Handler = @Sendable (InputEvent) -> RemapDecision

    private let handler: Handler
    private let poster: QuartzEventPoster
    private let runMacro: @Sendable (String) -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    public init(poster: QuartzEventPoster = QuartzEventPoster(),
                handler: @escaping Handler,
                runMacro: @escaping @Sendable (String) -> Void) {
        self.poster = poster
        self.handler = handler
        self.runMacro = runMacro
    }

    /// Starts watching. Returns false when the permissions are missing or the system refuses the tap.
    @discardableResult
    public func start() -> Bool {
        guard tap == nil, RemapPermissions.allGranted else { return false }
        let types: [CGEventType] = [.keyDown, .keyUp, .otherMouseDown, .otherMouseUp]
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

        let isKey = type == .keyDown || type == .keyUp
        let code = isKey ? Int(event.getIntegerValueField(.keyboardEventKeycode)) : Int(event.getIntegerValueField(.mouseEventButtonNumber))
        let modifiers = QuartzEventPoster.modifiers(from: event.flags)
        if isKey, code == 53, modifiers.contains(.command), modifiers.contains(.option) { return Unmanaged.passUnretained(event) }   // Force Quit

        let input = InputEvent(kind: isKey ? .keyboard : .mouseButton, code: code, modifiers: modifiers,
                               isDown: type == .keyDown || type == .otherMouseDown,
                               isRepeat: isKey && event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        switch handler(input) {
        case .passthrough: return Unmanaged.passUnretained(event)
        case .suppress: return nil
        case .emit(let events):
            events.forEach(poster.postNow)
            return nil
        case .runMacro(let id):
            runMacro(id)
            return nil
        }
    }
}
