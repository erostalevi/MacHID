import Foundation
import MacHIDDomain

/// Per-model parameters of the Razer protocol family.
public struct RazerModel: Sendable, Equatable {
    public let usbId: USBID
    /// Transaction id used for the extended-matrix (lighting) commands.
    public let lightingTransactionID: UInt8
    /// Transaction id for the battery commands (OpenRazer uses 0x3F, 0x1F or 0xFF depending on the model).
    /// Set through the definition's `driver_options.battery_transaction_id`; 0x3F when absent.
    public let batteryTransactionID: UInt8
    /// Key matrix size used by the custom frame (OpenRazer `MATRIX_DIMS`; Huntsman Mini is [5, 15]).
    /// Definitions can override it with `driver_options.matrix_rows` / `matrix_columns`.
    public let matrixRows: Int
    public let matrixColumns: Int

    public init(usbId: USBID, lightingTransactionID: UInt8, batteryTransactionID: UInt8 = 0x3F,
                matrixRows: Int = 5, matrixColumns: Int = 15) {
        self.matrixRows = matrixRows
        self.matrixColumns = matrixColumns
        self.usbId = usbId
        self.lightingTransactionID = lightingTransactionID
        self.batteryTransactionID = batteryTransactionID
    }

    public static let known: [RazerModel] = [
        RazerModel(usbId: USBID(vendor: 0x1532, product: 0x0257), lightingTransactionID: 0x3F), // Huntsman Mini
    ]

    public static func model(for id: USBID) -> RazerModel? { known.first { $0.usbId == id } }

    /// The model for a device: parameters from its definition when it gives them (so new models can be added as
    /// data), otherwise the built-in table.
    public static func model(for id: USBID, options: [String: String]?) -> RazerModel? {
        let battery = options?["battery_transaction_id"].flatMap(parseByte)
        let rows = options?["matrix_rows"].flatMap { Int($0) }.flatMap { (1...8).contains($0) ? $0 : nil }
        let columns = options?["matrix_columns"].flatMap { Int($0) }.flatMap { (1...25).contains($0) ? $0 : nil }
        if let text = options?["lighting_transaction_id"], let value = parseByte(text) {
            return RazerModel(usbId: id, lightingTransactionID: value, batteryTransactionID: battery ?? 0x3F,
                              matrixRows: rows ?? 5, matrixColumns: columns ?? 15)
        }
        guard let base = model(for: id) else { return nil }
        return RazerModel(usbId: id, lightingTransactionID: base.lightingTransactionID,
                          batteryTransactionID: battery ?? base.batteryTransactionID,
                          matrixRows: rows ?? base.matrixRows, matrixColumns: columns ?? base.matrixColumns)
    }

    /// Accepts "0x3F" or "63".
    static func parseByte(_ text: String) -> UInt8? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.hasPrefix("0x") ? UInt8(trimmed.dropFirst(2), radix: 16) : UInt8(trimmed)
    }
}

/// Razer family driver (M2 scope: firmware, backlight brightness, static color / off).
///
/// Capability ids: `info` (read, text), `brightness` (0-100), `backlight` (write: color, "off" or an effect:
/// spectrum, wave, reactive, starlight, breathing), `key_lighting` (write `.keyFrame`), `device_mode` (0 normal, 3 driver; volatile).
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
        case "battery":
            let level = try await exchange(RazerCommands.batteryLevel(transactionID: model.batteryTransactionID), on: transport)
            // Some models (AA-powered ones) reject the charging query: report the level without it.
            let charging = try? await exchange(RazerCommands.chargingStatus(transactionID: model.batteryTransactionID), on: transport)
            return .battery(percent: Self.percent(fromRaw: level.arguments[1]), charging: charging.map { $0.arguments[1] != 0 })
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
            let request = try Self.effectRequest(effect, transactionID: tid)
            try await ensureDriverMode(on: transport)       // only after the request is known to be valid
            _ = try await exchange(request, on: transport)
        case ("key_lighting", .keyFrame(let keys)):
            let rows = try customFrameRows(for: keys)       // validates before touching the device
            try await ensureDriverMode(on: transport)
            for (index, colors) in rows.enumerated() {
                _ = try await exchange(RazerCommands.customFrameRow(row: UInt8(index), startColumn: 0, colors: colors,
                                                                   transactionID: tid), on: transport)
            }
            _ = try await exchange(RazerCommands.activateCustomFrame(transactionID: tid), on: transport)
        case ("device_mode", .int(let mode)):
            guard mode == 0 || mode == 3 else { throw DriverError.invalidValue("device_mode must be 0 (normal) or 3 (driver)") }
            _ = try await exchange(RazerCommands.setDeviceMode(UInt8(mode)), on: transport)
        case ("brightness", _), ("backlight", _), ("device_mode", _), ("key_lighting", _):
            throw DriverError.invalidValue("wrong value type for '\(capability.id)'")
        default:
            throw DriverError.unsupportedCapability(capability.id)
        }
    }

    /// Maps an effect value to its request. Defaults: wave direction 1, reactive speed 2, starlight speed 2.
    /// Speeds and directions out of range are rejected rather than clamped silently.
    static func effectRequest(_ effect: LightingEffect, transactionID tid: UInt8) throws -> RazerReport {
        func check(_ value: Int?, _ range: ClosedRange<Int>, default fallback: Int, _ what: String) throws -> UInt8 {
            let value = value ?? fallback
            guard range.contains(value) else { throw DriverError.invalidValue("\(what) must be \(range.lowerBound)-\(range.upperBound)") }
            return UInt8(value)
        }
        if effect.secondColor != nil, effect.color == nil {
            throw DriverError.invalidValue("a second color needs a first color")
        }
        switch effect.effect {
        case "spectrum": return RazerCommands.spectrum(transactionID: tid)
        case "wave": return RazerCommands.wave(direction: try check(effect.direction, 0...1, default: 1, "wave direction"), transactionID: tid)
        case "reactive":
            guard let color = effect.color else { throw DriverError.invalidValue("reactive needs a color") }
            return RazerCommands.reactive(speed: try check(effect.speed, 1...4, default: 2, "reactive speed"), color: color, transactionID: tid)
        case "starlight":
            let speed = try check(effect.speed, 1...3, default: 2, "starlight speed")
            if let color = effect.color, let second = effect.secondColor {
                return RazerCommands.starlight(speed: speed, color: color, secondColor: second, transactionID: tid)
            }
            return RazerCommands.starlight(speed: speed, color: effect.color, transactionID: tid)
        case "breathing": return RazerCommands.breathing(color: effect.color, secondColor: effect.secondColor, transactionID: tid)
        default: throw DriverError.invalidValue("unknown effect '\(effect.effect)'")
        }
    }

    /// Dense rows (row index -> one color per column) for a key frame; dark where no key is listed, last entry wins.
    func customFrameRows(for keys: [KeyColor]) throws -> [[RGBColor]] {
        var rows = [[RGBColor]](repeating: [RGBColor](repeating: RGBColor(r: 0, g: 0, b: 0), count: model.matrixColumns),
                                count: model.matrixRows)
        for key in keys {
            guard (0..<model.matrixRows).contains(key.row), (0..<model.matrixColumns).contains(key.col) else {
                throw DriverError.invalidValue("key (\(key.row), \(key.col)) is outside the \(model.matrixRows)x\(model.matrixColumns) matrix")
            }
            rows[key.row][key.col] = key.color
        }
        return rows
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
