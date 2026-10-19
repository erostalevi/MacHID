import Foundation
import IOKit
import IOKit.hid
import MacHIDDomain

public enum EnumerationError: Error, CustomStringConvertible {
    case ioKit(String, kern_return_t)

    public var description: String {
        switch self {
        case .ioKit(let what, let code): "\(what) failed (IOKit error 0x\(String(UInt32(bitPattern: code), radix: 16)))"
        }
    }
}

/// Read-only enumeration. Reads registry properties only: it never opens a device, so it needs
/// no Input Monitoring permission and cannot disturb the device.
public struct IOKitDeviceEnumerator: DeviceEnumerator {
    public init() {}

    public func enumerate() throws -> [DiscoveredDevice] {
        let interfaces = hidInterfacesByUSBID()
        return try usbDeviceProperties().compactMap { properties in
            guard let vendor = properties["idVendor"] as? Int,
                  let product = properties["idProduct"] as? Int,
                  let vid = UInt16(exactly: vendor), let pid = UInt16(exactly: product) else { return nil }
            let id = USBID(vendor: vid, product: pid)
            let name = (properties["USB Product Name"] as? String) ?? (properties["kUSBProductString"] as? String) ?? "Unknown device"
            return DiscoveredDevice(
                usbId: id,
                name: name,
                manufacturer: (properties["USB Vendor Name"] as? String) ?? (properties["kUSBVendorString"] as? String),
                serialSuffix: DiscoveredDevice.redactSerial(properties["USB Serial Number"] as? String),
                usbRelease: (properties["bcdDevice"] as? Int).map(DiscoveredDevice.formatBCD),
                hidInterfaces: interfaces[id] ?? [])
        }
    }

    private func usbDeviceProperties() throws -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        let status = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator)
        guard status == KERN_SUCCESS else { throw EnumerationError.ioKit("IOServiceGetMatchingServices", status) }
        defer { IOObjectRelease(iterator) }

        var result: [[String: Any]] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var unmanaged: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dictionary = unmanaged?.takeRetainedValue() as? [String: Any] {
                result.append(dictionary)
            }
        }
        return result
    }

    private func hidInterfacesByUSBID() -> [USBID: [HIDInterfaceInfo]] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [:] }

        var result: [USBID: Set<HIDInterfaceInfo>] = [:]
        for device in devices {
            func int(_ key: String) -> Int? { IOHIDDeviceGetProperty(device, key as CFString) as? Int }
            guard let vendor = int(kIOHIDVendorIDKey), let product = int(kIOHIDProductIDKey),
                  let vid = UInt16(exactly: vendor), let pid = UInt16(exactly: product),
                  let page = int(kIOHIDPrimaryUsagePageKey), let usage = int(kIOHIDPrimaryUsageKey) else { continue }
            result[USBID(vendor: vid, product: pid), default: []].insert(HIDInterfaceInfo(usagePage: page, usage: usage))
        }
        return result.mapValues { $0.sorted { ($0.usagePage, $0.usage) < ($1.usagePage, $1.usage) } }
    }
}
