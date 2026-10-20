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
    /// Per-model parameters for the driver family (for example a protocol transaction id). Plain text values:
    /// a definition is data and never carries code.
    public let driverOptions: [String: String]?
    /// Relative path of an SVG drawing of the device, with `hotspot-<capability>` shapes (see `ArtworkLayout`).
    public let artwork: String?

    enum CodingKeys: String, CodingKey {
        case id, name, category, driver, capabilities, artwork
        case usbIds = "usb_ids"
        case driverOptions = "driver_options"
    }

    public init(id: String, name: String, category: DeviceCategory, usbIds: [USBID],
                driver: String, capabilities: [CapabilityDescriptor], driverOptions: [String: String]? = nil, artwork: String? = nil) {
        self.artwork = artwork
        self.driverOptions = driverOptions
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
    case invalidArtwork(String)

    public var description: String {
        switch self {
        case .invalidID(let id): "Invalid id '\(id)' (lowercase letters, digits and '-')"
        case .noUSBIDs: "A definition needs at least one USB ID"
        case .duplicateCapability(let id): "Duplicate capability id '\(id)'"
        case .invalidRange(let id): "Capability '\(id)' has an invalid range"
        case .invalidArtwork(let path): "Artwork path '\(path)' must be a relative .svg path inside the plugin"
        }
    }
}

extension DeviceDefinition {
    public func validate() throws {
        guard Identifier.isValid(id) else { throw DefinitionError.invalidID(id) }
        if let artwork, !(PluginManifest.isSafeRelativePath(artwork) && artwork.hasSuffix(".svg")) { throw DefinitionError.invalidArtwork(artwork) }
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

extension DeviceDefinition: Identifiable {}
