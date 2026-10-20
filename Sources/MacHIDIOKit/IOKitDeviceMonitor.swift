import Foundation
import IOKit

/// Wakes up when any USB device is plugged in or removed, so the app reacts at once instead of polling.
/// Each event is only a hint: the receiver re-enumerates to learn what changed.
public final class IOKitDeviceMonitor: @unchecked Sendable {
    /// Yields once per burst of USB changes (events arriving while one is pending are merged).
    public let changes: AsyncStream<Void>

    private let continuation: AsyncStream<Void>.Continuation
    private let port: IONotificationPortRef
    private let queue = DispatchQueue(label: "machid.usb.monitor")
    private var iterators: [io_iterator_t] = []

    public init() {
        var captured: AsyncStream<Void>.Continuation!
        changes = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { captured = $0 }
        continuation = captured
        port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, queue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let status = IOServiceAddMatchingNotification(port, notification, IOServiceMatching("IOUSBHostDevice"), { refcon, iterator in
                guard let refcon else { return }
                Unmanaged<IOKitDeviceMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(iterator)
            }, refcon, &iterator)
            guard status == KERN_SUCCESS else { continue }
            iterators.append(iterator)
            drain(iterator)   // arms the notification; the initial matches are not changes
        }
    }

    deinit {
        continuation.finish()
        IONotificationPortDestroy(port)
        iterators.forEach { IOObjectRelease($0) }
    }

    private func handle(_ iterator: io_iterator_t) {
        if drain(iterator) { continuation.yield() }
    }

    @discardableResult
    private func drain(_ iterator: io_iterator_t) -> Bool {
        var any = false
        while case let object = IOIteratorNext(iterator), object != 0 {
            any = true
            IOObjectRelease(object)
        }
        return any
    }
}
