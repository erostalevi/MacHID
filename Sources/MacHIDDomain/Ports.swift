/// Raw HID/UVC access. Adapters implement this; tests use a fake. Domain code never imports IOKit.
public protocol Transport: Sendable {
    func sendFeatureReport(_ data: [UInt8]) async throws
    func sendOutputReport(_ data: [UInt8]) async throws
    func readReport(timeoutMilliseconds: Int) async throws -> [UInt8]
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
