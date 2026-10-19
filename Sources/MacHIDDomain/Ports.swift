/// Raw HID/UVC access. Adapters implement this; tests use a fake. Domain code never imports IOKit.
/// `data` never includes the report ID byte; it is passed separately (0 when the device uses none).
public protocol Transport: Sendable {
    func sendFeatureReport(reportID: UInt8, _ data: [UInt8]) async throws
    func getFeatureReport(reportID: UInt8, length: Int) async throws -> [UInt8]
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
}

public protocol ProfileRepository: Sendable {
    func load() async throws -> [Profile]
    func save(_ profile: Profile) async throws
    func delete(id: String) async throws
}
