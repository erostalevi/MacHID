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
}

/// Decides what to do with each key or button event. Pure logic: no event taps, no permissions, no timing, so every
/// rule can be tested. It remembers which presses it remapped so the matching release is remapped the same way,
/// even when a modifier was let go first.
public struct RemapEngine: Sendable {
    private struct Pressed: Hashable { var kind: InputKind; var code: Int }

    public private(set) var config: RemapConfig
    private var active: [Pressed: RemapAction] = [:]

    public init(config: RemapConfig = RemapConfig()) { self.config = config }

    /// Replaces the rules. Presses that were remapped and are still held get their release sent now, because the
    /// physical release will no longer be recognized (otherwise a remapped modifier could stay down).
    @discardableResult
    public mutating func update(config: RemapConfig) -> [OutputEvent] {
        self.config = config
        var releases: [OutputEvent] = []
        for action in active.values {
            if case .emit(let events) = Self.release(action) { releases += events }
        }
        active.removeAll()
        return releases
    }

    public mutating func decide(_ event: InputEvent, frontmostBundleID: String?) -> RemapDecision {
        let pressed = Pressed(kind: event.kind, code: event.code)
        if !event.isDown {
            guard let action = active.removeValue(forKey: pressed) else { return .passthrough }
            return Self.release(action)
        }
        guard config.enabled, let rule = matchingRule(for: event, frontmostBundleID: frontmostBundleID) else {
            return .passthrough
        }
        active[pressed] = rule.action
        switch rule.action {
        case .key(let code, let modifiers): return .emit([.key(code: code, modifiers: modifiers, down: true)])
        case .mouseButton(let button): return .emit([.mouse(button: button, down: true)])
        case .macro(let id): return event.isRepeat ? .suppress : .runMacro(id)   // holding a key must not restart the macro
        case .disable: return .suppress
        }
    }

    private static func release(_ action: RemapAction) -> RemapDecision {
        switch action {
        case .key(let code, let modifiers): .emit([.key(code: code, modifiers: modifiers, down: false)])
        case .mouseButton(let button): .emit([.mouse(button: button, down: false)])
        case .macro, .disable: .suppress
        }
    }

    /// A rule for the frontmost app wins over a global one. Modifiers must match exactly.
    private func matchingRule(for event: InputEvent, frontmostBundleID: String?) -> RemapRule? {
        let candidates = config.rules.filter {
            $0.enabled && $0.trigger.kind == event.kind && $0.trigger.code == event.code && $0.trigger.modifiers == event.modifiers
        }
        if let frontmostBundleID, let scoped = candidates.first(where: { $0.appBundleID == frontmostBundleID }) { return scoped }
        return candidates.first { $0.appBundleID == nil }
    }
}
