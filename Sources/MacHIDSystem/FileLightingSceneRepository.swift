import Foundation
import MacHIDDomain

/// Lighting scenes as one JSON file (`lighting-scenes.json`). Atomic writes; a missing, unreadable or newer-schema file
/// yields the shipped defaults; broken scenes inside a readable file are dropped (see `LightingSetup` decoding).
public actor FileLightingSceneRepository {
    private let url: URL

    public init(url: URL = FileLightingSceneRepository.defaultURL) { self.url = url }

    public static var defaultURL: URL { FileRemapRepository.supportDirectory.appendingPathComponent("lighting-scenes.json") }

    public func load() -> LightingSetup {
        guard let data = try? Data(contentsOf: url),
              let setup = try? JSONDecoder().decode(LightingSetup.self, from: data),
              setup.schemaVersion <= LightingSetup.currentSchemaVersion, !setup.scenes.isEmpty else { return .defaults }
        return setup
    }

    public func save(_ setup: LightingSetup) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(setup).write(to: url, options: .atomic)
    }
}
