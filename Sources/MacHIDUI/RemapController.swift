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
    private var lastModes: Set<String> = []
    /// Called (outside the lock) whenever the set of active shift modes changes.
    var onModesChanged: (@Sendable (Set<String>) -> Void)?

    func update(config: RemapConfig) -> [OutputEvent] {
        lock.lock()
        let releases = engine.update(config: config)
        let changed = modesChange()
        lock.unlock()
        if let changed { onModesChanged?(changed) }
        return releases
    }

    func reset() -> [OutputEvent] {
        lock.lock()
        let releases = engine.resetTransientState()
        let changed = modesChange()
        lock.unlock()
        if let changed { onModesChanged?(changed) }
        return releases
    }

    func setFrontmost(_ id: String?) { lock.lock(); frontmost = id; lock.unlock() }

    func decide(_ event: InputEvent) -> RemapDecision {
        lock.lock()
        let decision = engine.decide(event, frontmostBundleID: frontmost)
        let changed = modesChange()
        lock.unlock()
        if let changed { onModesChanged?(changed) }
        return decision
    }

    var wantsPointerMotion: Bool { lock.lock(); defer { lock.unlock() }; return engine.wantsPointerMotion }

    func decideMotion(dx: Double, dy: Double) -> MotionDecision {
        lock.lock()
        let decision = engine.decideMotion(dx: dx, dy: dy)
        lock.unlock()
        return decision
    }

    /// Must be called with the lock held.
    private func modesChange() -> Set<String>? {
        let now = engine.activeShiftModeIDs
        guard now != lastModes else { return nil }
        lastModes = now
        return now
    }
}

/// Lets the event tap factory (built before the controller exists) reach the engine's pointer-motion logic. The controller
/// fills it in when the tap starts, and only when shift gestures exist, so plain remapping never watches pointer movement.
public final class MotionHook: @unchecked Sendable {
    public var handler: RemapEventTap.MotionHandler?
    public init() {}
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
    public private(set) var isRunning = false
    /// Shift modes that are active right now (updated on the main actor as the user holds or toggles triggers).
    public private(set) var activeShiftModes: Set<String> = []
    /// The app wires these: a rule asked for a profile by id, or for the next (+1) / previous (-1) one.
    @ObservationIgnored public var onSwitchProfile: (@MainActor (String) -> Void)?
    @ObservationIgnored public var onCycleProfile: (@MainActor (Int) -> Void)?
    /// Lets a lighting controller react to layers; receives the full set of active mode ids.
    @ObservationIgnored public var onShiftModesChanged: ((Set<String>) -> Void)?
    /// Macros pinned to the menu bar panel; kept in UserDefaults.
    public private(set) var favoriteMacroIDs: [String] = UserDefaults.standard.stringArray(forKey: RemapController.favoritesKey) ?? []
    static let favoritesKey = "macros.favorites"
    private var runningCount = 0

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
    @ObservationIgnored private let motionHook: MotionHook
    @ObservationIgnored private var tapWatchesMotion = false

    public init(repository: any RemapRepository, runner: MacroRunner,
                fingerprint: @escaping @Sendable (Macro) -> String,
                logReader: @escaping @Sendable () async -> [MacroLogEntry] = { [] },
                permissionCheck: @escaping @Sendable () -> (inputMonitoring: Bool, accessibility: Bool) = { (RemapPermissions.inputMonitoring, RemapPermissions.accessibility) },
                permissionPoll: Duration = .seconds(2),
                poster: (any EventPoster)? = nil,
                motionHook: MotionHook = MotionHook(),
                makeTap: @escaping @MainActor (@escaping @Sendable (InputEvent) -> RemapDecision, @escaping @Sendable (String) -> Void) -> any EventTapping) {
        self.repository = repository
        self.runner = runner
        self.fingerprint = fingerprint
        self.logReader = logReader
        self.permissionCheck = permissionCheck
        self.permissionPoll = permissionPoll
        self.poster = poster
        self.motionHook = motionHook
        self.makeTap = makeTap
        engine.onModesChanged = { [weak self] ids in
            Task { @MainActor in self?.shiftModesChanged(ids) }
        }
    }

    private func shiftModesChanged(_ ids: Set<String>) {
        guard ids != activeShiftModes else { return }
        activeShiftModes = ids
        onShiftModesChanged?(ids)
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
            tapWatchesMotion = engine.wantsPointerMotion
            let locked = engine
            if tapWatchesMotion {
                motionHook.handler = { (dx: Double, dy: Double) -> MotionDecision in locked.decideMotion(dx: dx, dy: dy) }
            } else {
                motionHook.handler = nil
            }
            tap = makeTap({ [engine, weak self] event in
                // Profile switches are carried out here, on the main actor; the tap just swallows the key.
                switch engine.decide(event) {
                case .switchProfile(let id):
                    Task { @MainActor in self?.onSwitchProfile?(id) }
                    return .suppress
                case .cycleProfile(let step):
                    Task { @MainActor in self?.onCycleProfile?(step) }
                    return .suppress
                case let decision: return decision
                }
            }, { [weak self] id in
                Task { @MainActor in await self?.run(macroID: id) }
            })
        }
        isActive = tap?.start() ?? false
        if !isActive { banner = "Remapping could not start. Check the Input Monitoring and Accessibility permissions." }
    }

    private func stopTap() {
        tap?.stop()
        isActive = false
        // A mode held or toggled when the tap stops must not stay on.
        let releases = engine.reset()
        if !releases.isEmpty { Task { for event in releases { await poster?.post(event) } } }
    }

    // MARK: Editing (every change is saved and reaches the engine at once)

    private func update(_ change: (inout RemapConfig) -> Void) async {
        var copy = config
        change(&copy)
        config = copy
        for event in engine.update(config: copy) { await poster?.post(event) }
        // The tap watches pointer movement only while shift gestures exist: restart it when that changes.
        if isActive, engine.wantsPointerMotion != tapWatchesMotion { stopTap(); tap = nil; startTap() }
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

    // MARK: Shift modes

    /// Adds or replaces a mode. Refused (with a banner) for triggers that could lock the user out: left/right clicks and Escape.
    @discardableResult
    public func upsertShiftMode(_ mode: ShiftMode) async -> Bool {
        guard mode.hasAllowedTrigger else {
            banner = "That key or button cannot be a shift trigger."
            return false
        }
        var clean = mode
        clean.name = String(mode.name.prefix(60))
        await update { $0 = $0.upsertingShiftMode(clean) }
        return true
    }

    @discardableResult public func addShiftMode(_ mode: ShiftMode) async -> Bool { await upsertShiftMode(mode) }
    @discardableResult public func updateShiftMode(_ mode: ShiftMode) async -> Bool { await upsertShiftMode(mode) }

    /// Removes the mode and every rule that needs it or toggles it.
    public func removeShiftMode(_ id: String) async { await update { $0 = $0.removingShiftMode(id: id) } }

    /// Adds or replaces a shift gesture. Same forbidden triggers as shift modes.
    @discardableResult
    public func upsertGesture(_ gesture: ShiftGesture) async -> Bool {
        guard gesture.hasAllowedTrigger else {
            banner = "That key or button cannot be a gesture trigger."
            return false
        }
        var clean = gesture
        clean.name = String(gesture.name.prefix(60))
        await update { $0 = $0.upsertingGesture(clean) }
        return true
    }

    public func removeGesture(_ id: String) async { await update { $0 = $0.removingGesture(id: id) } }

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
        runningCount += 1
        isRunning = true
        defer { runningCount -= 1; isRunning = runningCount > 0 }
        let outcome = await runner.run(macro, shellMacrosEnabled: config.shellMacrosEnabled)
        recentRuns = await logReader()
        if case .refused(let reason) = outcome { banner = "“\(macro.name)” did not run: \(Self.describe(reason))" }
        if case .failed(let message) = outcome { banner = "“\(macro.name)” stopped: \(message)" }
    }

    public func toggleFavorite(_ macroID: String) {
        if let index = favoriteMacroIDs.firstIndex(of: macroID) { favoriteMacroIDs.remove(at: index) } else { favoriteMacroIDs.append(macroID) }
        UserDefaults.standard.set(favoriteMacroIDs, forKey: Self.favoritesKey)
    }

    public func isFavorite(_ macroID: String) -> Bool { favoriteMacroIDs.contains(macroID) }

    /// Favorites that still exist, in the order they were starred.
    public var favoriteMacros: [Macro] { favoriteMacroIDs.compactMap { config.macro(id: $0) } }

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
        let hook = MotionHook()
        let controller = RemapController(repository: FileRemapRepository(), runner: runner, fingerprint: MacroFingerprint.of,
                                         logReader: { await log.entries() }, poster: QuartzEventPoster(), motionHook: hook,
                                         makeTap: { handler, runMacro in RemapEventTap(handler: handler, runMacro: runMacro, motion: hook.handler) })
        // Keep the engine's idea of the frontmost app current for app-scoped rules.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak controller] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor in controller?.frontmostAppChanged(id) }
        }
        controller.frontmostAppChanged(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        return controller
    }
}
