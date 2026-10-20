import Foundation
import MacHIDDomain

// MARK: Ports

/// Sends synthetic keyboard and mouse events. Implemented with Quartz events in the app.
public protocol EventPoster: Sendable {
    func post(_ event: OutputEvent) async
    func type(_ text: String) async
}

public struct ShellResult: Equatable, Sendable {
    public var exitCode: Int32
    public var timedOut: Bool
    public init(exitCode: Int32, timedOut: Bool = false) {
        self.exitCode = exitCode
        self.timedOut = timedOut
    }
}

public protocol ShellRunner: Sendable {
    func run(_ command: String, timeout: Duration) async -> ShellResult
}

public protocol Launcher: Sendable {
    /// An app (bundle id), a URL or a file path. Returns whether something was opened.
    func open(_ target: String) async -> Bool
    func runShortcut(named name: String) async -> Bool
}

/// What a run leaves in the log. It never holds typed text, commands, URLs or paths.
public struct MacroLogEntry: Equatable, Sendable, Codable {
    public enum Outcome: Equatable, Sendable, Codable {
        case completed
        case refused(MacroRunner.Refusal)
        case failed(String)
        case cancelled
    }

    public var macroID: String
    public var macroName: String
    public var date: Date
    public var outcome: Outcome
    public var stepKinds: [String]
    public var shellExitCodes: [Int32]

    public init(macroID: String, macroName: String, date: Date, outcome: Outcome, stepKinds: [String], shellExitCodes: [Int32]) {
        self.macroID = macroID
        self.macroName = macroName
        self.date = date
        self.outcome = outcome
        self.stepKinds = stepKinds
        self.shellExitCodes = shellExitCodes
    }
}

public protocol MacroLog: Sendable {
    func record(_ entry: MacroLogEntry) async
}

// MARK: Safeguards

/// Advisory check that a shell command does not try to gain administrator rights. It catches the obvious forms only;
/// a determined author can disguise a command, so the real control is that the user reads the full command before
/// approving it. Shell macros also run without a terminal, so a password prompt can never be answered.
public enum ElevationGuard {
    private static let blocked: Set<String> = ["sudo", "doas", "su", "pkexec", "authopen"]

    public static func attemptsElevation(_ command: String) -> Bool {
        let lowered = command.lowercased()
        if lowered.contains("administrator privileges") { return true }
        let separators = CharacterSet(charactersIn: " \t\n\r;|&()`$<>{}\"'\\=")
        return lowered.components(separatedBy: separators).contains { word in
            blocked.contains(String(word.split(separator: "/").last ?? ""))
        }
    }
}

// MARK: Runner

/// Runs macros. Everything that could surprise the user is checked here, before any step runs.
public actor MacroRunner {
    public enum Refusal: String, Equatable, Sendable, Codable {
        case tooManySteps
        case tooLong
        case notApproved
        case shellDisabled
        case elevation
        case alreadyRunning
    }

    public static let maxTotalWait = Duration.seconds(300)
    public static let maxStepWait = Duration.seconds(60)
    public static let shellTimeout = Duration.seconds(10)

    private let poster: any EventPoster
    private let shell: any ShellRunner
    private let launcher: any Launcher
    private let log: any MacroLog
    private let fingerprint: @Sendable (Macro) -> String
    private let pause: @Sendable (Duration) async throws -> Void
    private var running: Set<String> = []
    private var cancelled = false

    public init(poster: any EventPoster, shell: any ShellRunner, launcher: any Launcher, log: any MacroLog,
                fingerprint: @escaping @Sendable (Macro) -> String,
                pause: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.poster = poster
        self.shell = shell
        self.launcher = launcher
        self.log = log
        self.fingerprint = fingerprint
        self.pause = pause
    }

    /// Stops running macros after their current step.
    public func cancelAll() { cancelled = true }

    @discardableResult
    public func run(_ macro: Macro, shellMacrosEnabled: Bool, now: Date = Date()) async -> MacroLogEntry.Outcome {
        var entry = MacroLogEntry(macroID: macro.id, macroName: macro.name, date: now, outcome: .completed,
                                  stepKinds: macro.steps.map(\.kindName), shellExitCodes: [])
        func finish(_ outcome: MacroLogEntry.Outcome) async -> MacroLogEntry.Outcome {
            entry.outcome = outcome
            await log.record(entry)
            return outcome
        }

        if let refusal = refusal(for: macro, shellMacrosEnabled: shellMacrosEnabled) { return await finish(.refused(refusal)) }
        // A Stop pressed for another macro must not be cleared by starting this one: reset only when nothing is running.
        if running.isEmpty { cancelled = false }
        running.insert(macro.id)
        defer { running.remove(macro.id) }

        for _ in 0..<max(1, min(macro.repeatCount, Macro.maxRepeat)) {
            for step in macro.steps {
                if cancelled { return await finish(.cancelled) }
                if let failure = await perform(step, codes: &entry.shellExitCodes) { return await finish(.failed(failure)) }
            }
        }
        return await finish(.completed)
    }

    private func refusal(for macro: Macro, shellMacrosEnabled: Bool) -> Refusal? {
        if running.contains(macro.id) { return .alreadyRunning }
        if macro.steps.count > Macro.maxSteps { return .tooManySteps }
        if totalWait(macro) > Self.maxTotalWait { return .tooLong }
        if macro.needsApproval, macro.approvedFingerprint != fingerprint(macro) { return .notApproved }
        if macro.usesShell, !shellMacrosEnabled { return .shellDisabled }
        for case .shell(let command) in macro.steps where ElevationGuard.attemptsElevation(command) { return .elevation }
        return nil
    }

    private func totalWait(_ macro: Macro) -> Duration {
        let once = macro.steps.reduce(Duration.zero) { total, step in
            if case .wait(let milliseconds) = step { return total + .milliseconds(max(0, min(milliseconds, 3_600_000))) }
            return total
        }
        return once * max(1, min(macro.repeatCount, Macro.maxRepeat))
    }

    /// Returns a failure message, or nil when the step worked.
    private func perform(_ step: MacroStep, codes: inout [Int32]) async -> String? {
        switch step {
        case .key(let code, let modifiers):
            await poster.post(.key(code: code, modifiers: modifiers, down: true))
            await poster.post(.key(code: code, modifiers: modifiers, down: false))
        case .text(let text):
            // Typed in small pieces so Stop can interrupt a long text.
            var rest = Substring(text.prefix(Macro.maxTextLength))
            while !rest.isEmpty {
                if cancelled { return "stopped" }
                let piece = rest.prefix(40)
                await poster.type(String(piece))
                rest = rest.dropFirst(piece.count)
            }
        case .mouseClick(let button):
            await poster.post(.mouse(button: button, down: true))
            await poster.post(.mouse(button: button, down: false))
        case .wait(let milliseconds):
            let wait = min(Duration.milliseconds(max(0, milliseconds)), Self.maxStepWait)
            do { try await pause(wait) } catch { return "interrupted" }
        case .open(let target):
            if !(await launcher.open(target)) { return "could not open the target" }
        case .shortcut(let name):
            if !(await launcher.runShortcut(named: name)) { return "the shortcut did not run" }
        case .shell(let command):
            let result = await shell.run(command, timeout: Self.shellTimeout)
            codes.append(result.exitCode)
            if result.timedOut { return "the command timed out" }
            if result.exitCode != 0 { return "the command exited with status \(result.exitCode)" }
        }
        return nil
    }
}
