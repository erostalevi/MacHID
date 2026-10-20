import Foundation
import MacHIDDomain

/// A key press the reactive layers react to. `startTime` is on the same clock as the `time` given to `render`.
public struct KeyEvent: Sendable, Equatable {
    public let keyID: String
    public let startTime: TimeInterval
    public init(keyID: String, startTime: TimeInterval) { self.keyID = keyID; self.startTime = startTime }
}

/// Software renderer for layered scenes (M12). Pure and deterministic: the same inputs give the same output.
///
/// Color math: gamma-encoded sRGB components in 0...1 (no linearisation; this matches how the on-screen simulation and
/// the keyboard's own effects behave and keeps results predictable). Each layer yields a color and an alpha per key; the
/// layer alpha is `layerAlpha * opacity * regionMask`. Compositing over the backdrop (starts opaque black):
/// `out = backdrop * (1 - a) + a * blend(backdrop, source)` with normal = s, add = min(1, b + s), screen = 1 - (1 - b)(1 - s),
/// multiply = b * s. The scene brightness scales the final color. Spectrum, wave and gradients use HSV (s 0.85, v 1).
public enum LightingCompositor {
    /// Only the newest events count; older ones are dropped to bound the per-frame cost.
    public static let maxEvents = 32
    /// Ring speed of ripples, key units per second.
    static let rippleSpeed = 9.0

    private struct Pixel { var r = 0.0, g = 0.0, b = 0.0, a = 0.0 }

    // MARK: Public API

    public static func render(_ scene: LightingScene, layout: KeyboardLayout, time: TimeInterval,
                              keyEvents: [KeyEvent] = []) -> [String: RGBColor] {
        let events = Array(keyEvents.filter { $0.startTime <= time }.sorted { $0.startTime < $1.startTime }.suffix(maxEvents))
        var canvas = [String: (r: Double, g: Double, b: Double)](minimumCapacity: layout.keys.count)
        for key in layout.keys { canvas[key.id] = (0, 0, 0) }
        let boardWidth = max(layout.width, 1), boardHeight = max(layout.height, 1)
        let byCell = Dictionary(layout.keys.map { ("\($0.row),\($0.col)", $0.id) }, uniquingKeysWith: { first, _ in first })

        for layer in scene.layers where layer.enabled {
            let opacity = clamp01(layer.opacity)
            guard opacity > 0 else { continue }
            let painted: [String: RGBColor]
            if case .painted(let cells) = layer.kind {
                var map: [String: RGBColor] = [:]
                for cell in cells { if let id = byCell["\(cell.row),\(cell.col)"] { map[id] = cell.color } }
                painted = map
            } else { painted = [:] }

            for key in layout.keys where layer.region.contains(key.id) {
                let pixel = pixelFor(layer.kind, key: key, width: boardWidth, height: boardHeight, layout: layout,
                                     time: time, events: events, painted: painted)
                let a = clamp01(pixel.a) * opacity
                guard a > 0, let below = canvas[key.id] else { continue }
                let blended = blend(layer.blend, below: below, source: (pixel.r, pixel.g, pixel.b))
                canvas[key.id] = (below.r * (1 - a) + blended.r * a, below.g * (1 - a) + blended.g * a, below.b * (1 - a) + blended.b * a)
            }
        }
        let gain = Double(min(max(scene.brightness, 0), 100)) / 100
        return canvas.mapValues { RGBColor(r: byte($0.r * gain), g: byte($0.g * gain), b: byte($0.b * gain)) }
    }

    /// The per-key frame (matrix cells) of a render. Dark keys are left out: `SettingValue.keyFrame` leaves unlisted keys dark.
    public static func frame(_ scene: LightingScene, layout: KeyboardLayout, time: TimeInterval,
                             keyEvents: [KeyEvent] = []) -> [KeyColor] {
        let colors = render(scene, layout: layout, time: time, keyEvents: keyEvents)
        return layout.keys.compactMap { key in
            guard let color = colors[key.id], color.r != 0 || color.g != 0 || color.b != 0 else { return nil }
            return KeyColor(row: key.row, col: key.col, color: color)
        }
    }

    /// True when the output depends on neither time nor key events: render once and send once.
    public static func isStatic(_ scene: LightingScene) -> Bool {
        scene.layers.filter { $0.enabled && $0.opacity > 0 }.allSatisfy {
            switch $0.kind {
            case .solid, .painted, .gradient: return true
            default: return false
            }
        }
    }

    /// The single native effect equal to the scene, if there is one: exactly one enabled layer covering the whole board at
    /// full opacity, not multiplied. Effect names follow the device definitions ("static", "spectrum", "wave", ...).
    /// Native speed steps are approximations (Razer: reactive 1...4, starlight 1...3). Painted, gradient and ripple layers have none.
    public static func nativeEquivalent(_ scene: LightingScene) -> LightingEffect? {
        let active = scene.layers.filter { $0.enabled && $0.opacity > 0 }
        let brightness = scene.brightness < 100 ? max(scene.brightness, 1) : nil
        if active.isEmpty { return LightingEffect("off") }
        guard active.count == 1, let layer = active.first, layer.opacity >= 1, layer.region == .all, layer.blend != .multiply else { return nil }
        switch layer.kind {
        case .solid(let c): return LightingEffect("static", color: c, brightness: brightness)
        case .spectrum: return LightingEffect("spectrum", brightness: brightness)
        case .wave(_, let direction): return LightingEffect("wave", brightness: brightness, direction: direction == 1 ? 1 : 0)
        case .breathing(let c, let speed):
            return LightingEffect("breathing", color: c, period: Int((4000 / max(speed, 0.1)).rounded()), brightness: brightness)
        case .starlight(let colors, let speed, _):
            let step = speed < 0.75 ? 1 : (speed < 1.5 ? 2 : 3)
            return LightingEffect("starlight", color: colors.first, brightness: brightness, speed: step, secondColor: colors.count > 1 ? colors[1] : nil)
        case .reactive(let c, let decay, let ripple):
            guard !ripple else { return nil }
            return LightingEffect("reactive", color: c, brightness: brightness, speed: decay <= 0.4 ? 1 : (decay <= 0.8 ? 2 : (decay <= 1.2 ? 3 : 4)))
        case .painted, .gradient, .rainbowRipple: return nil
        }
    }

    /// One color for a single-zone device (a mouse): the average of the rendered board. Use `nativeEquivalent` when it exists.
    public static func singleZoneColor(_ scene: LightingScene, time: TimeInterval, keyEvents: [KeyEvent] = [],
                                       layout: KeyboardLayout = .huntsmanMini) -> RGBColor {
        let colors = Array(render(scene, layout: layout, time: time, keyEvents: keyEvents).values)
        guard !colors.isEmpty else { return RGBColor(r: 0, g: 0, b: 0) }
        func mean(_ f: (RGBColor) -> UInt8) -> UInt8 { UInt8(colors.reduce(0) { $0 + Int(f($1)) } / colors.count) }
        return RGBColor(r: mean(\.r), g: mean(\.g), b: mean(\.b))
    }

    // MARK: Layers

    private static func pixelFor(_ kind: LightingLayerKind, key: KeyboardKey, width: Double, height: Double, layout: KeyboardLayout,
                                 time t: TimeInterval, events: [KeyEvent], painted: [String: RGBColor]) -> Pixel {
        let cx = (key.x + key.width / 2) / width
        switch kind {
        case .solid(let c): return pixel(c, 1)
        case .spectrum(let speed):
            return hsv(t * 0.12 * speed, alpha: 1)
        case .wave(let speed, let direction):
            return hsv((direction == 1 ? 1 : -1) * t * 0.22 * speed + cx, alpha: 1)
        case .breathing(let c, let speed):
            return pixel(c, 0.12 + 0.88 * (0.5 + 0.5 * sin(2 * .pi * t * 0.25 * max(speed, 0))))
        case .starlight(let colors, let speed, let density):
            guard !colors.isEmpty else { return Pixel() }
            let seed = hash(key.id, 0)
            let period = 2 / max(speed, 0.05)
            let position = t / period + unit(seed)
            let cycle = Int(floor(position)), phase = position - floor(position)
            let roll = hash(key.id, UInt64(bitPattern: Int64(cycle)) &+ 1)
            guard unit(roll) < clamp01(density) else { return Pixel() }
            let color = colors[Int(roll >> 33) % colors.count]
            return pixel(color, pow(max(0, sin(phase * .pi)), 2))
        case .reactive(let c, let decay, let ripple):
            let life = max(decay, 0.05)
            var level = 0.0
            for event in events {
                let age = t - event.startTime
                guard age >= 0, age < life else { continue }
                let fade = pow(1 - age / life, 2)
                if event.keyID == key.id { level = max(level, fade) }
                else if ripple, let origin = layout.key(id: event.keyID) {
                    level = max(level, 0.6 * fade * ring(from: origin, to: key, age: age))
                }
            }
            return pixel(c, level)
        case .painted:
            return painted[key.id].map { pixel($0, 1) } ?? Pixel()
        case .gradient(let from, let to, let angle):
            let rad = angle * .pi / 180
            let nx = cx, ny = (key.y + key.height / 2) / height
            let (dx, dy) = (cos(rad), sin(rad))
            // Project onto the direction and normalise to the board's extent along it.
            let extent = abs(dx) + abs(dy)
            let p = extent == 0 ? 0 : clamp01(0.5 + ((nx - 0.5) * dx + (ny - 0.5) * dy) / extent)
            func mix(_ a: UInt8, _ b: UInt8) -> Double { (Double(a) + (Double(b) - Double(a)) * p) / 255 }
            return Pixel(r: mix(from.r, to.r), g: mix(from.g, to.g), b: mix(from.b, to.b), a: 1)
        case .rainbowRipple(let speed, let decay):
            let life = max(decay, 0.05)
            var best = Pixel()
            for event in events {
                let age = t - event.startTime
                guard age >= 0, age < life, let origin = layout.key(id: event.keyID) else { continue }
                let fade = pow(1 - age / life, 2)
                let d = distance(origin, key)
                let radius = age * rippleSpeed * max(speed, 0.1)
                let a = fade * max(0, 1 - abs(d - radius) / 1.6)
                if a > best.a { best = hsv(d / 8 + t * 0.2, alpha: a) }
            }
            return best
        }
    }

    private static func ring(from origin: KeyboardKey, to key: KeyboardKey, age: Double) -> Double {
        max(0, 1 - abs(distance(origin, key) - age * rippleSpeed) / 1.6)
    }

    private static func distance(_ a: KeyboardKey, _ b: KeyboardKey) -> Double {
        let dx = (a.x + a.width / 2) - (b.x + b.width / 2), dy = (a.y + a.height / 2) - (b.y + b.height / 2)
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: Math

    private static func blend(_ mode: LightingBlend, below b: (r: Double, g: Double, b: Double),
                              source s: (Double, Double, Double)) -> (r: Double, g: Double, b: Double) {
        func f(_ cb: Double, _ cs: Double) -> Double {
            switch mode {
            case .normal: return cs
            case .add: return min(1, cb + cs)
            case .screen: return 1 - (1 - cb) * (1 - cs)
            case .multiply: return cb * cs
            }
        }
        return (f(b.r, s.0), f(b.g, s.1), f(b.b, s.2))
    }

    private static func pixel(_ c: RGBColor, _ a: Double) -> Pixel { Pixel(r: Double(c.r) / 255, g: Double(c.g) / 255, b: Double(c.b) / 255, a: a) }

    /// HSV with s = 0.85, v = 1; `hue` wraps (any real number).
    private static func hsv(_ hue: Double, alpha: Double) -> Pixel {
        let h = (hue - floor(hue)) * 6, s = 0.85
        let i = Int(h) % 6, f = h - floor(h)
        let p = 1 - s, q = 1 - s * f, t = 1 - s * (1 - f)
        let rgb: (Double, Double, Double)
        switch i {
        case 0: rgb = (1, t, p)
        case 1: rgb = (q, 1, p)
        case 2: rgb = (p, 1, t)
        case 3: rgb = (p, q, 1)
        case 4: rgb = (t, p, 1)
        default: rgb = (1, p, q)
        }
        return Pixel(r: rgb.0, g: rgb.1, b: rgb.2, a: alpha)
    }

    /// FNV-1a over the key id, mixed with `salt` through splitmix64: stable across runs and platforms.
    static func hash(_ text: String, _ salt: UInt64) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        var z = h &+ salt &* 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    private static func unit(_ h: UInt64) -> Double { Double(h >> 11) / Double(1 << 53) }
    private static func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }
    private static func byte(_ v: Double) -> UInt8 { UInt8(min(max((v * 255).rounded(), 0), 255)) }
}

/// Decides whether a new frame is worth sending: at most one frame per `minInterval` and only when some channel
/// moved by more than `tolerance` (0...255) since the last frame sent. 0.05 s is 20 fps.
public struct FrameThrottle: Sendable {
    public let minInterval: TimeInterval
    public let tolerance: Int
    private var lastTime: TimeInterval?
    private var last: [String: RGBColor] = [:]

    public init(minInterval: TimeInterval = 0.05, tolerance: Int = 2) {
        self.minInterval = minInterval
        self.tolerance = tolerance
    }

    /// Returns true (and remembers the frame) when it should be sent.
    public mutating func shouldSend(_ frame: [KeyColor], at time: TimeInterval) -> Bool {
        let current = Dictionary(frame.map { ("\($0.row),\($0.col)", $0.color) }, uniquingKeysWith: { _, new in new })
        if let lastTime {
            if time - lastTime < minInterval { return false }
            if Self.maxDelta(last, current) <= tolerance { return false }
        }
        lastTime = time
        last = current
        return true
    }

    /// Forget the last frame (after a reconnect or a mode change) so the next one is sent.
    public mutating func reset() { lastTime = nil; last = [:] }

    /// Largest per-channel difference between two frames; a key missing from one side counts as black.
    public static func maxDelta(_ a: [String: RGBColor], _ b: [String: RGBColor]) -> Int {
        let black = RGBColor(r: 0, g: 0, b: 0)
        var delta = 0
        for key in Set(a.keys).union(b.keys) {
            let x = a[key] ?? black, y = b[key] ?? black
            delta = max(delta, abs(Int(x.r) - Int(y.r)), abs(Int(x.g) - Int(y.g)), abs(Int(x.b) - Int(y.b)))
        }
        return delta
    }
}
