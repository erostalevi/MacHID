import Foundation
import MacHIDApplication
import MacHIDDomain
import MacHIDIOKit
import MacHIDSystem

extension AppModel {
    /// The real thing: IOKit enumeration, real drivers, profiles in Application Support.
    @MainActor
    public static func live() -> AppModel {
        let (catalog, _) = (try? loadDefinitions()) ?? (DefinitionCatalog(definitions: []), [])
        let inventory = DeviceInventory(enumerator: IOKitDeviceEnumerator(), catalog: catalog)
        let control = DeviceControl(inventory: inventory, connector: SystemDeviceConnector())
        return AppModel(inventory: inventory, control: control, repository: FileProfileRepository())
    }

    /// Looks for the bundled definitions: inside the app, then an override, then the repository checkout.
    static func loadDefinitions() throws -> (catalog: DefinitionCatalog, errors: [String]) {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("Definitions")) }
        if let override = ProcessInfo.processInfo.environment["MACHID_DEFINITIONS"] { candidates.append(URL(fileURLWithPath: override)) }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Definitions"))
        var directory = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<6 {
            if let current = directory { candidates.append(current.appendingPathComponent("Definitions")); directory = current.deletingLastPathComponent() }
        }
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return try DefinitionCatalog.load(directory: candidate)
        }
        return (DefinitionCatalog(definitions: []), ["no Definitions directory found"])
    }
}
