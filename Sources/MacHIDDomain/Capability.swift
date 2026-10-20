public enum CapabilityType: String, Sendable, Codable, CaseIterable {
    case dpi
    case pollingRate = "polling_rate"
    case lightingZone = "lighting_zone"
    case brightness
    case buttonRemap = "button_remap"
    case keyRemap = "key_remap"
    case macroSlots = "macro_slots"
    case profileSlots = "profile_slots"
    case battery
    case info
    case cameraControl = "camera_control"
    /// Switches a device between its own onboard behavior and host (driver) control.
    case deviceMode = "device_mode"
    /// Host-side list of DPI steps the app cycles through in software (value: comma separated text, e.g. "400,800,1600").
    case dpiStages = "dpi_stages"
    /// Per-key colors on a key matrix (value: `SettingValue.keyFrame`). Parameters: `rows`, `columns`.
    case perKeyLighting = "per_key_lighting"
}

/// `writePersistent` touches onboard memory and always needs an explicit user action.
public enum AccessMode: String, Sendable, Codable {
    case read
    case writeVolatile = "write_volatile"
    case writePersistent = "write_persistent"
}

/// What a lighting mode accepts besides its main color (all optional; nil means "not supported").
/// `speedMin...speedMax` bound `LightingEffect.speed`; `directions` names the values of `LightingEffect.direction`
/// in order from 0; `colorsMin...colorsMax` bound how many colors (`color`, `secondColor`) the mode takes.
public struct LightingModeOptions: Sendable, Codable, Equatable {
    public let speedMin: Int?
    public let speedMax: Int?
    public let directions: [String]?
    public let colorsMin: Int?
    public let colorsMax: Int?

    private enum CodingKeys: String, CodingKey {
        case directions
        case speedMin = "speed_min"
        case speedMax = "speed_max"
        case colorsMin = "colors_min"
        case colorsMax = "colors_max"
    }

    public init(speedMin: Int? = nil, speedMax: Int? = nil, directions: [String]? = nil,
                colorsMin: Int? = nil, colorsMax: Int? = nil) {
        self.speedMin = speedMin
        self.speedMax = speedMax
        self.directions = directions
        self.colorsMin = colorsMin
        self.colorsMax = colorsMax
    }
}

public struct LightingZone: Sendable, Codable, Equatable {
    public let id: String
    public let modes: [String]
    /// Accepted effect period range in milliseconds (cycle, breathing); nil when the zone has no speed control.
    public let periodMin: Int?
    public let periodMax: Int?
    /// True when effects accept a brightness percentage (1...100).
    public let brightness: Bool?
    /// Breathing waveform names the zone accepts, in `LightingEffect.waveform` id order starting at 0.
    public let waveforms: [String]?
    /// Per-mode extras (speed range, directions, number of colors), keyed by mode name.
    public let modeOptions: [String: LightingModeOptions]?

    private enum CodingKeys: String, CodingKey {
        case id, modes, brightness, waveforms
        case modeOptions = "mode_options"
        case periodMin = "period_min"
        case periodMax = "period_max"
    }

    public init(id: String, modes: [String], periodMin: Int? = nil, periodMax: Int? = nil,
                brightness: Bool? = nil, waveforms: [String]? = nil, modeOptions: [String: LightingModeOptions]? = nil) {
        self.id = id
        self.modes = modes
        self.periodMin = periodMin
        self.periodMax = periodMax
        self.brightness = brightness
        self.waveforms = waveforms
        self.modeOptions = modeOptions
    }
}

/// Bounds and options for a capability. Which fields apply depends on the type.
public struct CapabilityParameters: Sendable, Codable, Equatable {
    public var min: Int?
    public var max: Int?
    public var step: Int?
    public var values: [Int]?
    public var zones: [LightingZone]?
    public var slots: Int?
    /// Key matrix size (`per_key_lighting`).
    public var rows: Int?
    public var columns: Int?

    public init(min: Int? = nil, max: Int? = nil, step: Int? = nil, values: [Int]? = nil,
                zones: [LightingZone]? = nil, slots: Int? = nil, rows: Int? = nil, columns: Int? = nil) {
        self.min = min
        self.max = max
        self.step = step
        self.values = values
        self.zones = zones
        self.slots = slots
        self.rows = rows
        self.columns = columns
    }
}

public struct CapabilityDescriptor: Sendable, Codable, Equatable {
    public let id: String
    public let type: CapabilityType
    public let access: AccessMode
    public let parameters: CapabilityParameters?

    public init(id: String, type: CapabilityType, access: AccessMode, parameters: CapabilityParameters? = nil) {
        self.id = id
        self.type = type
        self.access = access
        self.parameters = parameters
    }
}
