import SwiftUI
import MacHIDDomain

/// Changes what one key or mouse button does on the chosen layer (base, or while some shift modes are held).
/// Every edit is saved at once. Rules here are global (all apps).
struct AssignmentCard: View {
    @Bindable var remap: RemapController
    @Bindable var model: AppModel
    let trigger: InputTrigger
    let title: Text
    var accent: Color = .accentColor
    var layers: Set<String> = []

    enum Kind: Hashable { case original, key, button, system, macro, profile, shift, nothing }

    /// The action picked in the menu, kept until a rule exists for it (Key, Macro, Profile and Shift need one more choice).
    @State private var draft: Kind?
    @Environment(\.openWindow) private var openWindow

    private var rule: RemapRule? {
        remap.config.rules.first { $0.trigger == trigger && $0.appBundleID == nil && Set($0.shiftModeIDs) == layers }
    }

    private var kind: Kind { draft ?? savedKind }

    private var savedKind: Kind {
        switch rule?.action {
        case nil: .original
        case .key?: .key
        case .mouseButton?: .button
        case .macro?: .macro
        case .system?: .system
        case .switchProfile?, .nextProfile?, .previousProfile?: .profile
        case .toggleShiftMode?: .shift
        case .disable?: .nothing
        }
    }

    private static let order: [Kind] = [.original, .key, .button, .system, .macro, .profile, .shift, .nothing]

    private func name(_ kind: Kind) -> Text {
        switch kind {
        case .original: Text("Default")
        case .key: Text("Press a key")
        case .button: Text("Click a button")
        case .system: Text("macOS action")
        case .macro: Text("Run a macro")
        case .profile: Text("Switch profile")
        case .shift: Text("Toggle a shift mode")
        case .nothing: Text("Do nothing")
        }
    }

    var body: some View {
        Card(title: title) {
            HStack(spacing: 8) {
                Image(systemName: trigger.kind == .keyboard ? "keyboard" : "computermouse").foregroundStyle(accent)
                Text(verbatim: layerPrefix + KeyNames.trigger(trigger)).font(.title3.weight(.semibold)).lineLimit(2)
                Spacer()
            }
            Menu {
                ForEach(Self.order, id: \.self) { candidate in
                    Button { choose(candidate) } label: {
                        if candidate == kind { Label { name(candidate) } icon: { Image(systemName: "checkmark") } } else { name(candidate) }
                    }
                }
            } label: {
                HStack { name(kind).font(.callout.weight(.medium)); Spacer(); Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary) }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous))
                    .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain)
            detail.transition(.opacity)
        }
        .animation(.snappy(duration: 0.25), value: kind)
        .onChange(of: trigger) { _, _ in draft = nil }
        .onChange(of: layers) { _, _ in draft = nil }
    }

    private var layerPrefix: String {
        let names = layers.compactMap { remap.config.shiftMode(id: $0)?.name }.sorted()
        return names.isEmpty ? "" : names.joined(separator: " + ") + " + "
    }

    @ViewBuilder private var detail: some View {
        switch kind {
        case .original:
            Text(layers.isEmpty ? "Works as the device normally does." : "Works as on the base layer.").font(.callout).foregroundStyle(.secondary)
        case .key:
            HStack {
                Text("Types").font(.callout).foregroundStyle(.secondary)
                Spacer()
                InputPicker(capture: .keyOnly, current: currentKeyTrigger, allowsModifierToggles: true) { recorded in
                    save(.key(code: recorded.code, modifiers: recorded.modifiers))
                }
            }
        case .button:
            Picker("Click", selection: Binding(get: { currentButton }, set: { save(.mouseButton($0)) })) {
                ForEach([0, 1, 2, 3, 4], id: \.self) { Text(verbatim: KeyNames.mouseButton($0)).tag($0) }
            }
            .labelsHidden()
        case .system:
            SystemActionMenu(selection: currentSystem) { save(.system($0)) }
            Text("Navigation like the trackpad gestures: Mission Control, switch desktop, App Exposé, media keys.").font(.caption).foregroundStyle(.secondary)
        case .macro:
            if remap.config.macros.isEmpty {
                Text("No macros yet.").font(.callout).foregroundStyle(.secondary)
                Button("Create a macro…") {
                    UserDefaults.standard.set("macros", forKey: SettingsStore.pageKey)
                    openWindow(id: "settings"); NSApp.activate()
                }
                .buttonStyle(PillButtonStyle())
            } else {
                Picker("Macro", selection: Binding(get: { currentMacro }, set: { if let id = $0 { save(.macro(id)) } })) {
                    Text("Choose…").tag(String?.none)
                    ForEach(remap.config.macros) { Text(verbatim: $0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
            }
        case .profile:
            if model.profiles.isEmpty {
                Text("No profiles yet. Save one from the profile menu at the top of the window.").font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("Profile", selection: Binding(get: { currentProfileChoice }, set: saveProfileChoice)) {
                    Text("Choose…").tag(String?.none)
                    Text("Next profile").tag(Optional(Self.nextTag))
                    Text("Previous profile").tag(Optional(Self.previousTag))
                    Divider()
                    ForEach(model.profiles) { Text(verbatim: $0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                Text("Applies to every connected device that has settings in that profile.").font(.caption).foregroundStyle(.secondary)
            }
        case .shift:
            if remap.config.shiftModes.isEmpty {
                Text("Create a shift mode first (below).").font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("Shift mode", selection: Binding(get: { currentShiftMode }, set: { if let id = $0 { save(.toggleShiftMode(id)) } })) {
                    Text("Choose…").tag(String?.none)
                    ForEach(remap.config.shiftModes) { Text(verbatim: $0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
            }
        case .nothing:
            Text("Presses are ignored.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private static let nextTag = "__next__", previousTag = "__previous__"

    private var currentProfileChoice: String? {
        switch rule?.action {
        case .switchProfile(let id)?: id
        case .nextProfile?: Self.nextTag
        case .previousProfile?: Self.previousTag
        default: nil
        }
    }

    private func saveProfileChoice(_ choice: String?) {
        switch choice {
        case nil: break
        case Self.nextTag?: save(.nextProfile)
        case Self.previousTag?: save(.previousProfile)
        case let id?: save(.switchProfile(id))
        }
    }

    private var currentKeyTrigger: InputTrigger? {
        if case .key(let code, let modifiers)? = rule?.action { InputTrigger(kind: .keyboard, code: code, modifiers: modifiers) } else { nil }
    }
    private var currentSystem: String? { if case .system(let id)? = rule?.action { id } else { nil } }
    private var currentButton: Int { if case .mouseButton(let value)? = rule?.action { value } else { 2 } }
    private var currentMacro: String? { if case .macro(let id)? = rule?.action { id } else { nil } }
    private var currentShiftMode: String? { if case .toggleShiftMode(let id)? = rule?.action { id } else { nil } }

    private func choose(_ kind: Kind) {
        draft = kind == savedKind ? nil : kind
        switch kind {
        case .original: if let rule { Task { await remap.removeRule(rule.id) } }; draft = nil
        case .nothing: save(.disable)
        case .button: save(.mouseButton(currentButton))
        case .macro: if let first = remap.config.macros.first { save(.macro(currentMacro ?? first.id)) }
        case .key, .profile, .shift, .system: break   // wait for the choice
        }
    }

    private func save(_ action: RemapAction) {
        draft = nil
        let id = rule?.id ?? UUID().uuidString
        Task { await remap.upsertRule(RemapRule(id: id, trigger: trigger, action: action, shiftModeIDs: layers.sorted())) }
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
                LayerPicker(remap: remap, model: model, accent: device.accent)
                switch device.category {
                case .mouse: mouseButtons(remap)
                default: keyboardKeys(remap)
                }
                DisclosureCard(title: Text("Shift modes"), symbol: "arrow.up.square",
                               subtitle: remap.config.shiftModes.isEmpty ? nil : Text("\(remap.config.shiftModes.count)"),
                               expanded: !remap.config.shiftModes.isEmpty) {
                    ShiftModesManager(remap: remap, model: model, accent: device.accent)
                }
                DisclosureCard(title: Text("Shift gestures"), symbol: "hand.draw",
                               subtitle: remap.config.gestures.isEmpty ? nil : Text("\(remap.config.gestures.count)"),
                               expanded: !remap.config.gestures.isEmpty) {
                    GesturesManager(remap: remap, accent: device.accent)
                }
            } else {
                Text("Remapping is not available.").foregroundStyle(.secondary)
            }
        }
    }

    private var layers: Set<String> { model.selectedLayers }

    // MARK: Mouse

    private func mouseButtons(_ remap: RemapController) -> some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            if let selected = model.selectedInput, let button = MouseSimView.g203.first(where: { $0.id == selected }) {
                if let number = button.quartzButton {
                    AssignmentCard(remap: remap, model: model, trigger: InputTrigger(kind: .mouseButton, code: number),
                                   title: Text(LocalizedStringKey(button.title)), accent: device.accent, layers: layers)
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
                AssignmentCard(remap: remap, model: model, trigger: InputTrigger(kind: .keyboard, code: code),
                               title: Text("Key"), accent: device.accent, layers: layers)
            } else {
                Card {
                    Text("Select a key on the keyboard, or press one, to change what it does.").font(.callout).foregroundStyle(.secondary)
                    InputPicker(capture: .keyOnly, current: nil) { recorded in
                        if let id = KeyboardKeyCodes.keyID(forCode: recorded.code) { model.selectedInput = id }
                    }
                }
            }
            let rules = remap.config.rules.filter { $0.trigger.kind == .keyboard && $0.appBundleID == nil && Set($0.shiftModeIDs) == layers }
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
        guard let rule = remap.config.rules.first(where: { $0.trigger == trigger && $0.appBundleID == nil && Set($0.shiftModeIDs) == layers })
        else { return String(localized: "Default") }
        return Self.describe(rule.action, remap: remap, model: model)
    }

    static func describe(_ action: RemapAction, remap: RemapController, model: AppModel) -> String {
        switch action {
        case .key(let code, let modifiers): return KeyNames.combination(code: code, modifiers: modifiers)
        case .mouseButton(let button): return KeyNames.mouseButton(button)
        case .macro(let id): return remap.config.macro(id: id)?.name ?? String(localized: "Missing macro")
        case .disable: return String(localized: "Off")
        case .switchProfile(let id): return model.profiles.first { $0.id == id }?.name ?? String(localized: "Missing profile")
        case .nextProfile: return String(localized: "Next profile")
        case .previousProfile: return String(localized: "Previous profile")
        case .toggleShiftMode(let id): return remap.config.shiftMode(id: id)?.name ?? String(localized: "Missing shift mode")
        case .system(let id): return SystemActionMenu.title(for: id)
        }
    }
}

/// Which layer is being edited: the base layer, or any combination of shift modes held together.
struct LayerPicker: View {
    @Bindable var remap: RemapController
    @Bindable var model: AppModel
    var accent: Color

    var body: some View {
        if !remap.config.shiftModes.isEmpty {
            Card(title: Text("Layer")) {
                FlowRow(spacing: 8) {
                    chip(title: Text("Base \(ShiftModeDiagnostics.ruleCount(in: remap.config, layer: []))"), selected: model.selectedLayers.isEmpty, live: false) { model.selectedLayers = [] }
                    ForEach(remap.config.shiftModes) { mode in
                        chip(title: Text(verbatim: "\(mode.name) \(ShiftModeDiagnostics.ruleCount(in: remap.config, mode: mode.id))"), selected: model.selectedLayers.contains(mode.id), live: remap.activeShiftModes.contains(mode.id)) {
                            if model.selectedLayers.contains(mode.id) { model.selectedLayers.remove(mode.id) } else { model.selectedLayers.insert(mode.id) }
                        }
                    }
                }
                Text(model.selectedLayers.isEmpty ? "Editing what keys do normally."
                     : "Editing what keys do while these shift modes are held together.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func chip(title: Text, selected: Bool, live: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if live { Circle().fill(.green).frame(width: 6, height: 6) }
                title
            }
        }
        .buttonStyle(PillButtonStyle(tint: accent, selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
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
