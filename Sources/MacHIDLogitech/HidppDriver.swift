import MacHIDDomain

/// Valid DPI values reported by ADJUSTABLE_DPI function 1: either an explicit list, or a
/// `[min, 0xE000 + step, max]` range.
public struct HidppDPIList: Equatable, Sendable {
    public let values: [Int]
    public let step: Int?

    public init(values: [Int], step: Int? = nil) {
        self.values = values
        self.step = step
    }

    /// `parameters` are the 16 reply bytes: sensor index, then big-endian 16-bit entries ending at 0.
    public static func parse(_ parameters: [UInt8]) -> HidppDPIList {
        var values: [Int] = []
        var step: Int?
        var index = 1
        while index + 1 < parameters.count {
            let entry = Int(parameters[index]) << 8 | Int(parameters[index + 1])
            if entry == 0 { break }
            if entry > 0xE000 { step = entry - 0xE000 } else { values.append(entry) }
            index += 2
        }
        return HidppDPIList(values: values, step: step)
    }

    public func contains(_ dpi: Int) -> Bool {
        if let step, step > 0, values.count == 2, let low = values.first, let high = values.last {
            return (low...high).contains(dpi) && (dpi - low) % step == 0
        }
        return values.contains(dpi)
    }
}

/// Logitech HID++ 2.0 driver.
///
/// Capability ids: `info` (protocol version), `dpi` (sensor 0), `backlight` (zone 0: color or "off")
/// and `device_mode` (0 = onboard/device control, 1 = host control of the LEDs).
///
/// Commands follow libratbag (MIT) and Solaar's public sources. Lighting is written to RAM only:
/// libratbag's "also write to flash" flag is left at 0, so nothing is stored in the mouse.
public struct HidppDriver: DeviceDriver {
    public let familyID = "logitech-gseries"

    /// Fixed (static) and disabled effect ids of COLOR_LED_EFFECTS.
    private static let disabledEffect: UInt16 = 0
    private static let fixedEffect: UInt16 = 1
    private static let zone: UInt8 = 0

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
        case "device_mode":
            let index = try await client.featureIndex(for: HidppFeature.colorLEDEffects)
            return .int(Int(try await client.request(featureIndex: index, function: 7)[0]))
        default:
            throw DriverError.unsupportedCapability(capability.id)
        }
    }

    public func write(_ value: SettingValue, to capability: CapabilityDescriptor, using transport: any Transport) async throws {
        let client = HidppClient(transport: transport)
        switch (capability.id, value) {
        case ("dpi", .int(let dpi)):
            try await setDPI(dpi, client: client)
        case ("backlight", .color(let color)):
            try await setEffect(Self.fixedEffect, parameters: [color.r, color.g, color.b], client: client)
        case ("backlight", .text("off")):
            try await setEffect(Self.disabledEffect, parameters: [], client: client)
        case ("device_mode", .int(let mode)):
            guard mode == 0 || mode == 1 else { throw DriverError.invalidValue("device_mode must be 0 (device) or 1 (host)") }
            let index = try await client.featureIndex(for: HidppFeature.colorLEDEffects)
            _ = try await client.request(featureIndex: index, function: 8, parameters: [UInt8(mode)])
        case ("dpi", _), ("backlight", _), ("device_mode", _):
            throw DriverError.invalidValue("wrong value type for '\(capability.id)'")
        default:
            throw DriverError.unsupportedCapability(capability.id)
        }
    }

    // MARK: DPI

    private func setDPI(_ dpi: Int, client: HidppClient) async throws {
        guard (1...0xDFFF).contains(dpi) else { throw DriverError.invalidValue("DPI out of range") }
        let index = try await client.featureIndex(for: HidppFeature.adjustableDPI)
        // Function 1 lists what the sensor accepts; refuse anything else instead of sending it.
        let list = HidppDPIList.parse(try await client.request(featureIndex: index, function: 1, parameters: [0]))
        guard list.contains(dpi) else { throw DriverError.invalidValue("\(dpi) DPI is not supported by this sensor") }
        let reply = try await client.request(featureIndex: index, function: 3,
                                             parameters: [0, UInt8(dpi >> 8), UInt8(dpi & 0xFF)])
        // Protocol version 0 does not echo the value; otherwise it must match.
        let echoed = Int(reply[1]) << 8 | Int(reply[2])
        guard echoed == 0 || echoed == dpi else { throw HidppError.malformed("device set \(echoed) DPI instead of \(dpi)") }
    }

    // MARK: Lighting (COLOR_LED_EFFECTS 0x8070)

    private func setEffect(_ effectID: UInt16, parameters: [UInt8], client: HidppClient) async throws {
        let index = try await client.featureIndex(for: HidppFeature.colorLEDEffects)
        try await ensureHostControl(client: client, featureIndex: index)
        let effectIndex = try await effectIndex(for: effectID, client: client, featureIndex: index)
        // [zone, effect index, effect parameters...]; byte 12 (persistence) stays 0 = RAM only.
        _ = try await client.request(featureIndex: index, function: 3,
                                     parameters: [Self.zone, effectIndex] + parameters)
    }

    /// Zone effects are addressed by their position in the zone's effect list, not by effect id.
    private func effectIndex(for effectID: UInt16, client: HidppClient, featureIndex: UInt8) async throws -> UInt8 {
        let info = try await client.request(featureIndex: featureIndex, function: 0)
        guard info[0] > Self.zone else { throw HidppError.malformed("device reports no LED zones") }
        // zone info: [zone, location (BE16), number of effects, persistency]
        let zoneInfo = try await client.request(featureIndex: featureIndex, function: 1, parameters: [Self.zone])
        for position in 0..<zoneInfo[3] {
            // effect info: [zone, position, effect id (BE16), ...]
            let effect = try await client.request(featureIndex: featureIndex, function: 2, parameters: [Self.zone, position])
            if UInt16(effect[2]) << 8 | UInt16(effect[3]) == effectID { return position }
        }
        throw DriverError.deviceFailure("this LED zone has no effect 0x\(String(effectID, radix: 16))")
    }

    /// Zone effects only apply while the host controls the LEDs (Solaar's "LED Control").
    private func ensureHostControl(client: HidppClient, featureIndex: UInt8) async throws {
        let current = try await client.request(featureIndex: featureIndex, function: 7)
        guard current[0] == 0 else { return }
        _ = try await client.request(featureIndex: featureIndex, function: 8, parameters: [1])
    }
}
