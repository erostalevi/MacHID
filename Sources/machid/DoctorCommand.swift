import Foundation
import MacHIDApplication
import MacHIDDomain
import MacHIDIOKit
import MacHIDQuartz
import MacHIDSystem

struct DoctorReport: Codable {
    struct Permissions: Codable { let inputMonitoring: Bool; let accessibility: Bool }
    struct Device: Codable { let id: String; let name: String; let serialSuffix: String?; let hasDefinition: Bool; let definition: String? }
    struct Versions: Codable { let coreAPI: Int; let macOS: String }
    struct Counts: Codable { let definitions: Int; let plugins: Int; let pluginProblems: Int; let profiles: Int; let macros: Int }
    struct Paths: Codable { let supportDirectory: String; let profiles: String; let remap: String; let automation: String; let macroLog: String; let plugins: String }
    struct LogEntry: Codable { let date: Date; let stepKinds: [String]; let outcome: String; let shellExitCodes: [Int32] }

    let generated: Date
    let versions: Versions
    let permissions: Permissions
    let devices: [Device]
    let deviceError: String?
    let definitionsError: String?
    let counts: Counts
    let paths: Paths
    /// Only in diagnostics exports: kinds of steps and outcomes of recent runs. No names, ids, commands or text.
    let macroLog: [LogEntry]?
}

func outcomeLabel(_ outcome: MacroLogEntry.Outcome) -> String {
    switch outcome {
    case .completed: "completed"
    case .refused(let why): "refused:\(why.rawValue)"
    case .failed: "failed"
    case .cancelled: "cancelled"
    }
}

func buildReport(options: GlobalOptions, includeMacroLog: Bool) async -> DoctorReport {
    var catalog: DefinitionCatalog?
    var definitionsError: String?
    do { catalog = try findCatalog(explicit: options.definitionsPath) } catch let error as CatalogError { definitionsError = error.message } catch { definitionsError = "\(error)" }
    let plugins = await pluginInfo()
    let full = catalog?.adding(plugins.definitions, artworkRoots: [:])

    var devices: [DoctorReport.Device] = []
    var deviceError: String?
    do {
        let inventory = DeviceInventory(enumerator: IOKitDeviceEnumerator(), catalog: full ?? DefinitionCatalog(definitions: []))
        devices = try inventory.items(includeUnsupported: true).map {
            DoctorReport.Device(id: "\($0.device.usbId)", name: $0.device.name,
                                serialSuffix: DiscoveredDevice.redactSerial($0.device.serialSuffix),
                                hasDefinition: $0.isSupported, definition: $0.definition?.id)
        }
    } catch {
        deviceError = "\(error)"
    }

    let profiles = (try? await FileProfileRepository().load()) ?? []
    let remap = (try? await FileRemapRepository().load()) ?? RemapConfig()
    let support = FileRemapRepository.supportDirectory
    let log = includeMacroLog
        ? await FileMacroLog().entries(limit: 50).map {
            DoctorReport.LogEntry(date: $0.date, stepKinds: $0.stepKinds, outcome: outcomeLabel($0.outcome), shellExitCodes: $0.shellExitCodes)
        }
        : nil

    return DoctorReport(
        generated: Date(),
        versions: .init(coreAPI: coreAPIVersion, macOS: ProcessInfo.processInfo.operatingSystemVersionString),
        permissions: .init(inputMonitoring: InputMonitoringPermission.isGranted && RemapPermissions.inputMonitoring,
                           accessibility: RemapPermissions.accessibility),
        devices: devices, deviceError: deviceError, definitionsError: definitionsError,
        counts: .init(definitions: full?.definitions.count ?? 0, plugins: plugins.plugins.count, pluginProblems: plugins.problems.count,
                      profiles: profiles.count, macros: remap.macros.count),
        paths: .init(supportDirectory: redactHome(support.path),
                     profiles: redactHome(FileProfileRepository.defaultURL.path),
                     remap: redactHome(FileRemapRepository.defaultURL.path),
                     automation: redactHome(FileAutomationRepository.defaultURL.path),
                     macroLog: redactHome(support.appendingPathComponent("macro-log.jsonl").path),
                     plugins: redactHome(FileInstalledPluginStore.pluginsDirectory.path)),
        macroLog: log)
}

func printDoctor(_ report: DoctorReport) {
    func yesNo(_ value: Bool) -> String { value ? "granted" : "NOT granted" }
    print("machid doctor")
    print("  core API:         \(report.versions.coreAPI)")
    print("  macOS:            \(report.versions.macOS)")
    print("Permissions")
    print("  Input Monitoring: \(yesNo(report.permissions.inputMonitoring))  (needed to talk to devices and for remapping)")
    print("  Accessibility:    \(yesNo(report.permissions.accessibility))  (needed for remapping and macros that type)")
    print("Devices")
    if let error = report.deviceError { print("  could not list devices: \(error)") }
    else if report.devices.isEmpty { print("  none attached") }
    for device in report.devices {
        let serial = device.serialSuffix.map { "  serial …\($0)" } ?? ""
        print("  \(device.id)  \(device.name)  \(device.hasDefinition ? "definition: \(device.definition ?? "yes")" : "no definition")\(serial)")
    }
    print("Data")
    if let error = report.definitionsError { print("  definitions: \(error)") }
    print("  definitions: \(report.counts.definitions)   plugins: \(report.counts.plugins) (\(report.counts.pluginProblems) with problems)")
    print("  profiles: \(report.counts.profiles)   macros: \(report.counts.macros)")
    print("Files")
    print("  support folder: \(report.paths.supportDirectory)")
    print("  profiles:       \(report.paths.profiles)")
    print("  remap:          \(report.paths.remap)")
    print("  automation:     \(report.paths.automation)")
    print("  macro log:      \(report.paths.macroLog)")
    print("  plugins:        \(report.paths.plugins)")
}

func runDiagnostics(_ args: [String], options: GlobalOptions) async throws {
    guard args.count == 2, args[0] == "export" else { fail("diagnostics needs: export <path>\n" + usage, code: ExitCode.usage) }
    let report = await buildReport(options: options, includeMacroLog: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let url = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
    try encoder.encode(report).write(to: url, options: .atomic)
    print("Wrote redacted diagnostics to \(redactHome(url.path))")
}
