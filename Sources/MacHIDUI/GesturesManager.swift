import SwiftUI
import MacHIDDomain

/// Shift gestures: hold a key or button, move the pointer, and the direction you moved picks an action.
struct GesturesManager: View {
    @Bindable var remap: RemapController
    var accent: Color
    @State private var openID: String?
    @State private var pendingDelete: ShiftGesture?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hold the trigger and move the pointer: each direction runs its own action, like trackpad swipes.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(remap.config.gestures) { gesture in row(gesture) }
            Button { add() } label: { Label("New gesture", systemImage: "plus") }.buttonStyle(PillButtonStyle())
        }
        .confirmationDialog(pendingDelete.map { Text("Remove “\($0.name)”?") } ?? Text(""),
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { gesture in
            Button("Remove gesture", role: .destructive) { Task { await remap.removeGesture(gesture.id) } }
        }
    }

    private func row(_ gesture: ShiftGesture) -> some View {
        let open = openID == gesture.id
        return VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.snappy(duration: 0.25)) { openID = open ? nil : gesture.id } } label: {
                HStack(spacing: 8) {
                    Text(verbatim: gesture.name).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(verbatim: KeyNames.trigger(gesture.trigger)).font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Color.primary.opacity(0.08), in: Capsule())
                    Spacer()
                    if !gesture.hasAllowedTrigger { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption) }
                    Text("\(gesture.actions.count) directions").font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary).rotationEffect(.degrees(open ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { details(gesture).transition(.opacity) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Theme.chipRadius, style: .continuous))
    }

    @ViewBuilder private func details(_ gesture: ShiftGesture) -> some View {
        GestureNameField(gesture: gesture) { name in var copy = gesture; copy.name = name; Task { await remap.upsertGesture(copy) } }
        HStack {
            Text("Trigger").font(.callout).foregroundStyle(.secondary)
            Spacer()
            InputPicker(capture: .keyOrMouse, current: gesture.trigger, allowsModifierKeys: true) { recorded in
                var copy = gesture
                copy.trigger = InputTrigger(kind: recorded.kind, code: recorded.code, modifiers: [])
                Task { await remap.upsertGesture(copy) }
            }
        }
        ForEach(GestureDirection.allCases, id: \.self) { direction in
            HStack(spacing: 8) {
                Image(systemName: Self.arrow(direction)).frame(width: 18).foregroundStyle(accent)
                DirectionActionMenu(action: gesture.actions[direction], remap: remap) { action in
                    var copy = gesture
                    if let action { copy.actions[direction] = action } else { copy.actions[direction] = nil }
                    Task { await remap.upsertGesture(copy) }
                }
            }
        }
        SettingRow(title: Text("Distance"), value: Text("\(gesture.threshold) px")) {
            Slider(value: Binding(get: { Double(gesture.threshold) }, set: { value in
                var copy = gesture; copy.threshold = Int(value.rounded()); Task { await remap.upsertGesture(copy) }
            }), in: 20...400, step: 10)
        }
        Toggle(isOn: Binding(get: { gesture.freezePointer }, set: { value in
            var copy = gesture; copy.freezePointer = value; Task { await remap.upsertGesture(copy) }
        })) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Freeze the pointer").font(.callout)
                Text("Off: the pointer keeps moving while you gesture.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        Button(role: .destructive) { pendingDelete = gesture } label: { Label("Remove", systemImage: "trash") }.buttonStyle(PillButtonStyle())
    }

    private static func arrow(_ direction: GestureDirection) -> String {
        switch direction {
        case .left: "arrow.left"
        case .right: "arrow.right"
        case .up: "arrow.up"
        case .down: "arrow.down"
        }
    }

    private func add() {
        // Middle button is the usual gesture button; the user picks another trigger right away if needed.
        let number = remap.config.gestures.count + 1
        let gesture = ShiftGesture(id: UUID().uuidString, name: String(localized: "Gesture \(number)"),
                                   trigger: InputTrigger(kind: .mouseButton, code: 3),
                                   actions: [.left: .system("desktop-left"), .right: .system("desktop-right"), .up: .system("mission-control"), .down: .system("app-expose")])
        Task { if await remap.upsertGesture(gesture) { openID = gesture.id } }
    }
}

/// What one direction does: nothing, a profile switch, or a macOS action from the submenus.
private struct DirectionActionMenu: View {
    var action: RemapAction?
    var remap: RemapController
    let set: (RemapAction?) -> Void

    var body: some View {
        Menu {
            Button { set(nil) } label: { Label("Nothing", systemImage: action == nil ? "checkmark" : "nosign") }
            Button("Next profile") { set(.nextProfile) }
            Button("Previous profile") { set(.previousProfile) }
            Divider()
            ForEach(SystemActionCatalog.grouped, id: \.category) { group in
                Menu(LocalizedStringKey(group.category.title)) {
                    ForEach(group.actions) { item in
                        Button { set(.system(item.id)) } label: { Label(LocalizedStringKey(item.title), systemImage: item.symbol) }
                    }
                }
            }
        } label: {
            HStack {
                label.font(.callout)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.chipRadius - 2, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain)
    }

    private var label: Text {
        switch action {
        case nil: Text("Nothing")
        case .system(let id)?: Text(verbatim: SystemActionMenu.title(for: id))
        case .nextProfile?: Text("Next profile")
        case .previousProfile?: Text("Previous profile")
        case .some(let other): Text(verbatim: describe(other))
        }
    }

    private func describe(_ action: RemapAction) -> String {
        switch action {
        case .key(let code, let modifiers): KeyNames.combination(code: code, modifiers: modifiers)
        case .mouseButton(let button): KeyNames.mouseButton(button)
        case .macro(let id): remap.config.macro(id: id)?.name ?? String(localized: "Missing macro")
        default: String(localized: "Custom")
        }
    }
}

private struct GestureNameField: View {
    let gesture: ShiftGesture
    let rename: (String) -> Void
    @State private var name = ""

    var body: some View {
        TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            .commitsAndResigns { commit() }
            .onAppear { name = gesture.name }
            .onChange(of: gesture.name) { _, new in name = new }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { name = gesture.name } else if trimmed != gesture.name { rename(trimmed) }
    }
}
