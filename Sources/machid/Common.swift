import Foundation
import MacHIDDomain

/// Exit codes documented in docs/CLI.md.
enum ExitCode {
    static let ok: Int32 = 0
    static let runtime: Int32 = 1
    static let usage: Int32 = 2
    static let refused: Int32 = 3
}

func fail(_ message: String, code: Int32 = ExitCode.runtime) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data(("warning: " + message + "\n").utf8))
}

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    print(String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self))
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
    case .effect(let effect):
        effect.color.map { effect.effect + String(format: ":#%02X%02X%02X", $0.r, $0.g, $0.b) } ?? effect.effect
    case .battery(let percent, let charging):
        (percent.map { "\($0)%" } ?? "unknown") + (charging == true ? " (charging)" : "")
    case .text(let text): text
    case .keyFrame(let keys): "\(keys.count) keys"
    }
}

/// Replaces the home folder with `~` so reports and output never carry a user name.
func redactHome(_ path: String) -> String {
    let home = NSHomeDirectory()
    guard !home.isEmpty, home != "/" else { return path }
    if path == home { return "~" }
    return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
}

/// Case-insensitive match on name or exact id.
func matches(_ query: String, name: String, id: String) -> Bool {
    id == query || name.compare(query, options: .caseInsensitive) == .orderedSame
}
