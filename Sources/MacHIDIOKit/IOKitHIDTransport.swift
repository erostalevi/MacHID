import Foundation
import IOKit
import IOKit.hid
import MacHIDDomain

/// Which HID interface of a device to talk to. IOHIDDevice does not expose the USB interface number,
/// so interfaces are told apart by their report sizes.
public enum HIDInterfaceSelector: Sendable {
    /// Interface with this `MaxFeatureReportSize` (e.g. 90 for the Razer control interface).
    case featureReportSize(Int)
    /// Interface with this `MaxOutputReportSize` (e.g. 20 for Logitech HID++ long reports).
    case outputReportSize(Int)
}

/// Thread-safe queue filled by the IOKit input-report callback.
final class InputReportQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [(reportID: UInt8, data: [UInt8])] = []

    func push(_ reportID: UInt8, _ data: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        reports.append((reportID, data))
        if reports.count > 64 { reports.removeFirst() }
    }

    func pop() -> (reportID: UInt8, data: [UInt8])? {
        lock.lock(); defer { lock.unlock() }
        return reports.isEmpty ? nil : reports.removeFirst()
    }
}

/// Report transport over one HID interface of one device.
///
/// Opening the device may require the Input Monitoring permission for the host process
/// (Terminal, or the app).
public actor IOKitHIDTransport: Transport {
    /// IOKit objects are thread-safe handles but not marked Sendable; every use goes through the actor.
    private struct Handle: @unchecked Sendable {
        let manager: IOHIDManager
        let device: IOHIDDevice
        let buffer: UnsafeMutablePointer<UInt8>
    }

    private static let inputBufferSize = 256
    private let handle: Handle
    private let queue = InputReportQueue()

    public init(usbId: USBID, selector: HIDInterfaceSelector) throws {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: Int(usbId.vendor),
            kIOHIDProductIDKey: Int(usbId.product),
        ] as CFDictionary)
        let candidates = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        let key: String
        let wanted: Int
        switch selector {
        case .featureReportSize(let size): key = kIOHIDMaxFeatureReportSizeKey; wanted = size
        case .outputReportSize(let size): key = kIOHIDMaxOutputReportSizeKey; wanted = size
        }
        guard let device = candidates.first(where: { (IOHIDDeviceGetProperty($0, key as CFString) as? Int) == wanted }) else {
            throw DriverError.deviceFailure("no HID interface with \(key) = \(wanted) on \(usbId)")
        }
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else { throw Self.error("open HID interface", result) }

        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.inputBufferSize)
        buffer.initialize(repeating: 0, count: Self.inputBufferSize)
        self.handle = Handle(manager: manager, device: device, buffer: buffer)

        // The callback context is unretained: the queue outlives the device (cancelled in deinit).
        let context = Unmanaged.passUnretained(queue).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, Self.inputBufferSize, { context, _, _, _, reportID, report, length in
            guard let context else { return }
            let queue = Unmanaged<InputReportQueue>.fromOpaque(context).takeUnretainedValue()
            var bytes = Array(UnsafeBufferPointer(start: report, count: length))
            // With numbered reports macOS includes the report ID as the first byte; strip it.
            if reportID != 0, bytes.first == UInt8(truncatingIfNeeded: reportID) { bytes.removeFirst() }
            queue.push(UInt8(truncatingIfNeeded: reportID), bytes)
        }, context)
        IOHIDDeviceSetDispatchQueue(device, DispatchQueue(label: "machid.hid.input"))
        IOHIDDeviceActivate(device)
    }

    public init(usbId: USBID, maxFeatureReportSize: Int) throws {
        try self.init(usbId: usbId, selector: .featureReportSize(maxFeatureReportSize))
    }

    deinit {
        IOHIDDeviceCancel(handle.device)
        IOHIDDeviceClose(handle.device, IOOptionBits(kIOHIDOptionsTypeNone))
        handle.buffer.deallocate()
    }

    public func sendFeatureReport(reportID: UInt8, _ data: [UInt8]) async throws {
        let result = IOHIDDeviceSetReport(handle.device, kIOHIDReportTypeFeature, CFIndex(reportID), data, data.count)
        guard result == kIOReturnSuccess else { throw Self.error("send feature report", result) }
    }

    public func getFeatureReport(reportID: UInt8, length: Int) async throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: length)
        var received = CFIndex(length)
        let result = IOHIDDeviceGetReport(handle.device, kIOHIDReportTypeFeature, CFIndex(reportID), &buffer, &received)
        guard result == kIOReturnSuccess else { throw Self.error("read feature report", result) }
        return Array(buffer.prefix(received))
    }

    public func sendOutputReport(reportID: UInt8, _ data: [UInt8]) async throws {
        // For numbered reports IOHIDDeviceSetReport expects the report ID as the first byte of the data.
        let payload = reportID == 0 ? data : [reportID] + data
        let result = IOHIDDeviceSetReport(handle.device, kIOHIDReportTypeOutput, CFIndex(reportID), payload, payload.count)
        guard result == kIOReturnSuccess else { throw Self.error("send output report", result) }
    }

    public func nextInputReport(timeout: Duration) async throws -> (reportID: UInt8, data: [UInt8]) {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let report = queue.pop() { return report }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw DriverError.deviceFailure("timed out waiting for the device")
    }

    private static func error(_ action: String, _ code: IOReturn) -> DriverError {
        let hex = "0x" + String(UInt32(bitPattern: code), radix: 16)
        if code == kIOReturnNotPermitted || code == kIOReturnExclusiveAccess {
            return .deviceFailure("\(action) was refused (\(hex)). Grant Input Monitoring to the app running machid in System Settings → Privacy & Security, or another program has exclusive access.")
        }
        return .deviceFailure("\(action) failed (\(hex))")
    }
}
