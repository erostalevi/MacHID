import Foundation
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
/// Commands follow libratbag (MIT) and Solaar's public sources. Lighting on 0x8070 is written to RAM only
/// (libratbag's "also write to flash" flag stays 0). On 0x8071 the flag Solaar uses for its
/// "non-persistent" static effect is sent; this is unverified on a G203 and is the first thing to
/// check if the mouse keeps a color after being unplugged.
public struct HidppDriver: DeviceDriver {
    public let familyID = "logitech-gseries"

    /// Effect ids shared by COLOR_LED_EFFECTS and RGB_EFFECTS (libratbag's zone effect table).
    private static let disabledEffect: UInt16 = 0
    private static let fixedEffect: UInt16 = 1
    private static let cycleEffect: UInt16 = 3
    private static let breathingEffect: UInt16 = 10
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
            switch try await lightingFeature(client) {
            case .colorLED(let index):
                return .int(Int(try await client.request(featureIndex: index, function: 7)[0]))
            case .rgbEffects(let index):
                // GetSWControl: [sub-function echo, mode, flags]; any non-zero mode means the host owns the LEDs.
                let reply = try await client.request(featureIndex: index, function: 5)
                return .int(reply[1] == 0 ? 0 : 1)
            }
        case "polling_rate":
            let index = try await client.featureIndex(for: HidppFeature.adjustableReportRate)
            // GetReportRate (function 1) -> [period in ms]
            let periodMs = Int(try await client.request(featureIndex: index, function: 1)[0])
            guard periodMs > 0 else { throw HidppError.malformed("report period of 0") }
            return .int(1000 / periodMs)
        case "battery":
            return try await readBattery(client)
        case "onboard_state":
            return try await readOnboardState(client)
        case "features":
            // Diagnostic: "index:id" for every feature, e.g. "0:0000 1:0001 9:2201".
            let features = try await client.listFeatures()
            return .text(features.map { "\($0.index):" + String(format: "%04x", $0.id) }.joined(separator: " "))
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
        case ("backlight", .effect(let effect)):
            let built = try Self.effectParameters(for: effect)
            try await setEffect(built.id, parameters: built.parameters, client: client)
        case ("polling_rate", .int(let hertz)):
            try await setPollingRate(hertz, client: client)
        case ("device_mode", .int(let mode)):
            guard mode == 0 || mode == 1 else { throw DriverError.invalidValue("device_mode must be 0 (device) or 1 (host)") }
            switch try await lightingFeature(client) {
            case .colorLED(let index):
                _ = try await client.request(featureIndex: index, function: 8, parameters: [UInt8(mode)])
            case .rgbEffects(let index):
                try await setRGBHostControl(mode == 1, client: client, featureIndex: index)
            }
        case ("dpi_stages", .text(let text)):
            try await validateDPIStages(text, client: client)
        case ("dpi", _), ("backlight", _), ("device_mode", _), ("polling_rate", _), ("dpi_stages", _):
            throw DriverError.invalidValue("wrong value type for '\(capability.id)'")
        default:
            throw DriverError.unsupportedCapability(capability.id)
        }
    }

    // MARK: Lighting parameters (pure)

    static let periodRange = 1...0xFFFF
    static let defaultPeriod = 5000

    private static func scaled(_ color: RGBColor, brightness: Int) -> [UInt8] {
        [color.r, color.g, color.b].map { UInt8((Int($0) * brightness + 50) / 100) }
    }

    /// Effect id and the effect-specific bytes for 0x8071 / 0x8070 (libratbag `hidpp20_internal_led` layouts, which
    /// match Solaar's LEDEffects offsets): fixed = color; cycle = 5 unused, period BE16, intensity;
    /// breathing = color, period BE16, waveform, intensity. Static has no intensity field on the wire, so its
    /// brightness scales the color on the host.
    static func effectParameters(for effect: LightingEffect) throws -> (id: UInt16, parameters: [UInt8]) {
        let brightness = effect.brightness ?? 100
        guard (1...100).contains(brightness) else { throw DriverError.invalidValue("brightness must be 1...100") }
        let period = effect.period ?? defaultPeriod
        guard periodRange.contains(period) else { throw DriverError.invalidValue("period must be 1...65535 ms") }
        let periodBytes = [UInt8(period >> 8), UInt8(period & 0xFF)]
        switch effect.effect {
        case "static":
            guard let color = effect.color else { throw DriverError.invalidValue("static needs a color") }
            return (fixedEffect, scaled(color, brightness: brightness))
        case "off":
            return (disabledEffect, [])
        case "cycle":
            return (cycleEffect, [0, 0, 0, 0, 0] + periodBytes + [UInt8(brightness)])
        case "breathing":
            guard let color = effect.color else { throw DriverError.invalidValue("breathing needs a color") }
            let waveform = effect.waveform ?? 0
            guard (0...6).contains(waveform) else { throw DriverError.invalidValue("waveform must be 0...6") }
            return (breathingEffect, [color.r, color.g, color.b] + periodBytes + [UInt8(waveform), UInt8(brightness)])
        default:
            throw DriverError.invalidValue("unknown effect '\(effect.effect)'")
        }
    }

    // MARK: DPI stages (host side)

    /// DPI stages live in the profile and the app cycles them in software (the onboard stage table is
    /// persistent memory and is never written). The driver only checks every stage against the sensor's list.
    private func validateDPIStages(_ text: String, client: HidppClient) async throws {
        guard let stages = DPIStages(text: text) else {
            throw DriverError.invalidValue("dpi_stages needs 1 to 5 comma separated DPI values")
        }
        let index = try await client.featureIndex(for: HidppFeature.adjustableDPI)
        let list = HidppDPIList.parse(try await client.request(featureIndex: index, function: 1, parameters: [0]))
        for stage in stages.values where !list.contains(stage) {
            throw DriverError.invalidValue("\(stage) DPI is not supported by this sensor")
        }
    }

    // MARK: Onboard profiles (read only)

    /// 0x8100 read-only inspection: function 2 = GetOnboardMode (1 onboard, 2 host), function 4 = GetCurrentProfile
    /// (profile index in the second byte); libratbag CMD_ONBOARD_PROFILES_GET_ONBOARD_MODE 0x20 / GET_CURRENT_PROFILE 0x40.
    private func readOnboardState(_ client: HidppClient) async throws -> SettingValue {
        let index = try await client.featureIndex(for: HidppFeature.onboardProfiles)
        let mode = try await client.request(featureIndex: index, function: 2)[0]
        let profile = try await client.request(featureIndex: index, function: 4)[1]
        return .text("mode=\(mode == 2 ? "host" : mode == 1 ? "onboard" : String(mode)) profile=\(profile)")
    }

    // MARK: Battery

    /// Tries 0x1004 (unified), then 0x1000 (level status), then 0x1001 (voltage). Read-only.
    private func readBattery(_ client: HidppClient) async throws -> SettingValue {
        if let index = try await optionalFeatureIndex(client, HidppFeature.unifiedBattery) {
            // getStatus is function 1 (Solaar: feature_request(UNIFIED_BATTERY, 0x10)).
            return HidppBattery.unified(try await client.request(featureIndex: index, function: 1))
        }
        if let index = try await optionalFeatureIndex(client, HidppFeature.batteryLevelStatus) {
            return HidppBattery.levelStatus(try await client.request(featureIndex: index, function: 0))
        }
        if let index = try await optionalFeatureIndex(client, HidppFeature.batteryVoltage) {
            return HidppBattery.voltage(try await client.request(featureIndex: index, function: 0))
        }
        throw DriverError.unsupportedCapability("battery")
    }

    private func optionalFeatureIndex(_ client: HidppClient, _ id: UInt16) async throws -> UInt8? {
        do { return try await client.featureIndex(for: id) } catch HidppError.featureNotFound { return nil }
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

    // MARK: Polling rate (ADJUSTABLE_REPORT_RATE 0x8060)

    /// The period list is a bit field: bit n set means a period of (n + 1) ms is supported. Only the usual
    /// rates are offered, like libratbag does.
    static func supportedRates(bitFlags: UInt8) -> [Int: UInt8] {
        var rates: [Int: UInt8] = [:]
        for (bit, periodMs) in [(0, 1), (1, 2), (3, 4), (7, 8)] where bitFlags & (1 << UInt8(bit)) != 0 {
            rates[1000 / periodMs] = UInt8(periodMs)
        }
        return rates
    }

    private func setPollingRate(_ hertz: Int, client: HidppClient) async throws {
        let index = try await client.featureIndex(for: HidppFeature.adjustableReportRate)
        let flags = try await client.request(featureIndex: index, function: 0)[0]
        guard let periodMs = Self.supportedRates(bitFlags: flags)[hertz] else {
            throw DriverError.invalidValue("\(hertz) Hz is not supported by this mouse")
        }
        _ = try await client.request(featureIndex: index, function: 2, parameters: [periodMs])
    }

    // MARK: Lighting

    private enum LightingFeature {
        case colorLED(UInt8)    // 0x8070 (older mice)
        case rgbEffects(UInt8)  // 0x8071 (e.g. G203 LIGHTSYNC)
    }

    private func lightingFeature(_ client: HidppClient) async throws -> LightingFeature {
        do {
            return .colorLED(try await client.featureIndex(for: HidppFeature.colorLEDEffects))
        } catch HidppError.featureNotFound {
            do {
                return .rgbEffects(try await client.featureIndex(for: HidppFeature.rgbEffects))
            } catch HidppError.featureNotFound {
                throw DriverError.deviceFailure("this mouse exposes no supported lighting feature (0x8070 or 0x8071)")
            }
        }
    }

    private func setEffect(_ effectID: UInt16, parameters: [UInt8], client: HidppClient) async throws {
        switch try await lightingFeature(client) {
        case .colorLED(let index):
            try await ensureHostControl(client: client, featureIndex: index)
            let effectIndex = try await effectIndex(for: effectID, client: client, featureIndex: index)
            // [zone, effect index, effect parameters...]; byte 12 (persistence) stays 0 = RAM only.
            _ = try await client.request(featureIndex: index, function: 3,
                                         parameters: [Self.zone, effectIndex] + parameters)
        case .rgbEffects(let index):
            try await setRGBHostControl(true, client: client, featureIndex: index)
            var position = try await rgbEffectIndex(for: effectID, client: client, featureIndex: index)
            var colors = parameters
            if position == nil, effectID == Self.disabledEffect {
                // No "disabled" effect on this zone: black static is the same thing to the eye.
                position = try await rgbEffectIndex(for: Self.fixedEffect, client: client, featureIndex: index)
                colors = [0, 0, 0]
            }
            guard let position else {
                throw DriverError.deviceFailure("this LED zone has no effect 0x\(String(effectID, radix: 16))")
            }
            // SetEffectByIndex: [zone, effect index, 10 parameter bytes, flag]. Solaar sends flag 1 for its
            // "non-persistent" static effect on 0x8071.
            let effectParameters = colors + [UInt8](repeating: 0, count: 10 - colors.count)
            _ = try await client.request(featureIndex: index, function: 1,
                                         parameters: [Self.zone, position] + effectParameters + [0x01])
        }
    }

    /// 0x8070: zone effects are addressed by their position in the zone's effect list, not by id.
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

    /// 0x8070: zone effects only apply while the host controls the LEDs (Solaar's "LED Control").
    private func ensureHostControl(client: HidppClient, featureIndex: UInt8) async throws {
        let current = try await client.request(featureIndex: featureIndex, function: 7)
        guard current[0] == 0 else { return }
        _ = try await client.request(featureIndex: featureIndex, function: 8, parameters: [1])
    }

    /// 0x8071: position of an effect in the zone's list, or nil when the zone has none with that id.
    private func rgbEffectIndex(for effectID: UInt16, client: HidppClient, featureIndex: UInt8) async throws -> UInt8? {
        // device info: [cluster, effect, cluster count, ...]; zone info: [zone, effect, location (BE16), effect count, ...]
        let info = try await client.request(featureIndex: featureIndex, function: 0, parameters: [0xFF, 0xFF, 0x00])
        guard info[2] > Self.zone else { throw HidppError.malformed("device reports no LED zones") }
        let zoneInfo = try await client.request(featureIndex: featureIndex, function: 0, parameters: [Self.zone, 0xFF, 0x00])
        for position in 0..<zoneInfo[4] {
            // effect info: [zone, position, effect id (BE16), capabilities (BE16), period (BE16)]
            let effect = try await client.request(featureIndex: featureIndex, function: 0, parameters: [Self.zone, position, 0x00])
            if UInt16(effect[2]) << 8 | UInt16(effect[3]) == effectID { return position }
        }
        return nil
    }

    /// 0x8071: host control = onboard profiles in host mode + SetSWControl(mode 3, NV-config flag).
    /// Releasing reverses both. Sequences follow Solaar's LED Control setting.
    private func setRGBHostControl(_ enabled: Bool, client: HidppClient, featureIndex: UInt8) async throws {
        let profiles = try? await client.featureIndex(for: HidppFeature.onboardProfiles)
        if enabled {
            if let profiles { _ = try await client.request(featureIndex: profiles, function: 1, parameters: [0x02]) }
            _ = try await client.request(featureIndex: featureIndex, function: 5, parameters: [0x01, 0x03, 0x04])
        } else {
            _ = try await client.request(featureIndex: featureIndex, function: 5, parameters: [0x01, 0x00, 0x00])
            if let profiles { _ = try await client.request(featureIndex: profiles, function: 1, parameters: [0x01]) }
        }
    }
}
