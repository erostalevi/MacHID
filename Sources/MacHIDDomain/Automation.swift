/// "When this app is in front, use that profile on this device."
public struct AppRule: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var bundleID: String
    public var appName: String
    /// Device definition id the profile applies to (the profile must hold settings for it).
    public var deviceDefinitionID: String
    public var profileID: String

    public init(id: String, bundleID: String, appName: String, deviceDefinitionID: String, profileID: String) {
        self.id = id
        self.bundleID = bundleID
        self.appName = appName
        self.deviceDefinitionID = deviceDefinitionID
        self.profileID = profileID
    }
}

/// Everything about automatic profile switching. Persisted as one small JSON document.
public struct AutomationConfig: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int = AutomationConfig.currentSchemaVersion
    public var rules: [AppRule] = []
    /// Device definition id -> profile used when no rule matches the frontmost app.
    public var defaultProfiles: [String: String] = [:]
    /// Master switch: while true nothing is switched automatically (manual choices still work).
    public var paused = false
    /// Re-apply a device's profile when it is plugged in.
    public var applyOnConnect = true

    public init() {}

    /// Priority is explicit and has no hidden ties: a rule for the frontmost app, then the device default.
    /// There is at most one rule per app and device (see `upserting`).
    public func profileID(frontmostBundleID: String?, deviceDefinitionID: String) -> String? {
        guard !paused else { return nil }
        if let frontmostBundleID,
           let rule = rules.first(where: { $0.bundleID == frontmostBundleID && $0.deviceDefinitionID == deviceDefinitionID }) {
            return rule.profileID
        }
        return defaultProfiles[deviceDefinitionID]
    }

    /// Adds a rule, or replaces the existing rule for the same app and device.
    public func upserting(_ rule: AppRule) -> AutomationConfig {
        var copy = self
        copy.rules.removeAll { $0.id == rule.id || ($0.bundleID == rule.bundleID && $0.deviceDefinitionID == rule.deviceDefinitionID) }
        copy.rules.append(rule)
        return copy
    }

    public func removingRules(forProfile profileID: String) -> AutomationConfig {
        var copy = self
        copy.rules.removeAll { $0.profileID == profileID }
        copy.defaultProfiles = copy.defaultProfiles.filter { $0.value != profileID }
        return copy
    }
}

public protocol AutomationRepository: Sendable {
    func load() async throws -> AutomationConfig
    func save(_ config: AutomationConfig) async throws
}
