import Foundation
import MacHIDDomain

// Offline validation used by CI: `machid-validate registry plugins.json` or
// `machid-validate definition Definitions/*.json`. Exits non-zero on any issue.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { fail("usage: machid-validate registry <plugins.json> | definition <file>...") }

var failed = false
switch args[0] {
case "registry":
    for path in args.dropFirst() {
        do {
            let registry = try Registry.decode(try Data(contentsOf: URL(fileURLWithPath: path)))
            let issues = RegistryValidator().validate(registry)
            issues.forEach { print("\(path): \($0)") }
            failed = failed || !issues.isEmpty
        } catch {
            print("\(path): \(error)")
            failed = true
        }
    }
case "definition":
    for path in args.dropFirst() {
        do {
            let definition = try JSONDecoder().decode(DeviceDefinition.self, from: try Data(contentsOf: URL(fileURLWithPath: path)))
            try definition.validate()
        } catch {
            print("\(path): \(error)")
            failed = true
        }
    }
default:
    fail("unknown mode '\(args[0])'")
}
if failed { exit(1) }
print("OK")
