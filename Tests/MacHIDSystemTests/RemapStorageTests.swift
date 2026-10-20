import CryptoKit
import Foundation
import Testing
import MacHIDApplication
import MacHIDDomain
@testable import MacHIDSystem

private func tempURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("machid-\(UUID().uuidString)").appendingPathComponent(name)
}

@Suite struct FingerprintTests {
    @Test func isStableAndSensitiveToEveryStep() {
        let macro = Macro(id: "m", name: "M", steps: [.shell("echo a"), .text("t")], repeatCount: 2)
        #expect(MacroFingerprint.of(macro) == MacroFingerprint.of(macro))
        var edited = macro; edited.steps[0] = .shell("echo b")
        #expect(MacroFingerprint.of(edited) != MacroFingerprint.of(macro))
        var repeated = macro; repeated.repeatCount = 3
        #expect(MacroFingerprint.of(repeated) != MacroFingerprint.of(macro))
        var renamed = macro; renamed.name = "Other"
        #expect(MacroFingerprint.of(renamed) == MacroFingerprint.of(macro))        // a name change does not change what it does
        #expect(MacroFingerprint.of(macro).count == 64)
    }

    @Test func approvalSurvivesOnlyUntouchedSteps() {
        let macro = MacroFingerprint.approving(Macro(id: "m", name: "M", steps: [.open("https://example.com")]))
        #expect(macro.approvedFingerprint == MacroFingerprint.of(macro))
        var edited = macro; edited.steps = [.open("https://example.org")]
        #expect(edited.approvedFingerprint != MacroFingerprint.of(edited))
    }
}

@Suite struct RemapRepositoryTests {
    @Test func savesAndLoadsAndStartsEmpty() async throws {
        let repository = FileRemapRepository(url: tempURL("remap.json"))
        #expect(try await repository.load() == RemapConfig())
        var config = RemapConfig()
        config.enabled = true
        config.macros = [Macro(id: "m", name: "M", steps: [.wait(milliseconds: 10)])]
        config.rules = [RemapRule(id: "r", trigger: InputTrigger(kind: .keyboard, code: 5), action: .macro("m"))]
        try await repository.save(config)
        #expect(try await repository.load() == config)
    }

    @Test func aFileFromANewerVersionIsIgnored() async throws {
        let url = tempURL("remap.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"schemaVersion": 99, "enabled": true, "shellMacrosEnabled": true, "rules": [], "macros": []}"#.utf8).write(to: url)
        #expect(try await FileRemapRepository(url: url).load() == RemapConfig())
    }
}

@Suite struct MacroLogTests {
    @Test func recordsRunsWithoutTheirContent() async {
        let log = FileMacroLog(url: tempURL("log.jsonl"))
        await log.record(MacroLogEntry(macroID: "m", macroName: "Backup", date: Date(), outcome: .failed("the command exited with status 2"),
                                       stepKinds: ["text", "shell"], shellExitCodes: [2]))
        await log.record(MacroLogEntry(macroID: "n", macroName: "Open", date: Date(), outcome: .refused(.notApproved), stepKinds: ["open"], shellExitCodes: []))
        let entries = await log.entries()
        #expect(entries.map(\.macroName) == ["Backup", "Open"])
        #expect(entries[1].outcome == .refused(.notApproved) && entries[0].shellExitCodes == [2])
    }

    @Test func rotatesWhenItGrowsTooLarge() async throws {
        let url = tempURL("log.jsonl")
        let log = FileMacroLog(url: url, maxBytes: 600)
        for index in 0..<20 {
            await log.record(MacroLogEntry(macroID: "m\(index)", macroName: "Macro \(index)", date: Date(), outcome: .completed, stepKinds: ["key"], shellExitCodes: []))
        }
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("old").path))
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(size < 1500)
    }
}

@Test func approvalDependsOnTheKey() {
    let macro = Macro(id: "m", name: "M", steps: [.shell("echo hi")])
    let original = MacroFingerprint.key
    defer { MacroFingerprint.key = original }
    let first = MacroFingerprint.of(macro)
    MacroFingerprint.key = SymmetricKey(data: Data(repeating: 7, count: 32))
    #expect(MacroFingerprint.of(macro) != first)          // a forged hash without the key does not verify
    #expect(MacroFingerprint.of(macro).count == 64)
}
