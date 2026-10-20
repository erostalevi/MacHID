import MacHIDDomain

/// How a capability is shown. The UI is generated from these, never written per device (SPEC §4).
public enum ControlKind: Equatable, Sendable {
    /// `deviceLimits`: the real range comes from the device (see `DeviceDriver.limits`).
    case slider(min: Int, max: Int, step: Int, deviceLimits: Bool)
    case toggle
    case choice([Int])
    /// Lighting zone: the modes the device offers (static, off, spectrum, wave, ...).
    case lighting(modes: [String])
    /// Host (software) control of the device's lighting or mode.
    case hostControl
    case readout
}

public enum ControlSection: String, CaseIterable, Sendable {
    case lighting, performance, image, advanced, info
}

public struct ControlSpec: Equatable, Sendable, Identifiable {
    public let capability: CapabilityDescriptor
    public let kind: ControlKind
    public let section: ControlSection
    public let readable: Bool
    public var id: String { capability.id }

    /// Nil for capabilities this version has no widget for (they are simply not shown).
    public static func make(for capability: CapabilityDescriptor) -> ControlSpec? {
        let parameters = capability.parameters
        switch capability.type {
        case .info:
            return ControlSpec(capability: capability, kind: .readout, section: .info, readable: true)
        case .lightingZone:
            let modes = parameters?.zones?.flatMap(\.modes) ?? []
            guard modes.contains("static") else { return nil }
            return ControlSpec(capability: capability, kind: .lighting(modes: modes), section: .lighting, readable: false)
        case .pollingRate:
            let rates = parameters?.values?.sorted() ?? [125, 250, 500, 1000]
            return ControlSpec(capability: capability, kind: .choice(rates), section: .performance, readable: true)
        case .brightness:
            return ControlSpec(capability: capability, kind: .slider(min: parameters?.min ?? 0, max: parameters?.max ?? 100,
                                                                     step: parameters?.step ?? 1, deviceLimits: false),
                               section: .lighting, readable: true)
        case .dpi:
            return ControlSpec(capability: capability, kind: .slider(min: parameters?.min ?? 200, max: parameters?.max ?? 8000,
                                                                     step: parameters?.step ?? 50, deviceLimits: false),
                               section: .performance, readable: true)
        case .cameraControl:
            if let values = parameters?.values {
                return ControlSpec(capability: capability, kind: values.sorted() == [0, 1] ? .toggle : .choice(values.sorted()),
                                   section: .image, readable: true)
            }
            return ControlSpec(capability: capability, kind: .slider(min: parameters?.min ?? 0, max: parameters?.max ?? 255,
                                                                     step: parameters?.step ?? 1, deviceLimits: true),
                               section: .image, readable: true)
        case .deviceMode:
            return ControlSpec(capability: capability, kind: .hostControl, section: .advanced, readable: true)
        default:
            return nil
        }
    }

    /// Specs for a definition, in definition order, skipping what cannot be shown.
    public static func specs(for definition: DeviceDefinition) -> [ControlSpec] {
        definition.capabilities.compactMap(make(for:))
    }

    public var isWritable: Bool { capability.access != .read }

    /// A manual control that the device ignores while an automatic one is on (e.g. exposure time under auto exposure).
    public var disabledWhen: (control: String, equals: Int)? {
        switch id {
        case "exposure_time": ("exposure_auto", 1)
        case "white_balance_temperature": ("white_balance_auto", 1)
        default: nil
        }
    }
}

/// Which lighting modes take a color.
public enum LightingModes {
    public static func usesColor(_ mode: String) -> Bool { ["static", "reactive", "breathing", "starlight"].contains(mode) }
    /// Modes that also work without a color.
    public static func colorIsOptional(_ mode: String) -> Bool { mode == "starlight" }

    /// The mode a stored value corresponds to.
    public static func mode(of value: SettingValue?) -> String? {
        switch value {
        case .color?: "static"
        case .text(let text)?: text
        case .effect(let effect)?: effect.effect
        default: nil
        }
    }

    /// The value that selects `mode`, keeping `color` for the modes that use one.
    public static func value(for mode: String, color: RGBColor) -> SettingValue {
        switch mode {
        case "static": .color(color)
        case "off": .text("off")
        default: .effect(LightingEffect(mode, color: usesColor(mode) ? color : nil))
        }
    }
}
