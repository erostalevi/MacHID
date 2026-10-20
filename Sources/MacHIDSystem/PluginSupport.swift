import CryptoKit
import Foundation
import MacHIDApplication
import MacHIDDomain

public enum SHA256Hex {
    public static func of(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// Unpacks a .tar.gz with the system `tar`, after listing it: absolute paths, parent references and oversized or
/// very large archives are refused, and links or special files found after unpacking make the whole archive fail.
public struct TarExtractor: ArchiveExtractor {
    public static let maxEntries = 2000
    public static let maxTotalBytes = 50 * 1024 * 1024

    public init() {}

    public func extract(_ archive: URL, into directory: URL) throws {
        let listing = try run(["-tzf", archive.path])
        let entries = listing.split(separator: "\n").map(String.init)
        guard entries.count <= Self.maxEntries else { throw Failure("too many files") }
        for entry in entries {
            let parts = entry.split(separator: "/", omittingEmptySubsequences: true)
            if entry.hasPrefix("/") || parts.contains("..") || entry.contains("\0") { throw Failure("unsafe path '\(entry)'") }
        }
        _ = try run(["-xzf", archive.path, "-C", directory.path, "--no-same-owner"])

        var total = 0
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true { throw Failure("contains a link: \(url.lastPathComponent)") }
            guard values.isDirectory == true || values.isRegularFile == true else { throw Failure("contains a special file: \(url.lastPathComponent)") }
            total += values.fileSize ?? 0
            if total > Self.maxTotalBytes { throw Failure("unpacks to too much data") }
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        _ = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure("tar failed (status \(process.terminationStatus))") }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Downloads `https://codeload.github.com/<owner>/<repo>/tar.gz/<commit>`. Only GitHub repositories that pass the
/// registry rules, and only a full commit SHA, are accepted.
public struct GitHubArchiveFetcher: PluginFetcher {
    public static let maxBytes = 20 * 1024 * 1024
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func fetchArchive(repo: String, ref: String) async throws -> URL {
        guard RegistryValidator.isAllowedRepo(repo), let url = URL(string: repo) else { throw Failure("repository not allowed") }
        guard ref.count == 40, ref.allSatisfy({ $0.isHexDigit }) else { throw Failure("not a commit SHA") }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let archiveURL = URL(string: "https://codeload.github.com/\(parts[0])/\(parts[1])/tar.gz/\(ref)") else { throw Failure("bad URL") }
        var request = URLRequest(url: archiveURL)
        request.timeoutInterval = 60
        let (file, response) = try await session.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("server answered \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        guard size <= Self.maxBytes else { try? FileManager.default.removeItem(at: file); throw Failure("archive is larger than 20 MB") }
        return file
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
