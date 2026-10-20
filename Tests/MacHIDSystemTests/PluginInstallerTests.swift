import Foundation
import Testing
import MacHIDApplication
import MacHIDDomain
@testable import MacHIDSystem

private let mouse = USBID(vendor: 0x1234, product: 0x0001)
private var fm: FileManager { FileManager.default }

private func temp(_ name: String = "") -> URL {
    let url = fm.temporaryDirectory.appendingPathComponent("machid-test-\(UUID().uuidString)\(name)", isDirectory: true)
    try? fm.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func sh(_ args: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    process.arguments = args
    process.currentDirectoryURL = directory
    try process.run()
    process.waitUntilExit()
}

/// Builds a plugin folder named like a GitHub archive root and packs it into a .tar.gz.
private struct PluginFixture {
    var manifest: [String: Any] = [
        "id": "acme-mouse", "name": "Acme Mouse", "version": "1.0.0", "license": "MIT", "author": "Acme",
        "core_api": ["min": 1, "max": 1], "devices": ["1234:0001"],
        "permissions": ["transport": "hid", "writes": "volatile"],
    ]
    var definition: [String: Any] = [
        "id": "acme-mouse-1", "name": "Acme Mouse 1", "category": "mouse", "usb_ids": ["1234:0001"], "driver": "razer",
        "capabilities": [["id": "info", "type": "info", "access": "read"]],
        "driver_options": ["lighting_transaction_id": "0x1F"],
    ]
    var extraFiles: [String: String] = [:]
    var symlink = false
    var traversal = false

    func pack() throws -> (archive: URL, manifestHash: String) {
        let work = temp()
        let root = work.appendingPathComponent("acme-plugin-\(String(repeating: "a", count: 40))", isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("devices"), withIntermediateDirectories: true)
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try manifestData.write(to: root.appendingPathComponent("manifest.json"))
        try JSONSerialization.data(withJSONObject: definition).write(to: root.appendingPathComponent("devices/mouse.json"))
        for (path, content) in extraFiles { try content.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8) }
        if symlink { try fm.createSymbolicLink(at: root.appendingPathComponent("devices/link.json"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts")) }
        let archive = work.appendingPathComponent("plugin.tar.gz")
        var args = ["-czf", archive.path]
        if traversal { args += ["-s", "|^acme|../acme|"] }
        args += [root.lastPathComponent]
        try sh(args, in: work)
        return (archive, SHA256Hex.of(manifestData))
    }
}

private struct FixedFetcher: PluginFetcher {
    let archive: URL
    func fetchArchive(repo: String, ref: String) async throws -> URL {
        let copy = fm.temporaryDirectory.appendingPathComponent("machid-dl-\(UUID().uuidString).tar.gz")
        try fm.copyItem(at: archive, to: copy)
        return copy
    }
}

private func entry(hash: String, id: String = "acme-mouse", ref: String = String(repeating: "a", count: 40)) -> RegistryEntry {
    RegistryEntry(id: id, repo: "https://github.com/acme/plugin", ref: ref, manifestSha256: hash, license: "MIT", category: .mouse,
                  devices: [mouse], coreApi: APIRange(min: 1, max: 1), review: .reviewed)
}

private func installer(_ archive: URL, directory: URL = temp()) -> PluginInstaller {
    PluginInstaller(directory: directory, fetcher: FixedFetcher(archive: archive), extractor: TarExtractor(), sha256: SHA256Hex.of)
}

@Suite struct PluginInstallerTests {
    @Test func installsAGoodPluginAndKeepsOnlyTheManifestAndDefinitions() async throws {
        var fixture = PluginFixture()
        fixture.extraFiles["README.md"] = "hello"
        fixture.extraFiles["script.sh"] = "rm -rf ~"
        let (archive, hash) = try fixture.pack()
        let directory = temp()
        let installed = try await installer(archive, directory: directory).install(entry(hash: hash))
        #expect(installed.id == "acme-mouse" && installed.version == "1.0.0" && installed.definitionFiles == ["devices/mouse.json"])
        #expect(installed.review == .reviewed && installed.devices == [mouse])
        let folder = directory.appendingPathComponent("acme-mouse").appendingPathComponent(String(repeating: "a", count: 40))
        let kept = try fm.subpathsOfDirectory(atPath: folder.path).sorted()
        #expect(kept == ["devices", "devices/mouse.json", "manifest.json"])          // nothing else is kept, let alone run
    }

    @Test func aChangedManifestIsRefused() async throws {
        let (archive, _) = try PluginFixture().pack()
        await #expect(throws: PluginError.manifestHashMismatch) { try await installer(archive).install(entry(hash: String(repeating: "0", count: 64))) }
    }

    @Test func disagreeingWithTheRegistryEntryIsRefused() async throws {
        var fixture = PluginFixture()
        fixture.manifest["devices"] = ["1234:0001", "1234:0002"]
        let (archive, hash) = try fixture.pack()
        await #expect(throws: PluginError.registryMismatch("devices")) { try await installer(archive).install(entry(hash: hash)) }
        var other = PluginFixture()
        other.manifest["id"] = "someone-else"
        let (archive2, hash2) = try other.pack()
        await #expect(throws: PluginError.registryMismatch("id")) { try await installer(archive2).install(entry(hash: hash2)) }
    }

    @Test func codePluginsInstallTheirScriptAndAreFlagged() async throws {
        var fixture = PluginFixture()
        fixture.manifest["driver"] = "driver.js"
        fixture.manifest["permissions"] = ["transport": "hid", "report_ids": [1], "writes": "volatile"]
        fixture.definition["driver"] = "plugin:acme-mouse"
        fixture.extraFiles["driver.js"] = "function read(c) { return 1 }"
        let (archive, hash) = try fixture.pack()
        let installerDirectory = temp()
        let plugin = try await installer(archive, directory: installerDirectory).install(entry(hash: hash), allowCode: true)
        #expect(plugin.hasCode)
        #expect(fm.fileExists(atPath: installerDirectory.appendingPathComponent("acme-mouse/\(entry(hash: hash).ref)/driver.js").path))
    }

    @Test func codePluginScriptsAreChecked() async throws {
        for (content, label) in [("function read(){}\u{0}", "NUL"), (String(repeating: "a", count: 128 * 1024 + 1), "size")] {
            var fixture = PluginFixture()
            fixture.manifest["driver"] = "driver.js"
            fixture.definition["driver"] = "plugin:acme-mouse"
            fixture.extraFiles["driver.js"] = content
            let (archive, hash) = try fixture.pack()
            do { _ = try await installer(archive).install(entry(hash: hash)); Issue.record("\(label) should have failed") } catch is PluginError {}
        }
        var missing = PluginFixture()
        missing.manifest["driver"] = "driver.js"
        missing.definition["driver"] = "plugin:acme-mouse"
        let (archive, hash) = try missing.pack()
        do { _ = try await installer(archive).install(entry(hash: hash)); Issue.record("missing script should have failed") } catch is PluginError {}
    }

    @Test func dataPluginsCannotClaimACodeDriver() async throws {
        var fixture = PluginFixture()
        fixture.definition["driver"] = "plugin:acme-mouse"
        let (archive, hash) = try fixture.pack()
        await #expect(throws: PluginError.unknownDriver("plugin:acme-mouse")) { try await installer(archive).install(entry(hash: hash)) }
    }

    @Test func invalidManifestsAreExplained() async throws {
        var fixture = PluginFixture()
        fixture.manifest["version"] = "one"
        let (archive, hash) = try fixture.pack()
        do { _ = try await installer(archive).install(entry(hash: hash)); Issue.record("should have failed") }
        catch let error as PluginError { #expect("\(error)".contains("version")) }
    }

    @Test func definitionsMustUseKnownDriversAndDeclaredDevices() async throws {
        var unknown = PluginFixture()
        unknown.definition["driver"] = "totally-custom"
        let (a1, h1) = try unknown.pack()
        await #expect(throws: PluginError.unknownDriver("totally-custom")) { try await installer(a1).install(entry(hash: h1)) }

        var stray = PluginFixture()
        stray.definition["usb_ids"] = ["1234:0001", "9999:9999"]
        let (a2, h2) = try stray.pack()
        do { _ = try await installer(a2).install(entry(hash: h2)); Issue.record("should have failed") }
        catch let error as PluginError { #expect("\(error)".contains("9999:9999")) }

        var broken = PluginFixture()
        broken.definition["capabilities"] = [["id": "x", "type": "not-a-type", "access": "read"]]
        let (a3, h3) = try broken.pack()
        await #expect(throws: PluginError.self) { try await installer(a3).install(entry(hash: h3)) }
    }

    @Test func linksInsideTheArchiveAreRefused() async throws {
        var fixture = PluginFixture()
        fixture.symlink = true
        let (archive, hash) = try fixture.pack()
        await #expect(throws: PluginError.self) { try await installer(archive).install(entry(hash: hash)) }
    }

    @Test func pathsThatEscapeTheArchiveAreRefused() async throws {
        var fixture = PluginFixture()
        fixture.traversal = true
        let (archive, hash) = try fixture.pack()
        await #expect(throws: PluginError.self) { try await installer(archive).install(entry(hash: hash)) }
    }

    @Test func upgradingReplacesTheOldVersionAndRemovalDeletesEverything() async throws {
        let directory = temp()
        let (first, firstHash) = try PluginFixture().pack()
        _ = try await installer(first, directory: directory).install(entry(hash: firstHash, ref: String(repeating: "a", count: 40)))
        var next = PluginFixture()
        next.manifest["version"] = "1.1.0"
        let (second, secondHash) = try next.pack()
        let upgraded = try await installer(second, directory: directory).install(entry(hash: secondHash, ref: String(repeating: "b", count: 40)))
        #expect(upgraded.version == "1.1.0")
        let versions = try fm.contentsOfDirectory(atPath: directory.appendingPathComponent("acme-mouse").path)
        #expect(versions == [String(repeating: "b", count: 40)])
        await installer(second, directory: directory).remove(id: "acme-mouse")
        #expect(!fm.fileExists(atPath: directory.appendingPathComponent("acme-mouse").path))
    }

    @Test func aFailedInstallLeavesNothingBehind() async throws {
        let directory = temp()
        var fixture = PluginFixture()
        fixture.definition["driver"] = "nope"
        let (archive, hash) = try fixture.pack()
        _ = try? await installer(archive, directory: directory).install(entry(hash: hash))
        #expect(!fm.fileExists(atPath: directory.appendingPathComponent("acme-mouse").path))
    }
}

@Suite struct FetcherRulesTests {
    @Test func onlyGitHubRepositoriesAndFullCommitsAreAccepted() async {
        let fetcher = GitHubArchiveFetcher()
        let good = String(repeating: "a", count: 40)
        for (repo, ref) in [("https://evil.example/a/b", good), ("http://github.com/a/b", good), ("https://github.com/a/b", "main"),
                            ("https://github.com/a/b", String(repeating: "g", count: 40)), ("https://github.com/a", good)] {
            await #expect(throws: (any Error).self) { _ = try await fetcher.fetchArchive(repo: repo, ref: ref) }
        }
    }
}
