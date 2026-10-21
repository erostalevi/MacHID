import SwiftUI
import AppKit
import MacHIDDomain

/// Remapping: the master switch with its permissions, and the list of rules.
public struct RemapView: View {
    @Bindable var remap: RemapController

    public init(remap: RemapController) { self.remap = remap }
    @State private var adding = false

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switchCard
                rulesCard
            }
            .padding(24)
        }
    }

    private var switchCard: some View {
        SettingsCard(Text("Remapping")) {
            Toggle("Turn remapping on", isOn: Binding(get: { remap.config.enabled }, set: { value in Task { await remap.setEnabled(value) } }))
            Text("While it is on, MacHID watches key presses and extra mouse buttons to apply your rules. It never records or stores what you type.")
                .font(.callout).foregroundStyle(.secondary)
            if remap.config.enabled {
                HStack(spacing: 12) {
                    permissionBadge(Text("Input Monitoring"), granted: remap.inputMonitoringGranted)
                    permissionBadge(Text("Accessibility"), granted: remap.accessibilityGranted)
                    if !(remap.inputMonitoringGranted && remap.accessibilityGranted) {
                        Button("Grant…") { remap.requestPermissions() }.buttonStyle(PillButtonStyle())
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Circle().fill(remap.isActive ? Color.green : Color.secondary).frame(width: 8, height: 8)
                        remap.isActive ? Text("Active") : Text("Waiting")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let banner = remap.banner {
                HStack {
                    Text(verbatim: banner).font(.caption).foregroundStyle(.orange)
                    Button { remap.banner = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
            }
        }
    }

    private func permissionBadge(_ title: Text, granted: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(granted ? .green : .orange)
            title.font(.caption)
        }
    }

    private var rulesCard: some View {
        SettingsCard(Text("Rules")) {
            Text("Change what a key or button does. A rule for the app in front beats a rule for all apps.")
                .font(.callout).foregroundStyle(.secondary)
            if remap.config.rules.isEmpty { Text("No rules yet.").font(.callout).foregroundStyle(.tertiary) }
            ForEach(remap.config.rules) { rule in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(get: { rule.enabled }, set: { value in Task { await remap.setRule(rule.id, enabled: value) } }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "\(KeyNames.trigger(rule.trigger))  →  \(actionLabel(rule.action))").font(.callout.weight(.medium))
                        if let app = rule.appBundleID { Text(verbatim: appName(app)).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button { Task { await remap.removeRule(rule.id) } } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove rule")
                }
                .opacity(rule.enabled ? 1 : 0.5)
            }
            Button { adding = true } label: { Label("Add rule…", systemImage: "plus") }
                .buttonStyle(PillButtonStyle())
                .popover(isPresented: $adding, arrowEdge: .bottom) { AddRemapRuleView(remap: remap) { adding = false } }
        }
    }

    private func actionLabel(_ action: RemapAction) -> String {
        switch action {
        case .key(let code, let modifiers): KeyNames.combination(code: code, modifiers: modifiers)
        case .mouseButton(let button): KeyNames.mouseButton(button)
        case .macro(let id): remap.config.macro(id: id).map { "Macro “\($0.name)”" } ?? "Missing macro"
        case .disable: String(localized: "Do nothing")
        case .switchProfile: String(localized: "Switch profile")
        case .nextProfile: String(localized: "Next profile")
        case .previousProfile: String(localized: "Previous profile")
        case .toggleShiftMode(let id): remap.config.shiftMode(id: id).map { "Toggle “\($0.name)”" } ?? "Missing mode"
        case .system(let id): SystemActionMenu.title(for: id)
        }
    }

    private func appName(_ bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID
    }
}

private struct AddRemapRuleView: View {
    @Bindable var remap: RemapController
    let done: () -> Void

    enum Kind: String, CaseIterable { case key, button, macro, disable }

    @State private var trigger: InputTrigger?
    @State private var kind: Kind = .key
    @State private var keyTarget: InputTrigger?
    @State private var button = 2
    @State private var macroID: String?
    @State private var appID: String?

    private var runningApps: [(id: String, name: String)] {
        let own = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != own }
            .map { ($0.bundleIdentifier!, $0.localizedName ?? $0.bundleIdentifier!) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var action: RemapAction? {
        switch kind {
        case .key: keyTarget.flatMap { $0.kind == .keyboard ? .key(code: $0.code, modifiers: $0.modifiers) : .mouseButton($0.code) }
        case .button: .mouseButton(button)
        case .macro: macroID.map(RemapAction.macro)
        case .disable: .disable
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New rule").font(.headline)
            LabeledContent("When I press") { InputPicker(capture: .keyOrMouse, current: trigger) { trigger = $0 } }
            Picker("Do", selection: $kind) {
                Text("Press a key").tag(Kind.key)
                Text("Click a button").tag(Kind.button)
                Text("Run a macro").tag(Kind.macro)
                Text("Nothing").tag(Kind.disable)
            }
            switch kind {
            case .key: LabeledContent("Press") { InputPicker(capture: .keyOnly, current: keyTarget, allowsModifierToggles: true) { keyTarget = $0 } }
            case .button:
                Picker("Button", selection: $button) { ForEach([0, 1, 2, 3, 4], id: \.self) { Text(verbatim: KeyNames.mouseButton($0)).tag($0) } }
            case .macro:
                Picker("Macro", selection: $macroID) {
                    Text("Choose…").tag(String?.none)
                    ForEach(remap.config.macros) { Text(verbatim: $0.name).tag(Optional($0.id)) }
                }
            case .disable: EmptyView()
            }
            Picker("In", selection: $appID) {
                Text("All apps").tag(String?.none)
                ForEach(runningApps, id: \.id) { Text(verbatim: $0.name).tag(Optional($0.id)) }
            }
            HStack {
                Spacer()
                Button("Add") {
                    guard let trigger, let action else { return }
                    Task { await remap.upsertRule(RemapRule(id: UUID().uuidString, trigger: trigger, action: action, appBundleID: appID)) }
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trigger == nil || action == nil)
            }
        }
        .padding(18).frame(width: 340)
    }
}

/// A titled glass card used by the settings pages.
struct SettingsCard<Content: View>: View {
    let title: Text
    @ViewBuilder var content: Content

    init(_ title: Text, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            title.font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flatSurface(cornerRadius: Theme.cardRadius)
    }
}
