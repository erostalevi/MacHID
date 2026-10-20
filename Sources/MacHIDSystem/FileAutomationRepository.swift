import Foundation
import MacHIDDomain

/// Automation settings as one JSON file next to the profiles. Atomic writes; a file from a newer version is ignored.
public actor FileAutomationRepository: AutomationRepository {
    private let url: URL

    public init(url: URL = FileAutomationRepository.defaultURL) { self.url = url }

    public static var defaultURL: URL {
        FileRemapRepository.supportDirectory.appendingPathComponent("automation.json")
    }

    public func load() throws -> AutomationConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return AutomationConfig() }
        let config = try JSONDecoder().decode(AutomationConfig.self, from: Data(contentsOf: url))
        return config.schemaVersion <= AutomationConfig.currentSchemaVersion ? config : AutomationConfig()
    }

    public func save(_ config: AutomationConfig) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url, options: .atomic)
    }
}
