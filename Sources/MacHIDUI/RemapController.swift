import Foundation
import Observation
import AppKit
import MacHIDApplication
import MacHIDDomain
import MacHIDQuartz
import MacHIDSystem

/// What the controller needs from an event tap, so tests can use a fake one.
public protocol EventTapping: AnyObject, Sendable {
    func start() -> Bool
    func stop()
    var isRunning: Bool { get }
}

extension RemapEventTap: EventTapping {}

/// Thread-safe holder: the event tap asks the engine from the main run loop while settings change from actors.
final class LockedEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var engine = RemapEngine()
    private var frontmost: String?

    func update(config: RemapConfig) -> [OutputEvent] { lock.lock(); defer { lock.unlock() }; return engine.update(config: config) }
    func setFrontmost(_ id: String?) { lock.lock(); frontmost = id; lock.unlock() }
    func decide(_ event: InputEvent) -> RemapDecision {
        lock.lock(); defer { lock.unlock() }
        return engine.decide(event, frontmostBundleID: frontmost)
    }
}

/// Owns remapping and macros: the saved configuration, the permissions, the event tap and the macro runner.
@MainActor
@Observable
public final class RemapController {
    public private(set) var config = RemapConfig()
    public private(set) var inputMonitoringGranted = false
    public private(set) var accessibilityGranted = false
    public private(set) var isActive = false
    public private(set) var recentRuns: [MacroLogEntry] = []
    public var banner: String?

    @ObservationIgnored private let repository: any RemapRepository
    @ObservationIgnored private let runner: MacroRunner
    @ObservationIgnored private let logReader: @Sendable () async -> [MacroLogEntry]
    @ObservationIgnored private let fingerprint: @Sendable (Macro) -> String
    @ObservationIgnored private let permissionCheck: @Sendable () -> (inputMonitoring: Bool, accessibility: Bool)
    @ObservationIgnored private let engine = LockedEngine()
    @ObservationIgnored private var tap: (any EventTapping)?
    @ObservationIgnored private let makeTap: @MainActor (@escaping @Sendable (InputEvent) -> RemapDecision, @escaping @Sendable (String) -> Void) -> any EventTapping
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private let permissionPoll: Duration
    @ObservationIgnored private let poster: (any EventPoster)?

    public init(repository: any RemapRepository, runner: MacroRunner,
                fingerprint: @escaping @Sendable (Macro) -> String,
                logReader: @escaping @Sendable () async -> [MacroLogEntry] = { [] },
                permissionCheck: @escaping @Sendable () -> (inputMonitoring: Bool, accessibility: Bool) = { (RemapPermissions.inputMonitoring, RemapPermissions.accessibility) },
                permissionPoll: Duration = .seconds(2),
                poster: (any EventPoster)? = nil,
                makeTap: @escaping @MainActor (@escaping @Sendable (InputEvent) -> RemapDecision, @escaping @Sendable (String) -> Void) -> any EventTapping) {
        self.repository = repository
        self.runner = runner
        self.fingerprint = fingerprint
        self.logReader = logReader
        self.permissionCheck = permissionCheck
        self.permissionPoll = permissionPoll
        self.poster = poster
        self.makeTap = makeTap
    }

    // MARK: Lifecycle

    /// Design review only: shows sample rules and macros without touching the keyboard.
    func setPreview(config: RemapConfig, runs: [MacroLogEntry]) {
        self.config = config
        self.recentRuns = runs
        self.inputMonitoringGranted = true
        self.accessibilityGranted = false
    }

    public func load() async {
        config = (try? await repository.load()) ?? RemapConfig()
        _ = engine.update(config: config)
        refreshPermissions()
        recentRuns = await logReader()
        await reconcile()
    }

    public func frontmostAppChanged(_ bundleID: String?) { engine.setFrontmost(bundleID) }

    private func refreshPermissions() {
        let status = permissionCheck()
        inputMonitoringGranted = status.inputMonitoring
        accessibilityGranted = status.accessibility
    }

    /// Starts or stops the event tap to match the master switch and the permissions. While the switch is on but
    /// a permission is missing it keeps checking, so remapping starts as soon as the user grants it.
    private func reconcile() async {
        watchTask?.cancel()
        watchTask = nil
        guard config.enabled else { stopTap(); return }
        refreshPermissions()
        if inputMonitoringGranted && accessibilityGranted { startTap(); return }
        stopTap()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.permissionPoll ?? .seconds(2))
                guard let self else { return }
                self.refreshPermissions()
                if self.inputMonitoringGranted && self.accessibilityGranted, self.config.enabled { self.startTap(); return }
            }
        }
    }

    private func startTap() {
        if tap == nil {
            tap = makeTap({ [engine] in engine.decide($0) }, { [weak self] id in
                Task { @MainActor in await self?.run(macroID: id) }
            })
        }
        isActive = tap?.start() ?? false
        if !isActive { banner = "Remapping could not start. Check the Input Monitoring and Accessibility permissions." }
    }

    private func stopTap() {
        tap?.stop()
        isActive = false
    }

    // MARK: Editing (every change is saved and reaches the engine at once)

    private func update(_ change: (inout RemapConfig) -> Void) async {
        var copy = config
        change(&copy)
        config = copy
        for event in engine.update(config: copy) { await poster?.post(event) }
        do { try await repository.save(copy) } catch { banner = "Could not save remap settings: \(error)" }
    }

    public func setEnabled(_ enabled: Bool) async {
        await update { $0.enabled = enabled }
        await reconcile()
    }

    public func setShellMacrosEnabled(_ enabled: Bool) async { await update { $0.shellMacrosEnabled = enabled } }

    public func upsertRule(_ rule: RemapRule) async { await update { $0 = $0.upserting(rule) } }
    public func removeRule(_ id: String) async { await update { $0.rules.removeAll { $0.id == id } } }
    public func setRule(_ id: String, enabled: Bool) async {
        await update { if let index = $0.rules.firstIndex(where: { $0.id == id }) { $0.rules[index].enabled = enabled } }
    }

    /// Saves a macro. Its approval stays attached, but only counts while the steps are unchanged.
    public func saveMacro(_ macro: Macro) async {
        await update { config in
            if let index = config.macros.firstIndex(where: { $0.id == macro.id }) { config.macros[index] = macro } else { config.macros.append(macro) }
        }
    }

    public func deleteMacro(_ id: String) async { await update { $0 = $0.removingMacro(id: id) } }

    public func isApproved(_ macro: Macro) -> Bool {
        !macro.needsApproval || macro.approvedFingerprint == fingerprint(macro)
    }

    /// Records the user's approval of exactly these steps.
    public func approve(_ macroID: String) async {
        await update { config in
            guard let index = config.macros.firstIndex(where: { $0.id == macroID }) else { return }
            config.macros[index].approvedFingerprint = fingerprint(config.macros[index])
        }
    }

    // MARK: Import and export

    /// Macros are exported without any approval. Importing never carries trust over: the macros arrive unapproved,
    /// with fresh ids so they cannot replace the user's own.
    public func exportMacros(ids: [String]) -> Data? {
        var shared = config.macros.filter { ids.contains($0.id) }
        for index in shared.indices { shared[index].approvedFingerprint = nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(shared)
    }

    @discardableResult
    public func importMacros(from data: Data) async -> Int {
        guard let macros = try? JSONDecoder().decode([Macro].self, from: data) else {
            banner = "That file is not a MacHID macro export."
            return 0
        }
        let fresh = macros.prefix(50).map { macro in
            Macro(id: UUID().uuidString, name: String(macro.name.prefix(80)), steps: macro.steps, repeatCount: macro.repeatCount,
                  approvedFingerprint: nil, imported: true).clamped()
        }
        await update { $0.macros.append(contentsOf: fresh) }
        return fresh.count
    }

    // MARK: Running

    public func run(macroID: String) async {
        guard let macro = config.macro(id: macroID) else { return }
        let outcome = await runner.run(macro, shellMacrosEnabled: config.shellMacrosEnabled)
        recentRuns = await logReader()
        if case .refused(let reason) = outcome { banner = "“\(macro.name)” did not run: \(Self.describe(reason))" }
        if case .failed(let message) = outcome { banner = "“\(macro.name)” stopped: \(message)" }
    }

    public func stopMacros() async { await runner.cancelAll() }

    static func describe(_ reason: MacroRunner.Refusal) -> String {
        switch reason {
        case .tooManySteps: "it has too many steps"
        case .tooLong: "its waits add up to too long"
        case .notApproved: "it needs your approval first"
        case .shellDisabled: "shell macros are switched off"
        case .elevation: "it tries to gain administrator rights"
        case .alreadyRunning: "it is already running"
        }
    }

    public func requestPermissions() { RemapPermissions.request() }
}

extension RemapController {
    /// The real controller: Quartz tap and poster, shell runner, launcher, files in Application Support.
    public static func live() -> RemapController {
        let log = FileMacroLog()
        let runner = MacroRunner(poster: QuartzEventPoster(), shell: ProcessShellRunner(), launcher: WorkspaceLauncher(),
                                 log: log, fingerprint: MacroFingerprint.of)
        let controller = RemapController(repository: FileRemapRepository(), runner: runner, fingerprint: MacroFingerprint.of,
                                         logReader: { await log.entries() }, poster: QuartzEventPoster(),
                                         makeTap: { handler, runMacro in RemapEventTap(handler: handler, runMacro: runMacro) })
        // Keep the engine's idea of the frontmost app current for app-scoped rules.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak controller] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor in controller?.frontmostAppChanged(id) }
        }
        controller.frontmostAppChanged(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        return controller
    }
}
