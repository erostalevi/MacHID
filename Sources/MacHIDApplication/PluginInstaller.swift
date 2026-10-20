import Foundation
import MacHIDDomain

// MARK: Ports

/// Downloads the source of a plugin at an exact commit and returns the local archive.
public protocol PluginFetcher: Sendable {
    func fetchArchive(repo: String, ref: String) async throws -> URL
}

/// Unpacks an archive into a directory, refusing anything that could escape it.
public protocol ArchiveExtractor: Sendable {
    func extract(_ archive: URL, into directory: URL) throws
}

/// A plugin that is installed on this Mac.
public struct InstalledPlugin: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var version: String
    public var ref: String
    public var review: ReviewLevel
    public var license: String
    public var devices: [USBID]
    public var permissions: PluginPermissions
    /// Definition files inside the plugin folder, relative to it.
    public var definitionFiles: [String]
    public var installedAt: Date

    public init(id: String, name: String, version: String, ref: String, review: ReviewLevel, license: String,
                devices: [USBID], permissions: PluginPermissions, definitionFiles: [String], installedAt: Date) {
        self.id = id
        self.name = name
        self.version = version
        self.ref = ref
        self.review = review
        self.license = license
        self.devices = devices
        self.permissions = permissions
        self.definitionFiles = definitionFiles
        self.installedAt = installedAt
    }
}

public enum PluginError: Error, Equatable, CustomStringConvertible {
    case download(String)
    case unsafeArchive(String)
    case manifestMissing
    case manifestHashMismatch
    case invalidManifest([String])
    case registryMismatch(String)
    case codePluginsNotSupported
    case invalidDefinition(file: String, reason: String)
    case unknownDriver(String)
    case tooLarge(String)
    case storage(String)

    public var description: String {
        switch self {
        case .download(let why): "could not download the plugin: \(why)"
        case .unsafeArchive(let why): "the plugin archive is not safe: \(why)"
        case .manifestMissing: "the plugin has no manifest.json"
        case .manifestHashMismatch: "the manifest does not match the registry entry (it was changed after review)"
        case .invalidManifest(let issues): "invalid manifest: \(issues.joined(separator: "; "))"
        case .registryMismatch(let what): "the plugin disagrees with its registry entry: \(what)"
        case .codePluginsNotSupported: "plugins with code drivers need a newer MacHID"
        case .invalidDefinition(let file, let reason): "invalid definition \(file): \(reason)"
        case .unknownDriver(let name): "unknown driver family '\(name)'"
        case .tooLarge(let what): "\(what) is too large"
        case .storage(let why): "could not store the plugin: \(why)"
        }
    }
}

/// Installs data-only plugins: new device definitions for the driver families MacHID already has.
///
/// Nothing from a plugin is executed. The installer checks the plugin against its registry entry (pinned commit,
/// manifest hash, license, devices), validates every definition, and keeps only the manifest and the definitions.
public actor PluginInstaller {
    public static let maxManifestBytes = 64 * 1024
    public static let maxDefinitionBytes = 256 * 1024

    private let fetcher: any PluginFetcher
    private let extractor: any ArchiveExtractor
    private let directory: URL
    private let allowedDrivers: Set<String>
    private let sha256: @Sendable (Data) -> String
    private let now: @Sendable () -> Date
    private let fileManager = FileManager.default

    public init(directory: URL, fetcher: any PluginFetcher, extractor: any ArchiveExtractor,
                allowedDrivers: Set<String> = ["razer", "logitech-gseries", "uvc"],
                sha256: @escaping @Sendable (Data) -> String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.fetcher = fetcher
        self.extractor = extractor
        self.allowedDrivers = allowedDrivers
        self.sha256 = sha256
        self.now = now
    }

    public func install(_ entry: RegistryEntry) async throws -> InstalledPlugin {
        let archive: URL
        do { archive = try await fetcher.fetchArchive(repo: entry.repo, ref: entry.ref) }
        catch { throw PluginError.download("\(error)") }

        let staging = fileManager.temporaryDirectory.appendingPathComponent("machid-plugin-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging); try? fileManager.removeItem(at: archive) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do { try extractor.extract(archive, into: staging) } catch { throw PluginError.unsafeArchive("\(error)") }

        let root = try pluginRoot(in: staging)
        let manifest = try loadManifest(in: root, entry: entry)
        let definitions = try loadDefinitions(in: root, manifest: manifest)

        let destination = directory.appendingPathComponent(entry.id, isDirectory: true).appendingPathComponent(entry.ref, isDirectory: true)
        do {
            try store(manifestIn: root, definitions: definitions.map(\.path), into: destination)
        } catch {
            throw PluginError.storage("\(error)")
        }
        // Older versions of the same plugin are removed only after the new one is in place.
        removeOtherVersions(of: entry.id, keeping: entry.ref)
        return InstalledPlugin(id: entry.id, name: manifest.name, version: manifest.version, ref: entry.ref, review: entry.review,
                               license: manifest.license, devices: manifest.devices, permissions: manifest.permissions,
                               definitionFiles: definitions.map(\.path), installedAt: now())
    }

    /// Where an installed plugin's files live.
    public nonisolated func location(of plugin: InstalledPlugin) -> URL {
        directory.appendingPathComponent(plugin.id, isDirectory: true).appendingPathComponent(plugin.ref, isDirectory: true)
    }

    public func remove(id: String) {
        try? fileManager.removeItem(at: directory.appendingPathComponent(id, isDirectory: true))
    }

    // MARK: Steps

    /// GitHub archives hold one top-level folder named after the repository and commit.
    private func pluginRoot(in staging: URL) throws -> URL {
        let items = (try? fileManager.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        if items.count == 1, (try? items[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return items[0] }
        return staging
    }

    private func loadManifest(in root: URL, entry: RegistryEntry) throws -> PluginManifest {
        let url = root.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else { throw PluginError.manifestMissing }
        guard data.count <= Self.maxManifestBytes else { throw PluginError.tooLarge("manifest.json") }
        guard sha256(data) == entry.manifestSha256 else { throw PluginError.manifestHashMismatch }
        let manifest: PluginManifest
        do { manifest = try JSONDecoder().decode(PluginManifest.self, from: data) }
        catch { throw PluginError.invalidManifest(["not valid JSON for a manifest (\(error.localizedDescription))"]) }

        let issues = manifest.validate()
        guard issues.isEmpty else { throw PluginError.invalidManifest(issues.map(\.message)) }
        guard manifest.id == entry.id else { throw PluginError.registryMismatch("id") }
        guard manifest.license == entry.license else { throw PluginError.registryMismatch("license") }
        guard Set(manifest.devices) == Set(entry.devices) else { throw PluginError.registryMismatch("devices") }
        guard manifest.coreAPI == entry.coreApi else { throw PluginError.registryMismatch("core_api") }
        guard manifest.isDataOnly else { throw PluginError.codePluginsNotSupported }
        return manifest
    }

    private func loadDefinitions(in root: URL, manifest: PluginManifest) throws -> [(path: String, definition: DeviceDefinition)] {
        var paths = manifest.definitions ?? []
        if manifest.definitions == nil {
            let folder = root.appendingPathComponent("devices", isDirectory: true)
            let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
            paths = names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted().map { "devices/\($0)" }
        }
        guard !paths.isEmpty else { throw PluginError.invalidDefinition(file: "devices/", reason: "the plugin has no device definitions") }
        guard paths.count <= PluginManifest.maxDefinitionFiles else { throw PluginError.tooLarge("the list of definitions") }

        var seenIDs = Set<String>()
        var result: [(String, DeviceDefinition)] = []
        for path in paths {
            let url = root.appendingPathComponent(path)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
                throw PluginError.invalidDefinition(file: path, reason: "not a regular file")
            }
            guard (values?.fileSize ?? 0) <= Self.maxDefinitionBytes else { throw PluginError.tooLarge(path) }
            do {
                let definition = try JSONDecoder().decode(DeviceDefinition.self, from: Data(contentsOf: url))
                try definition.validate()
                guard allowedDrivers.contains(definition.driver) else { throw PluginError.unknownDriver(definition.driver) }
                guard seenIDs.insert(definition.id).inserted else { throw PluginError.invalidDefinition(file: path, reason: "duplicate definition id") }
                if let stray = definition.usbIds.first(where: { !manifest.devices.contains($0) }) {
                    throw PluginError.invalidDefinition(file: path, reason: "uses \(stray), which the manifest does not declare")
                }
                result.append((path, definition))
            } catch let error as PluginError {
                throw error
            } catch {
                throw PluginError.invalidDefinition(file: path, reason: "\(error)")
            }
        }
        return result
    }

    private func store(manifestIn root: URL, definitions: [String], into destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporary = parent.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
        do {
            try fileManager.copyItem(at: root.appendingPathComponent("manifest.json"), to: temporary.appendingPathComponent("manifest.json"))
            for path in definitions {
                let target = temporary.appendingPathComponent(path)
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: root.appendingPathComponent(path), to: target)
            }
            if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func removeOtherVersions(of id: String, keeping ref: String) {
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] where name != ref {
            try? fileManager.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
