import Foundation
import Observation
import MacHIDApplication
import MacHIDDomain
import MacHIDSystem

/// State behind the plugins page: what is installed, what the registry offers, and updates.
@MainActor
@Observable
public final class PluginsModel {
    public enum Status: Equatable { case idle, refreshing, failed(String) }

    public private(set) var installed: [InstalledPlugin] = []
    public private(set) var registry: Registry?
    public private(set) var recommendations: [RegistryEntry] = []
    public private(set) var updates: [PluginUpdate] = []
    public private(set) var orphaned: [InstalledPlugin] = []
    public private(set) var status: Status = .idle
    public private(set) var lastChecked: Date?
    public private(set) var busy: Set<String> = []
    /// Code plugins waiting for the user's explicit confirmation: plugin id to (script bytes, SHA-256).
    public private(set) var pendingCode: [String: (bytes: Int, sha256: String)] = [:]
    /// False when this build has no registry signing key: discovery is then off rather than untrusted.
    public let discoveryAvailable: Bool
    public var banner: String?
    public var autoUpdate: Bool {
        didSet { defaults.set(autoUpdate, forKey: Self.autoUpdateKey) }
    }

    @ObservationIgnored private let registryService: RegistryService
    @ObservationIgnored private let installer: PluginInstaller
    @ObservationIgnored private let store: any InstalledPluginStore
    @ObservationIgnored private let pluginsRoot: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let catalogChanged: @MainActor ([DeviceDefinition], [String: URL]) async -> Void
    @ObservationIgnored private let unsupportedDevices: @MainActor () async -> [USBID]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    private static let autoUpdateKey = "pluginsAutoUpdate"

    public init(registryService: RegistryService, installer: PluginInstaller, store: any InstalledPluginStore, pluginsRoot: URL,
                discoveryAvailable: Bool, defaults: UserDefaults = .standard,
                catalogChanged: @escaping @MainActor ([DeviceDefinition], [String: URL]) async -> Void,
                unsupportedDevices: @escaping @MainActor () async -> [USBID]) {
        self.registryService = registryService
        self.installer = installer
        self.store = store
        self.pluginsRoot = pluginsRoot
        self.discoveryAvailable = discoveryAvailable
        self.defaults = defaults
        self.catalogChanged = catalogChanged
        self.unsupportedDevices = unsupportedDevices
        self.autoUpdate = defaults.object(forKey: Self.autoUpdateKey) as? Bool ?? true
    }

    // MARK: Loading

    /// Design review only: shows sample entries without reaching the network.
    func setPreview(registry: Registry, recommendations: [RegistryEntry], installed: [InstalledPlugin]) {
        self.registry = registry
        self.recommendations = recommendations
        self.installed = installed
        self.lastChecked = Date().addingTimeInterval(-120)
    }

    /// Reads what is installed and the cached registry, and gives the app the plugin definitions.
    public func load() async {
        installed = (try? await store.load()) ?? []
        registry = await registryService.cached()
        await publishDefinitions()
        await recompute()
    }

    /// Checks the registry (at most every few minutes unless forced), then applies safe updates.
    public func refresh(force: Bool = false) async {
        guard discoveryAvailable else { return }
        if !force, let lastChecked, Date().timeIntervalSince(lastChecked) < 300 { return }
        status = .refreshing
        do {
            registry = try await registryService.refresh()
            lastChecked = Date()
            status = .idle
        } catch {
            status = .failed("\(error)")
        }
        await recompute()
        if autoUpdate { await applyAutomaticUpdates() }
    }

    /// Re-reads the lists that depend on the attached devices (after a plug or unplug).
    public func devicesChanged() async { await recompute() }

    private func recompute() async {
        guard let registry else { recommendations = []; updates = []; orphaned = []; return }
        recommendations = PluginPlanner.recommendations(registry: registry, installed: installed, unsupported: await unsupportedDevices())
        updates = PluginPlanner.updates(registry: registry, installed: installed)
        orphaned = PluginPlanner.orphaned(registry: registry, installed: installed)
    }

    private func publishDefinitions() async {
        let result = PluginDefinitions.load(installed, root: pluginsRoot)
        if !result.problems.isEmpty { banner = "Some plugin definitions were ignored: \(result.problems.first ?? "")" }
        await catalogChanged(result.definitions, result.artworkRoots)
    }

    // MARK: Changing

    public func cancelCode(_ id: String) { pendingCode[id] = nil }

    public func install(_ entry: RegistryEntry, allowCode: Bool = false) async {
        guard !busy.contains(entry.id) else { return }
        busy.insert(entry.id)
        defer { busy.remove(entry.id) }
        do {
            let plugin = try await installer.install(entry, allowCode: allowCode)
            pendingCode[entry.id] = nil
            installed.removeAll { $0.id == plugin.id }
            installed.append(plugin)
            try await store.save(installed)
            await publishDefinitions()
            await recompute()
        } catch PluginError.codeNeedsConfirmation(let bytes, let sha256) {
            pendingCode[entry.id] = (bytes, sha256)
        } catch {
            banner = "Could not install \(entry.id): \(error)"
        }
    }

    public func remove(_ id: String) async {
        installed.removeAll { $0.id == id }
        await installer.remove(id: id)
        do { try await store.save(installed) } catch { banner = "Could not update the plugin list: \(error)" }
        await publishDefinitions()
        await recompute()
    }

    /// Applies one update. Without `approved`, the update is refused when its permissions or license changed.
    public func update(_ update: PluginUpdate, approved: Bool) async {
        guard !busy.contains(update.entry.id) else { return }
        busy.insert(update.entry.id)
        defer { busy.remove(update.entry.id) }
        do {
            // A downgrade is never applied, approved or not; permission or license changes need approval.
            let gate: @Sendable (PluginManifest) -> String? = { @Sendable manifest in
                if let reason = PluginPlanner.downgradeBlocker(installed: update.installed, newManifest: manifest) { return reason }
                return approved ? nil : PluginPlanner.autoUpdateBlocker(for: update, newManifest: manifest)
            }
            let plugin = try await installer.install(update.entry, allowCode: approved, approve: gate)
            installed.removeAll { $0.id == plugin.id }
            installed.append(plugin)
            try await store.save(installed)
            await publishDefinitions()
            await recompute()
        } catch let error as PluginError {
            if case .notApproved = error { return }
            if case .codeNeedsConfirmation = error { return }     // stays in the list for the user to review
            banner = "Could not update \(update.entry.id): \(error)"
        } catch {
            banner = "Could not update \(update.entry.id): \(error)"
        }
    }

    /// Reviewed plugins whose permissions and license did not change update on their own; everything else waits.
    public func applyAutomaticUpdates() async {
        for pending in updates where pending.entry.review == .reviewed {
            await update(pending, approved: false)
        }
    }

    // MARK: Background checks

    public func startChecking(every interval: Duration = .seconds(6 * 3600)) {
        guard refreshTask == nil, discoveryAvailable else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stopChecking() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    public func isInstalled(_ id: String) -> Bool { installed.contains { $0.id == id } }
    public func update(for id: String) -> PluginUpdate? { updates.first { $0.entry.id == id } }
}

extension PluginsModel {
    /// The real thing: GitHub registry, signature key from the app's Info.plist, plugins in Application Support.
    public static func live(app: AppModel) -> PluginsModel {
        let keyText = (Bundle.main.object(forInfoDictionaryKey: "MacHIDRegistryPublicKey") as? String)
            ?? ProcessInfo.processInfo.environment["MACHID_REGISTRY_PUBLIC_KEY"]
        let verifier = keyText.flatMap { Ed25519RegistryVerifier(publicKeyBase64: $0) }
        let root = FileInstalledPluginStore.pluginsDirectory
        let service = RegistryService(source: GitHubRegistrySource(), verifier: verifier, cache: FileRegistryCache())
        let installer = PluginInstaller(directory: root, fetcher: GitHubArchiveFetcher(), extractor: TarExtractor(), sha256: SHA256Hex.of)
        return PluginsModel(registryService: service, installer: installer, store: FileInstalledPluginStore(), pluginsRoot: root,
                            discoveryAvailable: verifier != nil,
                            catalogChanged: { [weak app] definitions, roots in await app?.setPluginDefinitions(definitions, artworkRoots: roots) },
                            unsupportedDevices: { [weak app] in await app?.unsupportedDeviceIDs() ?? [] })
    }
}
