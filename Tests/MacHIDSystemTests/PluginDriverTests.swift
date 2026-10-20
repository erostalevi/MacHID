import Foundation
import Testing
import MacHIDApplication
import MacHIDDomain
@testable import MacHIDSystem

private final class BundleAnchor {}

private final class FakeTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return log }
    private func note(_ s: String) { lock.lock(); log.append(s); lock.unlock() }
    func sendFeatureReport(reportID: UInt8, _ data: [UInt8]) async throws { note("feature \(reportID) \(data)") }
    func getFeatureReport(reportID: UInt8, length: Int) async throws -> [UInt8] { note("get \(reportID)"); return [UInt8](repeating: 7, count: length) }
    func sendOutputReport(reportID: UInt8, _ data: [UInt8]) async throws { note("output \(reportID)") }
    func nextInputReport(timeout: Duration) async throws -> (reportID: UInt8, data: [UInt8]) { (reportID: 9, data: [1]) }
}

/// A host that says whatever the test scripted, and records what the broker sent back.
private final class ScriptedSession: PluginHostSession, @unchecked Sendable {
    private let lock = NSLock()
    private var incoming: [String]
    private(set) var terminated = false
    init(_ lines: [String]) { incoming = lines }
    func send(_ line: String) throws {}
    private func pop() -> String? { lock.lock(); defer { lock.unlock() }; return incoming.isEmpty ? nil : incoming.removeFirst() }
    func receiveLine(timeout: Duration) async throws -> String {
        guard let line = pop() else { throw DriverError.deviceFailure("the plugin took too long") }
        return line
    }
    func terminate() { setTerminated() }
    private func setTerminated() { lock.lock(); terminated = true; lock.unlock() }
}

private struct ScriptedLauncher: PluginHostLauncher {
    let session: ScriptedSession
    func launch() throws -> any PluginHostSession { session }
}

private let capability = CapabilityDescriptor(id: "dpi", type: .dpi, access: .writeVolatile)
private func permissions(ids: [Int]? = [1], writes: PluginPermissions.Writes = .volatile, transport: PluginPermissions.Transport = .hid) -> PluginPermissions {
    PluginPermissions(transport: transport, reportIDs: ids, writes: writes)
}

private func scripted(_ hid: String, permissions: PluginPermissions) -> (PluginDriver, ScriptedSession) {
    let session = ScriptedSession([#"{"type":"loaded","describe":false}"#, hid])
    return (PluginDriver(pluginID: "t", script: "", permissions: permissions, launcher: ScriptedLauncher(session: session)), session)
}

@Suite struct PluginBrokerTests {
    @Test func policyEnforcesTheManifest() throws {
        let policy = PluginBrokerPolicy(permissions: permissions())
        try policy.authorize(.sendFeature(reportID: 1, bytes: [1, 2]))
        try policy.authorize(.getFeature(reportID: 1, length: 8))
        #expect(throws: DriverError.self) { try policy.authorize(.sendFeature(reportID: 2, bytes: [1])) }               // id not allowed
        #expect(throws: DriverError.self) { try policy.authorize(.sendOutput(reportID: 1, bytes: [Int](repeating: 0, count: 257))) }
        #expect(throws: DriverError.self) { try policy.authorize(.sendOutput(reportID: 1, bytes: [300])) }
        #expect(throws: DriverError.self) { try PluginBrokerPolicy(permissions: permissions(writes: .none)).authorize(.sendFeature(reportID: 1, bytes: [])) }
        #expect(throws: DriverError.self) { try PluginBrokerPolicy(permissions: permissions(ids: nil)).authorize(.getFeature(reportID: 0, length: 1)) }
        #expect(throws: DriverError.self) { try PluginBrokerPolicy(permissions: permissions(ids: [])).authorize(.nextInput(timeoutMs: 10)) }
        #expect(throws: DriverError.self) { try PluginBrokerPolicy(permissions: permissions(transport: .uvc)).authorize(.getFeature(reportID: 1, length: 1)) }
        #expect(!policy.mayReceiveInput(reportID: 9))
    }

    @Test func aViolationKillsTheHostAndNeverTouchesTheDevice() async throws {
        let transport = FakeTransport()
        let (driver, session) = scripted(#"{"type":"hid","call":"sendFeature","reportID":5,"bytes":[1]}"#, permissions: permissions())
        await #expect(throws: DriverError.self) { _ = try await driver.read(capability, using: transport) }
        #expect(session.terminated)
        #expect(transport.calls.isEmpty)
    }

    @Test func writesNoneForbidsSends() async throws {
        let transport = FakeTransport()
        let (driver, session) = scripted(#"{"type":"hid","call":"sendOutput","reportID":1,"bytes":[1]}"#, permissions: permissions(writes: .none))
        await #expect(throws: DriverError.self) { _ = try await driver.read(capability, using: transport) }
        #expect(session.terminated && transport.calls.isEmpty)
    }

    @Test func allowedCallsReachTheTransportAndTheResultComesBack() async throws {
        let transport = FakeTransport()
        let session = ScriptedSession([#"{"type":"loaded","describe":false}"#, #"{"type":"hid","call":"sendFeature","reportID":1,"bytes":[4,5]}"#, #"{"type":"result","json":"800"}"#])
        let driver = PluginDriver(pluginID: "t", script: "", permissions: permissions(), launcher: ScriptedLauncher(session: session))
        #expect(try await driver.read(capability, using: transport) == .int(800))
        #expect(transport.calls == ["feature 1 [4, 5]"])
        #expect(session.terminated)
    }

    @Test func aHostThatGoesSilentIsKilled() async throws {
        let session = ScriptedSession([#"{"type":"loaded","describe":false}"#])
        let driver = PluginDriver(pluginID: "t", script: "", permissions: permissions(), launcher: ScriptedLauncher(session: session))
        await #expect(throws: DriverError.self) { _ = try await driver.read(capability, using: FakeTransport()) }
        #expect(session.terminated)
    }

    @Test func rateLimiterCapsWrites() {
        let limiter = PluginRateLimiter(maxCallsPerSecond: 100, maxWritesPerSecond: 2)
        #expect(limiter.admit(isWrite: true) && limiter.admit(isWrite: true))
        #expect(!limiter.admit(isWrite: true))
        #expect(limiter.admit(isWrite: false))
    }
}

/// Runs the real host binary (under the real sandbox). Skipped when the host was not built next to the tests.
@Suite struct PluginHostIntegrationTests {
    private func launcher() -> SandboxedPluginHostLauncher? {
        let url = Bundle(for: BundleAnchor.self).bundleURL.deletingLastPathComponent().appendingPathComponent("MacHIDPluginHost")
        return FileManager.default.isExecutableFile(atPath: url.path) ? SandboxedPluginHostLauncher(hostURL: url) : nil
    }

    private func driver(_ script: String, _ launcher: SandboxedPluginHostLauncher, timeout: Duration = .seconds(5)) -> PluginDriver {
        PluginDriver(pluginID: "t", script: script, permissions: permissions(), launcher: launcher, timeout: timeout)
    }

    @Test func scriptTalksToTheDeviceOnlyThroughTheBroker() async throws {
        guard let launcher = launcher() else { return }
        let transport = FakeTransport()
        let script = "function read(c){ var b = hid.getFeature(1, 3); return b[0] + b[1] + b[2]; } function write(c,v){ hid.sendFeature(1,[v]); }"
        #expect(try await driver(script, launcher).read(capability, using: transport) == .int(21))
        try await driver(script, launcher).write(.int(9), to: capability, using: transport)
        #expect(transport.calls == ["get 1", "feature 1 [9]"])
    }

    @Test func scriptHasNoWayOutOfTheContext() async throws {
        guard let launcher = launcher() else { return }
        let script = """
        function read(c){ var names = ['require','process','fetch','XMLHttpRequest','setTimeout','setInterval','WebSocket','importScripts','Deno','Bun','WebAssembly'];
          var present = names.filter(function(n){ return typeof globalThis[n] !== 'undefined'; }); return present.length === 0 ? 1 : 0; }
        """
        #expect(try await driver(script, launcher).read(capability, using: FakeTransport()) == .int(1))
    }

    @Test func hostCannotBeUsedToDenyTheLimits() async throws {
        guard let launcher = launcher() else { return }
        let transport = FakeTransport()
        // Unauthorized report id: the broker refuses and the request fails.
        await #expect(throws: DriverError.self) { _ = try await driver("function read(c){ hid.sendFeature(7,[1]); return 1 }", launcher).read(capability, using: transport) }
        // Endless loop: killed on timeout.
        await #expect(throws: DriverError.self) { _ = try await driver("function read(c){ while(true){} }", launcher, timeout: .seconds(1)).read(capability, using: transport) }
        #expect(transport.calls.isEmpty)
    }
}

@Suite struct CodePluginUpdateTests {
    @Test func codePluginsNeverAutoUpdateEvenWhenReviewed() {
        let usb = USBID(vendor: 0x1234, product: 1)
        let perms = permissions()
        let installed = InstalledPlugin(id: "acme", name: "A", version: "1.0.0", ref: String(repeating: "a", count: 40), review: .reviewed, license: "MIT",
                                        devices: [usb], permissions: perms, definitionFiles: [], installedAt: Date(), hasCode: true)
        let entry = RegistryEntry(id: "acme", repo: "https://github.com/a/b", ref: String(repeating: "b", count: 40), manifestSha256: "", license: "MIT",
                                  category: .mouse, devices: [usb], coreApi: APIRange(min: 1, max: 1), review: .reviewed)
        let manifest = PluginManifest(id: "acme", name: "A", version: "1.1.0", license: "MIT", author: "a", coreAPI: APIRange(min: 1, max: 1), devices: [usb],
                                      driver: "driver.js", permissions: perms, definitions: nil)
        #expect(PluginPlanner.autoUpdateBlocker(for: PluginUpdate(installed: installed, entry: entry), newManifest: manifest) != nil)
    }

    @Test func oldInstalledListsStillDecode() throws {
        let json = #"[{"id":"a","name":"A","version":"1.0.0","ref":"r","review":"reviewed","license":"MIT","devices":["1234:0001"],"permissions":{"transport":"hid","writes":"none"},"definitionFiles":[],"installedAt":"2026-01-01T00:00:00Z"}]"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode([InstalledPlugin].self, from: Data(json.utf8)).first?.hasCode == false)
    }
}
