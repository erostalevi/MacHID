import Foundation
import MacHIDDomain

/// Profiles stored as one JSON file (default: `~/Library/Application Support/MacHID/profiles.json`).
/// Writes are atomic so a crash cannot leave a half-written file.
public actor FileProfileRepository: ProfileRepository {
    private let url: URL

    public init(url: URL = FileProfileRepository.defaultURL) { self.url = url }

    public static var defaultURL: URL {
        FileRemapRepository.supportDirectory.appendingPathComponent("profiles.json")
    }

    public func load() throws -> [Profile] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let profiles = try JSONDecoder().decode([Profile].self, from: Data(contentsOf: url))
        // Files from a newer version are ignored rather than half-understood.
        return profiles.filter { $0.schemaVersion <= Profile.currentSchemaVersion }
    }

    public func save(_ profile: Profile) throws {
        var profiles = try load()
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile } else { profiles.append(profile) }
        try write(profiles)
    }

    public func delete(id: String) throws {
        try write(try load().filter { $0.id != id })
    }

    private func write(_ profiles: [Profile]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: url, options: .atomic)
    }
}
