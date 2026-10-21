import Foundation
import Observation
import MacHIDApplication
import MacHIDDomain
import MacHIDQuartz
import MacHIDSystem

/// Runs layered lighting scenes. A scene made of one native effect is sent once; anything layered is rendered here and
/// streamed to keyboards as per-key frames (about 20 per second, only when something changed). Single-zone devices such
/// as mice get the scene's color or closest native effect whenever the scene changes. The active scene follows the
/// shift modes that are held (see `RemapController.onShiftModesChanged`).
@MainActor
@Observable
public final class LightingScenesController {
    public private(set) var setup: LightingSetup
    /// Master switch (off by default: scenes take over the lighting of every device while it is on).
    public private(set) var enabled: Bool
    public private(set) var activeModes: Set<String> = []
    /// The scene whose layers are being edited in the panel.
    public var editingSceneID: String?
    /// While set, clicking keys on the drawing paints this (painted) layer of the edited scene.
    public var paintingLayerID: String?
    /// Latest key presses (key ids with their time), for reactive layers in the on-screen preview too.
    public private(set) var keyEvents: [KeyEvent] = []
    public var banner: String?

    /// While set (global light control), this scene is rendered from the shared clock on `deviceIDs` instead of the scene setup.
    public private(set) var globalOverride: (scene: LightingScene, clock: LightingClock, deviceIDs: Set<String>)?

    @ObservationIgnored private let repository: FileLightingSceneRepository?
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var monitor: KeyPressMonitor?
    @ObservationIgnored private var throttles: [String: FrameThrottle] = [:]
    @ObservationIgnored private var applied: [String: String] = [:]   // device id -> what was last sent once
    static let enabledKey = "lightingScenes.enabled"

    public init(model: AppModel, repository: FileLightingSceneRepository? = FileLightingSceneRepository(),
                defaults: UserDefaults = .standard, setup: LightingSetup = .defaults) {
        self.model = model
        self.repository = repository
        self.defaults = defaults
        self.setup = setup
        self.enabled = defaults.bool(forKey: Self.enabledKey)
        self.editingSceneID = setup.baseSceneID
    }

    /// The scene that applies right now.
    public var currentScene: LightingScene? { setup.scene(forActiveModes: activeModes) }
    public var editingScene: LightingScene? { editingSceneID.flatMap(setup.scene(id:)) ?? setup.scenes.first }

    // MARK: Lifecycle

    public func load() async {
        if let repository { setup = await repository.load() }
        if setup.scene(id: editingSceneID ?? "") == nil { editingSceneID = setup.scenes.first?.id }
        reconcile()
    }

    public func setEnabled(_ on: Bool) {
        enabled = on
        defaults.set(on, forKey: Self.enabledKey)
        applied.removeAll()
        reconcile()
    }

    public func setGlobalOverride(_ value: (scene: LightingScene, clock: LightingClock, deviceIDs: Set<String>)?) {
        globalOverride = value
        applied.removeAll()
        throttles.removeAll()
        reconcile()
    }

    public func modesChanged(_ modes: Set<String>) {
        guard modes != activeModes else { return }
        activeModes = modes
        applied.removeAll()
    }

    private func reconcile() {
        task?.cancel(); task = nil
        monitor?.stop(); monitor = nil
        guard enabled || globalOverride != nil else { return }
        if globalOverride == nil, setup.scenes.contains(where: Self.reactsToKeys) {
            let monitor = KeyPressMonitor { [weak self] code in
                Task { @MainActor in self?.recordKey(code: code) }
            }
            if monitor.start() { self.monitor = monitor }
            else { banner = "Reactive lighting needs Input Monitoring." }
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private static func reactsToKeys(_ scene: LightingScene) -> Bool {
        scene.layers.contains { layer in
            switch layer.kind { case .reactive, .rainbowRipple: true; default: false }
        }
    }

    private func recordKey(code: Int) {
        guard let id = KeyboardKeyCodes.keyID(forCode: code) else { return }
        let now = Date.timeIntervalSinceReferenceDate
        keyEvents.append(KeyEvent(keyID: id, startTime: now))
        keyEvents.removeAll { now - $0.startTime > 4 }
        if keyEvents.count > LightingCompositor.maxEvents { keyEvents.removeFirst(keyEvents.count - LightingCompositor.maxEvents) }
    }

    // MARK: Output

    private func tick() {
        var now = Date.timeIntervalSinceReferenceDate
        let scene: LightingScene
        if let global = globalOverride {
            scene = global.scene
            now = global.clock.time(at: now)   // one phase origin for every device
        } else if enabled, let current = currentScene { scene = current } else { return }
        guard let model else { return }
        for device in model.devices {
            if let global = globalOverride, !global.deviceIDs.contains(device.id) { continue }
            guard let lighting = device.specs.first(where: { if case .lighting = $0.kind { true } else { false } }) else { continue }
            let hasKeys = device.specs.contains { if case .keyLighting = $0.kind { true } else { false } }
            if hasKeys, let layout = KeyboardLayout.layout(forDefinitionID: device.definition?.id) {
                driveKeyboard(device, scene: scene, layout: layout, lighting: lighting, now: now, model: model)
            } else {
                driveSingleZone(device, scene: scene, lighting: lighting, now: now, model: model)
            }
        }
    }

    private func driveKeyboard(_ device: AppModel.DeviceEntry, scene: LightingScene, layout: KeyboardLayout, lighting: ControlSpec,
                               now: TimeInterval, model: AppModel) {
        let signature = "\(scene.id)#\(scene.layers.hashValueDescription)"
        if let native = LightingCompositor.nativeEquivalent(scene) {
            guard applied[device.id] != signature else { return }
            applied[device.id] = signature
            model.setPerKey(false, for: device.id)
            model.set(.effect(native), capability: lighting.id, on: device.id)
            return
        }
        if LightingCompositor.isStatic(scene) {
            guard applied[device.id] != signature else { return }
            applied[device.id] = signature
            model.set(.keyFrame(LightingCompositor.frame(scene, layout: layout, time: now)), capability: "key_lighting", on: device.id)
            return
        }
        applied[device.id] = nil
        let frame = LightingCompositor.frame(scene, layout: layout, time: now, keyEvents: keyEvents)
        var throttle = throttles[device.id] ?? FrameThrottle()
        let send = throttle.shouldSend(frame, at: now)
        throttles[device.id] = throttle
        if send { model.stream(.keyFrame(frame), capability: "key_lighting", to: device.id) }
    }

    private func driveSingleZone(_ device: AppModel.DeviceEntry, scene: LightingScene, lighting: ControlSpec, now: TimeInterval, model: AppModel) {
        let signature = "\(scene.id)#\(scene.layers.hashValueDescription)"
        guard applied[device.id] != signature else { return }
        applied[device.id] = signature
        var modes: [String] = []
        if case .lighting(let available, _) = lighting.kind { modes = available }
        if let native = LightingCompositor.nativeEquivalent(scene) {
            // The G203 calls the rainbow effect "cycle".
            let name = native.effect == "spectrum" && modes.contains("cycle") ? "cycle" : native.effect
            if modes.contains(name) {
                if name == "off" { model.set(.text("off"), capability: lighting.id, on: device.id) }
                else if name == "static", let color = native.color { model.set(.color(color), capability: lighting.id, on: device.id) }
                else { model.set(.effect(LightingEffect(name, color: native.color, period: native.period, brightness: native.brightness)), capability: lighting.id, on: device.id) }
                return
            }
        }
        model.set(.color(LightingCompositor.singleZoneColor(scene, time: now, keyEvents: keyEvents)), capability: lighting.id, on: device.id)
    }

    // MARK: Editing

    private func commit(_ change: (inout LightingSetup) -> Void) {
        var copy = setup
        change(&copy)
        setup = copy
        applied.removeAll()
        throttles.removeAll()
        if enabled { reconcile() }
        let saved = copy
        Task { try? await repository?.save(saved) }
    }

    public func upsertScene(_ scene: LightingScene) {
        commit { setup in
            if let index = setup.scenes.firstIndex(where: { $0.id == scene.id }) { setup.scenes[index] = scene } else { setup.scenes.append(scene) }
        }
    }

    @discardableResult
    public func newScene() -> LightingScene {
        let scene = LightingScene(id: UUID().uuidString, name: String(localized: "New scene"), layers: [
            LightingLayer(id: UUID().uuidString, name: String(localized: "Color"), kind: .solid(RGBColor(r: 0, g: 87, b: 255)))])
        upsertScene(scene)
        editingSceneID = scene.id
        return scene
    }

    public func duplicate(_ id: String) {
        guard var copy = setup.scene(id: id) else { return }
        copy.id = UUID().uuidString
        copy.name += " " + String(localized: "copy")
        copy.layers = copy.layers.map { var layer = $0; layer.id = UUID().uuidString; return layer }
        upsertScene(copy)
        editingSceneID = copy.id
    }

    public func deleteScene(_ id: String) {
        guard setup.scenes.count > 1 else { return }
        commit { setup in
            setup.scenes.removeAll { $0.id == id }
            setup.shiftScenes.removeAll { $0.sceneID == id }
            if setup.baseSceneID == id { setup.baseSceneID = setup.scenes.first?.id ?? "" }
        }
        if editingSceneID == id { editingSceneID = setup.scenes.first?.id }
    }

    public func setBase(_ id: String) { commit { $0.baseSceneID = id } }

    public func setShiftScene(modes: [String], scene: String) {
        commit { setup in
            let key = Set(modes)
            setup.shiftScenes.removeAll { Set($0.modeIDs) == key }
            setup.shiftScenes.append(ShiftSceneRule(modeIDs: modes.sorted(), sceneID: scene))
        }
    }

    public func removeShiftScene(modes: [String]) {
        commit { setup in setup.shiftScenes.removeAll { Set($0.modeIDs) == Set(modes) } }
    }

    /// Shift modes that were removed leave their scene rules behind; drop them.
    public func pruneRules(existingModeIDs: Set<String>) {
        guard setup.shiftScenes.contains(where: { !Set($0.modeIDs).isSubset(of: existingModeIDs) }) else { return }
        commit { $0.shiftScenes.removeAll { !Set($0.modeIDs).isSubset(of: existingModeIDs) } }
    }

    /// Paints one key into the painted layer being edited.
    public func paint(keyID: String, color: RGBColor, layout: KeyboardLayout) {
        guard let layerID = paintingLayerID, var scene = editingScene, let key = layout.key(id: keyID),
              let index = scene.layers.firstIndex(where: { $0.id == layerID }), case .painted(var cells) = scene.layers[index].kind else { return }
        cells.removeAll { $0.row == key.row && $0.col == key.col }
        cells.append(KeyColor(row: key.row, col: key.col, color: color))
        scene.layers[index].kind = .painted(cells)
        upsertScene(scene)
    }
}

private extension Array where Element == LightingLayer {
    /// A cheap fingerprint of the layers, to notice edits without comparing whole scenes every tick.
    var hashValueDescription: String {
        guard let data = try? JSONEncoder().encode(self) else { return "\(count)" }
        var hash: UInt64 = 1469598103934665603
        for byte in data { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(hash, radix: 16)
    }
}
