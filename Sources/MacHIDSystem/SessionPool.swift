import Foundation
import MacHIDApplication
import MacHIDDomain

/// Keeps one open session per device so a slider drag does not reopen the device for every write.
/// Sessions unused for `idleTimeout` are dropped (which closes the device for other programs), and a
/// session is dropped at once after any error, so a replugged device reconnects cleanly.
public actor SessionPool: DeviceConnector {
    private struct Entry {
        let driver: any DeviceDriver
        let transport: any Transport
        var lastUsed: ContinuousClock.Instant
    }

    private let inner: any DeviceConnector
    private let idleTimeout: Duration
    private let clock = ContinuousClock()
    private var sessions: [USBID: Entry] = [:]

    public init(wrapping inner: any DeviceConnector, idleTimeout: Duration = .seconds(30)) {
        self.inner = inner
        self.idleTimeout = idleTimeout
    }

    public func connect(to device: DiscoveredDevice, definition: DeviceDefinition) async throws -> (driver: any DeviceDriver, transport: any Transport) {
        let now = clock.now
        sessions = sessions.filter { $0.value.lastUsed.duration(to: now) < idleTimeout }
        if var entry = sessions[device.usbId] {
            entry.lastUsed = now
            sessions[device.usbId] = entry
            return (entry.driver, entry.transport)
        }
        let session = try await inner.connect(to: device, definition: definition)
        sessions[device.usbId] = Entry(driver: session.driver, transport: session.transport, lastUsed: now)
        return session
    }

    public func discard(_ device: DiscoveredDevice) async {
        sessions[device.usbId] = nil
        await inner.discard(device)
    }

    /// Drops every open session, for example when a device was unplugged.
    public func closeAll() { sessions.removeAll() }

    public var openSessionCount: Int { sessions.count }
}
