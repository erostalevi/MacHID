import MacHIDDomain

public struct InputEvent: Equatable, Sendable {
    public var kind: InputKind
    public var code: Int
    public var modifiers: Modifiers
    public var isDown: Bool
    public var isRepeat: Bool

    public init(kind: InputKind, code: Int, modifiers: Modifiers = [], isDown: Bool, isRepeat: Bool = false) {
        self.kind = kind
        self.code = code
        self.modifiers = modifiers
        self.isDown = isDown
        self.isRepeat = isRepeat
    }
}

public enum OutputEvent: Equatable, Sendable {
    case key(code: Int, modifiers: Modifiers, down: Bool)
    case mouse(button: Int, down: Bool)
}

public enum RemapDecision: Equatable, Sendable {
    case passthrough
    /// Swallow the event.
    case suppress
    /// Swallow the event and send these instead.
    case emit([OutputEvent])
    case runMacro(String)
    /// Swallow the event and switch to the profile with this id.
    case switchProfile(String)
    /// Swallow the event and move to the next (+1) or previous (-1) profile.
    case cycleProfile(Int)
    /// Swallow the event and run this `SystemActionCatalog` action.
    case runSystem(String)
}

/// What to do with pointer movement while a shift gesture is held.
public struct MotionDecision: Equatable, Sendable {
    /// Set when the movement completed a gesture; nil otherwise.
    public var fired: RemapDecision?
    /// Swallow the movement event (pointer frozen).
    public var suppress: Bool
    public static let none = MotionDecision(fired: nil, suppress: false)
}

/// Decides what to do with each key or button event. Pure logic: no event taps, no permissions, no timing, so every
/// rule can be tested. It remembers which presses it remapped so the matching release is remapped the same way,
/// even when a modifier was let go first or a shift mode ended in the meantime.
///
/// Shift modes (layers): the trigger of each mode is consumed. `hold` modes are active while the trigger is down,
/// `toggle` modes flip on every press. Modes are independent, so several can be active together.
public struct RemapEngine: Sendable {
    private struct Pressed: Hashable { var kind: InputKind; var code: Int }

    public private(set) var config: RemapConfig
    private var active: [Pressed: RemapAction] = [:]
    /// Triggers currently down that belong to a shift mode (their release is consumed too).
    private var modeTriggersDown: [Pressed: String] = [:]
    private var toggled: Set<String> = []
    private struct GestureState { var dx = 0.0, dy = 0.0; var armed = true; var lastFired: GestureDirection? }
    /// Gesture triggers currently down -> gesture id; and the travel of each held gesture.
    private var gestureTriggersDown: [Pressed: String] = [:]
    private var gestureStates: [String: GestureState] = [:]

    public init(config: RemapConfig = RemapConfig()) { self.config = config }

    /// Ids of the shift modes that are active right now.
    public var activeShiftModeIDs: Set<String> {
        guard config.enabled else { return [] }
        return toggled.union(modeTriggersDown.values.filter { id in config.shiftMode(id: id)?.behavior == .hold })
    }

    /// Replaces the rules. Presses that were remapped and are still held get their release sent now, because the
    /// physical release will no longer be recognized (otherwise a remapped modifier could stay down).
    /// Toggled modes and held mode triggers survive when the mode still exists with the same trigger.
    @discardableResult
    public mutating func update(config: RemapConfig) -> [OutputEvent] {
        self.config = config
        var releases: [OutputEvent] = []
        for action in active.values {
            if case .emit(let events) = Self.release(action) { releases += events }
        }
        active.removeAll()
        let valid = Dictionary(uniqueKeysWithValues: config.shiftModes.filter(\.hasAllowedTrigger).map { ($0.id, $0) })
        modeTriggersDown = modeTriggersDown.filter { pressed, id in
            guard let mode = valid[id] else { return false }
            return mode.trigger.kind == pressed.kind && mode.trigger.code == pressed.code
        }
        toggled = toggled.filter { valid[$0] != nil }
        let gestures = Dictionary(uniqueKeysWithValues: config.gestures.filter(\.hasAllowedTrigger).map { ($0.id, $0) })
        gestureTriggersDown = gestureTriggersDown.filter { pressed, id in
            guard let gesture = gestures[id] else { return false }
            return gesture.trigger.kind == pressed.kind && gesture.trigger.code == pressed.code
        }
        gestureStates = gestureStates.filter { gestureTriggersDown.values.contains($0.key) }
        if !config.enabled { modeTriggersDown.removeAll(); toggled.removeAll(); gestureTriggersDown.removeAll(); gestureStates.removeAll() }
        return releases
    }

    /// Forgets presses, held triggers and toggled modes (used when the tap stops). Returns the releases to send.
    @discardableResult
    public mutating func resetTransientState() -> [OutputEvent] {
        var releases: [OutputEvent] = []
        for action in active.values {
            if case .emit(let events) = Self.release(action) { releases += events }
        }
        active.removeAll()
        modeTriggersDown.removeAll()
        toggled.removeAll()
        gestureTriggersDown.removeAll()
        gestureStates.removeAll()
        return releases
    }

    public mutating func decide(_ event: InputEvent, frontmostBundleID: String?) -> RemapDecision {
        let pressed = Pressed(kind: event.kind, code: event.code)
        if !event.isDown {
            if modeTriggersDown.removeValue(forKey: pressed) != nil { return .suppress }
            if let id = gestureTriggersDown.removeValue(forKey: pressed) { gestureStates[id] = nil; return .suppress }
            guard let action = active.removeValue(forKey: pressed) else { return .passthrough }
            return Self.release(action)
        }
        guard config.enabled else { return .passthrough }

        if let mode = shiftMode(for: event) {
            if !event.isRepeat {
                modeTriggersDown[pressed] = mode.id
                if mode.behavior == .toggle { flip(mode.id) }
            }
            return .suppress
        }

        if let gesture = gesture(for: event) {
            if !event.isRepeat { gestureTriggersDown[pressed] = gesture.id; gestureStates[gesture.id] = GestureState() }
            return .suppress
        }

        guard let rule = matchingRule(for: event, frontmostBundleID: frontmostBundleID) else { return .passthrough }
        active[pressed] = rule.action
        return decision(for: rule.action, isRepeat: event.isRepeat)
    }

    private mutating func decision(for action: RemapAction, isRepeat: Bool) -> RemapDecision {
        switch action {
        case .key(let code, let modifiers): return .emit([.key(code: code, modifiers: modifiers, down: true)])
        case .mouseButton(let button): return .emit([.mouse(button: button, down: true)])
        case .macro(let id): return isRepeat ? .suppress : .runMacro(id)   // holding a key must not restart the macro
        case .disable: return .suppress
        case .switchProfile(let id): return isRepeat ? .suppress : .switchProfile(id)
        case .nextProfile: return isRepeat ? .suppress : .cycleProfile(1)
        case .previousProfile: return isRepeat ? .suppress : .cycleProfile(-1)
        case .system(let id): return isRepeat ? .suppress : .runSystem(id)
        case .toggleShiftMode(let id):
            if !isRepeat { flip(id) }
            return .suppress
        }
    }

    // MARK: Shift gestures

    /// True when any gesture trigger is held (the tap can skip pointer events otherwise).
    public var isTrackingGestures: Bool { !gestureTriggersDown.isEmpty }
    /// True when the config has gestures and remapping is on (the tap only watches pointer movement then).
    public var wantsPointerMotion: Bool { config.enabled && config.gestures.contains { $0.hasAllowedTrigger } }

    /// Feeds a pointer movement (pixels since the last event). While a gesture trigger is held, travel accumulates; at
    /// `threshold` pixels on the dominant axis the direction's action fires once. The gesture re-arms when the pointer
    /// travels back half a threshold the other way, or when the trigger is released. Releasing resets the travel.
    public mutating func decideMotion(dx: Double, dy: Double) -> MotionDecision {
        guard config.enabled, !gestureTriggersDown.isEmpty else { return .none }
        var result = MotionDecision.none
        for id in Set(gestureTriggersDown.values).sorted() {
            guard let gesture = config.gestures.first(where: { $0.id == id }) else { continue }
            if gesture.freezePointer { result.suppress = true }
            var state = gestureStates[id] ?? GestureState()
            state.dx += dx; state.dy += dy
            let threshold = Double(gesture.threshold)
            if !state.armed, let last = state.lastFired {
                // Moving back along the fired axis re-arms (a swipe right then left is two gestures).
                let along = (last == .left || last == .right) ? state.dx : state.dy
                let sign: Double = (last == .right || last == .down) ? 1 : -1
                if along * sign > 0 {
                    // Still going the same way: the point of reference follows the farthest position.
                    if last == .left || last == .right { state.dx = 0 } else { state.dy = 0 }
                } else if along * sign <= -threshold / 2 { state = GestureState() }
                gestureStates[id] = state
                continue
            }
            let horizontal = abs(state.dx) >= abs(state.dy)
            let major = horizontal ? state.dx : state.dy
            guard abs(major) >= threshold else { gestureStates[id] = state; continue }
            let direction: GestureDirection = horizontal ? (major > 0 ? .right : .left) : (major > 0 ? .down : .up)
            state.armed = false; state.lastFired = direction
            // After firing, measure travel from here so "moving back" is relative to the point of firing.
            state.dx = 0; state.dy = 0
            gestureStates[id] = state
            if result.fired == nil, let action = gesture.actions[direction] {
                result.fired = fireDecision(for: action)
            }
        }
        return result
    }

    /// A gesture is a tap, not a hold: key and mouse actions are sent as press + release.
    private mutating func fireDecision(for action: RemapAction) -> RemapDecision {
        switch action {
        case .key(let code, let modifiers):
            return .emit([.key(code: code, modifiers: modifiers, down: true), .key(code: code, modifiers: modifiers, down: false)])
        case .mouseButton(let button): return .emit([.mouse(button: button, down: true), .mouse(button: button, down: false)])
        default: return decision(for: action, isRepeat: false)
        }
    }

    private func gesture(for event: InputEvent) -> ShiftGesture? {
        config.gestures.first {
            $0.hasAllowedTrigger && $0.trigger.kind == event.kind && $0.trigger.code == event.code && $0.trigger.modifiers == event.modifiers
        }
    }

    private mutating func flip(_ id: String) {
        guard config.shiftMode(id: id) != nil else { return }
        if toggled.contains(id) { toggled.remove(id) } else { toggled.insert(id) }
    }

    private static func release(_ action: RemapAction) -> RemapDecision {
        switch action {
        case .key(let code, let modifiers): .emit([.key(code: code, modifiers: modifiers, down: false)])
        case .mouseButton(let button): .emit([.mouse(button: button, down: false)])
        case .macro, .disable, .switchProfile, .nextProfile, .previousProfile, .toggleShiftMode, .system: .suppress
        }
    }

    private func shiftMode(for event: InputEvent) -> ShiftMode? {
        config.shiftModes.first {
            $0.hasAllowedTrigger && $0.trigger.kind == event.kind && $0.trigger.code == event.code && $0.trigger.modifiers == event.modifiers
        }
    }

    /// Modes that apply to an input of this kind, honoring each mode's scope.
    private func effectiveModes(for kind: InputKind) -> Set<String> {
        let ids = activeShiftModeIDs
        guard !ids.isEmpty else { return [] }
        return Set(config.shiftModes.filter { ids.contains($0.id) && ($0.affectsOtherDevices || $0.trigger.kind == kind) }.map(\.id))
    }

    /// The rule that needs the most active modes wins; at equal depth a rule for the frontmost app beats a global one.
    /// Modifiers must match exactly.
    private func matchingRule(for event: InputEvent, frontmostBundleID: String?) -> RemapRule? {
        let modes = effectiveModes(for: event.kind)
        let candidates = config.rules.filter {
            $0.enabled && $0.trigger.kind == event.kind && $0.trigger.code == event.code && $0.trigger.modifiers == event.modifiers
                && Set($0.shiftModeIDs).isSubset(of: modes)
        }
        func depth(_ rule: RemapRule) -> Int { Set(rule.shiftModeIDs).count }
        for level in Set(candidates.map(depth)).sorted(by: >) {
            let best = candidates.filter { depth($0) == level }
            if let frontmostBundleID, let scoped = best.first(where: { $0.appBundleID == frontmostBundleID }) { return scoped }
            if let global = best.first(where: { $0.appBundleID == nil }) { return global }
        }
        return nil
    }
}
