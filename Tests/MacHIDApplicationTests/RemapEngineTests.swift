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
