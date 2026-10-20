/// Raw HID/UVC access. Adapters implement this; tests use a fake. Domain code never imports IOKit.
/// `data` never includes the report ID byte; it is passed separately (0 when the device uses none).
public protocol Transport: Sendable {
    func sendFeatureReport(reportID: UInt8, _ data: [UInt8]) async throws
    func getFeatureReport(reportID: UInt8, length: Int) async throws -> [UInt8]
    /// Output report (host to device). Used by HID++.
    func sendOutputReport(reportID: UInt8, _ data: [UInt8]) async throws
    /// Next input report (device to host), without its report ID byte; throws on timeout.
    func nextInputReport(timeout: Duration) async throws -> (reportID: UInt8, data: [UInt8])
    /// USB control transfer on endpoint 0 (device to host). Used by UVC.
    func controlRead(requestType: UInt8, request: UInt8, value: UInt16, index: UInt16, length: Int) async throws -> [UInt8]
    /// USB control transfer on endpoint 0 (host to device).
    func controlWrite(requestType: UInt8, request: UInt8, value: UInt16, index: UInt16, data: [UInt8]) async throws
    /// Raw configuration descriptor (all interfaces and class-specific descriptors).
    func usbConfigurationDescriptor() async throws -> [UInt8]
}

/// Defaults for transports that do not support an operation. Because each one is also a protocol
/// requirement, a conforming type's own implementation is the one that runs.
extension Transport {
    public func controlRead(requestType: UInt8, request: UInt8, value: UInt16, index: UInt16, length: Int) async throws -> [UInt8] {
        throw DriverError.deviceFailure("this transport does not support USB control transfers")
    }

    public func controlWrite(requestType: UInt8, request: UInt8, value: UInt16, index: UInt16, data: [UInt8]) async throws {
        throw DriverError.deviceFailure("this transport does not support USB control transfers")
    }

    public func usbConfigurationDescriptor() async throws -> [UInt8] {
        throw DriverError.deviceFailure("this transport cannot read USB descriptors")
    }

    public func sendOutputReport(reportID: UInt8, _ data: [UInt8]) async throws {
        throw DriverError.deviceFailure("this transport does not support output reports")
    }

    public func nextInputReport(timeout: Duration) async throws -> (reportID: UInt8, data: [UInt8]) {
        throw DriverError.deviceFailure("this transport does not support input reports")
    }
}

public enum DriverError: Error, Equatable, CustomStringConvertible {
    case unsupportedCapability(String)
    case unsupportedModel(USBID)
    case invalidValue(String)
    case deviceFailure(String)

    public var description: String {
        switch self {
        case .unsupportedCapability(let id): "capability '\(id)' is not supported by this driver"
        case .unsupportedModel(let id): "driver does not know device \(id)"
        case .invalidValue(let why): "invalid value: \(why)"
        case .deviceFailure(let why): "device error: \(why)"
        }
    }
}

/// Protocol-family driver: one per protocol family, not per device or vendor.
public protocol DeviceDriver: Sendable {
    var familyID: String { get }
    func read(_ capability: CapabilityDescriptor, using transport: any Transport) async throws -> SettingValue
    func write(_ value: SettingValue, to capability: CapabilityDescriptor, using transport: any Transport) async throws
    /// Limits only the device itself knows (e.g. a camera's brightness range). Nil when the definition is enough.
    func limits(for capability: CapabilityDescriptor, using transport: any Transport) async throws -> ValueLimits?
}

extension DeviceDriver {
    public func limits(for capability: CapabilityDescriptor, using transport: any Transport) async throws -> ValueLimits? { nil }
}

public struct ValueLimits: Equatable, Sendable {
    public let min: Int
    public let max: Int
    public let step: Int

    public init(min: Int, max: Int, step: Int = 1) {
        self.min = min
        self.max = max
        self.step = step
    }
}

public protocol ProfileRepository: Sendable {
    func load() async throws -> [Profile]
    func save(_ profile: Profile) async throws
    func delete(id: String) async throws
}
