import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MacHIDDomain
import MacHIDApplication

/// Macros: the list, the switch for shell macros, the editor and the recent runs.
public struct MacrosView: View {
    @Bindable var remap: RemapController

    public init(remap: RemapController) { self.remap = remap }
    @State private var editing: Macro?

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                macrosCard
                runsCard
            }
            .padding(24)
        }
        .sheet(item: $editing) { macro in
            MacroEditor(remap: remap, macro: macro) { editing = nil }
        }
    }

    private var macrosCard: some View {
        SettingsCard(Text("Macros")) {
            Text("A macro is a sequence of keys, clicks and pauses, and can also open things or run shell commands. Anything beyond keys and clicks needs your approval first.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Allow macros that run shell commands", isOn: Binding(get: { remap.config.shellMacrosEnabled }, set: { value in Task { await remap.setShellMacrosEnabled(value) } }))
            if remap.config.macros.isEmpty { Text("No macros yet.").font(.callout).foregroundStyle(.tertiary) }
            ForEach(remap.config.macros) { macro in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(verbatim: macro.name).font(.callout.weight(.medium))
                            badge(for: macro)
                        }
                        Text("\(macro.steps.count) steps").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { remap.toggleFavorite(macro.id) } label: { Image(systemName: remap.isFavorite(macro.id) ? "star.fill" : "star") }
                        .buttonStyle(.plain).foregroundStyle(remap.isFavorite(macro.id) ? Color.yellow : Color.secondary)
                        .help(remap.isFavorite(macro.id) ? "Remove from the menu bar" : "Show in the menu bar")
                        .accessibilityLabel(Text(remap.isFavorite(macro.id) ? "Remove from the menu bar" : "Show in the menu bar"))
                    Button { Task { await remap.run(macroID: macro.id) } } label: { Image(systemName: "play.fill") }
                        .buttonStyle(.plain).help("Run now")
                    Button { editing = macro } label: { Image(systemName: "pencil") }.buttonStyle(.plain).help("Edit")
                    Button { Task { await remap.deleteMacro(macro.id) } } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Delete")
                }
            }
            HStack(spacing: 10) {
                Button { editing = Macro(id: UUID().uuidString, name: "", steps: []) } label: { Label("New macro", systemImage: "plus") }
                    .buttonStyle(PillButtonStyle())
                Button("Import…") { importMacros() }.buttonStyle(PillButtonStyle())
                Button("Export…") { exportMacros() }.buttonStyle(PillButtonStyle()).disabled(remap.config.macros.isEmpty)
            }
        }
    }

    @ViewBuilder private func badge(for macro: Macro) -> some View {
        if macro.needsApproval {
            if remap.isApproved(macro) { Label("Approved", systemImage: "checkmark.seal.fill").font(.caption2).foregroundStyle(.green) }
            else { Label("Needs approval", systemImage: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange) }
        }
        if macro.imported { Text("Imported").font(.caption2).foregroundStyle(.secondary) }
    }

    private var runsCard: some View {
        SettingsCard(Text("Recent runs")) {
            if remap.recentRuns.isEmpty { Text("Nothing has run yet.").font(.callout).foregroundStyle(.tertiary) }
            ForEach(Array(remap.recentRuns.suffix(10).reversed().enumerated()), id: \.offset) { _, run in
                HStack {
                    Text(verbatim: run.macroName).font(.callout)
                    Spacer()
                    outcome(run.outcome)
                    Text(run.date, style: .time).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Only the macro name, what kinds of steps ran and how it ended are kept. Typed text and commands are never logged.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func outcome(_ outcome: MacroLogEntry.Outcome) -> some View {
        switch outcome {
        case .completed: Label("Done", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
        case .cancelled: Label("Stopped", systemImage: "stop.circle").font(.caption).foregroundStyle(.secondary)
        case .refused: Label("Refused", systemImage: "hand.raised").font(.caption).foregroundStyle(.orange)
        case .failed: Label("Failed", systemImage: "xmark.circle").font(.caption).foregroundStyle(.red)
        }
    }

    private func importMacros() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        Task { await remap.importMacros(from: data) }
    }

    private func exportMacros() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "machid-macros.json"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = remap.exportMacros(ids: remap.config.macros.map(\.id)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Edits one macro. Anything beyond keys and clicks is listed in full, and approving records exactly those steps.
private struct MacroEditor: View {
    @Bindable var remap: RemapController
    @State var macro: Macro
    let close: () -> Void
    @State private var approveOnSave = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(macro.name.isEmpty ? "New macro" : macro.name).font(.title3.weight(.semibold))
            TextField("Name", text: $macro.name).textFieldStyle(.roundedBorder).commitsAndResigns()
            Stepper(value: $macro.repeatCount, in: 1...Macro.maxRepeat) { Text("Repeat: \(macro.repeatCount)") }

            ScrollView {
                VStack(spacing: 8) {
                    if macro.steps.isEmpty { Text("Add the first step below.").foregroundStyle(.tertiary).padding(.vertical, 12) }
                    ForEach(macro.steps.indices, id: \.self) { index in StepRow(step: $macro.steps[index], index: index, count: macro.steps.count, move: move, remove: remove) }
                }
            }
            .frame(minHeight: 160, maxHeight: 280)

            Menu {
                Button("Press a key") { macro.steps.append(.key(code: 0, modifiers: [])) }
                Button("Type text") { macro.steps.append(.text("")) }
                Button("Click a button") { macro.steps.append(.mouseClick(button: 0)) }
                Button("Wait") { macro.steps.append(.wait(milliseconds: 500)) }
                Divider()
                Button("Open an app, link or file") { macro.steps.append(.open("")) }
                Button("Run a Shortcut") { macro.steps.append(.shortcut("")) }
                Button("Run a shell command") { macro.steps.append(.shell("")) }
            } label: { Label("Add step", systemImage: "plus") }
            .menuStyle(.button).buttonStyle(PillButtonStyle()).fixedSize()
            .disabled(macro.steps.count >= Macro.maxSteps)

            if macro.needsApproval { approvalBox }

            HStack {
                Button("Cancel", action: close)
                Spacer()
                Button("Save") {
                    let toSave = macro
                    Task {
                        await remap.saveMacro(toSave)
                        if approveOnSave { await remap.approve(toSave.id) }
                        close()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(macro.name.trimmingCharacters(in: .whitespaces).isEmpty || macro.steps.isEmpty)
            }
        }
        .padding(22).frame(width: 520)
    }

    private var approvalBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("This macro can act outside typing and clicking", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout.weight(.semibold))
            ForEach(Array(macro.steps.enumerated().filter { $0.element.isPowerful || macro.imported }), id: \.offset) { _, step in
                Text(verbatim: describe(step)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            Toggle("I have read these steps and approve them", isOn: $approveOnSave).font(.callout)
            Text("If you change a step later, approval is removed and you will be asked again.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(12).background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private func describe(_ step: MacroStep) -> String {
        switch step {
        case .open(let target): "open  \(target)"
        case .shortcut(let name): "shortcut  \(name)"
        case .shell(let command): "$ \(command)"
        case .text(let text): "type  \(text)"
        case .key(let code, let modifiers): "key  \(KeyNames.combination(code: code, modifiers: modifiers))"
        case .mouseClick(let button): "click  \(KeyNames.mouseButton(button))"
        case .wait(let milliseconds): "wait  \(milliseconds) ms"
        }
    }

    private func move(_ index: Int, _ offset: Int) {
        let target = index + offset
        guard macro.steps.indices.contains(target) else { return }
        macro.steps.swapAt(index, target)
    }

    private func remove(_ index: Int) { macro.steps.remove(at: index) }
}

private struct StepRow: View {
    @Binding var step: MacroStep
    let index: Int
    let count: Int
    let move: (Int, Int) -> Void
    let remove: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: "\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22)
            editor.frame(maxWidth: .infinity, alignment: .leading)
            Button { move(index, -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).disabled(index == 0)
            Button { move(index, 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain).disabled(index == count - 1)
            Button { remove(index) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var editor: some View {
        switch step {
        case .key(let code, let modifiers):
            HStack { Text("Key"); InputPicker(capture: .keyOnly, current: InputTrigger(kind: .keyboard, code: code, modifiers: modifiers), allowsModifierToggles: true) {
                step = .key(code: $0.code, modifiers: $0.modifiers)
            } }
        case .text(let text):
            HStack { Text("Type"); TextField("Text", text: Binding(get: { text }, set: { step = .text(String($0.prefix(500))) })).textFieldStyle(.roundedBorder).commitsAndResigns() }
        case .mouseClick(let button):
            HStack { Text("Click"); Picker("", selection: Binding(get: { button }, set: { step = .mouseClick(button: $0) })) {
                ForEach([0, 1, 2, 3, 4], id: \.self) { Text(verbatim: KeyNames.mouseButton($0)).tag($0) }
            }.labelsHidden().fixedSize() }
        case .wait(let milliseconds):
            HStack { Text("Wait"); Stepper(value: Binding(get: { milliseconds }, set: { step = .wait(milliseconds: $0) }), in: 0...60_000, step: 100) {
                Text(verbatim: "\(milliseconds) ms").monospacedDigit()
            } }
        case .open(let target):
            HStack { Text("Open"); TextField("App id, link or path", text: Binding(get: { target }, set: { step = .open($0) })).textFieldStyle(.roundedBorder).commitsAndResigns() }
        case .shortcut(let name):
            HStack { Text("Shortcut"); TextField("Name", text: Binding(get: { name }, set: { step = .shortcut($0) })).textFieldStyle(.roundedBorder).commitsAndResigns() }
        case .shell(let command):
            HStack { Text("Shell"); TextField("Command", text: Binding(get: { command }, set: { step = .shell($0) }))
                .textFieldStyle(.roundedBorder).commitsAndResigns().font(.system(.body, design: .monospaced)) }
        }
    }
}
