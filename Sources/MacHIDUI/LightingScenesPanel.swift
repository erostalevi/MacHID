import SwiftUI
import MacHIDDomain

/// Edit layered lighting scenes: the list, which scene runs on which shift mode, and the layers of the chosen scene.
struct LightingScenesPanel: View {
    @Bindable var scenes: LightingScenesController
    var remap: RemapController?
    var accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Card {
                Text("Scenes layer several effects, for example a slow wave with keys that flash when pressed, and can change while a shift mode is held. They run on every device with lighting.")
                    .font(.caption).foregroundStyle(.secondary)
                if let banner = scenes.banner { Text(verbatim: banner).font(.caption).foregroundStyle(.orange) }
            }
            sceneList
            assignments
            if let scene = scenes.editingScene { SceneEditor(scenes: scenes, scene: scene, accent: accent) }
        }
    }

    // MARK: Scene list

    private var sceneList: some View {
        Card(title: Text("Scenes")) {
            ForEach(scenes.setup.scenes) { scene in
                let editing = scene.id == scenes.editingScene?.id
                HStack(spacing: 10) {
                    Image(systemName: editing ? "largecircle.fill.circle" : "circle").foregroundStyle(editing ? accent : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: scene.name).font(.callout.weight(editing ? .semibold : .regular))
                        Text("\(scene.layers.count) layers").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if scene.id == scenes.currentScene?.id && scenes.enabled { Text("Running").font(.caption).foregroundStyle(.green) }
                }
                .contentShape(Rectangle())
                .onTapGesture { scenes.editingSceneID = scene.id; scenes.paintingLayerID = nil }
            }
            HStack {
                Button { scenes.newScene() } label: { Label("New", systemImage: "plus") }.buttonStyle(PillButtonStyle())
                if let id = scenes.editingScene?.id {
                    Button { scenes.duplicate(id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }.buttonStyle(PillButtonStyle())
                    Button { scenes.deleteScene(id) } label: { Image(systemName: "trash") }.buttonStyle(PillButtonStyle())
                        .disabled(scenes.setup.scenes.count <= 1).help("Delete scene")
                }
            }
        }
    }

    // MARK: Which scene when

    @State private var newRuleModes: Set<String> = []

    private var assignments: some View {
        Card(title: Text("When it runs")) {
            SettingRow(title: Text("Normally")) {
                scenePicker(selection: scenes.setup.baseSceneID) { scenes.setBase($0) }
            }
            if let remap, !remap.config.shiftModes.isEmpty {
                ForEach(Array(scenes.setup.shiftScenes.enumerated()), id: \.offset) { _, rule in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: names(rule.modeIDs, remap)).font(.callout.weight(.medium))
                            scenePicker(selection: rule.sceneID) { scenes.setShiftScene(modes: rule.modeIDs, scene: $0) }
                        }
                        Spacer()
                        Button { scenes.removeShiftScene(modes: rule.modeIDs) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove")
                    }
                }
                Divider().opacity(0.4)
                Text("While these are held").font(.caption).foregroundStyle(.secondary)
                FlowRow(spacing: 8) {
                    ForEach(remap.config.shiftModes) { mode in
                        Button { if newRuleModes.contains(mode.id) { newRuleModes.remove(mode.id) } else { newRuleModes.insert(mode.id) } } label: {
                            Text(verbatim: mode.name)
                        }
                        .buttonStyle(PillButtonStyle(tint: accent, selected: newRuleModes.contains(mode.id)))
                    }
                }
                Button {
                    if let first = scenes.setup.scenes.first(where: { $0.id != scenes.setup.baseSceneID }) ?? scenes.setup.scenes.first {
                        scenes.setShiftScene(modes: newRuleModes.sorted(), scene: first.id)
                        newRuleModes = []
                    }
                } label: { Label("Add shift scene", systemImage: "plus") }
                .buttonStyle(PillButtonStyle()).disabled(newRuleModes.isEmpty)
            } else {
                Text("Create shift modes in Buttons to use a different scene while one is held.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { if let remap { scenes.pruneRules(existingModeIDs: Set(remap.config.shiftModes.map(\.id))) } }
    }

    private func names(_ ids: [String], _ remap: RemapController) -> String {
        ids.compactMap { remap.config.shiftMode(id: $0)?.name }.joined(separator: " + ")
    }

    private func scenePicker(selection: String, set: @escaping (String) -> Void) -> some View {
        Picker("", selection: Binding(get: { selection }, set: set)) {
            ForEach(scenes.setup.scenes) { Text(verbatim: $0.name).tag($0.id) }
        }
        .labelsHidden()
    }
}

/// The layers of one scene, bottom to top.
private struct SceneEditor: View {
    @Bindable var scenes: LightingScenesController
    let scene: LightingScene
    var accent: Color

    private func save(_ change: (inout LightingScene) -> Void) {
        var copy = scene
        change(&copy)
        scenes.upsertScene(copy)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Card(title: Text("Scene")) {
                TextField("Name", text: Binding(get: { scene.name }, set: { value in save { $0.name = value } }))
                    .textFieldStyle(.plain).font(.title3.weight(.semibold))
                SettingRow(title: Text("Brightness"), value: Text(verbatim: "\(scene.brightness)%")) {
                    Slider(value: Binding(get: { Double(scene.brightness) }, set: { value in save { $0.brightness = Int(value.rounded()) } }), in: 1...100)
                }
            }
            ForEach(Array(scene.layers.enumerated()), id: \.element.id) { index, layer in
                LayerCard(scenes: scenes, layer: layer, index: index, count: scene.layers.count, accent: accent,
                          update: { change in save { change(&$0.layers[index]) } },
                          move: { offset in save { if $0.layers.indices.contains(index + offset) { $0.layers.swapAt(index, index + offset) } } },
                          remove: { save { $0.layers.remove(at: index) } })
            }
            Menu {
                ForEach(Self.kinds, id: \.name) { entry in
                    Button(LocalizedStringKey(entry.name)) {
                        save { $0.layers.append(LightingLayer(id: UUID().uuidString, name: String(localized: String.LocalizationValue(entry.name)), kind: entry.make())) }
                    }
                }
            } label: { Label("Add layer", systemImage: "plus") }
            .menuStyle(.button).buttonStyle(PillButtonStyle()).fixedSize()
        }
    }

    private static let white = RGBColor(r: 255, g: 255, b: 255)
    static let kinds: [(name: String, make: () -> LightingLayerKind)] = [
        ("Solid color", { .solid(RGBColor(r: 0, g: 87, b: 255)) }),
        ("Spectrum", { .spectrum(speed: 1) }),
        ("Wave", { .wave(speed: 1, direction: 0) }),
        ("Breathing", { .breathing(color: RGBColor(r: 138, g: 43, b: 255), speed: 1) }),
        ("Starlight", { .starlight(colors: [white], speed: 1, density: 0.25) }),
        ("Reactive", { .reactive(color: white, decay: 0.8, ripple: false) }),
        ("Rainbow ripple", { .rainbowRipple(speed: 1, decay: 1.2) }),
        ("Gradient", { .gradient(from: RGBColor(r: 255, g: 45, b: 170), to: RGBColor(r: 0, g: 229, b: 255), angle: 0) }),
        ("Painted keys", { .painted([]) }),
    ]
}

private struct LayerCard: View {
    @Bindable var scenes: LightingScenesController
    let layer: LightingLayer
    let index: Int, count: Int
    var accent: Color
    let update: ((inout LightingLayer) -> Void) -> Void
    let move: (Int) -> Void
    let remove: () -> Void

    private var title: Text {
        switch layer.kind {
        case .solid: Text("Solid color")
        case .spectrum: Text("Spectrum")
        case .wave: Text("Wave")
        case .breathing: Text("Breathing")
        case .starlight: Text("Starlight")
        case .reactive: Text("Reactive")
        case .rainbowRipple: Text("Rainbow ripple")
        case .gradient: Text("Gradient")
        case .painted: Text("Painted keys")
        }
    }

    var body: some View {
        Card {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(get: { layer.enabled }, set: { value in update { $0.enabled = value } }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                title.font(.callout.weight(.semibold))
                Spacer()
                Button { move(-1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain).disabled(index == 0).help("Move down")
                Button { move(1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).disabled(index == count - 1).help("Move up")
                Button(action: remove) { Image(systemName: "trash") }.buttonStyle(.plain).help("Remove layer")
            }
            .foregroundStyle(.secondary)
            parameters
            SettingRow(title: Text("Opacity"), value: Text(verbatim: "\(Int((layer.opacity * 100).rounded()))%")) {
                Slider(value: Binding(get: { layer.opacity }, set: { value in update { $0.opacity = value } }), in: 0...1)
            }
            HStack {
                Text("Blend").font(.callout)
                Spacer()
                Picker("", selection: Binding(get: { layer.blend }, set: { value in update { $0.blend = value } })) {
                    ForEach(LightingBlend.allCases, id: \.self) { Text(verbatim: Titles.humanize($0.rawValue)).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
        }
        .opacity(layer.enabled ? 1 : 0.55)
    }

    @ViewBuilder private var parameters: some View {
        switch layer.kind {
        case .solid(let color):
            ColorField(selected: color) { picked in update { $0.kind = .solid(picked) } }
        case .spectrum(let speed):
            speedRow(speed) { value in update { $0.kind = .spectrum(speed: value) } }
        case .wave(let speed, let direction):
            speedRow(speed) { value in update { $0.kind = .wave(speed: value, direction: direction) } }
            Segmented(options: [0, 1], selection: Binding(get: { direction }, set: { value in update { $0.kind = .wave(speed: speed, direction: value) } }), tint: accent) {
                $0 == 0 ? Text("Left to right") : Text("Right to left")
            }
        case .breathing(let color, let speed):
            ColorField(selected: color) { picked in update { $0.kind = .breathing(color: picked, speed: speed) } }
            speedRow(speed) { value in update { $0.kind = .breathing(color: color, speed: value) } }
        case .starlight(let colors, let speed, let density):
            ColorField(selected: colors.first ?? RGBColor(r: 255, g: 255, b: 255)) { picked in
                update { var list = colors; if list.isEmpty { list = [picked] } else { list[0] = picked }; $0.kind = .starlight(colors: list, speed: speed, density: density) }
            }
            Toggle(isOn: Binding(get: { colors.count > 1 }, set: { on in
                update { $0.kind = .starlight(colors: on ? [colors.first ?? RGBColor(r: 255, g: 255, b: 255), RGBColor(r: 0, g: 229, b: 255)] : Array(colors.prefix(1)), speed: speed, density: density) }
            })) { Text("Second color").font(.callout) }.toggleStyle(.switch)
            if colors.count > 1 {
                ColorField(selected: colors[1]) { picked in update { var list = colors; list[1] = picked; $0.kind = .starlight(colors: list, speed: speed, density: density) } }
            }
            speedRow(speed) { value in update { $0.kind = .starlight(colors: colors, speed: value, density: density) } }
            SettingRow(title: Text("Density"), value: Text(verbatim: "\(Int((density * 100).rounded()))%")) {
                Slider(value: Binding(get: { density }, set: { value in update { $0.kind = .starlight(colors: colors, speed: speed, density: value) } }), in: 0.05...1)
            }
        case .reactive(let color, let decay, let ripple):
            ColorField(selected: color) { picked in update { $0.kind = .reactive(color: picked, decay: decay, ripple: ripple) } }
            SettingRow(title: Text("Fade"), value: Text(verbatim: String(format: "%.1f s", decay))) {
                Slider(value: Binding(get: { decay }, set: { value in update { $0.kind = .reactive(color: color, decay: value, ripple: ripple) } }), in: 0.1...3)
            }
            Toggle(isOn: Binding(get: { ripple }, set: { value in update { $0.kind = .reactive(color: color, decay: decay, ripple: value) } })) { Text("Ripple outwards").font(.callout) }.toggleStyle(.switch)
        case .rainbowRipple(let speed, let decay):
            speedRow(speed) { value in update { $0.kind = .rainbowRipple(speed: value, decay: decay) } }
            SettingRow(title: Text("Fade"), value: Text(verbatim: String(format: "%.1f s", decay))) {
                Slider(value: Binding(get: { decay }, set: { value in update { $0.kind = .rainbowRipple(speed: speed, decay: value) } }), in: 0.2...3)
            }
        case .gradient(let from, let to, let angle):
            ColorField(selected: from, title: Text("From")) { picked in update { $0.kind = .gradient(from: picked, to: to, angle: angle) } }
            ColorField(selected: to, title: Text("To")) { picked in update { $0.kind = .gradient(from: from, to: picked, angle: angle) } }
            SettingRow(title: Text("Angle"), value: Text(verbatim: "\(Int(angle))°")) {
                Slider(value: Binding(get: { angle }, set: { value in update { $0.kind = .gradient(from: from, to: to, angle: value.rounded()) } }), in: 0...360)
            }
        case .painted(let cells):
            let painting = scenes.paintingLayerID == layer.id
            Text("\(cells.count) keys painted").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { scenes.paintingLayerID = painting ? nil : layer.id } label: {
                    Label(painting ? "Done painting" : "Paint keys", systemImage: painting ? "checkmark" : "paintbrush")
                }
                .buttonStyle(PillButtonStyle(tint: accent, selected: painting))
                Button("Clear") { update { $0.kind = .painted([]) } }.buttonStyle(PillButtonStyle())
            }
        }
    }

    private func speedRow(_ speed: Double, set: @escaping (Double) -> Void) -> some View {
        SettingRow(title: Text("Speed"), value: Text(verbatim: String(format: "%.1f×", speed))) {
            Slider(value: Binding(get: { speed }, set: set), in: 0.1...4)
        }
    }
}
