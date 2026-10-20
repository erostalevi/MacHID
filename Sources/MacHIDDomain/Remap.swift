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
}

public struct RemapRule: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var trigger: InputTrigger
    public var action: RemapAction
    public var enabled: Bool
    /// When set, the rule only applies while this app is in front, and wins over a global rule.
    public var appBundleID: String?

    public init(id: String, trigger: InputTrigger, action: RemapAction, enabled: Bool = true, appBundleID: String? = nil) {
        self.id = id
        self.trigger = trigger
        self.action = action
        self.enabled = enabled
        self.appBundleID = appBundleID
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

    public var needsApproval: Bool { steps.contains { $0.isPowerful } }
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

    public init() {}

    public func macro(id: String) -> Macro? { macros.first { $0.id == id } }

    /// At most one rule per trigger and app scope.
    public func upserting(_ rule: RemapRule) -> RemapConfig {
        var copy = self
        copy.rules.removeAll { $0.id == rule.id || ($0.trigger == rule.trigger && $0.appBundleID == rule.appBundleID) }
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
