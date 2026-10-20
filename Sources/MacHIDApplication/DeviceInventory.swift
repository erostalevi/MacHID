import MacHIDDomain

public struct InventoryItem: Sendable, Codable, Equatable {
    public let device: DiscoveredDevice
    /// Nil when no definition matches the USB ID (the device is detected but unsupported).
    public let definition: DeviceDefinition?

    public init(device: DiscoveredDevice, definition: DeviceDefinition?) {
        self.device = device
        self.definition = definition
    }

    public var isSupported: Bool { definition != nil }
}

/// Use case: what is plugged in, and which of it do we know how to handle.
public struct DeviceInventory: Sendable {
    public let enumerator: any DeviceEnumerator
    public let catalog: DefinitionCatalog

    public init(enumerator: any DeviceEnumerator, catalog: DefinitionCatalog) {
        self.enumerator = enumerator
        self.catalog = catalog
    }

    public func items(includeUnsupported: Bool) throws -> [InventoryItem] {
        try enumerator.enumerate()
            .map { InventoryItem(device: $0, definition: catalog.definition(for: $0.usbId)) }
            .filter { includeUnsupported || $0.isSupported }
            .sorted { ($0.device.name, $0.device.usbId.description) < ($1.device.name, $1.device.usbId.description) }
    }

    /// Finds one attached device by USB ID.
    public func item(for id: USBID) throws -> InventoryItem? {
        try items(includeUnsupported: true).first { $0.device.usbId == id }
    }
}
