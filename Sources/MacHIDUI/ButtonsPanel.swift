import SwiftUI
import MacHIDDomain

/// Changes what one key or mouse button does. Every edit is saved at once (it is a global rule: all apps).
struct AssignmentCard: View {
    @Bindable var remap: RemapController
    let trigger: InputTrigger
    let title: Text
    var accent: Color = .accentColor

    enum Kind: Hashable { case original, key, button, macro, nothing }

    private var rule: RemapRule? {
        remap.config.rules.first { $0.trigger == trigger && $0.appBundleID == nil }
    }

    private var kind: Kind {
        switch rule?.action {
        case nil: .original
        case .key?: .key
        case .mouseButton?: .button
        case .macro?: .macro
        case .disable?: .nothing
        }
    }

    var body: some View {
        Card(title: title) {
            HStack(spacing: 8) {
                Image(systemName: trigger.kind == .keyboard ? "keyboard" : "computermouse").foregroundStyle(accent)
                Text(verbatim: KeyNames.trigger(trigger)).font(.title3.weight(.semibold))
                Spacer()
            }
            Segmented(options: [Kind.original, .key, .button, .macro, .nothing], selection: Binding(get: { kind }, set: choose), tint: accent) { kind in
                switch kind {
                case .original: Text("Default")
                case .key: Text("Key")
                case .button: Text("Click")
                case .macro: Text("Macro")
                case .nothing: Text("Off")
                }
            }
            detail.transition(.opacity)
        }
        .animation(.snappy(duration: 0.25), value: kind)
    }

    @ViewBuilder private var detail: some View {
        switch kind {
        case .original:
            Text("Works as the device normally does.").font(.callout).foregroundStyle(.secondary)
        case .key:
            HStack {
                Text("Types").font(.callout).foregroundStyle(.secondary)
                Spacer()
                KeyRecorder(capture: .keyOnly, current: currentKeyTrigger) { recorded in
                    save(.key(code: recorded.code, modifiers: recorded.modifiers))
                }
            }
        case .button:
            Picker("Click", selection: Binding(get: { currentButton }, set: { save(.mouseButton($0)) })) {
                ForEach([0, 1, 2, 3, 4], id: \.self) { Text(verbatim: KeyNames.mouseButton($0)).tag($0) }
            }
            .labelsHidden()
        case .macro:
            if remap.config.macros.isEmpty {
                Text("No macros yet. Create one in Settings > Macros.").font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("Macro", selection: Binding(get: { currentMacro }, set: { if let id = $0 { save(.macro(id)) } })) {
                    Text("Choose…").tag(String?.none)
                    ForEach(remap.config.macros) { Text(verbatim: $0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
            }
        case .nothing:
            Text("Presses are ignored.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var currentKeyTrigger: InputTrigger? {
        if case .key(let code, let modifiers)? = rule?.action { InputTrigger(kind: .keyboard, code: code, modifiers: modifiers) } else { nil }
    }
    private var currentButton: Int { if case .mouseButton(let value)? = rule?.action { value } else { 2 } }
    private var currentMacro: String? { if case .macro(let id)? = rule?.action { id } else { nil } }

    private func choose(_ kind: Kind) {
        switch kind {
        case .original: if let rule { Task { await remap.removeRule(rule.id) } }
        case .nothing: save(.disable)
        case .button: save(.mouseButton(currentButton))
        case .macro: if let first = remap.config.macros.first { save(.macro(currentMacro ?? first.id)) }
        case .key: break   // waits for the recorder
        }
    }

    private func save(_ action: RemapAction) {
        let id = rule?.id ?? UUID().uuidString
        Task { await remap.upsertRule(RemapRule(id: id, trigger: trigger, action: action)) }
    }
}

/// The master switch with its permissions, shown wherever remapping is used.
struct RemapStatusCard: View {
    @Bindable var remap: RemapController

    var body: some View {
        Card {
            Toggle(isOn: Binding(get: { remap.config.enabled }, set: { value in Task { await remap.setEnabled(value) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remapping").font(.subheadline.weight(.medium))
                    Text("Applies your key and button changes. Never records what you type.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            if remap.config.enabled && !(remap.inputMonitoringGranted && remap.accessibilityGranted) {
                HStack {
                    Image(systemName: "lock.shield").foregroundStyle(.yellow)
                    Text("Needs Input Monitoring and Accessibility").font(.caption)
                    Spacer()
                    Button("Allow") { remap.requestPermissions() }.buttonStyle(PillButtonStyle())
                }
            } else if remap.config.enabled {
                HStack(spacing: 6) {
                    Circle().fill(remap.isActive ? Color.green : Color.secondary).frame(width: 7, height: 7)
                    (remap.isActive ? Text("Active") : Text("Waiting")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Buttons section of the sidebar for mice and keyboards.
struct ButtonsPanel: View {
    @Bindable var model: AppModel
    let device: AppModel.DeviceEntry
    var remap: RemapController?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            if let remap {
                RemapStatusCard(remap: remap)
                switch device.category {
                case .mouse: mouseButtons(remap)
                default: keyboardKeys(remap)
                }
            } else {
                Text("Remapping is not available.").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Mouse

    private func mouseButtons(_ remap: RemapController) -> some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            if let selected = model.selectedInput, let button = MouseSimView.g203.first(where: { $0.id == selected }) {
                if let number = button.quartzButton {
                    AssignmentCard(remap: remap, trigger: InputTrigger(kind: .mouseButton, code: number),
                                   title: Text(LocalizedStringKey(button.title)), accent: device.accent)
                } else {
                    Card(title: Text(LocalizedStringKey(button.title))) {
                        Text("This button changes DPI inside the mouse and never reaches the Mac, so it cannot be remapped. Use DPI presets in Performance instead.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            } else {
                Card {
                    Text("Select a button on the mouse to change what it does.").font(.callout).foregroundStyle(.secondary)
                }
            }
            Card(title: Text("All buttons")) {
                ForEach(MouseSimView.g203.filter { $0.quartzButton != nil }) { button in
                    Button { model.selectedInput = button.id } label: {
                        HStack {
                            Text(LocalizedStringKey(button.title)).font(.callout)
                            Spacer()
                            Text(verbatim: summary(for: InputTrigger(kind: .mouseButton, code: button.quartzButton ?? 0), remap)).font(.callout).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Keyboard

    private func keyboardKeys(_ remap: RemapController) -> some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            if let selected = model.selectedInput, let code = KeyboardKeyCodes.code(forKeyID: selected) {
                AssignmentCard(remap: remap, trigger: InputTrigger(kind: .keyboard, code: code),
                               title: Text("Key"), accent: device.accent)
            } else {
                Card {
                    Text("Select a key on the keyboard, or press one, to change what it does.").font(.callout).foregroundStyle(.secondary)
                    KeyRecorder(capture: .keyOnly, current: nil) { recorded in
                        if let id = KeyboardKeyCodes.keyID(forCode: recorded.code) { model.selectedInput = id }
                    }
                }
            }
            let rules = remap.config.rules.filter { $0.trigger.kind == .keyboard && $0.appBundleID == nil }
            if !rules.isEmpty {
                Card(title: Text("Changed keys")) {
                    ForEach(rules) { rule in
                        Button {
                            model.selectedInput = KeyboardKeyCodes.keyID(forCode: rule.trigger.code)
                        } label: {
                            HStack {
                                Text(verbatim: KeyNames.trigger(rule.trigger)).font(.callout)
                                Spacer()
                                Text(verbatim: summary(for: rule.trigger, remap)).font(.callout).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func summary(for trigger: InputTrigger, _ remap: RemapController) -> String {
        guard let rule = remap.config.rules.first(where: { $0.trigger == trigger && $0.appBundleID == nil }) else { return String(localized: "Default") }
        switch rule.action {
        case .key(let code, let modifiers): return KeyNames.combination(code: code, modifiers: modifiers)
        case .mouseButton(let button): return KeyNames.mouseButton(button)
        case .macro(let id): return remap.config.macro(id: id)?.name ?? String(localized: "Missing macro")
        case .disable: return String(localized: "Off")
        }
    }
}

/// Maps drawing key ids to macOS virtual key codes (ANSI) and back.
enum KeyboardKeyCodes {
    private static let table: [String: Int] = {
        var map: [String: Int] = [:]
        let letters: [(String, Int)] = [("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
                                        ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("o", 31), ("u", 32),
                                        ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("k", 40), ("n", 45), ("m", 46)]
        for (label, code) in letters { map[label] = code }
        let digits: [(String, Int)] = [("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23), ("6", 22), ("7", 26), ("8", 28), ("9", 25), ("0", 29)]
        for (label, code) in digits { map[label] = code }
        let others: [(String, Int)] = [("esc", 53), ("tab", 48), ("caps", 57), ("lshift", 56), ("lctrl", 59), ("lalt", 58), ("lsuper", 55),
                                       ("space", 49), ("ralt", 61), ("fn", 63), ("rctrl", 62), ("rshift", 60), ("enter", 36),
                                       ("backspace", 51), ("minus", 27), ("equal", 24), ("lbracket", 33), ("rbracket", 30), ("backslash", 42),
                                       ("semicolon", 41), ("quote", 39), ("comma", 43), ("period", 47), ("slash", 44), ("grave", 50),
                                       ("up", 126), ("down", 125), ("left", 123), ("right", 124), ("menu", 110)]
        for (label, code) in others { map[label] = code }
        return map
    }()
    private static let reverse: [Int: String] = Dictionary(uniqueKeysWithValues: table.map { ($0.value, $0.key) })

    static func code(forKeyID id: String) -> Int? { table[id] }
    static func keyID(forCode code: Int) -> String? { reverse[code] }
}
