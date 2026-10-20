import CryptoKit
import Foundation
import Testing
import MacHIDApplication
import MacHIDDomain
@testable import MacHIDSystem

private let OPENSSL_SIGNATURE = "O+PH/s/eo3sQ//7AII+SgO1mmfez0bImBr8HSGjU+QHo8iNwnJbNJJtGqEJ+ieRCz9iu4lul/0vMBrSo/xnZDQ=="
private let goodRef = String(repeating: "a", count: 40)
private let usb = USBID(vendor: 0x1234, product: 1)

private func entry(id: String = "acme", ref: String = goodRef, review: ReviewLevel = .reviewed, devices: [USBID]? = nil, core: APIRange = APIRange(min: 1, max: 1)) -> RegistryEntry {
    RegistryEntry(id: id, repo: "https://github.com/acme/\(id)", ref: ref, manifestSha256: String(repeating: "b", count: 64), license: "MIT",
                  category: .mouse, devices: devices ?? [usb], coreApi: core, review: review)
}

private func signed(_ registry: Registry, with key: Curve25519.Signing.PrivateKey) throws -> RegistrySnapshot {
    let data = try JSONEncoder().encode(registry)
    return RegistrySnapshot(data: data, signature: try key.signature(for: data))
}

private struct FixedSource: RegistrySource {
    let snapshot: RegistrySnapshot?
    func fetchLatest() async throws -> RegistrySnapshot {
        guard let snapshot else { throw URLError(.notConnectedToInternet) }
        return snapshot
    }
}

private actor MemoryCache: RegistryCache {
    var stored: RegistrySnapshot?
    func load() -> RegistrySnapshot? { stored }
    func save(_ snapshot: RegistrySnapshot) { stored = snapshot }
}

private func service(_ snapshot: RegistrySnapshot?, key: Curve25519.Signing.PrivateKey, cache: MemoryCache = MemoryCache(), trusted: Bool = true) -> RegistryService {
    let verifier = trusted ? Ed25519RegistryVerifier(publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString()) : nil
    return RegistryService(source: FixedSource(snapshot: snapshot), verifier: verifier, cache: cache)
}

@Suite struct RegistryServiceTests {
    @Test func acceptsASignedRegistryAndCachesIt() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let cache = MemoryCache()
        let registry = Registry(plugins: [entry()])
        let service = service(try signed(registry, with: key), key: key, cache: cache)
        #expect(try await service.refresh() == registry)
        #expect(await cache.stored != nil)
        #expect(await service.cached() == registry)
    }

    @Test func aWorkflowSignatureVerifiesWithOurKey() throws {
        // Produced with the exact command of .github/workflows/registry.yml:
        //   openssl pkeyutl -sign -rawin -inkey key.pem -in plugins.json -out plugins.json.sig   (OpenSSL 3)
        let verifier = try #require(Ed25519RegistryVerifier(publicKeyBase64: "JkUz3vcS/WxtT8Vp7Ks10+tgUs/QbxJK2mLWjik2WXc="))
        let data = Data(#"{"schema_version":1,"plugins":[]}"#.utf8)
        let signature = try #require(Data(base64Encoded: OPENSSL_SIGNATURE))
        #expect(signature.count == 64 && verifier.isValid(signature: signature, for: data))
        #expect(!verifier.isValid(signature: signature, for: data + Data(" ".utf8)))
    }

    @Test func tamperedOrForeignRegistriesAreRejected() async throws {
        let key = Curve25519.Signing.PrivateKey(), attacker = Curve25519.Signing.PrivateKey()
        var snapshot = try signed(Registry(plugins: [entry()]), with: key)
        snapshot.data.append(Data(" ".utf8))                                              // changed after signing
        await #expect(throws: RegistryError.badSignature) { try await service(snapshot, key: key).refresh() }
        let foreign = try signed(Registry(plugins: [entry()]), with: attacker)             // signed by someone else
        await #expect(throws: RegistryError.badSignature) { try await service(foreign, key: key).refresh() }
    }

    @Test func aValidSignatureDoesNotExcuseABadEntry() async throws {
        let key = Curve25519.Signing.PrivateKey()
        for bad in [entry(ref: "main"), entry(id: "Bad_Id"), entry(devices: [])] {
            do { _ = try await service(try signed(Registry(plugins: [bad]), with: key), key: key).refresh(); Issue.record("accepted \(bad.id)") }
            catch let error as RegistryError { if case .invalid = error {} else { Issue.record("wrong error \(error)") } }
        }
    }

    @Test func withoutATrustKeyNothingIsTrusted() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let snapshot = try signed(Registry(plugins: []), with: key)
        await #expect(throws: RegistryError.noTrustKey) { try await service(snapshot, key: key, trusted: false).refresh() }
        #expect(await service(snapshot, key: key, trusted: false).cached() == nil)
        #expect(Ed25519RegistryVerifier(publicKeyBase64: "not base64!") == nil)
        #expect(Ed25519RegistryVerifier(publicKeyBase64: Data(repeating: 1, count: 5).base64EncodedString()) == nil)
    }

    @Test func aFailedRefreshKeepsTheLastGoodCopy() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let cache = MemoryCache()
        let registry = Registry(plugins: [entry()])
        _ = try await service(try signed(registry, with: key), key: key, cache: cache).refresh()
        let offline = service(nil, key: key, cache: cache)
        await #expect(throws: RegistryError.self) { try await offline.refresh() }
        #expect(await offline.cached() == registry)
    }

    @Test func aTamperedCacheIsIgnored() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let cache = MemoryCache()
        var snapshot = try signed(Registry(plugins: [entry()]), with: key)
        snapshot.data = try JSONEncoder().encode(Registry(plugins: [entry(id: "evil")]))
        try await cache.save(snapshot)
        #expect(await service(nil, key: key, cache: cache).cached() == nil)
    }
}

@Suite struct PluginPlannerTests {
    private let installed = InstalledPlugin(id: "acme", name: "Acme", version: "1.0.0", ref: goodRef, review: .reviewed, license: "MIT", devices: [usb],
                                            permissions: PluginPermissions(transport: .hid, writes: .volatile), definitionFiles: [], installedAt: Date())

    @Test func recommendsReviewedCompatiblePluginsForUnsupportedDevices() {
        let registry = Registry(plugins: [entry(id: "zeta", review: .community), entry(id: "alpha", review: .reviewed), entry(id: "future", core: APIRange(min: 2, max: 2)),
                                          entry(id: "other", devices: [USBID(vendor: 9, product: 9)]), entry(id: "installed")])
        let found = PluginPlanner.recommendations(registry: registry, installed: [InstalledPlugin(id: "installed", name: "", version: "1.0.0", ref: goodRef, review: .reviewed, license: "MIT", devices: [usb],
                                                                                                 permissions: installed.permissions, definitionFiles: [], installedAt: Date())], unsupported: [usb])
        #expect(found.map(\.id) == ["alpha", "zeta"])         // reviewed first; not installed; compatible; matches the device
    }

    @Test func findsUpdatesByChangedCommit() {
        let newer = String(repeating: "c", count: 40)
        let registry = Registry(plugins: [entry(ref: newer)])
        #expect(PluginPlanner.updates(registry: registry, installed: [installed]).map(\.entry.ref) == [newer])
        #expect(PluginPlanner.updates(registry: Registry(plugins: [entry()]), installed: [installed]).isEmpty)
        #expect(PluginPlanner.updates(registry: Registry(plugins: [entry(ref: newer, core: APIRange(min: 5, max: 5))]), installed: [installed]).isEmpty)
    }

    @Test func onlyUnchangedReviewedPluginsUpdateAutomatically() {
        let manifest = { (license: String, writes: PluginPermissions.Writes) in
            PluginManifest(id: "acme", name: "Acme", version: "1.1.0", license: license, author: "A", coreAPI: APIRange(min: 1, max: 1), devices: [usb],
                           driver: nil, permissions: PluginPermissions(transport: .hid, writes: writes), definitions: nil)
        }
        let reviewed = PluginUpdate(installed: installed, entry: entry(ref: String(repeating: "c", count: 40), review: .reviewed))
        #expect(PluginPlanner.autoUpdateBlocker(for: reviewed, newManifest: manifest("MIT", .volatile)) == nil)
        #expect(PluginPlanner.autoUpdateBlocker(for: reviewed, newManifest: manifest("MIT", .none)) != nil)       // permissions changed
        #expect(PluginPlanner.autoUpdateBlocker(for: reviewed, newManifest: manifest("Apache-2.0", .volatile)) != nil)
        let community = PluginUpdate(installed: installed, entry: entry(ref: String(repeating: "c", count: 40), review: .community))
        #expect(PluginPlanner.autoUpdateBlocker(for: community, newManifest: manifest("MIT", .volatile)) != nil)
    }

    @Test func flagsPluginsTheRegistryDroppedOrIgnoresThemWhenListed() {
        #expect(PluginPlanner.orphaned(registry: Registry(plugins: []), installed: [installed]).map(\.id) == ["acme"])
        #expect(PluginPlanner.orphaned(registry: Registry(plugins: [entry()]), installed: [installed]).isEmpty)
    }
}

@Suite struct PluginStorageTests {
    @Test func installedStoreRoundTrips() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("machid-\(UUID().uuidString)/installed.json")
        let store = FileInstalledPluginStore(url: url)
        #expect(try await store.load().isEmpty)
        let plugin = InstalledPlugin(id: "acme", name: "Acme", version: "1.0.0", ref: goodRef, review: .community, license: "MIT", devices: [usb],
                                     permissions: PluginPermissions(transport: .hid, writes: .volatile), definitionFiles: ["devices/a.json"], installedAt: Date(timeIntervalSince1970: 1_000_000))
        try await store.save([plugin])
        #expect(try await store.load() == [plugin])
    }

    @Test func definitionsAreCheckedAgainWhenLoaded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("machid-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("acme").appendingPathComponent(goodRef).appendingPathComponent("devices")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let good = #"{"id":"acme-1","name":"A","category":"mouse","usb_ids":["1234:0001"],"driver":"razer","capabilities":[]}"#
        let stray = #"{"id":"acme-2","name":"B","category":"mouse","usb_ids":["9999:0001"],"driver":"razer","capabilities":[]}"#
        try good.write(to: folder.appendingPathComponent("good.json"), atomically: true, encoding: .utf8)
        try stray.write(to: folder.appendingPathComponent("stray.json"), atomically: true, encoding: .utf8)
        try "{ broken".write(to: folder.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)
        let plugin = InstalledPlugin(id: "acme", name: "Acme", version: "1.0.0", ref: goodRef, review: .reviewed, license: "MIT", devices: [usb],
                                     permissions: PluginPermissions(transport: .hid, writes: .volatile),
                                     definitionFiles: ["devices/good.json", "devices/stray.json", "devices/broken.json", "devices/missing.json"], installedAt: Date())
        let result = PluginDefinitions.load([plugin], root: root)
        #expect(result.definitions.map(\.id) == ["acme-1"] && result.problems.count == 3)
    }
}
