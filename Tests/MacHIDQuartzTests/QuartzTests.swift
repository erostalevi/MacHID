import CoreGraphics
import Foundation
import Testing
import MacHIDApplication
import MacHIDDomain
@testable import MacHIDQuartz

@Suite struct ShellRunnerTests {
    @Test func reportsExitCodes() async {
        let runner = ProcessShellRunner()
        #expect(await runner.run("true", timeout: .seconds(5)) == ShellResult(exitCode: 0))
        #expect(await runner.run("exit 3", timeout: .seconds(5)) == ShellResult(exitCode: 3))
    }

    @Test func aHangingCommandIsKilledAtTheTimeout() async {
        let started = ContinuousClock.now
        let result = await ProcessShellRunner().run("sleep 30", timeout: .milliseconds(300))
        #expect(result.timedOut)
        #expect(started.duration(to: .now) < .seconds(10))
    }

    @Test func commandsCannotWaitForKeyboardInput() async {
        // `cat` would block forever on a terminal; with no input attached it ends at once.
        let result = await ProcessShellRunner().run("cat", timeout: .seconds(5))
        #expect(result == ShellResult(exitCode: 0))
    }

    @Test func noisyCommandsDoNotBlock() async {
        let result = await ProcessShellRunner().run("yes | head -c 5000000", timeout: .seconds(10))
        #expect(result == ShellResult(exitCode: 0))
    }

    @Test func theEnvironmentIsSmallAndFixed() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("machid-env-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        setenv("MACHID_TEST_SECRET", "leak", 1)
        _ = await ProcessShellRunner().run("env > '\(marker.path)'", timeout: .seconds(5))
        let env = try String(contentsOf: marker, encoding: .utf8)
        #expect(!env.contains("MACHID_TEST_SECRET") && env.contains("PATH="))
    }

    @Test func aMissingExecutableFailsWithoutCrashing() async {
        let result = await ProcessShellRunner().run("definitely-not-a-command-xyz", timeout: .seconds(5))
        #expect(result.exitCode != 0 && !result.timedOut)
    }
}

@Suite struct PosterMappingTests {
    @Test func modifiersConvertBothWays() {
        let all: Modifiers = [.shift, .control, .option, .command, .function]
        #expect(QuartzEventPoster.modifiers(from: QuartzEventPoster.flags(for: all)) == all)
        #expect(QuartzEventPoster.flags(for: []) == [])
        #expect(QuartzEventPoster.flags(for: [.command]).contains(.maskCommand))
        #expect(QuartzEventPoster.modifiers(from: [.maskAlternate, .maskShift]) == [.option, .shift])
    }

    @Test func mouseButtonsMapToQuartzTypes() {
        #expect(QuartzEventPoster.mouse(button: 0, down: true).0 == .leftMouseDown)
        #expect(QuartzEventPoster.mouse(button: 1, down: false).0 == .rightMouseUp)
        #expect(QuartzEventPoster.mouse(button: 4, down: true).0 == .otherMouseDown)
    }

    @Test func theMarkerIsNotAnOrdinaryValue() {
        #expect(QuartzEventPoster.marker != 0)
    }
}
