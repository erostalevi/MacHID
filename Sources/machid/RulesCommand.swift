import Foundation
import MacHIDDomain
import MacHIDSystem

func modifierNames(_ modifiers: Modifiers) -> String {
    var names: [String] = []
    if modifiers.contains(.control) { names.append("ctrl") }
    if modifiers.contains(.option) { names.append("opt") }
    if modifiers.contains(.shift) { names.append("shift") }
    if modifiers.contains(.command) { names.append("cmd") }
    if modifiers.contains(.function) { names.append("fn") }
    return names.map { $0 + "+" }.joined()
}

/// Read-only listing of automatic profile switching and remap rules.
func runRules() async throws {
    let automation = try await FileAutomationRepository().load()
    let remap = try await FileRemapRepository().load()

    print("Automation (\(automation.paused ? "paused" : "active"), apply on connect: \(automation.applyOnConnect ? "yes" : "no"))")
    if automation.rules.isEmpty && automation.defaultProfiles.isEmpty { print("  no rules") }
    for rule in automation.rules {
        print("  app \(rule.appName) [\(rule.bundleID)] on \(rule.deviceDefinitionID) -> profile \(rule.profileID)")
    }
    for (definition, profile) in automation.defaultProfiles.sorted(by: { $0.key < $1.key }) {
        print("  default for \(definition) -> profile \(profile)")
    }

    print("Remapping (\(remap.enabled ? "on" : "off"))")
    if remap.rules.isEmpty { print("  no rules") }
    for rule in remap.rules {
        let trigger = (rule.trigger.kind == .keyboard ? "key " : "mouse button ") + modifierNames(rule.trigger.modifiers) + "\(rule.trigger.code)"
        let action: String
        switch rule.action {
        case .key(let code, let modifiers): action = "key \(modifierNames(modifiers))\(code)"
        case .mouseButton(let button): action = "mouse button \(button)"
        case .macro(let id): action = "macro " + (remap.macro(id: id).map { "'\($0.name)'" } ?? "(missing)")
        case .disable: action = "disabled"
        case .switchProfile(let id): action = "profile \(id)"
        case .nextProfile: action = "next profile"
        case .previousProfile: action = "previous profile"
        case .toggleShiftMode(let id): action = "toggle mode " + (remap.shiftMode(id: id).map { "'\($0.name)'" } ?? "(missing)")
        }
        let layers = rule.shiftModeIDs.compactMap { remap.shiftMode(id: $0)?.name }
        let scope = (rule.appBundleID.map { " in \($0)" } ?? "") + (layers.isEmpty ? "" : " while " + layers.joined(separator: "+"))
        print("  \(trigger) -> \(action)\(scope)\(rule.enabled ? "" : "  [off]")")
    }
}
