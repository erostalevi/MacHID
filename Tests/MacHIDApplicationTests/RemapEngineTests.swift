import Foundation
import Testing
import MacHIDDomain
@testable import MacHIDApplication

private let keyA = 0, keyB = 11, keyF5 = 96

private func engine(_ rules: [RemapRule], enabled: Bool = true) -> RemapEngine {
    var config = RemapConfig()
    config.enabled = enabled
    config.rules = rules
    return RemapEngine(config: config)
}

private func key(_ code: Int, down: Bool, modifiers: Modifiers = [], isRepeat: Bool = false) -> InputEvent {
    InputEvent(kind: .keyboard, code: code, modifiers: modifiers, isDown: down, isRepeat: isRepeat)
}

private func rule(_ id: String, from trigger: InputTrigger, to action: RemapAction, app: String? = nil) -> RemapRule {
    RemapRule(id: id, trigger: trigger, action: action, appBundleID: app)
}

@Suite struct RemapEngineTests {
    @Test func unmappedEventsPassThrough() {
        var engine = engine([rule("r", from: .init(kind: .keyboard, code: keyA), to: .key(code: keyB, modifiers: []))])
        #expect(engine.decide(key(5, down: true), frontmostBundleID: nil) == .passthrough)
        #expect(engine.decide(key(5, down: false), frontmostBundleID: nil) == .passthrough)
    }

    @Test func aKeyBecomesAnotherAndItsReleaseFollows() {
        var engine = engine([rule("r", from: .init(kind: .keyboard, code: keyA), to: .key(code: keyB, modifiers: [.shift]))])
        #expect(engine.decide(key(keyA, down: true), frontmostBundleID: nil) == .emit([.key(code: keyB, modifiers: [.shift], down: true)]))
        #expect(engine.decide(key(keyA, down: true, isRepeat: true), frontmostBundleID: nil) == .emit([.key(code: keyB, modifiers: [.shift], down: true)]))
        #expect(engine.decide(key(keyA, down: false), frontmostBundleID: nil) == .emit([.key(code: keyB, modifiers: [.shift], down: false)]))
        #expect(engine.decide(key(keyA, down: false), frontmostBundleID: nil) == .passthrough)       // nothing left pressed
    }

    @Test func modifiersMustMatchExactly() {
        var engine = engine([rule("r", from: .init(kind: .keyboard, code: keyA, modifiers: [.command]), to: .disable)])
        #expect(engine.decide(key(keyA, down: true), frontmostBundleID: nil) == .passthrough)
        #expect(engine.decide(key(keyA, down: false), frontmostBundleID: nil) == .passthrough)
        #expect(engine.decide(key(keyA, down: true, modifiers: [.command, .shift]), frontmostBundleID: nil) == .passthrough)
        #expect(engine.decide(key(keyA, down: false), frontmostBundleID: nil) == .passthrough)
        #expect(engine.decide(key(keyA, down: true, modifiers: [.command]), frontmostBundleID: nil) == .suppress)
    }

    @Test func releaseIsPairedEvenIfTheModifierWasReleasedFirst() {
        var engine = engine([rule("r", from: .init(kind: .keyboard, code: keyA, modifiers: [.command]), to: .key(code: keyB, modifiers: []))])
        _ = engine.decide(key(keyA, down: true, modifiers: [.command]), frontmostBundleID: nil)
        // The user lifted ⌘ before A: the release arrives without the modifier but must still end the remapped press.
        #expect(engine.decide(key(keyA, down: false), frontmostBundleID: nil) == .emit([.key(code: keyB, modifiers: [], down: false)]))
    }

    @Test func appSpecificRulesWinAndOthersFallBack() {
        let trigger = InputTrigger(kind: .keyboard, code: keyF5)
        var engine = engine([rule("global", from: trigger, to: .key(code: 1, modifiers: [])),
                             rule("scoped", from: trigger, to: .key(code: 2, modifiers: []), app: "com.game")])
        #expect(engine.decide(key(keyF5, down: true), frontmostBundleID: "com.game") == .emit([.key(code: 2, modifiers: [], down: true)]))
        _ = engine.decide(key(keyF5, down: false), frontmostBundleID: "com.game")
        #expect(engine.decide(key(keyF5, down: true), frontmostBundleID: "com.other") == .emit([.key(code: 1, modifiers: [], down: true)]))
        _ = engine.decide(key(keyF5, down: false), frontmostBundleID: "com.other")
        #expect(engine.decide(key(keyF5, down: true), frontmostBundleID: nil) == .emit([.key(code: 1, modifiers: [], down: true)]))
    }

    @Test func macroRunsOnceEvenWhenTheKeyIsHeld() {
        var engine = engine([rule("r", from: .init(kind: .keyboard, code: keyF5), to: .macro("m1"))])
        #expect(engine.decide(key(keyF5, down: true), frontmostBundleID: nil) == .runMacro("m1"))
        #expect(engine.decide(key(keyF5, down: true, isRepeat: true), frontmostBundleID: nil) == .suppress)
        #expect(engine.decide(key(keyF5, down: false), frontmostBundleID: nil) == .suppress)
    }

    @Test func disabledRulesAndAnOffMasterSwitchDoNothing() {
        var rule = rule("r", from: .init(kind: .keyboard, code: keyA), to: .disable)
        rule.enabled = false
        var off = engine([rule])
        #expect(off.decide(key(keyA, down: true), frontmostBundleID: nil) == .passthrough)
        rule.enabled = true
        var masterOff = engine([rule], enabled: false)
        #expect(masterOff.decide(key(keyA, down: true), frontmostBundleID: nil) == .passthrough)
    }

    @Test func mouseButtonsAndKeysAreSeparateNamespaces() {
        var engine = engine([rule("r", from: .init(kind: .mouseButton, code: 3), to: .key(code: keyB, modifiers: [.command]))])
        #expect(engine.decide(key(3, down: true), frontmostBundleID: nil) == .passthrough)           // key code 3 is not button 3
        let button = InputEvent(kind: .mouseButton, code: 3, isDown: true)
        #expect(engine.decide(button, frontmostBundleID: nil) == .emit([.key(code: keyB, modifiers: [.command], down: true)]))
        var release = button; release.isDown = false
        #expect(engine.decide(release, frontmostBundleID: nil) == .emit([.key(code: keyB, modifiers: [.command], down: false)]))
    }

    @Test func updatingTheConfigDropsStalePresses() {
        var engine = engine([rule("r", from: .init(kind: .keyboard, code: keyA), to: .disable)])
        _ = engine.decide(key(keyA, down: true), frontmostBundleID: nil)
        engine.update(config: RemapConfig())
        #expect(engine.decide(key(keyA, down: false), frontmostBundleID: nil) == .passthrough)
    }

    @Test func configHelpersKeepOneRulePerTriggerAndCleanMacros() {
        let trigger = InputTrigger(kind: .keyboard, code: keyA)
        var config = RemapConfig().upserting(rule("r1", from: trigger, to: .disable)).upserting(rule("r2", from: trigger, to: .macro("m")))
        #expect(config.rules.map(\.id) == ["r2"])
        config = config.upserting(rule("r3", from: trigger, to: .disable, app: "com.app"))
        #expect(config.rules.count == 2)                                   // a different app scope is a different rule
        config.macros = [Macro(id: "m", name: "M", steps: [])]
        let cleaned = config.removingMacro(id: "m")
        #expect(cleaned.macros.isEmpty && cleaned.rules.map(\.id) == ["r3"])
    }

    @Test func configRoundTripsThroughJSON() throws {
        var config = RemapConfig().upserting(rule("r", from: .init(kind: .keyboard, code: keyA, modifiers: [.command, .shift]), to: .key(code: keyB, modifiers: [.option])))
        config.macros = [Macro(id: "m", name: "Greeting", steps: [.text("hi"), .wait(milliseconds: 50), .shell("echo ok"), .key(code: 36, modifiers: [])], repeatCount: 2)]
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(RemapConfig.self, from: data) == config)
        #expect(!config.enabled)                                           // off until the user turns it on
    }
}

// MARK: Shift modes

private let modeA = ShiftMode(id: "A", name: "A", trigger: .init(kind: .keyboard, code: 63), behavior: .hold)          // fn
private let modeB = ShiftMode(id: "B", name: "B", trigger: .init(kind: .mouseButton, code: 3), behavior: .toggle)
private let keyF1 = 122

private func layered(_ modes: [ShiftMode], _ rules: [RemapRule]) -> RemapEngine {
    var config = RemapConfig()
    config.enabled = true
    config.shiftModes = modes
    config.rules = rules
    return RemapEngine(config: config)
}

private func mouse(_ code: Int, down: Bool) -> InputEvent { InputEvent(kind: .mouseButton, code: code, isDown: down) }

private func layerRule(_ id: String, _ code: Int, to out: Int, modes: [String], app: String? = nil) -> RemapRule {
    RemapRule(id: id, trigger: .init(kind: .keyboard, code: code), action: .key(code: out, modifiers: []), appBundleID: app, shiftModeIDs: modes)
}

private func down(_ out: Int) -> RemapDecision { .emit([.key(code: out, modifiers: [], down: true)]) }
private func up(_ out: Int) -> RemapDecision { .emit([.key(code: out, modifiers: [], down: false)]) }

@Suite struct ShiftModeTests {
    @Test func holdModeIsActiveOnlyWhileTheTriggerIsDown() {
        var e = layered([modeA], [layerRule("r", keyA, to: keyB, modes: ["A"])])
        #expect(e.decide(key(keyA, down: true), frontmostBundleID: nil) == .passthrough)
        _ = e.decide(key(keyA, down: false), frontmostBundleID: nil)
        #expect(e.decide(key(63, down: true), frontmostBundleID: nil) == .suppress)       // trigger is consumed
        #expect(e.activeShiftModeIDs == ["A"])
        #expect(e.decide(key(63, down: true, isRepeat: true), frontmostBundleID: nil) == .suppress)
        #expect(e.decide(key(keyA, down: true), frontmostBundleID: nil) == down(keyB))
        #expect(e.decide(key(keyA, down: false), frontmostBundleID: nil) == up(keyB))
        #expect(e.decide(key(63, down: false), frontmostBundleID: nil) == .suppress)
        #expect(e.activeShiftModeIDs.isEmpty)
        #expect(e.decide(key(keyA, down: true), frontmostBundleID: nil) == .passthrough)
    }

    @Test func toggleModeFlipsOnEachPress() {
        var e = layered([modeB], [])
        #expect(e.decide(mouse(3, down: true), frontmostBundleID: nil) == .suppress)
        #expect(e.decide(mouse(3, down: false), frontmostBundleID: nil) == .suppress)
        #expect(e.activeShiftModeIDs == ["B"])
        _ = e.decide(mouse(3, down: true), frontmostBundleID: nil)
        _ = e.decide(mouse(3, down: false), frontmostBundleID: nil)
        #expect(e.activeShiftModeIDs.isEmpty)
    }

    @Test func twoModesAreIndependentAndCombinedRulesNeedBoth() {
        var e = layered([modeA, modeB], [layerRule("a", keyA, to: 1, modes: ["A"]), layerRule("ab", keyA, to: 2, modes: ["A", "B"]),
                                         layerRule("base", keyA, to: 3, modes: [])])
        _ = e.decide(key(63, down: true), frontmostBundleID: nil)
        #expect(e.decide(key(keyA, down: true), frontmostBundleID: nil) == down(1))
        _ = e.decide(key(keyA, down: false), frontmostBundleID: nil)
        _ = e.decide(mouse(3, down: true), frontmostBundleID: nil)
        #expect(e.activeShiftModeIDs == ["A", "B"])
        #expect(e.decide(key(keyA, down: true), frontmostBundleID: nil) == down(2))          // most modes wins
        _ = e.decide(key(keyA, down: false), frontmostBundleID: nil)
        _ = e.decide(key(63, down: false), frontmostBundleID: nil)                           // only B left
        #expect(e.decide(key(keyA, down: true), frontmostBundleID: nil) == down(3))          // falls back to the base layer
    }

    @Test func appScopedBeatsGlobalAtTheSameDepthButDepthBeatsScope() {
        var e = layered([modeA], [layerRule("g", keyA, to: 1, modes: ["A"]), layerRule("s", keyA, to: 2, modes: ["A"], app: "com.app"),
                                  layerRule("base", keyB, to: 5, modes: []), layerRule("baseApp", keyB, to: 6, modes: [], app: "com.app"),
                                  layerRule("deep", keyB, to: 7, modes: ["A"])])
        _ = e.decide(key(63, down: true), frontmostBundleID: "com.app")
        #expect(e.decide(key(keyA, down: true), frontmostBundleID: "com.app") == down(2))
        _ = e.decide(key(keyA, down: false), frontmostBundleID: "com.app")
        #expect(e.decide(key(keyA, down: true), frontmostBundleID: "com.other") == down(1))
        _ = e.decide(key(keyA, down: false), frontmostBundleID: "com.other")
        #expect(e.decide(key(keyB, down: true), frontmostBundleID: "com.app") == down(7))     // layer rule beats app-scoped base rule
    }

    @Test func scopeFollowsTheInputKindWhenNotAffectingOtherDevices() {
        var local = modeA; local.affectsOtherDevices = false                                   // keyboard-only mode
        let mouseRule = RemapRule(id: "m", trigger: .init(kind: .mouseButton, code: 4), action: .key(code: 9, modifiers: []), shiftModeIDs: ["A"])
        var e = layered([local], [layerRule("k", keyA, to: 1, modes: ["A"]), mouseRule])
        _ = e.decide(key(63, down: true), frontmostBundleID: nil)
        #expect(e.decide(key(keyA, down: true), frontmostBundleID: nil) == down(1))
        #expect(e.decide(mouse(4, down: true), frontmostBundleID: nil) == .passthrough)       // mouse is outside the mode
        var global = modeA; global.affectsOtherDevices = true
        e.update(config: { var c = e.config; c.shiftModes = [global]; return c }())
        #expect(e.activeShiftModeIDs == ["A"])                                                 // held trigger survives the edit
        #expect(e.decide(mouse(4, down: true), frontmostBundleID: nil) == .emit([.key(code: 9, modifiers: [], down: true)]))
    }

    @Test func releaseStillPairsWhenTheModeEndsMidPress() {
        var e = layered([modeA], [layerRule("r", keyA, to: keyB, modes: ["A"])])
        _ = e.decide(key(63, down: true), frontmostBundleID: nil)
        #expect(e.decide(key(keyA, down: true), frontmostBundleID: nil) == down(keyB))
        _ = e.decide(key(63, down: false), frontmostBundleID: nil)                            // layer ends first
        #expect(e.decide(key(keyA, down: false), frontmostBundleID: nil) == up(keyB))
        #expect(e.decide(key(keyA, down: false), frontmostBundleID: nil) == .passthrough)
    }

    @Test func modifierKeyTriggersWorkWithSyntheticEvents() {
        let rightOption = ShiftMode(id: "R", name: "R", trigger: .init(kind: .keyboard, code: 61))
        var e = layered([rightOption], [layerRule("r", keyA, to: keyB, modes: ["R"])])
        #expect(e.decide(key(58, down: true), frontmostBundleID: nil) == .passthrough)        // left option is not configured
        #expect(e.decide(key(61, down: true), frontmostBundleID: nil) == .suppress)
        #expect(e.decide(key(keyA, down: true), frontmostBundleID: nil) == down(keyB))
        #expect(e.decide(key(61, down: false), frontmostBundleID: nil) == .suppress)
    }

    @Test func triggersThatCouldLockTheUserOutAreIgnored() {
        let click = ShiftMode(id: "L", name: "L", trigger: .init(kind: .mouseButton, code: 0))
        let esc = ShiftMode(id: "E", name: "E", trigger: .init(kind: .keyboard, code: 53))
        #expect(!click.hasAllowedTrigger && !esc.hasAllowedTrigger && modeB.hasAllowedTrigger)
        var e = layered([click, esc], [])
        #expect(e.decide(mouse(0, down: true), frontmostBundleID: nil) == .passthrough)
        #expect(e.decide(key(53, down: true), frontmostBundleID: nil) == .passthrough)
    }

    @Test func profileActionsAndToggleActionProduceDecisions() {
        let trigger = { (code: Int) in InputTrigger(kind: .keyboard, code: code) }
        var e = layered([modeB], [RemapRule(id: "p", trigger: trigger(keyF1), action: .switchProfile("work")),
                                  RemapRule(id: "n", trigger: trigger(120), action: .nextProfile),
                                  RemapRule(id: "v", trigger: trigger(118), action: .previousProfile),
                                  RemapRule(id: "t", trigger: trigger(99), action: .toggleShiftMode("B"))])
        #expect(e.decide(key(keyF1, down: true), frontmostBundleID: nil) == .switchProfile("work"))
        #expect(e.decide(key(keyF1, down: true, isRepeat: true), frontmostBundleID: nil) == .suppress)
        #expect(e.decide(key(keyF1, down: false), frontmostBundleID: nil) == .suppress)
        #expect(e.decide(key(120, down: true), frontmostBundleID: nil) == .cycleProfile(1))
        #expect(e.decide(key(118, down: true), frontmostBundleID: nil) == .cycleProfile(-1))
        #expect(e.decide(key(99, down: true), frontmostBundleID: nil) == .suppress)
        #expect(e.activeShiftModeIDs == ["B"])
    }

    @Test func masterSwitchOffAndModeRemovalClearModes() {
        var e = layered([modeB], [])
        _ = e.decide(mouse(3, down: true), frontmostBundleID: nil)
        #expect(e.activeShiftModeIDs == ["B"])
        e.update(config: e.config.removingShiftMode(id: "B"))
        #expect(e.activeShiftModeIDs.isEmpty)
        #expect(e.decide(mouse(3, down: true), frontmostBundleID: nil) == .passthrough)
    }

    @Test func removingAModeRemovesItsRules() {
        let config = layered([modeA], [layerRule("r", keyA, to: 1, modes: ["A"]), layerRule("base", keyB, to: 2, modes: [])]).config
        #expect(config.removingShiftMode(id: "A").rules.map(\.id) == ["base"])
        let same = config.upserting(layerRule("x", keyA, to: 9, modes: ["A"]))
        #expect(same.rules.count == 2)                                                         // same trigger+modes replaces
        #expect(same.upserting(layerRule("y", keyA, to: 9, modes: [])).rules.count == 3)       // other layer is a different rule
    }

    @Test func oldConfigFilesStillDecodeAndNewOnesRoundTrip() throws {
        let old = """
        {"schemaVersion":1,"enabled":true,"shellMacrosEnabled":false,"macros":[],
         "rules":[{"id":"r","enabled":true,"trigger":{"kind":"keyboard","code":0,"modifiers":0},"action":{"disable":{}}}]}
        """
        let config = try JSONDecoder().decode(RemapConfig.self, from: Data(old.utf8))
        #expect(config.shiftModes.isEmpty && config.rules[0].shiftModeIDs.isEmpty && config.enabled)
        let partial = try JSONDecoder().decode(RemapConfig.self, from: Data("{}".utf8))
        #expect(!partial.enabled && partial.shellMacrosEnabled)
        let modern = layered([modeA, modeB], [RemapRule(id: "p", trigger: .init(kind: .keyboard, code: 1), action: .switchProfile("w"), shiftModeIDs: ["A"]),
                                              RemapRule(id: "q", trigger: .init(kind: .keyboard, code: 2), action: .toggleShiftMode("B"))]).config
        #expect(try JSONDecoder().decode(RemapConfig.self, from: JSONEncoder().encode(modern)) == modern)
    }
}
