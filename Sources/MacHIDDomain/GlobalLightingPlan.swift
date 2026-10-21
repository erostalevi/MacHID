/// Global light control: one simple preset applied to every device (see `GlobalLightingPlan`).
public enum GlobalLightingPreset: Sendable, Equatable, Codable {
    case off
    case solid(RGBColor)
    case spectrum
    case wave
    case breathing(RGBColor)

    /// Effect id as device definitions name it.
    var effectID: String {
        switch self {
        case .off: "off"
        case .solid: "static"
        case .spectrum: "spectrum"
        case .wave: "wave"
        case .breathing: "breathing"
        }
    }
}

public struct GlobalLightingSettings: Sendable, Equatable, Codable {
    public var preset: GlobalLightingPreset
    /// 1...100.
    public var brightness: Int
    /// Seconds per cycle for spectrum, wave and breathing (the shared cycle timer).
    public var cycleSeconds: Double
    /// Keep animated effects phase-locked: devices whose own firmware cannot take the period (or be phase-locked) but that can
    /// show per-key frames are driven in software from the shared clock instead.
    public var keepInSync: Bool

    public init(preset: GlobalLightingPreset, brightness: Int = 100, cycleSeconds: Double = 10, keepInSync: Bool = true) {
        self.preset = preset
        self.brightness = min(max(brightness, 1), 100)
        self.cycleSeconds = cycleSeconds
        self.keepInSync = keepInSync
    }
}

public struct GlobalLightingDevice: Sendable, Equatable {
    public let id: String
    public let definition: DeviceDefinition
    public init(id: String, definition: DeviceDefinition) { self.id = id; self.definition = definition }
}

/// What to do on every device to show a global preset. Pure: it only reads capabilities and returns writes.
public struct GlobalLightingPlan: Sendable, Equatable {
    public struct Write: Sendable, Equatable {
        public let deviceID: String
        public let capabilityID: String
        public let value: SettingValue
        public init(deviceID: String, capabilityID: String, value: SettingValue) {
            self.deviceID = deviceID; self.capabilityID = capabilityID; self.value = value
        }
    }
    public struct Skip: Sendable, Equatable {
        public let deviceID: String
        public let reason: String
        public init(deviceID: String, reason: String) { self.deviceID = deviceID; self.reason = reason }
    }

    /// Native writes, to apply to all devices back to back (firmware effects start when they arrive, so a tight loop keeps them close).
    public var writes: [Write] = []
    /// Devices to drive in software from the shared `LightingClock` (render the `scene` and stream key frames).
    public var softwareDeviceIDs: [String] = []
    /// Devices whose firmware effect runs on its own clock: same period at best, not phase-locked.
    public var notPhaseLockedDeviceIDs: [String] = []
    public var skipped: [Skip] = []

    public init() {}

    private static func pickMode(_ preset: GlobalLightingPreset, zone: LightingZone) -> String? {
        let wanted: [String] = switch preset {
        case .off: ["off"]
        case .solid: ["static"]
        case .spectrum: ["spectrum", "cycle"]
        case .wave: ["wave", "spectrum", "cycle"]
        case .breathing: ["breathing"]
        }
        return wanted.first { zone.modes.contains($0) }
    }

    /// The software scene equal to the settings (for `softwareDeviceIDs`); the caller retimes it with `LightingClock.retimed`.
    public static func scene(for settings: GlobalLightingSettings) -> LightingScene {
        let kind: LightingLayerKind? = switch settings.preset {
        case .off: nil
        case .solid(let c): .solid(c)
        case .spectrum: .spectrum(speed: 1)
        case .wave: .wave(speed: 1, direction: 0)
        case .breathing(let c): .breathing(color: c, speed: 1)
        }
        let layers = kind.map { [LightingLayer(id: "global", name: "Global", kind: $0)] } ?? []
        return LightingScene(id: "global", name: "Global", layers: layers, brightness: settings.brightness, syncToGlobalClock: true)
    }

    public static func make(settings: GlobalLightingSettings, devices: [GlobalLightingDevice]) -> GlobalLightingPlan {
        var plan = GlobalLightingPlan()
        let animated: Bool = { switch settings.preset { case .spectrum, .wave, .breathing: true; default: false } }()
        for device in devices {
            let caps = device.definition.capabilities
            guard let lighting = caps.first(where: { $0.type == .lightingZone && $0.access != .read }),
                  let zone = lighting.parameters?.zones?.first else {
                if device.definition.category != .camera { plan.skipped.append(Skip(deviceID: device.id, reason: "no lighting")) }
                continue
            }
            let hasFrames = caps.contains { $0.type == .perKeyLighting && $0.access != .read }
            let mode = pickMode(settings.preset, zone: zone)
            let periodMs = Int((settings.cycleSeconds * 1000).rounded())
            let takesPeriod = (zone.periodMin != nil || zone.periodMax != nil) && (mode == "cycle" || mode == "breathing")
            // Software sync wins when the preset animates, sync is wanted, frames are available and the firmware cannot take a period.
            if animated, settings.keepInSync, hasFrames, !takesPeriod {
                plan.softwareDeviceIDs.append(device.id)
                continue
            }
            guard let mode else {
                plan.skipped.append(Skip(deviceID: device.id, reason: "no matching effect"))
                continue
            }
            var color: RGBColor?
            switch settings.preset {
            case .solid(let c), .breathing(let c): color = c
            default: break
            }
            let separateBrightness = caps.first { $0.type == .brightness && $0.access != .read }
            let inline = zone.brightness == true && separateBrightness == nil
            var period: Int?
            if takesPeriod {
                period = min(max(periodMs, zone.periodMin ?? periodMs), zone.periodMax ?? periodMs)
            }
            let effect = LightingEffect(mode, color: color, period: period, brightness: inline ? settings.brightness : nil)
            plan.writes.append(Write(deviceID: device.id, capabilityID: lighting.id, value: .effect(effect)))
            if let separateBrightness {
                plan.writes.append(Write(deviceID: device.id, capabilityID: separateBrightness.id, value: .int(settings.brightness)))
            }
            if animated, !(mode == "static" || mode == "off") { plan.notPhaseLockedDeviceIDs.append(device.id) }
        }
        return plan
    }
}
