import Foundation
import MacHIDDomain

// MARK: Ports

/// A running plugin host process: newline-delimited JSON in both directions.
public protocol PluginHostSession: Sendable {
    func send(_ line: String) throws
    /// Next line from the host. Throws when the host exits, sends an oversized line, or nothing arrives in time.
    func receiveLine(timeout: Duration) async throws -> String
    /// Kills the host. Safe to call more than once.
    func terminate()
}

/// Starts the sandboxed host (see `MacHIDPluginHost`). The system adapter runs it under `sandbox-exec`.
public protocol PluginHostLauncher: Sendable {
    func launch() throws -> any PluginHostSession
}

// MARK: Policy

/// What the broker lets a plugin do with the device. Pure: decides from the manifest permissions the user approved.
public struct PluginBrokerPolicy: Sendable {
    public static let maxBytesPerCall = 256
    public static let maxCallsPerRequest = 64
    public static let maxInputWait = Duration.seconds(2)

    public let permissions: PluginPermissions

    public init(permissions: PluginPermissions) { self.permissions = permissions }

    public enum Call: Equatable, Sendable {
        case sendFeature(reportID: Int, bytes: [Int])
        case sendOutput(reportID: Int, bytes: [Int])
        case getFeature(reportID: Int, length: Int)
        case nextInput(timeoutMs: Int)

        public var isWrite: Bool {
            switch self {
            case .sendFeature, .sendOutput: true
            case .getFeature, .nextInput: false
            }
        }
    }

    /// Throws `DriverError.deviceFailure` describing the violation. Any violation ends the request.
    public func authorize(_ call: Call) throws {
        guard permissions.transport == .hid else { throw Self.violation("the plugin did not declare HID access") }
        let allowed = Set(permissions.reportIDs ?? [])
        func checkID(_ id: Int) throws {
            guard (0...255).contains(id) else { throw Self.violation("report id \(id) is not valid") }
            guard allowed.contains(id) else { throw Self.violation("report id \(id) is not in the plugin's permissions") }
        }
        func checkBytes(_ count: Int) throws {
            guard count <= Self.maxBytesPerCall else { throw Self.violation("\(count) bytes exceed the limit of \(Self.maxBytesPerCall)") }
        }
        switch call {
        case .sendFeature(let id, let bytes), .sendOutput(let id, let bytes):
            guard permissions.writes == .volatile else { throw Self.violation("the plugin may not write to the device") }
            try checkID(id)
            try checkBytes(bytes.count)
            guard bytes.allSatisfy({ (0...255).contains($0) }) else { throw Self.violation("bytes must be 0-255") }
        case .getFeature(let id, let length):
            try checkID(id)
            guard length >= 1 else { throw Self.violation("length must be positive") }
            try checkBytes(length)
        case .nextInput(let timeoutMs):
            // Without declared report ids there is nothing the plugin may see: input reports can be key presses.
            guard !allowed.isEmpty else { throw Self.violation("the plugin did not declare any report ids, so it may not read input") }
            guard timeoutMs >= 0, timeoutMs <= 2000 else { throw Self.violation("timeout out of range") }
        }
    }

    /// Input reports are only handed over when their id was declared; anything else (for example key events) is dropped.
    public func mayReceiveInput(reportID: UInt8) -> Bool { (permissions.reportIDs ?? []).contains(Int(reportID)) }

    static func violation(_ why: String) -> DriverError { .deviceFailure("plugin blocked: \(why)") }
}

/// Sliding one-second window. Injectable clock for tests.
public final class PluginRateLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [ContinuousClock.Instant] = []
    private var writes: [ContinuousClock.Instant] = []
    private let maxCalls: Int
    private let maxWrites: Int
    private let now: @Sendable () -> ContinuousClock.Instant

    public init(maxCallsPerSecond: Int = 200, maxWritesPerSecond: Int = 50, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.maxCalls = maxCallsPerSecond
        self.maxWrites = maxWritesPerSecond
        self.now = now
    }

    public func admit(isWrite: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let t = now()
        let cutoff = t - .seconds(1)
        calls.removeAll { $0 < cutoff }
        writes.removeAll { $0 < cutoff }
        guard calls.count < maxCalls, !isWrite || writes.count < maxWrites else { return false }
        calls.append(t)
        if isWrite { writes.append(t) }
        return true
    }
}

// MARK: Driver

/// A `DeviceDriver` whose protocol is a plugin script. The script runs in a separate sandboxed process; every device
/// access it asks for is checked against the manifest permissions here and then performed on the real `Transport`.
public struct PluginDriver: DeviceDriver {
    public static let maxScriptBytes = 128 * 1024
    public static let maxLineBytes = 16 * 1024

    public let pluginID: String
    private let script: String
    private let policy: PluginBrokerPolicy
    private let launcher: any PluginHostLauncher
    private let limiter: PluginRateLimiter
    private let timeout: Duration
    private let logger: @Sendable (String) -> Void

    public var familyID: String { "plugin:\(pluginID)" }

    public init(pluginID: String, script: String, permissions: PluginPermissions, launcher: any PluginHostLauncher,
                limiter: PluginRateLimiter = PluginRateLimiter(), timeout: Duration = .seconds(5),
                logger: @escaping @Sendable (String) -> Void = { _ in }) {
        self.pluginID = pluginID
        self.script = script
        self.policy = PluginBrokerPolicy(permissions: permissions)
        self.launcher = launcher
        self.limiter = limiter
        self.timeout = timeout
        self.logger = logger
    }

    public func read(_ capability: CapabilityDescriptor, using transport: any Transport) async throws -> SettingValue {
        let json = try await run(["op": "read", "capability": capability.id], transport: transport)
        guard let data = json.data(using: .utf8), let value = try? JSONDecoder().decode(SettingValue.self, from: data) else {
            throw DriverError.deviceFailure("the plugin returned a value MacHID cannot use")
        }
        return value
    }

    public func write(_ value: SettingValue, to capability: CapabilityDescriptor, using transport: any Transport) async throws {
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else {
            throw DriverError.invalidValue("cannot encode the value")
        }
        _ = try await run(["op": "write", "capability": capability.id, "json": text], transport: transport)
    }

    // MARK: Session

    private func run(_ request: [String: Any], transport: any Transport) async throws -> String {
        guard script.utf8.count <= Self.maxScriptBytes else { throw DriverError.deviceFailure("the plugin script is too large") }
        let session: any PluginHostSession
        do { session = try launcher.launch() } catch { throw DriverError.deviceFailure("could not start the plugin sandbox: \(error)") }
        defer { session.terminate() }
        let deadline = ContinuousClock.now + timeout

        func remaining() throws -> Duration {
            let left = deadline - .now
            guard left > .zero else { throw DriverError.deviceFailure("the plugin took too long") }
            return left
        }
        func next() async throws -> [String: Any] {
            let line: String
            do { line = try await session.receiveLine(timeout: try remaining()) }
            catch let error as DriverError { throw error }
            catch { throw DriverError.deviceFailure("the plugin host stopped: \(error)") }
            guard line.utf8.count <= Self.maxLineBytes, let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw DriverError.deviceFailure("the plugin host sent something unexpected")
            }
            return object
        }
        func send(_ object: [String: Any]) throws {
            guard let data = try? JSONSerialization.data(withJSONObject: object), let line = String(data: data, encoding: .utf8) else {
                throw DriverError.deviceFailure("could not encode a request for the plugin host")
            }
            do { try session.send(line) } catch { throw DriverError.deviceFailure("could not talk to the plugin host: \(error)") }
        }

        try send(["op": "load", "source": script, "limits": ["maxCalls": PluginBrokerPolicy.maxCallsPerRequest, "maxSeconds": 4.0]])
        let loaded = try await next()
        guard loaded["type"] as? String == "loaded" else { throw Self.failure(loaded) }
        try send(request)

        var calls = 0
        while true {
            let message = try await next()
            switch message["type"] as? String {
            case "log":
                logger("[\(pluginID)] \(String((message["message"] as? String ?? "").prefix(200)))")
            case "result":
                guard let json = message["json"] as? String else { throw DriverError.deviceFailure("the plugin host sent something unexpected") }
                return json
            case "error":
                throw Self.failure(message)
            case "hid":
                calls += 1
                guard calls <= PluginBrokerPolicy.maxCallsPerRequest else { throw PluginBrokerPolicy.violation("too many device calls in one request") }
                try send(try await serve(message, transport: transport, remaining: remaining))
            default:
                throw DriverError.deviceFailure("the plugin host sent something unexpected")
            }
        }
    }

    private static func failure(_ message: [String: Any]) -> DriverError {
        .deviceFailure("plugin error: \(String((message["message"] as? String ?? "unknown").prefix(200)))")
    }

    /// Checks one hid request against the policy and performs it. Violations throw (and so end the request); device
    /// errors are reported back to the script, which may handle them.
    private func serve(_ message: [String: Any], transport: any Transport, remaining: () throws -> Duration) async throws -> [String: Any] {
        func int(_ key: String) throws -> Int {
            guard let value = message[key] as? Int else { throw DriverError.deviceFailure("the plugin host sent something unexpected") }
            return value
        }
        func bytes() throws -> [Int] {
            guard let value = message["bytes"] as? [Int] else { throw DriverError.deviceFailure("the plugin host sent something unexpected") }
            return value
        }
        let call: PluginBrokerPolicy.Call
        switch message["call"] as? String {
        case "sendFeature": call = .sendFeature(reportID: try int("reportID"), bytes: try bytes())
        case "sendOutput": call = .sendOutput(reportID: try int("reportID"), bytes: try bytes())
        case "getFeature": call = .getFeature(reportID: try int("reportID"), length: try int("length"))
        case "nextInput": call = .nextInput(timeoutMs: try int("timeoutMs"))
        default: throw DriverError.deviceFailure("the plugin host sent something unexpected")
        }
        try policy.authorize(call)
        guard limiter.admit(isWrite: call.isWrite) else { throw PluginBrokerPolicy.violation("too many device calls per second") }

        do {
            switch call {
            case .sendFeature(let id, let data):
                try await transport.sendFeatureReport(reportID: UInt8(id), data.map(UInt8.init))
                return ["ok": true]
            case .sendOutput(let id, let data):
                try await transport.sendOutputReport(reportID: UInt8(id), data.map(UInt8.init))
                return ["ok": true]
            case .getFeature(let id, let length):
                let data = try await transport.getFeatureReport(reportID: UInt8(id), length: length)
                return ["ok": true, "bytes": data.prefix(PluginBrokerPolicy.maxBytesPerCall).map(Int.init)]
            case .nextInput(let timeoutMs):
                let end = ContinuousClock.now + .milliseconds(timeoutMs)
                // Reports whose id the plugin did not declare are dropped, not delivered.
                for _ in 0..<16 {
                    let wait = min(end - .now, try remaining())
                    guard wait > .zero else { break }
                    let report: (reportID: UInt8, data: [UInt8])
                    do { report = try await transport.nextInputReport(timeout: wait) }
                    catch let error as DriverError where "\(error)".contains("timed out") { break }
                    if policy.mayReceiveInput(reportID: report.reportID) {
                        return ["ok": true, "reportID": Int(report.reportID), "bytes": report.data.prefix(PluginBrokerPolicy.maxBytesPerCall).map(Int.init)]
                    }
                }
                return ["ok": true, "timeout": true]
            }
        } catch let error as DriverError {
            return ["ok": false, "error": String("\(error)".prefix(200))]
        }
    }
}
