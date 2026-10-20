import Foundation
import MacHIDApplication
import MacHIDDomain
import MacHIDIOKit
import MacHIDSystem

// Entry point: take the global options, then hand the command to its file.
var arguments = Arguments(values: Array(CommandLine.arguments.dropFirst()))
let options = GlobalOptions(json: arguments.takeFlag("--json"),
                            showAll: arguments.takeFlag("--all"),
                            trace: arguments.takeFlag("--trace"),
                            definitionsPath: arguments.takeOption("--definitions"),
                            device: arguments.takeOption("--device"))
let args = arguments.values

guard let command = args.first else { fail(usage, code: ExitCode.usage) }

if command == "--version" {
    print("machid core-api \(coreAPIVersion)")
    exit(ExitCode.ok)
}

/// Commands that never touch a device load nothing from the device catalog.
func makeInventory(plugins: Bool = false) async -> DeviceInventory {
    let base = loadCatalog(explicit: options.definitionsPath)
    return DeviceInventory(enumerator: IOKitDeviceEnumerator(), catalog: plugins ? await catalogWithPlugins(base) : base)
}

func makeControl(_ inventory: DeviceInventory) -> DeviceControl {
    let trace = options.trace
    return DeviceControl(inventory: inventory, connector: SystemDeviceConnector(decorate: { trace ? TracingTransport(inner: $0) : $0 }))
}

do {
    switch command {
    case "get", "set", "list", "info":
        let inventory = await makeInventory()
        switch command {
        case "get": try await runGet(args, control: makeControl(inventory))
        case "set": try await runSet(args, control: makeControl(inventory))
        case "list": try runList(inventory: inventory, options: options)
        default: try runInfo(args, inventory: inventory, options: options)
        }

    case "profile":
        try await runProfile(Array(args.dropFirst()), options: options)

    case "macro":
        try await runMacro(Array(args.dropFirst()), options: options)

    case "rules":
        try await runRules()

    case "doctor":
        let report = await buildReport(options: options, includeMacroLog: false)
        if options.json { printJSON(report) } else { printDoctor(report) }

    case "diagnostics":
        try await runDiagnostics(Array(args.dropFirst()), options: options)

    case "completions":
        runCompletions(Array(args.dropFirst()))

    default:
        fail("unknown command '\(command)'\n" + usage, code: ExitCode.usage)
    }
} catch {
    fail("error: \(error)")
}
