import Foundation
import Observation
import MacHIDApplication
import MacHIDDomain

/// One page for every device's lighting: a simple preset, brightness and a shared cycle time. Devices whose firmware can
/// take the effect get it as a native write; keyboards (and anything else that shows per-key frames) are driven from one
/// shared clock so their animations stay in step.
@MainActor
@Observable
public final class GlobalLightController {
    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        case off, solid, spectrum, wave, breathing
        public var id: String { rawValue }
    }

    public var kind: Kind = .spectrum
    public var color = RGBColor(r: 0, g: 229, b: 255)
    public var brightness = 100.0
    public var cycleSeconds = LightingClock.defaultCycleSeconds
    public var keepInSync = true
    public private(set) var notes: [String] = []
    public private(set) var active = false

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private weak var scenes: LightingScenesController?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var clock = LightingClock(origin: Date.timeIntervalSinceReferenceDate)
    static let key = "globalLight.settings"

    public init(model: AppModel, scenes: LightingScenesController, defaults: UserDefaults = .standard) {
        self.model = model
        self.scenes = scenes
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode(GlobalLightingSettings.self, from: data) {
            brightness = Double(saved.brightness)
            cycleSeconds = saved.cycleSeconds
            keepInSync = saved.keepInSync
            switch saved.preset {
            case .off: kind = .off
            case .solid(let c): kind = .solid; color = c
            case .spectrum: kind = .spectrum
            case .wave: kind = .wave
            case .breathing(let c): kind = .breathing; color = c
            }
        }
    }

    var settings: GlobalLightingSettings {
        let preset: GlobalLightingPreset = switch kind {
        case .off: .off
        case .solid: .solid(color)
        case .spectrum: .spectrum
        case .wave: .wave
        case .breathing: .breathing(color)
        }
        return GlobalLightingSettings(preset: preset, brightness: Int(brightness), cycleSeconds: cycleSeconds, keepInSync: keepInSync)
    }

    public var needsColor: Bool { kind == .solid || kind == .breathing }
    public var usesCycle: Bool { kind == .spectrum || kind == .wave || kind == .breathing }

    /// Sends the current settings to every connected device and restarts the shared clock.
    public func apply() {
        guard let model, let scenes else { return }
        let settings = settings
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.key) }
        clock = LightingClock(origin: Date.timeIntervalSinceReferenceDate, cycleSeconds: settings.cycleSeconds)
        let devices = model.devices.compactMap { entry in entry.definition.map { GlobalLightingDevice(id: entry.id, definition: $0) } }
        let plan = GlobalLightingPlan.make(settings: settings, devices: devices)
        for write in plan.writes { model.set(write.value, capability: write.capabilityID, on: write.deviceID) }
        if plan.softwareDeviceIDs.isEmpty {
            scenes.setGlobalOverride(nil)
        } else {
            scenes.setGlobalOverride((clock.retimed(GlobalLightingPlan.scene(for: settings)), clock, Set(plan.softwareDeviceIDs)))
        }
        active = true
        var lines: [String] = []
        if !plan.notPhaseLockedDeviceIDs.isEmpty {
            lines.append(String(localized: "Some devices run the effect in their own firmware; they use the same cycle time but can drift apart."))
        }
        for skip in plan.skipped { lines.append("\(name(of: skip.deviceID)): \(skip.reason)") }
        notes = lines
    }

    /// Hands the lighting back to the per-device settings and scenes.
    public func release() {
        scenes?.setGlobalOverride(nil)
        active = false
        notes = []
    }

    private func name(of id: String) -> String { model?.devices.first { $0.id == id }?.definition?.name ?? id }
}
