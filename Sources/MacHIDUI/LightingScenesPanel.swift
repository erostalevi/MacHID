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
    /// Only one layer is open at a time (the others fold to one line); nil means the top layer.
    @State private var expandedID: String?

    private var expandedLayerID: String? {
        if let painting = scenes.paintingLayerID, scene.layers.contains(where: { $0.id == painting }) { return painting }
        if let expandedID, scene.layers.contains(where: { $0.id == expandedID }) { return expandedID }
        return scene.layers.last?.id
    }

    private func save(_ change: (inout LightingScene) -> Void) {
        var copy = scene
        change(&copy)
        scenes.upsertScene(copy)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Card(title: Text("Scene")) {
                TextField("Name", text: Binding(get: { scene.name }, set: { value in save { $0.name = value } }))
                    .textFieldStyle(.plain).font(.title3.weight(.semibold)).commitsAndResigns()
                SettingRow(title: Text("Brightness"), value: Text(verbatim: "\(scene.brightness)%")) {
                    Slider(value: Binding(get: { Double(scene.brightness) }, set: { value in save { $0.brightness = Int(value.rounded()) } }), in: 1...100)
                }
            }
            // Shown top layer first (what you see on top of the keyboard is on top of the list); the stored
            // order, which the renderer composites bottom to top, is unchanged.
            ForEach(Array(scene.layers.enumerated()).reversed(), id: \.element.id) { index, layer in
                LayerCard(scenes: scenes, layer: layer, index: index, count: scene.layers.count, accent: accent,
                          expanded: expandedLayerID == layer.id,
                          expand: { withAnimation(.snappy(duration: 0.25)) { expandedID = layer.id } },
                          update: { change in save { change(&$0.layers[index]) } },
                          move: { offset in save { if $0.layers.indices.contains(index + offset) { $0.layers.swapAt(index, index + offset) } } },
                          remove: { save { $0.layers.remove(at: index) }; if expandedID == layer.id { expandedID = nil } })
            }
            Menu {
                ForEach(Self.kinds, id: \.name) { entry in
                    Button(LocalizedStringKey(entry.name)) {
                        let layer = LightingLayer(id: UUID().uuidString, name: String(localized: String.LocalizationValue(entry.name)), kind: entry.make())
                        save { $0.layers.append(layer) }
                        expandedID = layer.id   // a new layer opens, so it can be edited at once
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
