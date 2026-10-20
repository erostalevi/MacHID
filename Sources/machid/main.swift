import Foundation
import MacHIDApplication
import MacHIDDomain
import MacHIDIOKit

// Read-only CLI (M1). Writes to devices arrive with drivers in M2/M3.
let usage = """
usage:
  machid list [--all] [--json] [--definitions <dir>]
  machid info <vvvv:pppp> [--json] [--definitions <dir>]
  machid get <vvvv:pppp> <capability>
  machid set <vvvv:pppp> brightness <0-100>
  machid set <vvvv:pppp> backlight <RRGGBB|off>
  machid set <vvvv:pppp> device_mode <0|3>
  machid --version

add --trace to get/set to print the raw protocol bytes to stderr
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
let trace = arguments.takeFlag("--trace")
let definitionsPath = arguments.takeOption("--definitions")
let args = arguments.values

guard let command = args.first else { fail(usage, code: 2) }

if command == "--version" {
    print("machid core-api \(coreAPIVersion)")
    exit(0)
}

let inventory = DeviceInventory(enumerator: IOKitDeviceEnumerator(), catalog: loadCatalog(explicit: definitionsPath))

func parseColor(_ text: String) -> RGBColor? {
    let digits = text.hasPrefix("#") ? String(text.dropFirst()) : text
    guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
    return RGBColor(r: UInt8(value >> 16 & 0xFF), g: UInt8(value >> 8 & 0xFF), b: UInt8(value & 0xFF))
}

func describe(_ value: SettingValue) -> String {
    switch value {
    case .bool(let flag): "\(flag)"
    case .int(let number): "\(number)"
    case .color(let color): String(format: "#%02X%02X%02X", color.r, color.g, color.b)
    case .text(let text): text
    }
}

let control = DeviceControl(inventory: inventory, connector: SystemDeviceConnector(trace: trace))

do {
    switch command {
    case "get":
        guard args.count == 3, let id = USBID(string: args[1]) else { fail("get needs <vvvv:pppp> <capability>\n" + usage, code: 2) }
        print(describe(try await control.read(id, capability: args[2])))

    case "set":
        guard args.count == 4, let id = USBID(string: args[1]) else { fail("set needs <vvvv:pppp> <capability> <value>\n" + usage, code: 2) }
        let value: SettingValue
        switch args[2] {
        case "brightness":
            guard let number = Int(args[3]) else { fail("brightness must be a whole number 0-100", code: 2) }
            value = .int(number)
        case "device_mode":
            guard let number = Int(args[3]) else { fail("device_mode must be 0 (normal) or 3 (driver)", code: 2) }
            value = .int(number)
        case "backlight":
            if args[3] == "off" { value = .text("off") }
            else if let color = parseColor(args[3]) { value = .color(color) }
            else { fail("backlight must be RRGGBB (hex) or 'off'", code: 2) }
        default:
            fail("'\(args[2])' cannot be set from the CLI yet", code: 2)
        }
        try await control.write(id, capability: args[2], value: value)
        print("OK: \(args[2]) = \(describe(value))  (volatile; not saved to the device)")

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
