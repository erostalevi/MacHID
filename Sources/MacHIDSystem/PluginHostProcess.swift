import Foundation
import MacHIDApplication
import MacHIDDomain

/// Starts `MacHIDPluginHost` under `sandbox-exec` with a deny-default profile. There is no unsandboxed fallback:
/// if the sandbox or the host cannot be found, plugin drivers fail instead of running unconfined.
public struct SandboxedPluginHostLauncher: PluginHostLauncher {
    public struct Failure: Error, CustomStringConvertible { public let description: String }

    private let hostURL: URL?

    /// - Parameter hostURL: the `MacHIDPluginHost` executable; found next to the app when nil.
    public init(hostURL: URL? = nil) { self.hostURL = hostURL }

    public static func locateHost() -> URL? {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["MACHID_PLUGIN_HOST"] { candidates.append(URL(fileURLWithPath: override)) }
        if let dir = Bundle.main.executableURL?.deletingLastPathComponent() { candidates.append(dir.appendingPathComponent("MacHIDPluginHost")) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Reads: system libraries and the host binary only. No writes, no network, no other processes, no mach services.
    public static func profile(host: String) -> String {
        """
        (version 1)
        (deny default)
        (allow process-exec* (literal "\(host)"))
        (allow file-read* (subpath "/usr/lib") (subpath "/System/Library") (subpath "/System/Cryptexes") (literal "\(host)") (literal "/dev/null") (literal "/dev/urandom") (literal "/dev/random") (literal "/"))
        (allow file-read-metadata)
        (allow sysctl-read)
        """
    }

    public func launch() throws -> any PluginHostSession {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else { throw Failure(description: "sandbox-exec is not available") }
        guard let url = hostURL ?? Self.locateHost() else { throw Failure(description: "MacHIDPluginHost was not found") }
        // The sandbox matches real paths (/private/tmp, not /tmp), so resolve with realpath.
        guard let resolved = realpath(url.path, nil) else { throw Failure(description: "cannot resolve the host path") }
        defer { free(resolved) }
        let host = String(cString: resolved)
        guard !host.contains("\""), !host.contains("\\"), !host.contains("\n") else { throw Failure(description: "unsafe host path") }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", Self.profile(host: host), host]
        process.environment = ["JSC_useJIT": "false"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        return ProcessPluginHostSession(process: process, input: input.fileHandleForWriting, output: output.fileHandleForReading)
    }
}

final class ProcessPluginHostSession: PluginHostSession, @unchecked Sendable {
    private let process: Process
    private let input: FileHandle
    private let lock = NSLock()
    private var lines: [String] = []
    private var buffer = Data()
    private var finished = false
    private var oversized = false
    private static let maxLine = 16 * 1024

    init(process: Process, input: FileHandle, output: FileHandle) {
        self.process = process
        self.input = input
        Thread.detachNewThread { [weak self] in
            while true {
                let chunk = output.availableData
                guard let self else { return }
                if chunk.isEmpty { self.lock.lock(); self.finished = true; self.lock.unlock(); return }
                self.append(chunk)
            }
        }
    }

    private func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if line.count > Self.maxLine { oversized = true } else if let text = String(data: line, encoding: .utf8) { lines.append(text) }
        }
        if buffer.count > Self.maxLine { oversized = true; buffer.removeAll() }
    }

    func send(_ line: String) throws {
        try input.write(contentsOf: Data((line + "\n").utf8))
    }

    private enum Poll { case line(String), oversized, done, empty }

    private func poll() -> Poll {
        lock.lock(); defer { lock.unlock() }
        if oversized { return .oversized }
        if !lines.isEmpty { return .line(lines.removeFirst()) }
        return finished ? .done : .empty
    }

    func receiveLine(timeout: Duration) async throws -> String {
        let deadline = ContinuousClock.now + timeout
        while true {
            switch poll() {
            case .line(let line): return line
            case .oversized: throw DriverError.deviceFailure("the plugin host sent an oversized line")
            case .done: throw DriverError.deviceFailure("the plugin host exited")
            case .empty: break
            }
            if ContinuousClock.now >= deadline { throw DriverError.deviceFailure("the plugin took too long") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func terminate() {
        try? input.close()
        if process.isRunning { process.terminate(); kill(process.processIdentifier, SIGKILL) }
    }

    deinit { terminate() }
}
