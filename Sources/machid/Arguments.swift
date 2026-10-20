import Foundation

struct Arguments {
    var values: [String]

    mutating func takeFlag(_ name: String) -> Bool {
        guard let index = values.firstIndex(of: name) else { return false }
        values.remove(at: index)
        return true
    }

    mutating func takeOption(_ name: String) -> String? {
        guard let index = values.firstIndex(of: name) else { return nil }
        guard index + 1 < values.count else { fail("\(name) needs a value", code: ExitCode.usage) }
        let value = values[index + 1]
        values.removeSubrange(index...index + 1)
        return value
    }
}

/// Options that apply to every command, taken out of the argument list before dispatch.
struct GlobalOptions {
    var json: Bool
    var showAll: Bool
    var trace: Bool
    var definitionsPath: String?
    var device: String?
}

let usage = """
usage:
  machid list [--all] [--json] [--definitions <dir>]
  machid info <vvvv:pppp> [--json] [--definitions <dir>]
  machid get <vvvv:pppp> <capability>
  machid set <vvvv:pppp> brightness <0-100>
  machid set <vvvv:pppp> backlight <RRGGBB|off|effect[:RRGGBB]>
  machid set <vvvv:pppp> dpi <value>
  machid set <vvvv:pppp> device_mode <0|1|3>
  machid profile list [--json]
  machid profile show <name>
  machid profile apply <name> --device <vvvv:pppp>
  machid macro list [--json]
  machid macro run <name>
  machid rules
  machid doctor [--json]
  machid diagnostics export <path>
  machid completions <zsh|bash|fish>
  machid --version

add --trace to get/set to print the raw protocol bytes to stderr
exit codes: 0 ok, 1 runtime error, 2 usage error, 3 refused for safety
"""
