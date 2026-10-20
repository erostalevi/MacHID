import Foundation
import MacHIDApplication
import MacHIDDomain

/// Remap rules and macros as one JSON file. Atomic writes; a file from a newer version is ignored.
public actor FileRemapRepository: RemapRepository {
    private let url: URL

    public init(url: URL = FileRemapRepository.defaultURL) { self.url = url }

    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacHID", isDirectory: true)
    }

    public static var defaultURL: URL { supportDirectory.appendingPathComponent("remap.json") }

    public func load() throws -> RemapConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return RemapConfig() }
        let config = try JSONDecoder().decode(RemapConfig.self, from: Data(contentsOf: url))
        return config.schemaVersion <= RemapConfig.currentSchemaVersion ? config : RemapConfig()
    }

    public func save(_ config: RemapConfig) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url, options: .atomic)
    }
}

/// Macro runs, one JSON object per line. It records what ran and how it ended, never typed text or commands.
public actor FileMacroLog: MacroLog {
    private let url: URL
    private let maxBytes: Int

    public init(url: URL = FileRemapRepository.supportDirectory.appendingPathComponent("macro-log.jsonl"), maxBytes: Int = 512 * 1024) {
        self.url = url
        self.maxBytes = maxBytes
    }

    public func record(_ entry: MacroLogEntry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int, size > maxBytes {
            try? FileManager.default.removeItem(at: url.appendingPathExtension("old"))
            try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("old"))
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    public func entries(limit: Int = 50) -> [MacroLogEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").suffix(limit).compactMap { try? decoder.decode(MacroLogEntry.self, from: Data($0.utf8)) }
    }
}
