import Foundation
import MacHIDApplication

/// Runs a shell command for a macro: no terminal input, a small fixed environment, output discarded beyond a
/// cap, and a hard timeout. Elevation attempts are refused earlier, by `ElevationGuard`.
public struct ProcessShellRunner: ShellRunner {
    public static let outputLimit = 64 * 1024

    public init() {}

    public func run(_ command: String, timeout: Duration) async -> ShellResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            process.standardInput = FileHandle.nullDevice
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            let home = NSHomeDirectory()
            process.environment = ["PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                                   "HOME": home, "LANG": "en_US.UTF-8", "USER": NSUserName()]
            process.currentDirectoryURL = URL(fileURLWithPath: home)

            let state = RunState()
            // Drain the pipe so a chatty command cannot block on a full buffer; keep only the first bytes.
            output.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                state.append(data.count)
            }
            process.terminationHandler = { finished in
                output.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: ShellResult(exitCode: finished.terminationStatus, timedOut: state.timedOut))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: ShellResult(exitCode: 127))
                return
            }
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                guard process.isRunning else { return }
                state.markTimedOut()
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            }
        }
    }

    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = 0
        private var timeout = false
        var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return timeout }
        func markTimedOut() { lock.lock(); timeout = true; lock.unlock() }
        func append(_ count: Int) { lock.lock(); bytes = min(bytes + count, ProcessShellRunner.outputLimit); lock.unlock() }
    }
}
