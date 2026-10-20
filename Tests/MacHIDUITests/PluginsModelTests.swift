import Foundation
import Testing
import MacHIDApplication
import MacHIDDomain
import MacHIDSystem
@testable import MacHIDUI

private let device = USBID(vendor: 0x1234, product: 1)
private let refA = String(repeating: "a", count: 40)
private let refB = String(repeating: "b", count: 40)

/// A fake "GitHub": each commit holds a manifest (as a dictionary) and one definition.
private struct FakeRepo: Sendable {
    var versions: [String: [String: String]]    // ref -> file name -> content
}

private final class Hosting: @unchecked Sendable {
    var manifests: [String: [String: Any]] = [:]
    func file(for ref: String) -> [String: String] {
        let manifest = manifests[ref]!
        let manifestText = String(decoding: try! JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]), as: UTF8.self)
        let definition = #"{"id":"acme-1","name":"Acme 1","category":"mouse","usb_ids":["1234:0001"],"driver":"razer","capabilities":[]}"#
        return ["manifest.json": manifestText, "devices/a.json": definition]
    }
}

private struct FakeFetcher: PluginFetcher {
    func fetchArchive(repo: String, ref: String) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID().uuidString)")
        try ref.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

private struct FakeExtractor: ArchiveExtractor {
    let hosting: Hosting
    func extract(_ archive: URL, into directory: URL) throws {
        let ref = try String(contentsOf: archive, encoding: .utf8)
        for (path, content) in hosting.file(for: ref) {
            let target = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: target, atomically: true, encoding: .utf8)
        }
    }
}

private struct AlwaysValid: RegistryVerifier {
    func isValid(signature: Data, for data: Data) -> Bool { true }
}

private actor FakeSource: RegistrySource {
    var registry: Registry
    init(_ registry: Registry) { self.registry = registry }
    func set(_ registry: Registry) { self.registry = registry }
    func fetchLatest() async throws -> RegistrySnapshot {
        RegistrySnapshot(data: try JSONEncoder().encode(registry), signature: Data([1]))
    }
}

private actor MemoryCache: RegistryCache {
    var stored: RegistrySnapshot?
    func load() -> RegistrySnapshot? { stored }
    func save(_ snapshot: RegistrySnapshot) { stored = snapshot }
}

private actor MemoryStore: InstalledPluginStore {
    var plugins: [InstalledPlugin] = []
    func load() -> [InstalledPlugin] { plugins }
    func save(_ plugins: [InstalledPlugin]) { self.plugins = plugins }
}

private final class Catalog: @unchecked Sendable {
    var definitions: [[String]] = []     // one list of definition ids per notification
}

private func manifest(version: String, writes: String = "volatile", license: String = "MIT") -> [String: Any] {
    ["id": "acme", "name": "Acme", "version": version, "license": license, "author": "A", "core_api": ["min": 1, "max": 1],
     "devices": ["1234:0001"], "permissions": ["transport": "hid", "writes": writes]]
}

private func entry(ref: String, hosting: Hosting, review: ReviewLevel = .reviewed) -> RegistryEntry {
    let data = try! JSONSerialization.data(withJSONObject: hosting.manifests[ref]!, options: [.sortedKeys])
    return RegistryEntry(id: "acme", repo: "https://github.com/acme/acme", ref: ref, manifestSha256: SHA256Hex.of(data), license: hosting.manifests[ref]!["license"] as! String,
                         category: .mouse, devices: [device], coreApi: APIRange(min: 1, max: 1), review: review)
}

@MainActor
private func makeModel(hosting: Hosting, registry: Registry, discovery: Bool = true, store: MemoryStore = MemoryStore(), catalog: Catalog = Catalog(),
                       source: FakeSource? = nil) -> (PluginsModel, FakeSource, Catalog, MemoryStore) {
    let source = source ?? FakeSource(registry)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("machid-plugins-\(UUID().uuidString)")
    let service = RegistryService(source: source, verifier: discovery ? AlwaysValid() : nil, cache: MemoryCache())
    let installer = PluginInstaller(directory: root, fetcher: FakeFetcher(), extractor: FakeExtractor(hosting: hosting), sha256: SHA256Hex.of)
    let model = PluginsModel(registryService: service, installer: installer, store: store, pluginsRoot: root, discoveryAvailable: discovery,
                             defaults: UserDefaults(suiteName: "machid-plugins-\(UUID().uuidString)")!,
                             catalogChanged: { catalog.definitions.append($0.map(\.id)) }, unsupportedDevices: { [device] })
    return (model, source, catalog, store)
}

@MainActor
@Suite struct PluginsModelTests {
    @Test func discoveryIsOffWithoutATrustKey() async {
        let hosting = Hosting(); hosting.manifests[refA] = manifest(version: "1.0.0")
        let (model, _, _, _) = makeModel(hosting: hosting, registry: Registry(plugins: [entry(ref: refA, hosting: hosting)]), discovery: false)
        await model.refresh(force: true)
        #expect(!model.discoveryAvailable && model.registry == nil && model.recommendations.isEmpty && model.status == .idle)
    }

    @Test func refreshRecommendsPluginsForUnsupportedDevices() async {
        let hosting = Hosting(); hosting.manifests[refA] = manifest(version: "1.0.0")
        let (model, _, _, _) = makeModel(hosting: hosting, registry: Registry(plugins: [entry(ref: refA, hosting: hosting)]))
        await model.refresh(force: true)
        #expect(model.recommendations.map(\.id) == ["acme"] && model.lastChecked != nil)
    }

    @Test func installingAddsDefinitionsAndRemovingTakesThemAway() async {
        let hosting = Hosting(); hosting.manifests[refA] = manifest(version: "1.0.0")
        let e = entry(ref: refA, hosting: hosting)
        let (model, _, catalog, store) = makeModel(hosting: hosting, registry: Registry(plugins: [e]))
        await model.refresh(force: true)
        await model.install(e)
        #expect(model.installed.map(\.id) == ["acme"] && model.isInstalled("acme") && model.recommendations.isEmpty)
        #expect(catalog.definitions.last == ["acme-1"])
        #expect(await store.plugins.count == 1)
        await model.remove("acme")
        #expect(model.installed.isEmpty && catalog.definitions.last == [])
        #expect(await store.plugins.isEmpty)
    }

    @Test func aFailedInstallExplainsAndChangesNothing() async {
        let hosting = Hosting(); hosting.manifests[refA] = manifest(version: "1.0.0")
        var bad = entry(ref: refA, hosting: hosting)
        bad = RegistryEntry(id: bad.id, repo: bad.repo, ref: bad.ref, manifestSha256: String(repeating: "0", count: 64), license: bad.license,
                            category: bad.category, devices: bad.devices, coreApi: bad.coreApi, review: bad.review)
        let (model, _, _, _) = makeModel(hosting: hosting, registry: Registry(plugins: [bad]))
        await model.install(bad)
        #expect(model.installed.isEmpty && model.banner?.contains("registry") == true || model.banner?.contains("manifest") == true)
    }

    @Test func installedPluginsReachTheCatalogOnLoad() async {
        let hosting = Hosting(); hosting.manifests[refA] = manifest(version: "1.0.0")
        let e = entry(ref: refA, hosting: hosting)
        let (first, _, _, store) = makeModel(hosting: hosting, registry: Registry(plugins: [e]))
        await first.install(e)
        let catalog = Catalog()
        let (second, _, _, _) = makeModel(hosting: hosting, registry: Registry(plugins: [e]), store: store, catalog: catalog)
        // A fresh model with the same store reads what is installed (its files live in the first model's folder).
        await second.load()
        #expect(second.installed.map(\.id) == ["acme"] && catalog.definitions.count == 1)
    }

    @Test func reviewedUpdatesWithSamePermissionsApplyAutomatically() async {
        let hosting = Hosting(); hosting.manifests[refA] = manifest(version: "1.0.0"); hosting.manifests[refB] = manifest(version: "1.1.0")
        let (model, source, _, _) = makeModel(hosting: hosting, registry: Registry(plugins: [entry(ref: refA, hosting: hosting)]))
        await model.install(entry(ref: refA, hosting: hosting))
        await source.set(Registry(plugins: [entry(ref: refB, hosting: hosting)]))
        await model.refresh(force: true)
        #expect(model.installed.first?.version == "1.1.0" && model.updates.isEmpty)
    }

    @Test func changedPermissionsWaitForApprovalAndAutoUpdateCanBeTurnedOff() async {
        let hosting = Hosting()
        hosting.manifests[refA] = manifest(version: "1.0.0"); hosting.manifests[refB] = manifest(version: "1.1.0", writes: "none")
        let (model, source, _, _) = makeModel(hosting: hosting, registry: Registry(plugins: [entry(ref: refA, hosting: hosting)]))
        await model.install(entry(ref: refA, hosting: hosting))
        await source.set(Registry(plugins: [entry(ref: refB, hosting: hosting)]))
        await model.refresh(force: true)
        #expect(model.installed.first?.version == "1.0.0" && model.updates.count == 1)        // waiting for the user
        await model.update(model.updates[0], approved: true)
        #expect(model.installed.first?.version == "1.1.0" && model.updates.isEmpty)
    }

    @Test func communityUpdatesNeverApplyByThemselves() async {
        let hosting = Hosting(); hosting.manifests[refA] = manifest(version: "1.0.0"); hosting.manifests[refB] = manifest(version: "1.1.0")
        let (model, source, _, _) = makeModel(hosting: hosting, registry: Registry(plugins: [entry(ref: refA, hosting: hosting, review: .community)]))
        await model.install(entry(ref: refA, hosting: hosting, review: .community))
        await source.set(Registry(plugins: [entry(ref: refB, hosting: hosting, review: .community)]))
        await model.refresh(force: true)
        #expect(model.installed.first?.version == "1.0.0" && model.updates.count == 1)
    }

    @Test func turningAutoUpdateOffKeepsEveryUpdatePending() async {
        let hosting = Hosting(); hosting.manifests[refA] = manifest(version: "1.0.0"); hosting.manifests[refB] = manifest(version: "1.1.0")
        let (model, source, _, _) = makeModel(hosting: hosting, registry: Registry(plugins: [entry(ref: refA, hosting: hosting)]))
        model.autoUpdate = false
        await model.install(entry(ref: refA, hosting: hosting))
        await source.set(Registry(plugins: [entry(ref: refB, hosting: hosting)]))
        await model.refresh(force: true)
        #expect(model.installed.first?.version == "1.0.0" && model.updates.count == 1)
    }

    @Test func recentChecksAreNotRepeated() async {
        let hosting = Hosting(); hosting.manifests[refA] = manifest(version: "1.0.0")
        let (model, source, _, _) = makeModel(hosting: hosting, registry: Registry(plugins: [entry(ref: refA, hosting: hosting)]))
        await model.refresh(force: true)
        await source.set(Registry(plugins: []))
        await model.refresh()                                             // within five minutes: skipped
        #expect(model.registry?.plugins.count == 1)
        await model.refresh(force: true)
        #expect(model.registry?.plugins.isEmpty == true)
    }
}
