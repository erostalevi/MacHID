import Foundation
import Testing
import MacHIDDomain
@testable import MacHIDApplication

private func definition(_ id: String) -> DeviceDefinition {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Definitions/\(id).json")
    return try! JSONDecoder().decode(DeviceDefinition.self, from: Data(contentsOf: url))
}
private let keyboard = GlobalLightingDevice(id: "kb", definition: definition("razer-huntsman-mini"))
private let mouse = GlobalLightingDevice(id: "ms", definition: definition("logitech-g203-lightsync"))
private let camera = GlobalLightingDevice(id: "cam", definition: definition("logitech-brio-100"))

@Suite struct GlobalLightingTests {
    @Test func solidWritesNativeColorEverywhere() {
        let plan = GlobalLightingPlan.make(settings: .init(preset: .solid(RGBColor(r: 1, g: 2, b: 3)), brightness: 60), devices: [keyboard, mouse, camera])
        #expect(plan.softwareDeviceIDs.isEmpty && plan.notPhaseLockedDeviceIDs.isEmpty)
        #expect(plan.writes.contains(.init(deviceID: "kb", capabilityID: "backlight", value: .effect(LightingEffect("static", color: RGBColor(r: 1, g: 2, b: 3))))))
        #expect(plan.writes.contains(.init(deviceID: "kb", capabilityID: "brightness", value: .int(60))))
        #expect(plan.writes.contains(.init(deviceID: "ms", capabilityID: "backlight", value: .effect(LightingEffect("static", color: RGBColor(r: 1, g: 2, b: 3), brightness: 60)))))
        #expect(plan.skipped.isEmpty)      // a camera without lighting is not an error
    }

    @Test func spectrumSyncsKeyboardInSoftwareAndMouseGetsPeriod() {
        let plan = GlobalLightingPlan.make(settings: .init(preset: .spectrum, cycleSeconds: 6), devices: [keyboard, mouse])
        #expect(plan.softwareDeviceIDs == ["kb"])
        #expect(plan.writes.contains { $0.deviceID == "ms" && $0.value == .effect(LightingEffect("cycle", period: 6000, brightness: 100)) })
        #expect(plan.notPhaseLockedDeviceIDs == ["ms"])
    }

    @Test func withoutKeepInSyncTheKeyboardUsesItsOwnEffect() {
        let plan = GlobalLightingPlan.make(settings: .init(preset: .wave, keepInSync: false), devices: [keyboard, mouse])
        #expect(plan.softwareDeviceIDs.isEmpty)
        #expect(plan.writes.contains { $0.deviceID == "kb" && $0.value == .effect(LightingEffect("wave")) })
        #expect(Set(plan.notPhaseLockedDeviceIDs) == ["kb", "ms"])
    }

    @Test func periodIsClampedAndOffNeedsNoSync() {
        let slow = GlobalLightingPlan.make(settings: .init(preset: .breathing(RGBColor(r: 9, g: 9, b: 9)), cycleSeconds: 0.2), devices: [mouse])
        guard case .effect(let e)? = slow.writes.first?.value else { Issue.record("no write"); return }
        #expect(e.effect == "breathing" && e.period == 1000)
        let off = GlobalLightingPlan.make(settings: .init(preset: .off), devices: [keyboard, mouse])
        #expect(off.softwareDeviceIDs.isEmpty && off.notPhaseLockedDeviceIDs.isEmpty)
    }

    @Test func softwareSceneFollowsTheSharedClock() {
        let clock = LightingClock(origin: 100, cycleSeconds: 10)
        let scene = clock.retimed(GlobalLightingPlan.scene(for: .init(preset: .spectrum)))
        #expect(scene.syncToGlobalClock)
        let layout = KeyboardLayout.huntsmanMini
        // Two "devices" asking at the same instant get the same frame, one cycle later the same frame again.
        let a = LightingCompositor.render(scene, layout: layout, time: clock.renderTime(for: scene, now: 103, localTime: 0))
        let b = LightingCompositor.render(scene, layout: layout, time: clock.renderTime(for: scene, now: 103, localTime: 55))
        let c = LightingCompositor.render(scene, layout: layout, time: clock.renderTime(for: scene, now: 113, localTime: 7))
        #expect(a == b)
        #expect(a == c)
    }

    @Test func clockPhaseAndSpeeds() {
        let clock = LightingClock(origin: 10, cycleSeconds: 8)
        #expect(clock.phase(at: 14) == 0.5)
        #expect(abs(clock.phase(at: 2) - 0.0) < 1e-9)            // before the origin wraps forward
        #expect(abs(clock.spectrumSpeed * 0.12 * 8 - 1) < 1e-9)
        #expect(LightingClock(cycleSeconds: 0).cycleSeconds == 2)
    }

    @Test func sceneCodingKeepsSyncFlagAndOldFilesDecode() throws {
        var scene = LightingScene.defaults[0]; scene.syncToGlobalClock = true
        #expect(try JSONDecoder().decode(LightingScene.self, from: JSONEncoder().encode(scene)).syncToGlobalClock)
        #expect(try JSONDecoder().decode(LightingScene.self, from: Data(#"{"id":"x","layers":[]}"#.utf8)).syncToGlobalClock == false)
        #expect(LightingScene.defaults.prefix(4).map(\.id) == ["solid", "breathing", "reactive", "gaming"])
        #expect(LightingSetup.defaults.scene(id: "aurora") != nil)
    }
}
