import SwiftUI
import MacHIDApplication
import MacHIDDomain

/// Fake devices for design review and snapshots: no hardware, no permissions, nothing is written.
public enum PreviewSupport {
    private struct NoEnumerator: DeviceEnumerator { func enumerate() throws -> [DiscoveredDevice] { [] } }
    private struct NoConnector: DeviceConnector {
        func connect(to device: DiscoveredDevice, definition: DeviceDefinition) async throws -> (driver: any DeviceDriver, transport: any Transport) {
            throw DriverError.deviceFailure("preview only")
        }
    }
    private actor EmptyRepository: ProfileRepository {
        func load() -> [Profile] { [] }
        func save(_ profile: Profile) {}
        func delete(id: String) {}
    }

    /// A model filled with sample devices from the bundled definitions.
    @MainActor
    public static func model(selecting category: DeviceCategory = .keyboard, profileName: String? = "Work") -> AppModel {
        let (catalog, _) = (try? AppModel.loadDefinitions()) ?? (DefinitionCatalog(definitions: []), [])
        let inventory = DeviceInventory(enumerator: NoEnumerator(), catalog: catalog)
        let model = AppModel(inventory: inventory, control: DeviceControl(inventory: inventory, connector: NoConnector()),
                             repository: EmptyRepository(), defaults: UserDefaults(suiteName: "machid.preview")!,
                             permissionCheck: { true })
        model.loadPreviewDevices(catalog.definitions, selecting: category, profileName: profileName)
        return model
    }
}

extension AppModel {
    @MainActor
    func loadPreviewDevices(_ definitions: [DeviceDefinition], selecting category: DeviceCategory, profileName: String?) {
        var entries: [DeviceEntry] = []
        for definition in definitions.sorted(by: { $0.id < $1.id }) {
            guard let usbId = definition.usbIds.first else { continue }
            let device = DiscoveredDevice(usbId: usbId, name: definition.name, manufacturer: nil)
            var entry = DeviceEntry(id: usbId.description, item: InventoryItem(device: device, definition: definition),
                                    specs: ControlSpec.specs(for: definition))
            for spec in entry.specs {
                switch spec.kind {
                case .slider(let min, let max, _, _): entry.values[spec.id] = .int(min + (max - min) * 6 / 10)
                case .toggle: entry.values[spec.id] = .int(1)
                case .choice(let values): entry.values[spec.id] = .int(values.last ?? 0)
                case .lighting: entry.values[spec.id] = .color(MacHIDDomain.RGBColor(r: 120, g: 70, b: 255))
                case .hostControl: entry.values[spec.id] = .int(0)
                case .readout: entry.values[spec.id] = .text("v1.12")
                }
            }
            entries.append(entry)
        }
        setPreview(devices: entries, selected: entries.first { $0.definition?.category == category }?.id, profileName: profileName)
    }
}
