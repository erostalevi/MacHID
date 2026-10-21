import SwiftUI
import MacHIDDomain

/// Facts about shift modes the manager shows (pure, so they are unit tested).
enum ShiftModeDiagnostics {
    enum Warning: Equatable {
        /// Two modes use the same key or button.
        case sharedTrigger(otherName: String)
        /// A normal rule listens for the same trigger; the mode consumes it first, so the rule never runs.
        case shadowsRule
        /// The trigger can never drive a mode (left/right click, Escape).
        case forbiddenTrigger
    }

    /// Rules that apply on exactly this layer (the shift modes held together; empty is the base layer).
    static func ruleCount(in config: RemapConfig, layer: Set<String>) -> Int {
        config.rules.filter { Set($0.shiftModeIDs) == layer }.count
    }

    /// Rules that mention this mode in any combination.
    static func ruleCount(in config: RemapConfig, mode id: String) -> Int {
        config.rules.filter { $0.shiftModeIDs.contains(id) }.count
    }

    static func warnings(for mode: ShiftMode, in config: RemapConfig) -> [Warning] {
        var result: [Warning] = []
        if !mode.hasAllowedTrigger { result.append(.forbiddenTrigger) }
        for other in config.shiftModes where other.id != mode.id && other.trigger.kind == mode.trigger.kind && other.trigger.code == mode.trigger.code {
            result.append(.sharedTrigger(otherName: other.name))
        }
        if config.rules.contains(where: { $0.shiftModeIDs.isEmpty && $0.trigger.kind == mode.trigger.kind && $0.trigger.code == mode.trigger.code }) {
            result.append(.shadowsRule)
        }
        return result
    }

    /// A copy of `mode` with a fresh id and name, plus copies of the rules that belong to it (rules on combinations
    /// that include it get the new id in place of the old one).
    static func duplicate(_ mode: ShiftMode, in config: RemapConfig, newID: String, name: String) -> (mode: ShiftMode, rules: [RemapRule]) {
        var copy = mode
        copy = ShiftMode(id: newID, name: name, trigger: mode.trigger, behavior: mode.behavior, affectsOtherDevices: mode.affectsOtherDevices)
        let rules = config.rules.filter { $0.shiftModeIDs.contains(mode.id) }.map { rule -> RemapRule in
            var duplicate = rule
            duplicate = RemapRule(id: UUID().uuidString, trigger: rule.trigger, action: rule.action, enabled: rule.enabled,
                                  appBundleID: rule.appBundleID, shiftModeIDs: rule.shiftModeIDs.map { $0 == mode.id ? newID : $0 }.sorted())
            return duplicate
        }
        return (copy, rules)
    }
}

/// Compact manager for shift modes: one line per mode (live dot, name, trigger, rule count), details open on click.
struct ShiftModesManager: View {
    @Bindable var remap: RemapController
    @Bindable var model: AppModel
    var accent: Color
    @State private var openID: String?
    @State private var pendingDelete: ShiftMode?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("A shift mode changes what other keys and buttons do while it is on. Modes work independently and can be combined.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(remap.config.shiftModes) { mode in
                row(mode)
            }
            HStack {
                Button { add() } label: { Label("New shift mode", systemImage: "plus") }.buttonStyle(PillButtonStyle())
                if remap.config.shiftModes.count > 0 {
                    Text("\(remap.config.rules.filter { !$0.shiftModeIDs.isEmpty }.count) rules on layers").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog(pendingDelete.map { Text("Remove “\($0.name)”?") } ?? Text(""), isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { mode in
            Button("Remove shift mode and its rules", role: .destructive) {
                Task { await remap.removeShiftMode(mode.id); model.selectedLayers.remove(mode.id) }
                if openID == mode.id { openID = nil }
            }
        } message: { mode in
            Text("\(ShiftModeDiagnostics.ruleCount(in: remap.config, mode: mode.id)) rules that use it are removed too.")
        }
    }

    private func row(_ mode: ShiftMode) -> some View {
        let open = openID == mode.id
        let live = remap.activeShiftModes.contains(mode.id)
        let editing = model.selectedLayers.contains(mode.id)
        let warnings = ShiftModeDiagnostics.warnings(for: mode, in: remap.config)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { openID = open ? nil : mode.id }
                model.selectedLayers = [mode.id]
            } label: {
                HStack(spacing: 8) {
                    Circle().fill(live ? Color.green : Color.primary.opacity(0.2)).frame(width: 8, height: 8)
                        .accessibilityLabel(live ? Text("Active") : Text("Inactive"))
                    Text(verbatim: mode.name).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(verbatim: KeyNames.trigger(mode.trigger)).font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Color.primary.opacity(0.08), in: Capsule())
                    Image(systemName: mode.behavior == .hold ? "hand.point.up.left" : "switch.2").font(.caption).foregroundStyle(.secondary)
                        .help(mode.behavior == .hold ? "While held" : "Toggle on/off")
                    Spacer()
                    if !warnings.isEmpty { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption) }
                    Text("\(ShiftModeDiagnostics.ruleCount(in: remap.config, mode: mode.id)) rules").font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary).rotationEffect(.degrees(open ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { details(mode, warnings: warnings).transition(.opacity) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((editing ? accent.opacity(0.14) : Color.primary.opacity(0.04)), in: RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous))
    }

    @ViewBuilder private func details(_ mode: ShiftMode, warnings: [ShiftModeDiagnostics.Warning]) -> some View {
        ShiftModeNameField(mode: mode) { name in
            var copy = mode; copy.name = name; Task { await remap.upsertShiftMode(copy) }
        }
        HStack {
            Text("Trigger").font(.callout).foregroundStyle(.secondary)
            Spacer()
            InputPicker(capture: .keyOrMouse, current: mode.trigger, allowsModifierKeys: true) { recorded in
                var copy = mode
                copy.trigger = InputTrigger(kind: recorded.kind, code: recorded.code, modifiers: [])
                Task { await remap.upsertShiftMode(copy) }
            }
        }
        Segmented(options: ShiftBehavior.allCases, selection: Binding(get: { mode.behavior }, set: { value in
            var copy = mode; copy.behavior = value; Task { await remap.upsertShiftMode(copy) }
        }), tint: accent) { $0 == .hold ? Text("While held") : Text("Toggle on/off") }
        Toggle(isOn: Binding(get: { mode.affectsOtherDevices }, set: { value in
            var copy = mode; copy.affectsOtherDevices = value; Task { await remap.upsertShiftMode(copy) }
        })) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Also shifts other devices").font(.callout)
                Text(mode.affectsOtherDevices ? "Keyboard and mouse both change." : "Only the same kind of device changes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
            Label { warningText(warning).font(.caption) } icon: { Image(systemName: "exclamationmark.triangle.fill") }.foregroundStyle(.orange)
        }
        HStack {
            Button { duplicate(mode) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }.buttonStyle(PillButtonStyle())
            Button(role: .destructive) { pendingDelete = mode } label: { Label("Remove", systemImage: "trash") }.buttonStyle(PillButtonStyle())
        }
    }

    private func warningText(_ warning: ShiftModeDiagnostics.Warning) -> Text {
        switch warning {
        case .sharedTrigger(let name): Text("Same trigger as “\(name)”. Pick a different key.")
        case .shadowsRule: Text("A normal rule uses this trigger; the shift mode takes it over and that rule stops working.")
        case .forbiddenTrigger: Text("This key cannot drive a shift mode (clicks and Escape are reserved).")
        }
    }

    private func add() {
        // A placeholder trigger the user replaces right away; Right Option is rarely used by itself.
        let number = remap.config.shiftModes.count + 1
        let mode = ShiftMode(id: UUID().uuidString, name: String(localized: "Shift \(number)"),
                             trigger: InputTrigger(kind: .keyboard, code: 61), behavior: .hold, affectsOtherDevices: true)
        Task { if await remap.upsertShiftMode(mode) { model.selectedLayers = [mode.id]; openID = mode.id } }
    }

    private func duplicate(_ mode: ShiftMode) {
        let copy = ShiftModeDiagnostics.duplicate(mode, in: remap.config, newID: UUID().uuidString, name: String(localized: "\(mode.name) copy"))
        Task {
            if await remap.upsertShiftMode(copy.mode) {
                for rule in copy.rules { await remap.upsertRule(rule) }
                model.selectedLayers = [copy.mode.id]; openID = copy.mode.id
            }
        }
    }
}

private struct ShiftModeNameField: View {
    let mode: ShiftMode
    let rename: (String) -> Void
    @State private var name = ""

    var body: some View {
        TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            .commitsAndResigns { commit() }
            .onAppear { name = mode.name }
            .onChange(of: mode.name) { _, new in name = new }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { name = mode.name } else if trimmed != mode.name { rename(trimmed) }
    }
}
