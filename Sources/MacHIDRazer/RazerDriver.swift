import Foundation
import MacHIDDomain

/// Per-model parameters of the Razer protocol family.
public struct RazerModel: Sendable, Equatable {
    public let usbId: USBID
    /// Transaction id used for the extended-matrix (lighting) commands.
    public let lightingTransactionID: UInt8

    public static let known: [RazerModel] = [
        RazerModel(usbId: USBID(vendor: 0x1532, product: 0x0257), lightingTransactionID: 0x3F), // Huntsman Mini
    ]

    public static func model(for id: USBID) -> RazerModel? { known.first { $0.usbId == id } }

    /// The model for a device: parameters from its definition when it gives them (so new models can be added as
    /// data), otherwise the built-in table.
    public static func model(for id: USBID, options: [String: String]?) -> RazerModel? {
        if let text = options?["lighting_transaction_id"], let value = parseByte(text) {
            return RazerModel(usbId: id, lightingTransactionID: value)
        }
        return model(for: id)
    }

    /// Accepts "0x3F" or "63".
    static func parseByte(_ text: String) -> UInt8? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.hasPrefix("0x") ? UInt8(trimmed.dropFirst(2), radix: 16) : UInt8(trimmed)
    }
}

/// Razer family driver (M2 scope: firmware, backlight brightness, static color / off).
///
/// Capability ids: `info` (read, text), `brightness` (0-100), `backlight` (write: color or "off"),
/// `device_mode` (0 normal, 3 driver; volatile).
/// All writes use variable storage, i.e. nothing is stored in onboard memory.
public struct RazerDriver: DeviceDriver {
    public let familyID = "razer"
    public let model: RazerModel
    private let attempts: Int
    private let settleDelay: Duration

    public init(model: RazerModel, attempts: Int = 5, settleDelay: Duration = .milliseconds(10)) {
        self.model = model
        self.attempts = attempts
        self.settleDelay = settleDelay
    }

    public func read(_ capability: CapabilityDescriptor, using transport: any Transport) async throws -> SettingValue {
        switch capability.id {
        case "info":
            let response = try await exchange(RazerCommands.firmwareVersion(), on: transport)
            return .text("v\(response.arguments[0]).\(response.arguments[1])")
        case "brightness":
            let response = try await exchange(RazerCommands.getBrightness(transactionID: model.lightingTransactionID), on: transport)
            return .int(Self.percent(fromRaw: response.arguments[2]))
        case "device_mode":
            let response = try await exchange(RazerCommands.getDeviceMode(), on: transport)
            return .int(Int(response.arguments[0]))
        default:
            throw DriverError.unsupportedCapability(capability.id)
        }
    }

    public func write(_ value: SettingValue, to capability: CapabilityDescriptor, using transport: any Transport) async throws {
        let tid = model.lightingTransactionID
        switch (capability.id, value) {
        case ("brightness", .int(let percent)):
            guard (0...100).contains(percent) else { throw DriverError.invalidValue("brightness must be 0-100") }
            try await ensureDriverMode(on: transport)
            _ = try await exchange(RazerCommands.setBrightness(Self.raw(fromPercent: percent), transactionID: tid), on: transport)
        case ("backlight", .color(let color)):
            try await ensureDriverMode(on: transport)
            _ = try await exchange(RazerCommands.staticColor(color, transactionID: tid), on: transport)
        case ("backlight", .text("off")):
            try await ensureDriverMode(on: transport)
            _ = try await exchange(RazerCommands.effectNone(transactionID: tid), on: transport)
        case ("backlight", .effect(let effect)):
            let request: RazerReport
            switch (effect.effect, effect.color) {
            case ("spectrum", _): request = RazerCommands.spectrum(transactionID: tid)
            case ("wave", _): request = RazerCommands.wave(direction: 1, transactionID: tid)
            case ("reactive", let color?): request = RazerCommands.reactive(speed: 2, color: color, transactionID: tid)
            case ("starlight", let color): request = RazerCommands.starlight(speed: 2, color: color, transactionID: tid)
            case ("reactive", nil): throw DriverError.invalidValue("reactive needs a color")
            default: throw DriverError.invalidValue("unknown effect '\(effect.effect)'")
            }
            try await ensureDriverMode(on: transport)       // only after the request is known to be valid
            _ = try await exchange(request, on: transport)
        case ("device_mode", .int(let mode)):
            guard mode == 0 || mode == 3 else { throw DriverError.invalidValue("device_mode must be 0 (normal) or 3 (driver)") }
            _ = try await exchange(RazerCommands.setDeviceMode(UInt8(mode)), on: transport)
        case ("brightness", _), ("backlight", _), ("device_mode", _):
            throw DriverError.invalidValue("wrong value type for '\(capability.id)'")
        default:
            throw DriverError.unsupportedCapability(capability.id)
        }
    }

    /// Software lighting is ignored while the keyboard runs its own onboard effect (verified on a
    /// Huntsman Mini). Driver mode (3) hands lighting to the host. It is volatile and is left in place
    /// until `device_mode` is set back to 0 or the keyboard is unplugged; special keys can behave
    /// differently while it is active.
    func ensureDriverMode(on transport: any Transport) async throws {
        let current = try await exchange(RazerCommands.getDeviceMode(), on: transport)
        guard current.arguments[0] != 0x03 else { return }
        _ = try await exchange(RazerCommands.setDeviceMode(0x03), on: transport)
    }

    static func raw(fromPercent percent: Int) -> UInt8 { UInt8((Double(percent) * 255 / 100).rounded()) }
    static func percent(fromRaw raw: UInt8) -> Int { Int((Double(raw) * 100 / 255).rounded()) }

    /// Sends a request and waits for a matching, successful response. Retries while the device is busy.
    func exchange(_ request: RazerReport, on transport: any Transport) async throws -> RazerReport {
        for attempt in 1...attempts {
            try await transport.sendFeatureReport(reportID: 0, request.encoded())
            try await Task.sleep(for: settleDelay)
            let response = try RazerReport.decode(try await transport.getFeatureReport(reportID: 0, length: RazerReport.size))
            guard response.commandClass == request.commandClass,
                  response.commandID == request.commandID else {
                throw DriverError.deviceFailure("response does not match the request")
            }
            switch RazerReport.Status(rawValue: response.status) {
            case .successful: return response
            case .busy where attempt < attempts: continue
            case .busy: throw DriverError.deviceFailure("device stayed busy")
            case .notSupported: throw DriverError.deviceFailure("command not supported by this device")
            case .timeout: throw DriverError.deviceFailure("device timed out")
            default: throw DriverError.deviceFailure("command failed (status 0x\(String(response.status, radix: 16)))")
            }
        }
        throw DriverError.deviceFailure("no response")
    }
}
