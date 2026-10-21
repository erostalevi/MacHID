import Foundation
import Testing
import MacHIDDomain
@testable import MacHIDApplication

private let btn = InputTrigger(kind: .mouseButton, code: 3)

private func engine(_ gestures: [ShiftGesture], enabled: Bool = true) -> RemapEngine {
    var config = RemapConfig()
    config.enabled = enabled
    config.gestures = gestures
    return RemapEngine(config: config)
}

private func swipe(threshold: Int = 80, freeze: Bool = false) -> ShiftGesture {
    ShiftGesture(id: "g", name: "g", trigger: btn, threshold: threshold,
                 actions: [.right: .system("desktop-right"), .left: .system("desktop-left"), .up: .system("mission-control"),
                           .down: .key(code: 0, modifiers: [.command])], freezePointer: freeze)
}

private func press(_ down: Bool) -> InputEvent { InputEvent(kind: .mouseButton, code: 3, isDown: down) }

@Suite struct ShiftGestureTests {
    @Test func triggerIsConsumedAndNothingFiresWithoutIt() {
        var e = engine([swipe()])
        #expect(e.decideMotion(dx: 500, dy: 0) == .none)
        #expect(e.decide(press(true), frontmostBundleID: nil) == .suppress)
        #expect(e.isTrackingGestures)
        #expect(e.decide(press(false), frontmostBundleID: nil) == .suppress)
        #expect(!e.isTrackingGestures)
    }

    @Test func firesAtThresholdInTheDominantDirection() {
        var e = engine([swipe()])
        _ = e.decide(press(true), frontmostBundleID: nil)
        #expect(e.decideMotion(dx: 40, dy: 5).fired == nil)
        #expect(e.decideMotion(dx: 39, dy: 0).fired == nil)
        #expect(e.decideMotion(dx: 2, dy: 0).fired == .runSystem("desktop-right"))
    }

    @Test func eachDirectionAndKeyActionsTapOnce() {
        for (dx, dy, expected) in [(-90.0, 0.0, RemapDecision.runSystem("desktop-left")), (0, -90, .runSystem("mission-control")),
                                   (0, 90, .emit([.key(code: 0, modifiers: [.command], down: true), .key(code: 0, modifiers: [.command], down: false)]))] {
            var e = engine([swipe()])
            _ = e.decide(press(true), frontmostBundleID: nil)
            #expect(e.decideMotion(dx: dx, dy: dy).fired == expected)
        }
    }

    @Test func firesOnceUntilItMovesBackOrIsReleased() {
        var e = engine([swipe()])
        _ = e.decide(press(true), frontmostBundleID: nil)
        #expect(e.decideMotion(dx: 100, dy: 0).fired != nil)
        #expect(e.decideMotion(dx: 300, dy: 0).fired == nil)       // still moving the same way: no repeat
        #expect(e.decideMotion(dx: -20, dy: 0).fired == nil)
        #expect(e.decideMotion(dx: -50, dy: 0).fired == nil)       // back more than half a threshold: re-armed, nothing yet
        #expect(e.decideMotion(dx: -100, dy: 0).fired == .runSystem("desktop-left"))
        _ = e.decide(press(false), frontmostBundleID: nil)
        _ = e.decide(press(true), frontmostBundleID: nil)
        #expect(e.decideMotion(dx: 100, dy: 0).fired == .runSystem("desktop-right"))
    }

    @Test func freezePointerOnlyWhileHeld() {
        var e = engine([swipe(freeze: true)])
        #expect(e.decideMotion(dx: 1, dy: 0).suppress == false)
        _ = e.decide(press(true), frontmostBundleID: nil)
        #expect(e.decideMotion(dx: 1, dy: 0).suppress)
        var plain = engine([swipe()])
        _ = plain.decide(press(true), frontmostBundleID: nil)
        #expect(plain.decideMotion(dx: 1, dy: 0).suppress == false)
    }

    @Test func disabledForbiddenAndMissingActions() {
        var off = engine([swipe()], enabled: false)
        #expect(off.decide(press(true), frontmostBundleID: nil) == .passthrough)
        var left = engine([ShiftGesture(id: "x", name: "", trigger: InputTrigger(kind: .mouseButton, code: 0), actions: [.right: .disable])])
        #expect(left.decide(InputEvent(kind: .mouseButton, code: 0, isDown: true), frontmostBundleID: nil) == .passthrough)
        var esc = engine([ShiftGesture(id: "x", name: "", trigger: InputTrigger(kind: .keyboard, code: 53))])
        #expect(esc.decide(InputEvent(kind: .keyboard, code: 53, isDown: true), frontmostBundleID: nil) == .passthrough)
        var none = engine([ShiftGesture(id: "n", name: "", trigger: btn)])
        _ = none.decide(press(true), frontmostBundleID: nil)
        #expect(none.decideMotion(dx: 500, dy: 0).fired == nil)
    }

    @Test func keyboardTriggerAndConfigUpdate() {
        var e = engine([ShiftGesture(id: "k", name: "", trigger: InputTrigger(kind: .keyboard, code: 61), actions: [.right: .nextProfile])])
        #expect(e.decide(InputEvent(kind: .keyboard, code: 61, isDown: true), frontmostBundleID: nil) == .suppress)
        #expect(e.decideMotion(dx: 100, dy: 0).fired == .cycleProfile(1))
        var config = e.config; config.gestures = []
        e.update(config: config)                                    // removing the gesture releases the hold
        #expect(!e.isTrackingGestures)
    }

    @Test func thresholdIsClampedAndConfigRoundTrips() throws {
        #expect(ShiftGesture(id: "a", name: "", trigger: btn, threshold: 1).threshold == 10)
        var config = RemapConfig()
        config.gestures = [swipe(threshold: 120, freeze: true)]
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(RemapConfig.self, from: data) == config)
        let old = #"{"schemaVersion":1,"enabled":true,"rules":[],"macros":[]}"#
        #expect(try JSONDecoder().decode(RemapConfig.self, from: Data(old.utf8)).gestures.isEmpty)
    }
}

@Suite struct SystemActionTests {
    @Test func systemRuleRunsOnceAndCatalogIsConsistent() throws {
        var config = RemapConfig(); config.enabled = true
        config.rules = [RemapRule(id: "r", trigger: InputTrigger(kind: .keyboard, code: 96), action: .system("mission-control"))]
        var e = RemapEngine(config: config)
        #expect(e.decide(InputEvent(kind: .keyboard, code: 96, isDown: true), frontmostBundleID: nil) == .runSystem("mission-control"))
        #expect(e.decide(InputEvent(kind: .keyboard, code: 96, isDown: true, isRepeat: true), frontmostBundleID: nil) == .suppress)
        #expect(e.decide(InputEvent(kind: .keyboard, code: 96, isDown: false), frontmostBundleID: nil) == .suppress)
        let ids = SystemActionCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(SystemActionCatalog.action(id: "desktop-left")?.implementation == .key(code: 123, modifiers: .control))
        #expect(SystemActionCatalog.grouped.flatMap(\.actions).count == ids.count)
        let data = try JSONEncoder().encode(RemapAction.system("mute"))
        #expect(try JSONDecoder().decode(RemapAction.self, from: data) == .system("mute"))
    }
}
