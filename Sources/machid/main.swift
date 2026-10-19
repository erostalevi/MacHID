import Foundation
import MacHIDApplication
import MacHIDDomain
import MacHIDIOKit

// Read-only CLI (M1). Writes to devices arrive with drivers in M2/M3.
let usage = """
usage:
  machid list [--all] [--json] [--definitions <dir>]
  machid info <vvvv:pppp> [--json] [--definitions <dir>]
  machid --version
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func usagePageName(_ page: Int) -> String {
    switch page {
    case 0x01: "Generic Desktop"
    case 0x07: "Keyboard"
    case 0x0C: "Consumer"
    case 0x0D: "Digitizer"
    case 0xFF00...0xFFFF: "Vendor-defined"
    default: "0x" + String(page, radix: 16)
    }
}

func loadCatalog(explicit: String?) -> DefinitionCatalog {
    let executableDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    let candidates: [String] = [explicit as String?,
                      FileManager.default.currentDirectoryPath + "/Definitions",
                      executableDir.appendingPathComponent("../share/machid/Definitions").path].compactMap { $0 }
    for path in candidates {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            if path == explicit { fail("definitions directory not found: \(path)") }
            continue
        }
        do {
            let (catalog, errors) = try DefinitionCatalog.load(directory: URL(fileURLWithPath: path))
            errors.forEach { FileHandle.standardError.write(Data(("warning: " + $0 + "\n").utf8)) }
            return catalog
        } catch {
            fail("cannot read definitions in \(path): \(error)")
        }
    }
    fail("no definitions found; pass --definitions <dir> or run from the repository root")
}

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self))
}

struct Arguments {
    var values: [String]

    mutating func takeFlag(_ name: String) -> Bool {
        guard let index = values.firstIndex(of: name) else { return false }
        values.remove(at: index)
        return true
    }

    mutating func takeOption(_ name: String) -> String? {
        guard let index = values.firstIndex(of: name) else { return nil }
        guard index + 1 < values.count else { fail("\(name) needs a value") }
        let value = values[index + 1]
        values.removeSubrange(index...index + 1)
        return value
    }
}

var arguments = Arguments(values: Array(CommandLine.arguments.dropFirst()))
let json = arguments.takeFlag("--json")
let showAll = arguments.takeFlag("--all")
let definitionsPath = arguments.takeOption("--definitions")
let args = arguments.values

guard let command = args.first else { fail(usage, code: 2) }

if command == "--version" {
    print("machid core-api \(coreAPIVersion)")
    exit(0)
}

let inventory = DeviceInventory(enumerator: IOKitDeviceEnumerator(), catalog: loadCatalog(explicit: definitionsPath))

do {
    switch command {
    case "list":
        let items = try inventory.items(includeUnsupported: showAll)
        if json { printJSON(items); break }
        if items.isEmpty {
            print(showAll ? "No devices found." : "No supported devices found. Use --all to list every USB device.")
        }
        for item in items {
            let status = item.isSupported ? "supported" : "unsupported"
            print("\(item.device.usbId)  \(item.device.name)  [\(status)]")
        }

    case "info":
        guard args.count == 2, let id = USBID(string: args[1]) else { fail("info needs a USB ID like 046d:c092\n" + usage, code: 2) }
        guard let item = try inventory.item(for: id) else { fail("no attached device with ID \(id)") }
        if json { printJSON(item); break }
        let device = item.device
        print("\(device.name)  (\(device.usbId))")
        if let value = device.manufacturer { print("  manufacturer: \(value)") }
        if let value = device.usbRelease { print("  USB release:  \(value)  (not the vendor firmware version)") }
        if let value = device.serialSuffix { print("  serial:       …\(value)") }
        if !device.hidInterfaces.isEmpty {
            print("  HID interfaces:")
            for hid in device.hidInterfaces {
                print("    \(usagePageName(hid.usagePage)) (page 0x\(String(hid.usagePage, radix: 16)), usage 0x\(String(hid.usage, radix: 16)))")
            }
        }
        if let definition = item.definition {
            print("  definition:   \(definition.id)  (driver: \(definition.driver))")
            print("  capabilities: " + definition.capabilities.map { "\($0.id) [\($0.access.rawValue)]" }.joined(separator: ", "))
        } else {
            print("  definition:   none (device detected but unsupported)")
        }

    default:
        fail("unknown command '\(command)'\n" + usage, code: 2)
    }
} catch {
    fail("error: \(error)")
}
