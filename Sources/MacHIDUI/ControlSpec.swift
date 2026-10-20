import MacHIDDomain

/// How a capability is shown. The UI is generated from these, never written per device (SPEC §4).
public enum ControlKind: Equatable, Sendable {
    /// `deviceLimits`: the real range comes from the device (see `DeviceDriver.limits`).
    case slider(min: Int, max: Int, step: Int, deviceLimits: Bool)
    case toggle
    case choice([Int])
    case color(canTurnOff: Bool)
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
            return ControlSpec(capability: capability, kind: .color(canTurnOff: modes.contains("off")), section: .lighting, readable: false)
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
}
