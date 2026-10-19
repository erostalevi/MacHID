import Foundation

public struct HIDInterfaceInfo: Sendable, Codable, Hashable {
    public let usagePage: Int
    public let usage: Int

    public init(usagePage: Int, usage: Int) {
        self.usagePage = usagePage
        self.usage = usage
    }
}

/// A device currently attached, as reported by the OS. Read-only facts; nothing here is a setting.
public struct DiscoveredDevice: Sendable, Codable, Hashable {
    public let usbId: USBID
    public let name: String
    public let manufacturer: String?
    /// Only the last four characters are kept: serials are identifying and must not reach logs.
    public let serialSuffix: String?
    /// USB device release number (`bcdDevice`), e.g. "2.01". Not the vendor firmware version,
    /// which needs a driver to read.
    public let usbRelease: String?
    public let hidInterfaces: [HIDInterfaceInfo]

    public init(usbId: USBID, name: String, manufacturer: String? = nil, serialSuffix: String? = nil,
                usbRelease: String? = nil, hidInterfaces: [HIDInterfaceInfo] = []) {
        self.usbId = usbId
        self.name = name
        self.manufacturer = manufacturer
        self.serialSuffix = serialSuffix
        self.usbRelease = usbRelease
        self.hidInterfaces = hidInterfaces
    }

    /// Keeps the last four characters of a serial number.
    public static func redactSerial(_ serial: String?) -> String? {
        guard let serial, !serial.isEmpty else { return nil }
        return String(serial.suffix(4))
    }

    /// Formats a BCD release number: 0x0201 -> "2.01".
    public static func formatBCD(_ value: Int) -> String {
        let major = ((value >> 12) & 0xF) * 10 + ((value >> 8) & 0xF)
        let minor = ((value >> 4) & 0xF) * 10 + (value & 0xF)
        return "\(major)." + (minor < 10 ? "0" : "") + "\(minor)"
    }
}

/// Port: lists the devices attached right now. Implemented by the IOKit adapter.
public protocol DeviceEnumerator: Sendable {
    func enumerate() throws -> [DiscoveredDevice]
}

/// Device definitions indexed by USB ID.
public struct DefinitionCatalog: Sendable {
    private let byUSBID: [USBID: DeviceDefinition]
    public let definitions: [DeviceDefinition]

    public init(definitions: [DeviceDefinition]) {
        self.definitions = definitions
        var index: [USBID: DeviceDefinition] = [:]
        for definition in definitions {
            for id in definition.usbIds where index[id] == nil { index[id] = definition }
        }
        byUSBID = index
    }

    public func definition(for id: USBID) -> DeviceDefinition? { byUSBID[id] }

    /// Loads every `*.json` definition in a directory. Invalid files are reported, not skipped silently.
    public static func load(directory: URL) throws -> (catalog: DefinitionCatalog, errors: [String]) {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var loaded: [DeviceDefinition] = []
        var errors: [String] = []
        for file in files {
            do {
                let definition = try JSONDecoder().decode(DeviceDefinition.self, from: Data(contentsOf: file))
                try definition.validate()
                loaded.append(definition)
            } catch {
                errors.append("\(file.lastPathComponent): \(error)")
            }
        }
        return (DefinitionCatalog(definitions: loaded), errors)
    }
}
