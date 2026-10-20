import Foundation
import Testing
import MacHIDDomain
@testable import MacHIDApplication

private func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> RGBColor { RGBColor(r: r, g: g, b: b) }
private let board = KeyboardLayout.huntsmanMini
private func scene(_ layers: [LightingLayer], brightness: Int = 100) -> LightingScene { LightingScene(id: "t", name: "t", layers: layers, brightness: brightness) }
private func layer(_ kind: LightingLayerKind, opacity: Double = 1, blend: LightingBlend = .normal, region: LightingRegion = .all) -> LightingLayer {
    LightingLayer(id: UUID().uuidString, name: "l", kind: kind, opacity: opacity, blend: blend, region: region)
}

@Test func solidAndBrightness() {
    let out = LightingCompositor.render(scene([layer(.solid(rgb(200, 100, 50)))], brightness: 50), layout: board, time: 0)
    #expect(out["a"] == rgb(100, 50, 25))
    #expect(out.count == board.keys.count)
}

@Test func blendModes() {
    let base = layer(.solid(rgb(100, 100, 100)))
    func top(_ b: LightingBlend) -> RGBColor {
        LightingCompositor.render(scene([base, layer(.solid(rgb(200, 200, 200)), blend: b)]), layout: board, time: 0)["a"]!
    }
    #expect(top(.normal) == rgb(200, 200, 200))
    #expect(top(.add) == rgb(255, 255, 255))
    #expect(top(.multiply) == rgb(78, 78, 78))     // 0.392 * 0.784 = 0.307
    #expect(top(.screen) == rgb(222, 222, 222))    // 1 - 0.608 * 0.216 = 0.869
}

@Test func opacityAndOrdering() {
    let red = layer(.solid(rgb(255, 0, 0))), blue = layer(.solid(rgb(0, 0, 255)), opacity: 0.5)
    #expect(LightingCompositor.render(scene([red, blue]), layout: board, time: 0)["a"] == rgb(128, 0, 128))
    #expect(LightingCompositor.render(scene([blue, red]), layout: board, time: 0)["a"] == rgb(255, 0, 0))
    var off = blue; off.enabled = false
    #expect(LightingCompositor.render(scene([red, off]), layout: board, time: 0)["a"] == rgb(255, 0, 0))
}

@Test func regionMask() {
    let out = LightingCompositor.render(scene([layer(.solid(rgb(9, 9, 9)), region: .keys(["a", "s"]))]), layout: board, time: 0)
    #expect(out["a"] == rgb(9, 9, 9) && out["s"] == rgb(9, 9, 9))
    #expect(out["d"] == rgb(0, 0, 0))
}

@Test func paintedUsesMatrixCells() {
    let a = board.key(id: "a")!
    let out = LightingCompositor.render(scene([layer(.painted([KeyColor(row: a.row, col: a.col, color: rgb(1, 2, 3))]))]), layout: board, time: 0)
    #expect(out["a"] == rgb(1, 2, 3))
    #expect(out["s"] == rgb(0, 0, 0))
    #expect(LightingCompositor.frame(scene([layer(.painted([KeyColor(row: a.row, col: a.col, color: rgb(1, 2, 3))]))]), layout: board, time: 0).count == 1)
}

@Test func reactiveDecaysWithAge() {
    let s = scene([layer(.reactive(color: rgb(255, 255, 255), decay: 1, ripple: false))])
    func level(_ now: Double) -> UInt8 { LightingCompositor.render(s, layout: board, time: now, keyEvents: [KeyEvent(keyID: "a", startTime: 10)])["a"]!.r }
    #expect(level(10) == 255)
    #expect(level(10.5) == 64)     // (1 - 0.5)^2
    #expect(level(11) == 0)
    #expect(level(9) == 0)         // event in the future
    let other = LightingCompositor.render(s, layout: board, time: 10, keyEvents: [KeyEvent(keyID: "a", startTime: 10)])["s"]!
    #expect(other == rgb(0, 0, 0))
}

@Test func rippleReachesNeighboursLater() {
    let s = scene([layer(.reactive(color: rgb(255, 255, 255), decay: 1, ripple: true))])
    let events = [KeyEvent(keyID: "g", startTime: 0)]
    let early = LightingCompositor.render(s, layout: board, time: 0.01, keyEvents: events)["h"]!.r
    let later = LightingCompositor.render(s, layout: board, time: 0.11, keyEvents: events)["h"]!.r
    #expect(later > early)
}

@Test func eventCapKeepsNewest() {
    let s = scene([layer(.reactive(color: rgb(255, 255, 255), decay: 100, ripple: false))])
    var events = [KeyEvent(keyID: "a", startTime: 0)]
    events += (1...LightingCompositor.maxEvents).map { KeyEvent(keyID: "s", startTime: Double($0) * 0.001) }
    let out = LightingCompositor.render(s, layout: board, time: 1, keyEvents: events)
    #expect(out["a"] == rgb(0, 0, 0))      // the oldest event fell off
    #expect(out["s"]!.r > 0)
}

@Test func starlightIsDeterministic() {
    let s = scene([layer(.starlight(colors: [rgb(255, 255, 255)], speed: 1, density: 0.5))])
    let a = LightingCompositor.render(s, layout: board, time: 3.3)
    #expect(a == LightingCompositor.render(s, layout: board, time: 3.3))
    #expect(a.values.contains { $0.r > 0 })
    let none = scene([layer(.starlight(colors: [rgb(255, 255, 255)], speed: 1, density: 0))])
    #expect(LightingCompositor.render(none, layout: board, time: 3.3).values.allSatisfy { $0.r == 0 })
}

@Test func spectrumAndGradient() {
    let spec = LightingCompositor.render(scene([layer(.spectrum(speed: 1))]), layout: board, time: 0)["a"]!
    #expect(spec == rgb(255, 38, 38))      // hue 0, s 0.85
    let g = LightingCompositor.render(scene([layer(.gradient(from: rgb(0, 0, 0), to: rgb(255, 255, 255), angle: 0))]), layout: board, time: 0)
    #expect(g["1"]!.r < g["0"]!.r)
    #expect(g["backspace"]!.r > g["esc"]!.r)
}

@Test func staticAndNativeEquivalence() {
    #expect(LightingCompositor.isStatic(scene([layer(.solid(rgb(1, 1, 1))), layer(.gradient(from: rgb(0, 0, 0), to: rgb(1, 1, 1), angle: 0))])))
    #expect(!LightingCompositor.isStatic(scene([layer(.spectrum(speed: 1))])))
    #expect(LightingCompositor.nativeEquivalent(scene([layer(.solid(rgb(1, 2, 3)))])) == LightingEffect("static", color: rgb(1, 2, 3)))
    #expect(LightingCompositor.nativeEquivalent(scene([layer(.spectrum(speed: 1))]))?.effect == "spectrum")
    #expect(LightingCompositor.nativeEquivalent(scene([layer(.wave(speed: 1, direction: 1))]))?.direction == 1)
    #expect(LightingCompositor.nativeEquivalent(scene([layer(.reactive(color: rgb(1, 1, 1), decay: 0.7, ripple: false))]))?.speed == 2)
    #expect(LightingCompositor.nativeEquivalent(scene([layer(.reactive(color: rgb(1, 1, 1), decay: 0.7, ripple: true))])) == nil)
    #expect(LightingCompositor.nativeEquivalent(scene([layer(.spectrum(speed: 1)), layer(.solid(rgb(1, 1, 1)))])) == nil)
    #expect(LightingCompositor.nativeEquivalent(scene([layer(.spectrum(speed: 1), opacity: 0.5)])) == nil)
    #expect(LightingCompositor.nativeEquivalent(scene([layer(.spectrum(speed: 1), region: .keys(["a"]))])) == nil)
    #expect(LightingCompositor.nativeEquivalent(scene([layer(.solid(rgb(1, 1, 1)))], brightness: 40))?.brightness == 40)
    let star = LightingCompositor.nativeEquivalent(scene([layer(.starlight(colors: [rgb(1, 0, 0), rgb(0, 1, 0)], speed: 1, density: 0.2))]))
    #expect(star?.secondColor == rgb(0, 1, 0) && star?.speed == 2)
}

@Test func singleZoneAveragesBoard() {
    #expect(LightingCompositor.singleZoneColor(scene([layer(.solid(rgb(10, 20, 30)))]), time: 0) == rgb(10, 20, 30))
}

@Test func defaultScenesRender() {
    for s in LightingScene.defaults {
        let out = LightingCompositor.render(s, layout: board, time: 1.5, keyEvents: [KeyEvent(keyID: "a", startTime: 1.4)])
        #expect(out.count == board.keys.count)
    }
    #expect(LightingScene.defaults.count == 5)
}

@Test func sceneSelectionByShiftModes() {
    func s(_ id: String) -> LightingScene { LightingScene(id: id, name: id, layers: []) }
    let setup = LightingSetup(baseSceneID: "base", shiftScenes: [
        ShiftSceneRule(modeIDs: ["fn"], sceneID: "fn"),
        ShiftSceneRule(modeIDs: ["fn", "game"], sceneID: "both"),
        ShiftSceneRule(modeIDs: ["game"], sceneID: "game"),
        ShiftSceneRule(modeIDs: ["ghost"], sceneID: "missing"),
    ], scenes: [s("base"), s("fn"), s("both"), s("game")])
    #expect(setup.scene(forActiveModes: [])?.id == "base")
    #expect(setup.scene(forActiveModes: ["fn"])?.id == "fn")
    #expect(setup.scene(forActiveModes: ["game"])?.id == "game")
    #expect(setup.scene(forActiveModes: ["game", "fn"])?.id == "both")
    #expect(setup.scene(forActiveModes: ["fn", "other"])?.id == "fn")
    #expect(setup.scene(forActiveModes: ["ghost"])?.id == "base")
    // Tie: the first rule wins.
    let tie = LightingSetup(baseSceneID: "base", shiftScenes: [ShiftSceneRule(modeIDs: ["a"], sceneID: "x"), ShiftSceneRule(modeIDs: ["b"], sceneID: "y")],
                            scenes: [s("base"), s("x"), s("y")])
    #expect(tie.scene(forActiveModes: ["a", "b"])?.id == "x")
}

@Test func jsonRoundTripAndTolerance() throws {
    let setup = LightingSetup.defaults
    let data = try JSONEncoder().encode(setup)
    #expect(try JSONDecoder().decode(LightingSetup.self, from: data) == setup)

    let json = """
    {"baseSceneID":"a","scenes":[
      {"id":"a","layers":[{"id":"1","kind":{"type":"solid"}},{"id":"2","kind":{"type":"hologram"}},{"kind":{"type":"spectrum"}}]},
      "garbage"]}
    """
    let tolerant = try JSONDecoder().decode(LightingSetup.self, from: Data(json.utf8))
    #expect(tolerant.schemaVersion == 1)
    #expect(tolerant.scenes.count == 1)
    #expect(tolerant.scenes[0].brightness == 100)
    #expect(tolerant.scenes[0].layers.count == 1)
    #expect(tolerant.scenes[0].layers[0].kind == .solid(rgb(255, 255, 255)))
    #expect(tolerant.scenes[0].layers[0].opacity == 1)
}

@Test func throttleSkipsFastAndUnchanged() {
    var t = FrameThrottle(minInterval: 0.05, tolerance: 2)
    let f1 = [KeyColor(row: 0, col: 1, color: rgb(10, 10, 10))]
    let f2 = [KeyColor(row: 0, col: 1, color: rgb(100, 10, 10))]
    do { let sent = t.shouldSend(f1, at: 0); #expect(sent) } 
    do { let sent = t.shouldSend(f2, at: 0.01); #expect(!sent) } // too soon
    do { let sent = t.shouldSend(f1, at: 0.10); #expect(!sent) } // unchanged
    do { let sent = t.shouldSend([KeyColor(row: 0, col: 1, color: rgb(12, 10, 10))], at: 0.2); #expect(!sent) } // within tolerance
    do { let sent = t.shouldSend(f2, at: 0.3); #expect(sent) } 
    do { let sent = t.shouldSend([], at: 0.4); #expect(sent) } // key went dark
    t.reset()
    do { let sent = t.shouldSend([], at: 0.401); #expect(sent) } 
}
