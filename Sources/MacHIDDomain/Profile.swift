public struct RGBColor: Sendable, Codable, Equatable {
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }
}

/// A named lighting effect, optionally with a color (e.g. reactive, breathing, starlight).
public struct LightingEffect: Sendable, Codable, Equatable {
    public let effect: String
    public let color: RGBColor?

    public init(_ effect: String, color: RGBColor? = nil) {
        self.effect = effect
        self.color = color
    }
}

/// A single value a profile stores for a capability.
public enum SettingValue: Sendable, Equatable, Codable {
    case bool(Bool)
    case int(Int)
    case effect(LightingEffect)
    case color(RGBColor)
    case text(String)
    /// Read-only battery reading. `percent` is nil when the device gives no usable level; `charging` nil when unknown.
    case battery(percent: Int?, charging: Bool?)

    private struct BatteryPayload: Codable { let percent: Int?; let charging: Bool? }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(LightingEffect.self) { self = .effect(value) }
        else if let value = try? container.decode(RGBColor.self) { self = .color(value) }
        else if let value = try? container.decode(BatteryPayload.self) { self = .battery(percent: value.percent, charging: value.charging) }
        else { self = .text(try container.decode(String.self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .effect(let value): try container.encode(value)
        case .color(let value): try container.encode(value)
        case .text(let value): try container.encode(value)
        case .battery(let percent, let charging): try container.encode(BatteryPayload(percent: percent, charging: charging))
        }
    }
}

/// Settings the hub owns. The hub, not the device, is the source of truth (see SPEC §8).
public struct Profile: Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: String
    public var name: String
    /// device definition id -> capability id -> value.
    public var settings: [String: [String: SettingValue]]

    public init(id: String, name: String, settings: [String: [String: SettingValue]] = [:],
                schemaVersion: Int = Profile.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.settings = settings
    }
}

extension Profile: Identifiable {}
