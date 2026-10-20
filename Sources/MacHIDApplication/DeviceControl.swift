import MacHIDDomain

/// Port: opens a driver and transport for an attached device. Implemented at the composition root.
public protocol DeviceConnector: Sendable {
    func connect(to device: DiscoveredDevice, definition: DeviceDefinition) async throws -> (driver: any DeviceDriver, transport: any Transport)
    /// Called after a failure so a connector that keeps sessions open can drop the one for this device.
    func discard(_ device: DiscoveredDevice) async
}

extension DeviceConnector {
    public func discard(_ device: DiscoveredDevice) async {}
}

public enum ControlError: Error, Equatable, CustomStringConvertible {
    case deviceNotFound(USBID)
    case unsupportedDevice(USBID)
    case unknownCapability(String)
    case notWritable(String)
    case persistentWriteBlocked(String)
    case outOfRange(String)
    case invalidValue(String)

    public var description: String {
        switch self {
        case .deviceNotFound(let id): "no attached device with ID \(id)"
        case .unsupportedDevice(let id): "device \(id) has no definition"
        case .unknownCapability(let id): "unknown capability '\(id)'"
        case .notWritable(let id): "capability '\(id)' is read-only"
        case .persistentWriteBlocked(let id): "capability '\(id)' writes to device memory, which is not enabled yet"
        case .outOfRange(let why): "out of range: \(why)"
        case .invalidValue(let why): "invalid value: \(why)"
        }
    }
}

/// Use case: read or change one capability of an attached device, after checking the request against
/// the device definition. Only volatile writes are allowed until the explicit-save flow exists (SPEC §9).
public struct DeviceControl: Sendable {
    private let inventory: DeviceInventory
    public let connector: any DeviceConnector

    public init(inventory: DeviceInventory, connector: any DeviceConnector) {
        self.inventory = inventory
        self.connector = connector
    }

    public func read(_ id: USBID, capability capabilityID: String) async throws -> SettingValue {
        let (device, definition, capability) = try await resolve(id, capabilityID)
        let session = try await connector.connect(to: device, definition: definition)
        do {
            return try await session.driver.read(capability, using: session.transport)
        } catch {
            await connector.discard(device)
            throw error
        }
    }

    /// Forgets any open session for a device that is gone.
    public func discard(_ device: DiscoveredDevice) async { await connector.discard(device) }

    /// Limits reported by the device itself, if the driver has any for this capability.
    public func limits(_ id: USBID, capability capabilityID: String) async throws -> ValueLimits? {
        let (device, definition, capability) = try await resolve(id, capabilityID)
        let session = try await connector.connect(to: device, definition: definition)
        do {
            return try await session.driver.limits(for: capability, using: session.transport)
        } catch {
            await connector.discard(device)
            throw error
        }
    }

    public func write(_ id: USBID, capability capabilityID: String, value: SettingValue) async throws {
        let (device, definition, capability) = try await resolve(id, capabilityID)
        switch capability.access {
        case .read: throw ControlError.notWritable(capabilityID)
        case .writePersistent: throw ControlError.persistentWriteBlocked(capabilityID)
        case .writeVolatile: break
        }
        try Self.validate(value, against: capability)
        let session = try await connector.connect(to: device, definition: definition)
        do {
            try await session.driver.write(value, to: capability, using: session.transport)
        } catch {
            await connector.discard(device)
            throw error
        }
    }

    private func resolve(_ id: USBID, _ capabilityID: String) async throws -> (DiscoveredDevice, DeviceDefinition, CapabilityDescriptor) {
        guard let item = try inventory.item(for: id) else { throw ControlError.deviceNotFound(id) }
        guard let definition = item.definition else { throw ControlError.unsupportedDevice(id) }
        guard let capability = definition.capabilities.first(where: { $0.id == capabilityID }) else {
            throw ControlError.unknownCapability(capabilityID)
        }
        return (item.device, definition, capability)
    }

    static func validate(_ value: SettingValue, against capability: CapabilityDescriptor) throws {
        let parameters = capability.parameters
        switch (capability.type, value) {
        case (_, .int(let number)):
            if let low = parameters?.min, number < low { throw ControlError.outOfRange("\(number) < \(low)") }
            if let high = parameters?.max, number > high { throw ControlError.outOfRange("\(number) > \(high)") }
            if let allowed = parameters?.values, !allowed.contains(number) {
                throw ControlError.outOfRange("\(number) is not one of \(allowed)")
            }
            if let step = parameters?.step, let low = parameters?.min ?? Optional(0), (number - low) % step != 0 {
                throw ControlError.outOfRange("\(number) is not a multiple of \(step) from \(low)")
            }
        case (.lightingZone, .color):
            let modes = parameters?.zones?.flatMap(\.modes) ?? []
            guard modes.contains("static") else { throw ControlError.invalidValue("'\(capability.id)' has no static color mode") }
        case (.lightingZone, .effect(let effect)):
            let modes = parameters?.zones?.flatMap(\.modes) ?? []
            guard modes.contains(effect.effect) else { throw ControlError.invalidValue("'\(capability.id)' has no mode '\(effect.effect)'") }
        case (.lightingZone, .text(let mode)):
            let modes = parameters?.zones?.flatMap(\.modes) ?? []
            guard modes.contains(mode) else { throw ControlError.invalidValue("'\(capability.id)' has no mode '\(mode)'") }
        default:
            throw ControlError.invalidValue("wrong value type for '\(capability.id)'")
        }
    }
}
