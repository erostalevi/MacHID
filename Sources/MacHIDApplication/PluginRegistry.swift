import Foundation
import MacHIDDomain

// MARK: Ports

public struct RegistrySnapshot: Equatable, Sendable {
    public var data: Data
    public var signature: Data
    public init(data: Data, signature: Data) {
        self.data = data
        self.signature = signature
    }
}

/// Where the signed registry comes from (the latest registry release of the project repository).
public protocol RegistrySource: Sendable {
    func fetchLatest() async throws -> RegistrySnapshot
}

public protocol RegistryVerifier: Sendable {
    func isValid(signature: Data, for data: Data) -> Bool
}

public protocol RegistryCache: Sendable {
    func load() async -> RegistrySnapshot?
    func save(_ snapshot: RegistrySnapshot) async throws
}

public protocol InstalledPluginStore: Sendable {
    func load() async throws -> [InstalledPlugin]
    func save(_ plugins: [InstalledPlugin]) async throws
}

public enum RegistryError: Error, Equatable, CustomStringConvertible {
    case noTrustKey
    case network(String)
    case badSignature
    case invalid([String])
    case stale(String)

    public var description: String {
        switch self {
        case .noTrustKey: "this build has no registry signing key, so plugin lists cannot be trusted"
        case .network(let why): "could not reach the plugin registry: \(why)"
        case .badSignature: "the plugin registry failed its signature check and was ignored"
        case .invalid(let issues): "the plugin registry is invalid: \(issues.joined(separator: "; "))"
        case .stale(let why): "the plugin registry is out of date and was ignored: \(why)"
        }
    }
}

// MARK: Service

/// Keeps a verified copy of the plugin registry. A list is used only after its signature checks out and every entry
/// passes the registry rules; anything else is discarded and the last good copy stays in use.
public actor RegistryService {
    private let source: any RegistrySource
    private let verifier: (any RegistryVerifier)?
    private let cache: any RegistryCache
    private let now: @Sendable () -> Date

    /// - Parameter verifier: nil when the build has no signing key; refreshing then fails instead of trusting anything.
    public init(source: any RegistrySource, verifier: (any RegistryVerifier)?, cache: any RegistryCache, now: @escaping @Sendable () -> Date = { Date() }) {
        self.source = source
        self.verifier = verifier
        self.cache = cache
        self.now = now
    }

    /// The last verified registry, re-checked against its signature.
    public func cached() async -> Registry? {
        guard let verifier, let snapshot = await cache.load() else { return nil }
        return try? Self.accept(snapshot, verifier: verifier)
    }

    @discardableResult
    public func refresh() async throws -> Registry {
        guard let verifier else { throw RegistryError.noTrustKey }
        let snapshot: RegistrySnapshot
        do { snapshot = try await source.fetchLatest() } catch { throw RegistryError.network("\(error)") }
        let registry = try Self.accept(snapshot, verifier: verifier)
        try Self.checkFreshness(registry, previous: await cached(), now: now())
        try? await cache.save(snapshot)
        return registry
    }

    /// A list must be stamped, newer than the last one accepted, and not too old.
    static func checkFreshness(_ registry: Registry, previous: Registry?, now: Date) throws {
        guard let sequence = registry.sequence, let issued = registry.issuedAt.flatMap({ ISO8601DateFormatter().date(from: $0) }) else {
            throw RegistryError.stale("it carries no sequence number or issue date")
        }
        if let known = previous?.sequence, sequence < known { throw RegistryError.stale("sequence \(sequence) is older than the \(known) already seen") }
        if now.timeIntervalSince(issued) > maxAge { throw RegistryError.stale("it was issued more than 45 days ago") }
    }

    static let maxAge: TimeInterval = 45 * 24 * 3600

    static func accept(_ snapshot: RegistrySnapshot, verifier: any RegistryVerifier) throws -> Registry {
        guard verifier.isValid(signature: snapshot.signature, for: snapshot.data) else { throw RegistryError.badSignature }
        let registry: Registry
        do { registry = try Registry.decode(snapshot.data) } catch { throw RegistryError.invalid(["not valid JSON (\(error.localizedDescription))"]) }
        let issues = RegistryValidator().validate(registry)
        guard issues.isEmpty else { throw RegistryError.invalid(issues.map(\.description)) }
        return registry
    }
}

// MARK: Planning

public struct PluginUpdate: Equatable, Sendable {
    public var installed: InstalledPlugin
    public var entry: RegistryEntry

    public init(installed: InstalledPlugin, entry: RegistryEntry) {
        self.installed = installed
        self.entry = entry
    }
}

/// Pure decisions about what to offer and what to update.
public enum PluginPlanner {
    /// Registry entries that could support an attached device that has no definition yet, best first: reviewed before
    /// community, and compatible with this MacHID.
    public static func recommendations(registry: Registry, installed: [InstalledPlugin], unsupported: [USBID],
                                       coreAPIVersion: Int = MacHIDDomain.coreAPIVersion) -> [RegistryEntry] {
        let installedIDs = Set(installed.map(\.id))
        return registry.plugins
            .filter { !installedIDs.contains($0.id) && $0.coreApi.contains(coreAPIVersion) && !Set($0.devices).isDisjoint(with: unsupported) }
            .sorted { ($0.review == .reviewed ? 0 : 1, $0.id) < ($1.review == .reviewed ? 0 : 1, $1.id) }
    }

    /// Installed plugins whose registry entry points at a different commit.
    public static func updates(registry: Registry, installed: [InstalledPlugin], coreAPIVersion: Int = MacHIDDomain.coreAPIVersion) -> [PluginUpdate] {
        installed.compactMap { plugin in
            guard let entry = registry.plugins.first(where: { $0.id == plugin.id }), entry.ref != plugin.ref,
                  entry.coreApi.contains(coreAPIVersion) else { return nil }
            return PluginUpdate(installed: plugin, entry: entry)
        }
    }

    /// A reason to refuse when the new version is older than the installed one (a downgrade is never applied).
    public static func downgradeBlocker(installed: InstalledPlugin?, newManifest: PluginManifest) -> String? {
        guard let installed, let current = SemanticVersion(installed.version), let next = SemanticVersion(newManifest.version) else { return nil }
        return next < current ? "version \(next) is older than the installed \(current)" : nil
    }

    /// Only reviewed plugins may update by themselves, and only when permissions and license did not change
    /// (checked on the manifest once it has been downloaded). Returns the reason to ask the user, or nil.
    public static func autoUpdateBlocker(for update: PluginUpdate, newManifest manifest: PluginManifest) -> String? {
        if update.entry.review != .reviewed { return "it is not a reviewed plugin" }
        if manifest.permissions != update.installed.permissions { return "its permissions changed" }
        if manifest.license != update.installed.license { return "its license changed" }
        return nil
    }

    /// Installed plugins that the registry no longer lists (kept, but flagged).
    public static func orphaned(registry: Registry, installed: [InstalledPlugin]) -> [InstalledPlugin] {
        let listed = Set(registry.plugins.map(\.id))
        return installed.filter { !listed.contains($0.id) }
    }
}
