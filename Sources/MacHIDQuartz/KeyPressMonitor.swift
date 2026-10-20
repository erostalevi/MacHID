import ApplicationServices
import CoreGraphics
import Foundation

/// A listen-only tap that reports which key was pressed, so reactive lighting can flash it. It only ever sees the key
/// code of a key-down (never text), passes every event through untouched, and keeps nothing.
public final class KeyPressMonitor: @unchecked Sendable {
    public typealias Handler = @Sendable (Int) -> Void

    private let handler: Handler
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    public init(handler: @escaping Handler) { self.handler = handler }

    /// Starts watching. Returns false when Input Monitoring is missing or the system refuses the tap.
    @discardableResult
    public func start() -> Bool {
        guard tap == nil, CGPreflightListenEventAccess() else { return false }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: { _, type, event, refcon in
            if type == .keyDown, let refcon, event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                Unmanaged<KeyPressMonitor>.fromOpaque(refcon).takeUnretainedValue()
                    .handler(Int(event.getIntegerValueField(.keyboardEventKeycode)))
            } else if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput, let refcon {
                Unmanaged<KeyPressMonitor>.fromOpaque(refcon).takeUnretainedValue().reenable()
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: refcon) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    fileprivate func reenable() { if let tap { CGEvent.tapEnable(tap: tap, enable: true) } }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    public var isRunning: Bool { tap != nil }

    deinit { stop() }
}
