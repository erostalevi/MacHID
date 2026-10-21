import SwiftUI
import MacHIDDomain

/// One selectable key or mouse button.
struct InputChoice: Identifiable, Hashable {
    enum Group: Int, CaseIterable {
        case letters, numbers, function, modifiers, navigation, punctuation, keypad, mouse
        var title: Text {
            switch self {
            case .letters: Text("Letters")
            case .numbers: Text("Numbers")
            case .function: Text("Function keys")
            case .modifiers: Text("Modifiers")
            case .navigation: Text("Navigation and editing")
            case .punctuation: Text("Punctuation")
            case .keypad: Text("Keypad")
            case .mouse: Text("Mouse buttons")
            }
        }
        var searchName: String {
            switch self {
            case .letters: "letters"
            case .numbers: "numbers digits"
            case .function: "function f keys"
            case .modifiers: "modifiers shift control option command fn"
            case .navigation: "navigation arrows editing"
            case .punctuation: "punctuation symbols"
            case .keypad: "keypad numpad"
            case .mouse: "mouse button click"
            }
        }
    }

    let kind: InputKind
    let code: Int
    let group: Group
    var id: String { "\(kind.rawValue):\(code)" }
    var name: String { kind == .keyboard ? KeyNames.key(code) : KeyNames.mouseButton(code) }
}

/// The keys and buttons the picker offers, and the search over them (pure, so it is unit tested).
enum InputCatalog {
    static let all: [InputChoice] = {
        var list: [InputChoice] = []
        func add(_ group: InputChoice.Group, _ codes: [Int]) { list += codes.map { InputChoice(kind: .keyboard, code: $0, group: group) } }
        add(.letters, [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6])
        add(.numbers, [29, 18, 19, 20, 21, 23, 22, 26, 28, 25])
        add(.function, [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113])
        add(.modifiers, [59, 62, 58, 61, 55, 54, 56, 60, 57, 63])
        add(.navigation, [126, 125, 123, 124, 115, 119, 116, 121, 48, 49, 36, 51, 117, 53])
        add(.punctuation, [27, 24, 33, 30, 42, 41, 39, 43, 47, 44, 50])
        add(.keypad, [82, 83, 84, 85, 86, 87, 88, 89, 91, 92, 71, 76])
        list += (0...7).map { InputChoice(kind: .mouseButton, code: $0, group: .mouse) }
        return list
    }()

    /// Choices matching `query` (name or group, case-insensitive), grouped in display order.
    /// `includeMouse` and `includeModifierKeys` hide the groups a caller cannot use.
    static func sections(matching query: String, includeMouse: Bool, includeModifierKeys: Bool) -> [(group: InputChoice.Group, choices: [InputChoice])] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return InputChoice.Group.allCases.compactMap { group in
            if group == .mouse && !includeMouse { return nil }
            if group == .modifiers && !includeModifierKeys { return nil }
            let inGroup = all.filter { $0.group == group }
            let groupMatches = !needle.isEmpty && group.searchName.contains(needle)
            let hits = inGroup.filter { needle.isEmpty || groupMatches || $0.name.lowercased().contains(needle) }
            return hits.isEmpty ? nil : (group, hits)
        }
    }
}

/// Pick a key or mouse button: listen for it, or choose it from a searchable list.
/// With `allowsModifierToggles` the chosen key can carry ⌃ ⌥ ⇧ ⌘ (used for key outputs).
struct InputPicker: View {
    var capture: KeyRecorder.Capture = .keyOnly
    var current: InputTrigger?
    var allowsModifierKeys = false
    var allowsModifierToggles = false
    let onPick: (InputTrigger) -> Void

    @State private var showList = false

    var body: some View {
        HStack(spacing: 6) {
            KeyRecorder(capture: capture, current: current, allowsModifierKeys: allowsModifierKeys, onRecord: onPick)
            Button { showList.toggle() } label: { Image(systemName: "list.bullet") }
                .buttonStyle(PillButtonStyle())
                .help("Choose from a list")
                .accessibilityLabel(Text("Choose from a list"))
                .popover(isPresented: $showList, arrowEdge: .bottom) {
                    InputListView(capture: capture, current: current, allowsModifierKeys: allowsModifierKeys,
                                  allowsModifierToggles: allowsModifierToggles) { picked in
                        showList = false
                        onPick(picked)
                    }
                }
        }
    }
}

private struct InputListView: View {
    let capture: KeyRecorder.Capture
    let current: InputTrigger?
    let allowsModifierKeys: Bool
    let allowsModifierToggles: Bool
    let pick: (InputTrigger) -> Void
    @State private var query = ""
    @State private var modifiers: Modifiers = []
    @FocusState private var searching: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search keys", text: $query).textFieldStyle(.plain).focused($searching)
                    .commitsAndResigns()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            if allowsModifierToggles {
                HStack(spacing: 6) {
                    ForEach([(Modifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")], id: \.1) { entry in
                        Button { if modifiers.contains(entry.0) { modifiers.remove(entry.0) } else { modifiers.insert(entry.0) } } label: { Text(verbatim: entry.1).frame(minWidth: 18) }
                            .buttonStyle(PillButtonStyle(selected: modifiers.contains(entry.0)))
                    }
                    Spacer()
                    Text("Held with the key").font(.caption).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4, pinnedViews: []) {
                    let sections = InputCatalog.sections(matching: query, includeMouse: capture == .keyOrMouse, includeModifierKeys: allowsModifierKeys || !allowsModifierToggles)
                    ForEach(sections, id: \.group) { section in
                        section.group.title.font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
                        FlowRow(spacing: 6) {
                            ForEach(section.choices) { choice in
                                Button { pick(InputTrigger(kind: choice.kind, code: choice.code, modifiers: choice.kind == .keyboard ? modifiers : [])) } label: {
                                    Text(verbatim: choice.name).font(.callout)
                                }
                                .buttonStyle(PillButtonStyle(selected: current?.kind == choice.kind && current?.code == choice.code))
                            }
                        }
                    }
                    if sections.isEmpty { Text("No matching keys").font(.callout).foregroundStyle(.secondary).padding(.top, 8) }
                }
            }
            .frame(height: 280)
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { modifiers = current?.modifiers ?? []; searching = true }
    }
}
