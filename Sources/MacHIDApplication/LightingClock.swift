import Foundation
import MacHIDDomain

/// One shared clock for every lit device, so animated effects stay in step instead of drifting apart.
///
/// Pure and injectable: callers pass `now` (seconds on any steady timeline, e.g. `Date.timeIntervalSinceReferenceDate`).
/// All devices rendered with `time(at:)` see the same phase for the same instant, so two keyboards (or a keyboard and
/// the software color of a mouse) show the same point of the spectrum at the same moment.
///
/// Limit: effects that run inside the device firmware (G203 `cycle`, Razer `spectrum`/`wave`) start when the command is
/// received and the app cannot read or set their phase. Those can match a period at best (when the device takes one) but
/// cannot be phase-locked; to lock them, render the effect in software (`GlobalLightingPlan` does this for devices with
/// per-key lighting) or re-send the effect on all devices at once (`GlobalLightingPlan.writes` are meant to be applied together).
public struct LightingClock: Sendable, Equatable {
    public static let defaultCycleSeconds = 10.0
    public static let cycleRange = 2.0...120.0

    /// The instant phase 0 refers to.
    public var origin: TimeInterval
    /// Seconds for one full cycle of a spectrum, wave or breathing effect.
    public var cycleSeconds: Double

    public init(origin: TimeInterval = 0, cycleSeconds: Double = LightingClock.defaultCycleSeconds) {
        self.origin = origin
        self.cycleSeconds = min(max(cycleSeconds, Self.cycleRange.lowerBound), Self.cycleRange.upperBound)
    }

    /// Time to give `LightingCompositor.render`: identical for every device at the same `now`.
    public func time(at now: TimeInterval) -> TimeInterval { now - origin }

    /// Position inside the current cycle, 0..<1.
    public func phase(at now: TimeInterval) -> Double {
        let p = (time(at: now) / cycleSeconds).truncatingRemainder(dividingBy: 1)
        return p < 0 ? p + 1 : p
    }

    /// Compositor speeds that make each animated layer complete one cycle in `cycleSeconds`
    /// (the compositor's base rates: spectrum 0.12 cycles/s, wave 0.22, breathing 0.25 at speed 1).
    public var spectrumSpeed: Double { 1 / (0.12 * cycleSeconds) }
    public var waveSpeed: Double { 1 / (0.22 * cycleSeconds) }
    public var breathingSpeed: Double { 1 / (0.25 * cycleSeconds) }

    /// The scene with its spectrum, wave and breathing layers set to this clock's cycle, marked as synced.
    public func retimed(_ scene: LightingScene) -> LightingScene {
        var copy = scene
        copy.syncToGlobalClock = true
        copy.layers = scene.layers.map { layer in
            var l = layer
            switch layer.kind {
            case .spectrum: l.kind = .spectrum(speed: spectrumSpeed)
            case .wave(_, let direction): l.kind = .wave(speed: waveSpeed, direction: direction)
            case .breathing(let color, _): l.kind = .breathing(color: color, speed: breathingSpeed)
            default: break
            }
            return l
        }
        return copy
    }

    /// Time to render `scene` at: the shared clock when the scene asks for it, otherwise `localTime`.
    public func renderTime(for scene: LightingScene, now: TimeInterval, localTime: TimeInterval) -> TimeInterval {
        scene.syncToGlobalClock ? time(at: now) : localTime
    }
}
