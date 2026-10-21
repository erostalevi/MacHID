/// Layered lighting scenes (M12). Pure data: rendering lives in `MacHIDApplication.LightingCompositor`.
/// Every type is Codable with tolerant decoding: unknown layer kinds or malformed layers are dropped, missing fields take defaults.

public enum LightingBlend: String, Sendable, Codable, Equatable, CaseIterable {
    case normal, add, screen, multiply
}

/// Which keys of the board a layer touches.
public enum LightingRegion: Sendable, Equatable, Codable {
    case all
    case keys([String])

    private enum CodingKeys: String, CodingKey { case type, keys }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if (try c.decodeIfPresent(String.self, forKey: .type)) == "keys" {
            self = .keys(try c.decodeIfPresent([String].self, forKey: .keys) ?? [])
        } else {
            self = .all
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .all: try c.encode("all", forKey: .type)
        case .keys(let ids): try c.encode("keys", forKey: .type); try c.encode(ids, forKey: .keys)
        }
    }

    public func contains(_ keyID: String) -> Bool {
        switch self {
        case .all: return true
        case .keys(let ids): return ids.contains(keyID)
        }
    }
}

/// What a layer draws. Speeds are multipliers (1 = default pace). Times are seconds.
public enum LightingLayerKind: Sendable, Equatable, Codable {
    case solid(RGBColor)
    case spectrum(speed: Double)
    /// `direction` 0 = left to right, 1 = right to left.
    case wave(speed: Double, direction: Int)
    case breathing(color: RGBColor, speed: Double)
    /// `density` 0...1: share of keys that sparkle in a given cycle.
    case starlight(colors: [RGBColor], speed: Double, density: Double)
    /// Keys flash when pressed and fade over `decay` seconds; `ripple` also sends a ring over the neighbours.
    case reactive(color: RGBColor, decay: Double, ripple: Bool)
    /// Listed cells take their color, the rest is transparent.
    case painted([KeyColor])
    /// Linear gradient across the board; `angle` in degrees (0 = left to right, 90 = top to bottom).
    case gradient(from: RGBColor, to: RGBColor, angle: Double)
    /// Ring that grows from each pressed key with a rainbow of hues.
    case rainbowRipple(speed: Double, decay: Double)

    private enum CodingKeys: String, CodingKey { case type, color, from, to, colors, speed, direction, density, decay, ripple, keys, angle }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        let speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        let white = RGBColor(r: 255, g: 255, b: 255)
        switch type {
        case "solid": self = .solid(try c.decodeIfPresent(RGBColor.self, forKey: .color) ?? white)
        case "spectrum": self = .spectrum(speed: speed)
        case "wave": self = .wave(speed: speed, direction: try c.decodeIfPresent(Int.self, forKey: .direction) ?? 0)
        case "breathing": self = .breathing(color: try c.decodeIfPresent(RGBColor.self, forKey: .color) ?? white, speed: speed)
        case "starlight":
            self = .starlight(colors: try c.decodeIfPresent([RGBColor].self, forKey: .colors) ?? [white], speed: speed,
                              density: try c.decodeIfPresent(Double.self, forKey: .density) ?? 0.2)
        case "reactive":
            self = .reactive(color: try c.decodeIfPresent(RGBColor.self, forKey: .color) ?? white,
                             decay: try c.decodeIfPresent(Double.self, forKey: .decay) ?? 0.8,
                             ripple: try c.decodeIfPresent(Bool.self, forKey: .ripple) ?? false)
        case "painted": self = .painted(try c.decodeIfPresent([KeyColor].self, forKey: .keys) ?? [])
        case "gradient":
            self = .gradient(from: try c.decodeIfPresent(RGBColor.self, forKey: .from) ?? white,
                             to: try c.decodeIfPresent(RGBColor.self, forKey: .to) ?? RGBColor(r: 0, g: 0, b: 0),
                             angle: try c.decodeIfPresent(Double.self, forKey: .angle) ?? 0)
        case "rainbowRipple":
            self = .rainbowRipple(speed: speed, decay: try c.decodeIfPresent(Double.self, forKey: .decay) ?? 1.2)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown layer kind \(type)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .solid(let color): try c.encode("solid", forKey: .type); try c.encode(color, forKey: .color)
        case .spectrum(let speed): try c.encode("spectrum", forKey: .type); try c.encode(speed, forKey: .speed)
        case .wave(let speed, let direction):
            try c.encode("wave", forKey: .type); try c.encode(speed, forKey: .speed); try c.encode(direction, forKey: .direction)
        case .breathing(let color, let speed):
            try c.encode("breathing", forKey: .type); try c.encode(color, forKey: .color); try c.encode(speed, forKey: .speed)
        case .starlight(let colors, let speed, let density):
            try c.encode("starlight", forKey: .type); try c.encode(colors, forKey: .colors)
            try c.encode(speed, forKey: .speed); try c.encode(density, forKey: .density)
        case .reactive(let color, let decay, let ripple):
            try c.encode("reactive", forKey: .type); try c.encode(color, forKey: .color)
            try c.encode(decay, forKey: .decay); try c.encode(ripple, forKey: .ripple)
        case .painted(let keys): try c.encode("painted", forKey: .type); try c.encode(keys, forKey: .keys)
        case .gradient(let from, let to, let angle):
            try c.encode("gradient", forKey: .type); try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to); try c.encode(angle, forKey: .angle)
        case .rainbowRipple(let speed, let decay):
            try c.encode("rainbowRipple", forKey: .type); try c.encode(speed, forKey: .speed); try c.encode(decay, forKey: .decay)
        }
    }
}

public struct LightingLayer: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var kind: LightingLayerKind
    /// 0...1 (values outside are clamped when rendering).
    public var opacity: Double
    public var blend: LightingBlend
    public var region: LightingRegion
    public var enabled: Bool

    public init(id: String, name: String, kind: LightingLayerKind, opacity: Double = 1, blend: LightingBlend = .normal,
                region: LightingRegion = .all, enabled: Bool = true) {
        self.id = id; self.name = name; self.kind = kind; self.opacity = opacity
        self.blend = blend; self.region = region; self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey { case id, name, kind, opacity, blend, region, enabled }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        kind = try c.decode(LightingLayerKind.self, forKey: .kind)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        blend = (try? c.decodeIfPresent(LightingBlend.self, forKey: .blend)) ?? .normal
        region = (try? c.decodeIfPresent(LightingRegion.self, forKey: .region)) ?? .all
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

/// Decodes an element or yields nil instead of failing the whole array.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
}

public struct LightingScene: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var name: String
    /// Bottom to top.
    public var layers: [LightingLayer]
    /// 0...100, applied to the final color.
    public var brightness: Int
    /// When true the scene is rendered on the shared `LightingClock` (one phase origin for every device) instead of its own
    /// start time, so animated layers on several devices stay in step.
    public var syncToGlobalClock: Bool

    public init(id: String, name: String, layers: [LightingLayer], brightness: Int = 100, syncToGlobalClock: Bool = false) {
        self.id = id; self.name = name; self.layers = layers; self.brightness = brightness; self.syncToGlobalClock = syncToGlobalClock
    }

    private enum CodingKeys: String, CodingKey { case id, name, layers, brightness, syncToGlobalClock }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        layers = (try c.decodeIfPresent([Lossy<LightingLayer>].self, forKey: .layers) ?? []).compactMap(\.value)
        brightness = try c.decodeIfPresent(Int.self, forKey: .brightness) ?? 100
        syncToGlobalClock = try c.decodeIfPresent(Bool.self, forKey: .syncToGlobalClock) ?? false
    }
}

/// While all of `modeIDs` are active, `sceneID` replaces the base scene.
public struct ShiftSceneRule: Sendable, Equatable, Codable {
    public var modeIDs: [String]
    public var sceneID: String
    public init(modeIDs: [String], sceneID: String) { self.modeIDs = modeIDs; self.sceneID = sceneID }
}

public struct LightingSetup: Sendable, Equatable, Codable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var baseSceneID: String
    /// Ordered: on equal specificity the first rule wins.
    public var shiftScenes: [ShiftSceneRule]
    public var scenes: [LightingScene]

    public init(baseSceneID: String, shiftScenes: [ShiftSceneRule] = [], scenes: [LightingScene],
                schemaVersion: Int = LightingSetup.currentSchemaVersion) {
        self.schemaVersion = schemaVersion; self.baseSceneID = baseSceneID
        self.shiftScenes = shiftScenes; self.scenes = scenes
    }

    /// The shipped scenes with `aurora` as base.
    public static var defaults: LightingSetup { LightingSetup(baseSceneID: "aurora", scenes: LightingScene.defaults) }

    private enum CodingKeys: String, CodingKey { case schemaVersion, baseSceneID, shiftScenes, scenes }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        scenes = (try c.decodeIfPresent([Lossy<LightingScene>].self, forKey: .scenes) ?? []).compactMap(\.value)
        baseSceneID = try c.decodeIfPresent(String.self, forKey: .baseSceneID) ?? scenes.first?.id ?? ""
        shiftScenes = (try c.decodeIfPresent([Lossy<ShiftSceneRule>].self, forKey: .shiftScenes) ?? []).compactMap(\.value)
    }

    public func scene(id: String) -> LightingScene? { scenes.first { $0.id == id } }

    /// Scene for the active shift modes. Among rules whose modes are all active, the one naming the most modes wins
    /// (ties: first in list). Rules pointing at a missing scene are skipped. Falls back to the base scene, then the first scene.
    public func scene(forActiveModes active: Set<String>) -> LightingScene? {
        var best: (count: Int, scene: LightingScene)?
        for rule in shiftScenes {
            let modes = Set(rule.modeIDs)
            guard !modes.isEmpty, modes.isSubset(of: active), let scene = scene(id: rule.sceneID) else { continue }
            if best == nil || modes.count > best!.count { best = (modes.count, scene) }
        }
        return best?.scene ?? scene(id: baseSceneID) ?? scenes.first
    }
}

extension LightingScene {
    private static func c(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> RGBColor { RGBColor(r: r, g: g, b: b) }

    /// Simple, one-idea scenes first (easy to pick and to edit), then the richer layered ones.
    public static let defaults: [LightingScene] = simple + layered

    public static let simple: [LightingScene] = [
        LightingScene(id: "solid", name: "Solid", layers: [
            LightingLayer(id: "base", name: "Color", kind: .solid(c(255, 255, 255)))]),
        LightingScene(id: "breathing", name: "Breathing", layers: [
            LightingLayer(id: "breathe", name: "Breathing", kind: .breathing(color: c(0, 140, 255), speed: 1))]),
        LightingScene(id: "reactive", name: "Reactive", layers: [
            LightingLayer(id: "base", name: "Dim base", kind: .solid(c(10, 10, 20))),
            LightingLayer(id: "react", name: "Keypress", kind: .reactive(color: c(255, 80, 0), decay: 0.8, ripple: false))]),
        LightingScene(id: "gaming", name: "Gaming", layers: [
            LightingLayer(id: "base", name: "Dim base", kind: .solid(c(40, 0, 0))),
            LightingLayer(id: "wasd", name: "WASD", kind: .solid(c(255, 40, 0)), region: .keys(["w", "a", "s", "d"]))]),
    ]

    public static let layered: [LightingScene] = [
        LightingScene(id: "aurora", name: "Aurora", layers: [
            LightingLayer(id: "wave", name: "Wave", kind: .wave(speed: 0.35, direction: 0), opacity: 0.85),
            LightingLayer(id: "react", name: "Keypress", kind: .reactive(color: c(255, 255, 255), decay: 0.9, ripple: true), blend: .add)]),
        LightingScene(id: "ember", name: "Ember", layers: [
            LightingLayer(id: "glow", name: "Glow", kind: .breathing(color: c(200, 30, 10), speed: 0.5)),
            LightingLayer(id: "sparks", name: "Sparks", kind: .starlight(colors: [c(255, 140, 20), c(255, 60, 10)], speed: 1, density: 0.25), blend: .add)]),
        LightingScene(id: "focus", name: "Focus", layers: [
            LightingLayer(id: "base", name: "Warm white", kind: .solid(c(255, 190, 120)))], brightness: 70),
        LightingScene(id: "typing-glow", name: "Typing glow", layers: [
            LightingLayer(id: "base", name: "Dim base", kind: .solid(c(20, 30, 45))),
            LightingLayer(id: "react", name: "Keypress", kind: .reactive(color: c(0, 220, 255), decay: 0.7, ripple: false), blend: .add)]),
        LightingScene(id: "rainbow", name: "Rainbow", layers: [
            LightingLayer(id: "spectrum", name: "Spectrum", kind: .spectrum(speed: 1))]),
    ]
}
