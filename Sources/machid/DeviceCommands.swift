import Foundation
import MacHIDApplication
import MacHIDDomain

func runList(inventory: DeviceInventory, options: GlobalOptions) throws {
    let items = try inventory.items(includeUnsupported: options.showAll)
    if options.json { printJSON(items); return }
    if items.isEmpty {
        print(options.showAll ? "No devices found." : "No supported devices found. Use --all to list every USB device.")
    }
    for item in items {
        let status = item.isSupported ? "supported" : "unsupported"
        print("\(item.device.usbId)  \(item.device.name)  [\(status)]")
    }
}

func runInfo(_ args: [String], inventory: DeviceInventory, options: GlobalOptions) throws {
    guard args.count == 2, let id = USBID(string: args[1]) else { fail("info needs a USB ID like 046d:c092\n" + usage, code: ExitCode.usage) }
    guard let item = try inventory.item(for: id) else { fail("no attached device with ID \(id)") }
    if options.json { printJSON(item); return }
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
}

func runGet(_ args: [String], control: DeviceControl) async throws {
    guard args.count == 3, let id = USBID(string: args[1]) else { fail("get needs <vvvv:pppp> <capability>\n" + usage, code: ExitCode.usage) }
    print(describe(try await control.read(id, capability: args[2])))
}

func runSet(_ args: [String], control: DeviceControl) async throws {
    guard args.count == 4, let id = USBID(string: args[1]) else { fail("set needs <vvvv:pppp> <capability> <value>\n" + usage, code: ExitCode.usage) }
    let value: SettingValue
    switch args[2] {
    case "brightness":
        guard let number = Int(args[3]) else { fail("brightness must be a whole number 0-100", code: ExitCode.usage) }
        value = .int(number)
    case "dpi":
        guard let number = Int(args[3]) else { fail("dpi must be a whole number", code: ExitCode.usage) }
        value = .int(number)
    case "device_mode":
        guard let number = Int(args[3]) else { fail("device_mode must be 0 (normal) or 3 (driver)", code: ExitCode.usage) }
        value = .int(number)
    case "backlight":
        if args[3] == "off" { value = .text("off") }
        else if let color = parseColor(args[3]) { value = .color(color) }
        else {
            // An effect by name, optionally with a color: spectrum, wave, reactive:FF0000, breathing:00FF00 ...
            let parts = args[3].split(separator: ":", maxSplits: 1).map(String.init)
            let color = parts.count == 2 ? parseColor(parts[1]) : nil
            guard let name = parts.first, name.allSatisfy({ $0.isLetter }), parts.count == 1 || color != nil else {
                fail("backlight must be RRGGBB, 'off' or an effect such as spectrum or reactive:FF0000", code: ExitCode.usage)
            }
            value = .effect(LightingEffect(name, color: color))
        }
    default:
        // Any other capability takes a whole number; the definition and the driver validate it.
        guard let number = Int(args[3]) else { fail("'\(args[2])' takes a whole number", code: ExitCode.usage) }
        value = .int(number)
    }
    try await control.write(id, capability: args[2], value: value)
    print("OK: \(args[2]) = \(describe(value))  (volatile; not saved to the device)")
}
