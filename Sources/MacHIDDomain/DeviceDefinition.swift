public enum DeviceCategory: String, Sendable, Codable {
    case mouse, keyboard, camera, headset, other
}

/// Declarative description of a device model. Data only: it never executes code.
public struct DeviceDefinition: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let category: DeviceCategory
    public let usbIds: [USBID]
    /// Protocol-family driver that handles this device (e.g. `razer`, `logitech-gseries`, `uvc`).
    public let driver: String
    public let capabilities: [CapabilityDescriptor]

    enum CodingKeys: String, CodingKey {
        case id, name, category, driver, capabilities
        case usbIds = "usb_ids"
    }

    public init(id: String, name: String, category: DeviceCategory, usbIds: [USBID],
                driver: String, capabilities: [CapabilityDescriptor]) {
        self.id = id
        self.name = name
        self.category = category
        self.usbIds = usbIds
        self.driver = driver
        self.capabilities = capabilities
    }
}

public enum DefinitionError: Error, Equatable, CustomStringConvertible {
    case invalidID(String)
    case noUSBIDs
    case duplicateCapability(String)
    case invalidRange(capability: String)

    public var description: String {
        switch self {
        case .invalidID(let id): "Invalid id '\(id)' (lowercase letters, digits and '-')"
        case .noUSBIDs: "A definition needs at least one USB ID"
        case .duplicateCapability(let id): "Duplicate capability id '\(id)'"
        case .invalidRange(let id): "Capability '\(id)' has an invalid range"
        }
    }
}

extension DeviceDefinition {
    public func validate() throws {
        guard Identifier.isValid(id) else { throw DefinitionError.invalidID(id) }
        guard !usbIds.isEmpty else { throw DefinitionError.noUSBIDs }
        var seen = Set<String>()
        for capability in capabilities {
            guard seen.insert(capability.id).inserted else {
                throw DefinitionError.duplicateCapability(capability.id)
            }
            if let p = capability.parameters {
                if let lo = p.min, let hi = p.max, lo > hi { throw DefinitionError.invalidRange(capability: capability.id) }
                if let step = p.step, step <= 0 { throw DefinitionError.invalidRange(capability: capability.id) }
            }
        }
    }
}

/// Ids for plugins and definitions: lowercase kebab-case.
enum Identifier {
    static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64,
              value.first != "-", value.last != "-" else { return false }
        return value.utf8.allSatisfy { ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 }
    }
}
