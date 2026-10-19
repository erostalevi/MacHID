import Foundation
import IOKit
import IOKit.hid
import MacHIDDomain

/// Feature-report transport over one HID interface of one device.
///
/// The interface is chosen by `MaxFeatureReportSize` (e.g. 90 for the Razer control interface),
/// not by interface number, because that is what IOHIDDevice exposes. Opening the device may require
/// the Input Monitoring permission for the host process (Terminal, or the app).
public actor IOKitHIDTransport: Transport {
    /// IOKit objects are thread-safe handles but not marked Sendable; every use goes through the actor.
    private struct Handle: @unchecked Sendable {
        let manager: IOHIDManager
        let device: IOHIDDevice
    }

    private let handle: Handle

    public init(usbId: USBID, maxFeatureReportSize: Int) throws {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: Int(usbId.vendor),
            kIOHIDProductIDKey: Int(usbId.product),
        ] as CFDictionary)
        let candidates = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
        guard let device = candidates.first(where: {
            (IOHIDDeviceGetProperty($0, kIOHIDMaxFeatureReportSizeKey as CFString) as? Int) == maxFeatureReportSize
        }) else {
            throw DriverError.deviceFailure("no HID interface with a \(maxFeatureReportSize)-byte feature report on \(usbId)")
        }
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else { throw Self.error("open HID interface", result) }
        self.handle = Handle(manager: manager, device: device)
    }

    deinit { IOHIDDeviceClose(handle.device, IOOptionBits(kIOHIDOptionsTypeNone)) }

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

    private static func error(_ action: String, _ code: IOReturn) -> DriverError {
        let hex = "0x" + String(UInt32(bitPattern: code), radix: 16)
        if code == kIOReturnNotPermitted || code == kIOReturnExclusiveAccess {
            return .deviceFailure("\(action) was refused (\(hex)). Grant Input Monitoring to this app in System Settings → Privacy & Security, or another program has exclusive access.")
        }
        return .deviceFailure("\(action) failed (\(hex))")
    }
}
