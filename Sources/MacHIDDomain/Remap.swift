/// Keyboard modifier keys, as a bit set that is stable on disk.
public struct Modifiers: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = Modifiers(rawValue: 1 << 0)
    public static let control = Modifiers(rawValue: 1 << 1)
    public static let option = Modifiers(rawValue: 1 << 2)
    public static let command = Modifiers(rawValue: 1 << 3)
    public static let function = Modifiers(rawValue: 1 << 4)
}

public enum InputKind: String, Codable, Sendable { case keyboard, mouseButton }

/// What the user presses: a key (macOS virtual key code) or a mouse button, with exact modifiers.
public struct InputTrigger: Codable, Hashable, Sendable {
    public var kind: InputKind
    public var code: Int
    public var modifiers: Modifiers

    public init(kind: InputKind, code: Int, modifiers: Modifiers = []) {
        self.kind = kind
        self.code = code
        self.modifiers = modifiers
    }
}

public enum RemapAction: Codable, Equatable, Sendable {
    case key(code: Int, modifiers: Modifiers)
    case mouseButton(Int)
    case macro(String)
    case disable
    /// Switches to the profile with this id (see `RemapDecision.switchProfile`).
    case switchProfile(String)
    case nextProfile
    case previousProfile
    /// Flips a shift mode on or off, whatever its own trigger or behavior.
    case toggleShiftMode(String)
    /// A macOS navigation or system action, by `SystemActionCatalog` id (Mission Control, switch desktop, media keys...).
    case system(String)
}

public enum GestureDirection: String, Codable, Sendable, CaseIterable { case left, right, up, down }

/// Hold a key or mouse button and move the pointer: moving `threshold` pixels in a direction fires that direction's action.
/// The trigger is consumed while the gesture exists, like a shift mode's trigger.
public struct ShiftGesture: Codable, Equatable, Sendable, Identifiable {
    public static let defaultThreshold = 80
    public static let thresholdRange = 10...1000

    public let id: String
    public var name: String
    public var trigger: InputTrigger
    /// Pixels of pointer travel (on the dominant axis) needed to fire.
    public var threshold: Int
    /// Direction -> action. Directions without an action do nothing.
    public var actions: [GestureDirection: RemapAction]
    /// Freeze the pointer while the trigger is held. Off by default: the pointer keeps moving so the user sees what they do.
    public var freezePointer: Bool

    public init(id: String, name: String, trigger: InputTrigger, threshold: Int = ShiftGesture.defaultThreshold,
                actions: [GestureDirection: RemapAction] = [:], freezePointer: Bool = false) {
        self.id = id
        self.name = name
        self.trigger = trigger
        self.threshold = min(max(threshold, Self.thresholdRange.lowerBound), Self.thresholdRange.upperBound)
        self.actions = actions
        self.freezePointer = freezePointer
    }

    /// Same forbidden triggers as shift modes (left/right click, Escape).
    public var hasAllowedTrigger: Bool { ShiftMode.isAllowedTrigger(trigger) }

    private enum CodingKeys: String, CodingKey { case id, name, trigger, threshold, actions, freezePointer }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent([String: RemapAction].self, forKey: .actions) ?? [:]
        var actions: [GestureDirection: RemapAction] = [:]
        for (key, value) in raw { if let direction = GestureDirection(rawValue: key) { actions[direction] = value } }
        self.init(id: try c.decode(String.self, forKey: .id), name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
                  trigger: try c.decode(InputTrigger.self, forKey: .trigger),
                  threshold: try c.decodeIfPresent(Int.self, forKey: .threshold) ?? Self.defaultThreshold,
                  actions: actions, freezePointer: try c.decodeIfPresent(Bool.self, forKey: .freezePointer) ?? false)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(trigger, forKey: .trigger)
        try c.encode(threshold, forKey: .threshold); try c.encode(freezePointer, forKey: .freezePointer)
        try c.encode(Dictionary(uniqueKeysWithValues: actions.map { ($0.key.rawValue, $0.value) }), forKey: .actions)
    }
}

public enum ShiftBehavior: String, Codable, Sendable, CaseIterable { case hold, toggle }

/// A layer: while it is active, rules that list its id apply. Several modes can be active at once.
public struct ShiftMode: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var name: String
    /// The key or button that drives the mode. It is consumed (never reaches apps) while the mode exists.
    public var trigger: InputTrigger
    public var behavior: ShiftBehavior
    /// False: the mode only affects inputs of the same `InputKind` as its trigger (keyboard vs mouse is the closest scope
    /// the event tap can offer, it cannot tell two keyboards apart). True: it affects every input.
    public var affectsOtherDevices: Bool

    public init(id: String, name: String, trigger: InputTrigger, behavior: ShiftBehavior = .hold, affectsOtherDevices: Bool = true) {
        self.id = id
        self.name = name
        self.trigger = trigger
        self.behavior = behavior
        self.affectsOtherDevices = affectsOtherDevices
    }

    /// Triggers that can never drive a mode: left/right clicks (the tap does not see them, and consuming them could lock
    /// the user out) and Escape (kept free for the Force Quit shortcut).
    public static func isAllowedTrigger(_ trigger: InputTrigger) -> Bool {
        switch trigger.kind {
        case .mouseButton: trigger.code >= 2
        case .keyboard: trigger.code != 53 && trigger.code >= 0
        }
    }

    public var hasAllowedTrigger: Bool { Self.isAllowedTrigger(trigger) }
}

public struct RemapRule: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var trigger: InputTrigger
    public var action: RemapAction
    public var enabled: Bool
    /// When set, the rule only applies while this app is in front, and wins over a global rule.
    public var appBundleID: String?
    /// The rule applies only while ALL of these shift modes are active. Empty is the base layer.
    public var shiftModeIDs: [String]

    public init(id: String, trigger: InputTrigger, action: RemapAction, enabled: Bool = true, appBundleID: String? = nil,
                shiftModeIDs: [String] = []) {
        self.shiftModeIDs = shiftModeIDs
        self.id = id
        self.trigger = trigger
        self.action = action
        self.enabled = enabled
        self.appBundleID = appBundleID
    }
}

extension RemapRule {
    /// Files written before shift modes have no `shiftModeIDs`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), trigger: try c.decode(InputTrigger.self, forKey: .trigger),
                  action: try c.decode(RemapAction.self, forKey: .action), enabled: try c.decode(Bool.self, forKey: .enabled),
                  appBundleID: try c.decodeIfPresent(String.self, forKey: .appBundleID),
                  shiftModeIDs: try c.decodeIfPresent([String].self, forKey: .shiftModeIDs) ?? [])
    }
}

public enum MacroStep: Codable, Equatable, Sendable {
    case key(code: Int, modifiers: Modifiers)
    case text(String)
    case mouseClick(button: Int)
    case wait(milliseconds: Int)
    /// An app (bundle id), a URL or a file path.
    case open(String)
    /// A macOS Shortcuts shortcut, by name.
    case shortcut(String)
    case shell(String)

    /// Steps that reach beyond typing and clicking. A macro containing one must be approved by the user.
    public var isPowerful: Bool {
        switch self {
        case .open, .shortcut, .shell: true
        default: false
        }
    }

    public var isShell: Bool { if case .shell = self { true } else { false } }

    /// A label that is safe to log: the kind of step, never its content.
    public var kindName: String {
        switch self {
        case .key: "key"
        case .text: "text"
        case .mouseClick: "mouse"
        case .wait: "wait"
        case .open: "open"
        case .shortcut: "shortcut"
        case .shell: "shell"
        }
    }
}

public struct Macro: Codable, Equatable, Sendable, Identifiable {
    public static let maxSteps = 200
    public static let maxRepeat = 100
    public static let maxTextLength = 2000
    public static let maxCommandLength = 4000

    /// The macro with every step clamped to a sane size (used for anything that comes from outside).
    public func clamped() -> Macro {
        var copy = self
        copy.steps = Array(steps.prefix(Self.maxSteps)).map { step in
            switch step {
            case .text(let text): .text(String(text.prefix(Self.maxTextLength)))
            case .shell(let command): .shell(String(command.prefix(Self.maxCommandLength)))
            case .open(let target): .open(String(target.prefix(1000)))
            case .shortcut(let name): .shortcut(String(name.prefix(200)))
            case .wait(let milliseconds): .wait(milliseconds: min(max(milliseconds, 0), 3_600_000))
            default: step
            }
        }
        copy.repeatCount = min(max(repeatCount, 1), Self.maxRepeat)
        return copy
    }

    public let id: String
    public var name: String
    public var steps: [MacroStep]
    public var repeatCount: Int
    /// Fingerprint of the steps the user last approved. Any edit changes the fingerprint and revokes approval.
    public var approvedFingerprint: String?
    public var imported: Bool

    public init(id: String, name: String, steps: [MacroStep], repeatCount: Int = 1,
                approvedFingerprint: String? = nil, imported: Bool = false) {
        self.id = id
        self.name = name
        self.steps = steps
        self.repeatCount = repeatCount
        self.approvedFingerprint = approvedFingerprint
        self.imported = imported
    }

    /// Imported macros always need approval, even when they only press keys: a key sequence can open a launcher and type a
    /// command, which would sidestep every check on shell and app steps.
    public var needsApproval: Bool { imported || steps.contains { $0.isPowerful } }
    public var usesShell: Bool { steps.contains { $0.isShell } }
}

/// Everything about remapping and macros, saved as one JSON document.
public struct RemapConfig: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int = RemapConfig.currentSchemaVersion
    /// Master switch. Off by default: remapping watches the keyboard, so the user turns it on knowingly.
    public var enabled = false
    /// Second switch for macros that run shell commands.
    public var shellMacrosEnabled = true
    public var rules: [RemapRule] = []
    public var macros: [Macro] = []
    public var shiftModes: [ShiftMode] = []
    public var gestures: [ShiftGesture] = []

    public init() {}

    /// Additive format: every key added after schema 1 is optional, so older files decode unchanged (no version bump).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        shellMacrosEnabled = try c.decodeIfPresent(Bool.self, forKey: .shellMacrosEnabled) ?? true
        rules = try c.decodeIfPresent([RemapRule].self, forKey: .rules) ?? []
        macros = try c.decodeIfPresent([Macro].self, forKey: .macros) ?? []
        shiftModes = try c.decodeIfPresent([ShiftMode].self, forKey: .shiftModes) ?? []
        gestures = try c.decodeIfPresent([ShiftGesture].self, forKey: .gestures) ?? []
    }

    public func upsertingGesture(_ gesture: ShiftGesture) -> RemapConfig {
        var copy = self
        if let index = copy.gestures.firstIndex(where: { $0.id == gesture.id }) { copy.gestures[index] = gesture } else { copy.gestures.append(gesture) }
        return copy
    }

    public func removingGesture(id: String) -> RemapConfig {
        var copy = self
        copy.gestures.removeAll { $0.id == id }
        return copy
    }

    public func shiftMode(id: String) -> ShiftMode? { shiftModes.first { $0.id == id } }

    public func upsertingShiftMode(_ mode: ShiftMode) -> RemapConfig {
        var copy = self
        if let index = copy.shiftModes.firstIndex(where: { $0.id == mode.id }) { copy.shiftModes[index] = mode } else { copy.shiftModes.append(mode) }
        return copy
    }

    /// Removing a mode also removes the rules that need it or would toggle it.
    public func removingShiftMode(id: String) -> RemapConfig {
        var copy = self
        copy.shiftModes.removeAll { $0.id == id }
        copy.rules.removeAll { $0.shiftModeIDs.contains(id) || $0.action == .toggleShiftMode(id) }
        return copy
    }

    public func macro(id: String) -> Macro? { macros.first { $0.id == id } }

    /// At most one rule per trigger, app scope and set of shift modes.
    public func upserting(_ rule: RemapRule) -> RemapConfig {
        var copy = self
        copy.rules.removeAll { $0.id == rule.id || ($0.trigger == rule.trigger && $0.appBundleID == rule.appBundleID && Set($0.shiftModeIDs) == Set(rule.shiftModeIDs)) }
        copy.rules.append(rule)
        return copy
    }

    /// Removing a macro also removes the rules that would run it.
    public func removingMacro(id: String) -> RemapConfig {
        var copy = self
        copy.macros.removeAll { $0.id == id }
        copy.rules.removeAll { $0.action == .macro(id) }
        return copy
    }
}

public protocol RemapRepository: Sendable {
    func load() async throws -> RemapConfig
    func save(_ config: RemapConfig) async throws
}
