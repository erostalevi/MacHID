import Foundation
import IOKit
import IOUSBHost
import MacHIDDomain

/// USB control transfers and descriptor access for one device, through IOUSBHost.
///
/// The device is opened without capture, so the system's camera drivers keep working.
public actor IOKitUSBTransport: Transport {
    private struct Handle: @unchecked Sendable { let device: IOUSBHostDevice }
    private let handle: Handle
    private let timeout: TimeInterval = 1.0

    public init(usbId: USBID) throws {
        let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        matching["idVendor"] = Int(usbId.vendor)
        matching["idProduct"] = Int(usbId.product)
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            throw DriverError.deviceFailure("could not search the USB registry")
        }
        defer { IOObjectRelease(iterator) }
        let service = IOIteratorNext(iterator)
        guard service != 0 else { throw DriverError.deviceFailure("USB device \(usbId) is not attached") }
        defer { IOObjectRelease(service) }
        do {
            handle = Handle(device: try IOUSBHostDevice(__ioService: service, options: [], queue: nil, interestHandler: nil))
        } catch {
            throw DriverError.deviceFailure("could not open USB device \(usbId): \(error.localizedDescription)")
        }
    }

    public func usbConfigurationDescriptor() async throws -> [UInt8] {
        guard let descriptor = handle.device.configurationDescriptor else {
            throw DriverError.deviceFailure("the device has no configuration descriptor")
        }
        let total = Int(descriptor.pointee.wTotalLength)
        return Array(UnsafeBufferPointer(start: UnsafeRawPointer(descriptor).assumingMemoryBound(to: UInt8.self), count: total))
    }

    public func controlRead(requestType: UInt8, request: UInt8, value: UInt16, index: UInt16, length: Int) async throws -> [UInt8] {
        let data = NSMutableData(length: length) ?? NSMutableData()
        var transferred = 0
        let setup = IOUSBDeviceRequest(bmRequestType: requestType, bRequest: request, wValue: value, wIndex: index, wLength: UInt16(length))
        do {
            try handle.device.__send(setup, data: data, bytesTransferred: &transferred, completionTimeout: timeout)
        } catch {
            throw DriverError.deviceFailure("USB control read failed: \(error.localizedDescription)")
        }
        return Array(Data(referencing: data).prefix(transferred))
    }

    public func controlWrite(requestType: UInt8, request: UInt8, value: UInt16, index: UInt16, data: [UInt8]) async throws {
        let payload = NSMutableData(data: Data(data))
        var transferred = 0
        let setup = IOUSBDeviceRequest(bmRequestType: requestType, bRequest: request, wValue: value, wIndex: index, wLength: UInt16(data.count))
        do {
            try handle.device.__send(setup, data: payload, bytesTransferred: &transferred, completionTimeout: timeout)
        } catch {
            throw DriverError.deviceFailure("USB control write failed: \(error.localizedDescription)")
        }
    }

    public func sendFeatureReport(reportID: UInt8, _ data: [UInt8]) async throws {
        throw DriverError.deviceFailure("this transport does not support HID reports")
    }

    public func getFeatureReport(reportID: UInt8, length: Int) async throws -> [UInt8] {
        throw DriverError.deviceFailure("this transport does not support HID reports")
    }
}
