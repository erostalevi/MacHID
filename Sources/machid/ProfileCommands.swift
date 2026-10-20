import Foundation
import MacHIDApplication
import MacHIDDomain
import MacHIDIOKit
import MacHIDSystem

struct ProfileSummary: Codable {
    let id: String
    let name: String
    let devices: [String: Int]
}

struct ApplyResult: Codable {
    let capability: String
    let status: String   // applied | failed | skipped
    let message: String?
}

private func findProfile(_ query: String, in profiles: [Profile]) -> Profile {
    guard let profile = profiles.first(where: { matches(query, name: $0.name, id: $0.id) }) else {
        fail("no profile named '\(query)'. Run 'machid profile list'.")
    }
    return profile
}

func runProfile(_ args: [String], options: GlobalOptions) async throws {
    let repository = FileProfileRepository()
    guard let sub = args.first else { fail("profile needs list, show or apply\n" + usage, code: ExitCode.usage) }
    let profiles = try await repository.load()

    switch sub {
    case "list":
        let summaries = profiles.map { ProfileSummary(id: $0.id, name: $0.name, devices: $0.settings.mapValues(\.count)) }
        if options.json { printJSON(summaries); return }
        if summaries.isEmpty { print("No profiles. Create them in the MacHID app."); return }
        for item in summaries {
            let devices = item.devices.keys.sorted().joined(separator: ", ")
            print("\(item.name)  [\(item.id)]  devices: \(devices.isEmpty ? "none" : devices)")
        }

    case "show":
        guard args.count == 2 else { fail("profile show needs <name>\n" + usage, code: ExitCode.usage) }
        let profile = findProfile(args[1], in: profiles)
        if options.json { printJSON(profile); return }
        print("\(profile.name)  [\(profile.id)]")
        for (definition, settings) in profile.settings.sorted(by: { $0.key < $1.key }) {
            print("  \(definition):")
            for (capability, value) in settings.sorted(by: { $0.key < $1.key }) {
                print("    \(capability) = \(describe(value))")
            }
        }

    case "apply":
        guard args.count == 2 else { fail("profile apply needs <name> --device <vvvv:pppp>\n" + usage, code: ExitCode.usage) }
        guard let deviceText = options.device, let id = USBID(string: deviceText) else {
            fail("profile apply needs --device <vvvv:pppp>\n" + usage, code: ExitCode.usage)
        }
        let profile = findProfile(args[1], in: profiles)
        let base = loadCatalog(explicit: options.definitionsPath)
        let inventory = DeviceInventory(enumerator: IOKitDeviceEnumerator(), catalog: await catalogWithPlugins(base))
        guard let item = try inventory.item(for: id) else { fail("no attached device with ID \(id)") }
        guard let definition = item.definition else { fail("device \(id) has no definition") }
        guard let settings = profile.settings[definition.id] else {
            fail("profile '\(profile.name)' has no settings for \(definition.id)")
        }
        let control = DeviceControl(inventory: inventory, connector: SystemDeviceConnector())
        let results = await applySettings(settings, definition: definition, deviceID: id, control: control)
        if options.json { printJSON(results) } else {
            for result in results {
                print("\(result.status.uppercased())  \(result.capability)" + (result.message.map { "  (\($0))" } ?? ""))
            }
        }
        if results.contains(where: { $0.status == "failed" }) { exit(ExitCode.runtime) }

    default:
        fail("unknown profile command '\(sub)'\n" + usage, code: ExitCode.usage)
    }
}

/// Writes each setting like the app does: definition order, volatile capabilities only, one result per setting.
func applySettings(_ settings: [String: SettingValue], definition: DeviceDefinition, deviceID: USBID, control: DeviceControl) async -> [ApplyResult] {
    var results: [ApplyResult] = []
    for capability in definition.capabilities {
        guard let value = settings[capability.id] else { continue }
        guard capability.access == .writeVolatile else {
            results.append(ApplyResult(capability: capability.id, status: "skipped", message: "not a volatile writable capability"))
            continue
        }
        do {
            try await control.write(deviceID, capability: capability.id, value: value)
            results.append(ApplyResult(capability: capability.id, status: "applied", message: nil))
        } catch {
            results.append(ApplyResult(capability: capability.id, status: "failed", message: "\(error)"))
        }
    }
    let known = Set(definition.capabilities.map(\.id))
    for name in settings.keys.sorted() where !known.contains(name) {
        results.append(ApplyResult(capability: name, status: "skipped", message: "unknown capability for this device"))
    }
    return results
}
