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
}

/// `writePersistent` touches onboard memory and always needs an explicit user action.
public enum AccessMode: String, Sendable, Codable {
    case read
    case writeVolatile = "write_volatile"
    case writePersistent = "write_persistent"
}

public struct LightingZone: Sendable, Codable, Equatable {
    public let id: String
    public let modes: [String]

    public init(id: String, modes: [String]) {
        self.id = id
        self.modes = modes
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

    public init(min: Int? = nil, max: Int? = nil, step: Int? = nil, values: [Int]? = nil,
                zones: [LightingZone]? = nil, slots: Int? = nil) {
        self.min = min
        self.max = max
        self.step = step
        self.values = values
        self.zones = zones
        self.slots = slots
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
