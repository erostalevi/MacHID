import CryptoKit
import Foundation
import MacHIDApplication
import MacHIDDomain

/// Ed25519 check of `plugins.json` against `plugins.json.sig` (a raw 64-byte signature), with the project's public key.
public struct Ed25519RegistryVerifier: RegistryVerifier {
    private let key: Curve25519.Signing.PublicKey

    public init?(publicKeyBase64: String) {
        guard let data = Data(base64Encoded: publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: data) else { return nil }
        self.key = key
    }

    public func isValid(signature: Data, for data: Data) -> Bool { key.isValidSignature(signature, for: data) }
}

/// Reads the latest `registry-*` release of the project repository from GitHub.
public struct GitHubRegistrySource: RegistrySource {
    public static let maxBytes = 2 * 1024 * 1024
    private let owner: String
    private let repo: String
    private let session: URLSession

    public init(owner: String = "erostalevi", repo: String = "MacHID", session: URLSession = .shared) {
        self.owner = owner
        self.repo = repo
        self.session = session
    }

    private struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let published_at: String?
        let assets: [Asset]
    }

    public func fetchLatest() async throws -> RegistrySnapshot {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=30")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("releases request failed") }
        let releases = try JSONDecoder().decode([Release].self, from: data)
        // Several kinds of release share the repository; registry releases are told apart by their tag.
        guard let release = releases.filter({ $0.tag_name.hasPrefix("registry-") && !$0.draft && !$0.prerelease })
                .max(by: { ($0.published_at ?? "") < ($1.published_at ?? "") }),
              let index = release.assets.first(where: { $0.name == "plugins.json" }),
              let signature = release.assets.first(where: { $0.name == "plugins.json.sig" }) else { throw Failure("no registry release found") }
        return RegistrySnapshot(data: try await download(index.browser_download_url), signature: try await download(signature.browser_download_url))
    }

    private func download(_ urlString: String) async throws -> Data {
        // Assets must come from GitHub over HTTPS.
        guard let url = URL(string: urlString), url.scheme == "https",
              let host = url.host, host == "github.com" || host.hasSuffix(".githubusercontent.com") else { throw Failure("unexpected download location") }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= Self.maxBytes else { throw Failure("download failed or too large") }
        return data
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

/// The last verified registry on disk.
public actor FileRegistryCache: RegistryCache {
    private let folder: URL

    public init(folder: URL = FileRemapRepository.supportDirectory.appendingPathComponent("registry", isDirectory: true)) { self.folder = folder }

    public func load() -> RegistrySnapshot? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("plugins.json")),
              let signature = try? Data(contentsOf: folder.appendingPathComponent("plugins.json.sig")) else { return nil }
        return RegistrySnapshot(data: data, signature: signature)
    }

    public func save(_ snapshot: RegistrySnapshot) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try snapshot.data.write(to: folder.appendingPathComponent("plugins.json"), options: .atomic)
        try snapshot.signature.write(to: folder.appendingPathComponent("plugins.json.sig"), options: .atomic)
    }
}

/// `installed.json` in the plugins folder.
public actor FileInstalledPluginStore: InstalledPluginStore {
    private let url: URL

    public static var pluginsDirectory: URL { FileRemapRepository.supportDirectory.appendingPathComponent("plugins", isDirectory: true) }

    public init(url: URL = FileInstalledPluginStore.pluginsDirectory.appendingPathComponent("installed.json")) { self.url = url }

    public func load() throws -> [InstalledPlugin] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([InstalledPlugin].self, from: Data(contentsOf: url))
    }

    public func save(_ plugins: [InstalledPlugin]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(plugins).write(to: url, options: .atomic)
    }
}

/// Definitions shipped by installed plugins. Each file is checked again when it is loaded: the folder is user data and
/// could have been edited since installation.
public enum PluginDefinitions {
    public static func load(_ plugins: [InstalledPlugin], root: URL) -> (definitions: [DeviceDefinition], artworkRoots: [String: URL], problems: [String]) {
        var definitions: [DeviceDefinition] = []
        var artworkRoots: [String: URL] = [:]
        var problems: [String] = []
        for plugin in plugins {
            // installed.json is user data: do not follow a path that was edited to point elsewhere.
            guard PluginManifest.isSafeRelativePath(plugin.id), plugin.ref.count == 40, plugin.ref.allSatisfy(\.isHexDigit),
                  plugin.definitionFiles.allSatisfy(PluginManifest.isSafeRelativePath) else {
                problems.append("\(plugin.id): unsafe entry in the installed list")
                continue
            }
            let folder = root.appendingPathComponent(plugin.id, isDirectory: true).appendingPathComponent(plugin.ref, isDirectory: true)
            for path in plugin.definitionFiles {
                do {
                    let definition = try JSONDecoder().decode(DeviceDefinition.self, from: Data(contentsOf: folder.appendingPathComponent(path)))
                    try definition.validate()
                    guard definition.usbIds.allSatisfy({ plugin.devices.contains($0) }) else { throw DefinitionError.noUSBIDs }
                    definitions.append(definition)
                    artworkRoots[definition.id] = folder
                } catch {
                    problems.append("\(plugin.id)/\(path): \(error)")
                }
            }
        }
        return (definitions, artworkRoots, problems)
    }
}
