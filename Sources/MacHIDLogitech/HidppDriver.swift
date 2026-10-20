import MacHIDDomain

/// Logitech HID++ 2.0 driver. Read-only for now: writes stay disabled until the protocol has been
/// confirmed on real hardware.
///
/// Capability ids: `info` (protocol version, text) and `dpi` (current DPI of sensor 0).
public struct HidppDriver: DeviceDriver {
    public let familyID = "logitech-gseries"

    public init() {}

    public func read(_ capability: CapabilityDescriptor, using transport: any Transport) async throws -> SettingValue {
        let client = HidppClient(transport: transport)
        switch capability.id {
        case "info":
            let version = try await client.protocolVersion()
            return .text("HID++ \(version.major).\(version.minor)")
        case "dpi":
            let index = try await client.featureIndex(for: HidppFeature.adjustableDPI)
            // ADJUSTABLE_DPI function 2 = getSensorDpi(sensor) -> [sensor, dpi (BE16), default dpi (BE16)]
            let reply = try await client.request(featureIndex: index, function: 2, parameters: [0])
            let dpi = Int(reply[1]) << 8 | Int(reply[2])
            guard dpi > 0 else { throw HidppError.malformed("DPI of 0") }
            return .int(dpi)
        default:
            throw DriverError.unsupportedCapability(capability.id)
        }
    }

    public func write(_ value: SettingValue, to capability: CapabilityDescriptor, using transport: any Transport) async throws {
        throw DriverError.unsupportedCapability("\(capability.id) (writes are not enabled for HID++ yet)")
    }
}
