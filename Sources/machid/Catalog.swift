import Foundation
import MacHIDApplication
import MacHIDDomain
import MacHIDSystem

struct CatalogError: Error { let message: String }

/// Finds the device definitions: `--definitions`, then `./Definitions`, then next to the executable.
func findCatalog(explicit: String?) throws -> DefinitionCatalog {
    let executableDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    let candidates: [String] = [explicit as String?,
                                FileManager.default.currentDirectoryPath + "/Definitions",
                                executableDir.appendingPathComponent("../share/machid/Definitions").path].compactMap { $0 }
    for path in candidates {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            if path == explicit { throw CatalogError(message: "definitions directory not found: \(path)") }
            continue
        }
        do {
            let (catalog, errors) = try DefinitionCatalog.load(directory: URL(fileURLWithPath: path))
            errors.forEach { warn($0) }
            return catalog
        } catch {
            throw CatalogError(message: "cannot read definitions in \(path): \(error)")
        }
    }
    throw CatalogError(message: "no definitions found; pass --definitions <dir> or run from the repository root")
}

func loadCatalog(explicit: String?) -> DefinitionCatalog {
    do { return try findCatalog(explicit: explicit) } catch let error as CatalogError { fail(error.message) } catch { fail("\(error)") }
}

/// Installed plugins and their definitions (checked again on load), as the app does. Problems are returned, not fatal.
func pluginInfo() async -> (plugins: [InstalledPlugin], definitions: [DeviceDefinition], problems: [String]) {
    guard let plugins = try? await FileInstalledPluginStore().load() else { return ([], [], []) }
    let loaded = PluginDefinitions.load(plugins, root: FileInstalledPluginStore.pluginsDirectory)
    return (plugins, loaded.definitions, loaded.problems)
}

func catalogWithPlugins(_ base: DefinitionCatalog) async -> DefinitionCatalog {
    base.adding(await pluginInfo().definitions, artworkRoots: [:])
}
