import Foundation
import Testing
import MacHIDDomain
@testable import MacHIDUI

@Suite struct ControlSpecTests {
    private func spec(_ type: CapabilityType, access: AccessMode = .writeVolatile, _ parameters: CapabilityParameters? = nil) -> ControlSpec? {
        ControlSpec.make(for: CapabilityDescriptor(id: "x", type: type, access: access, parameters: parameters))
    }

    @Test func sliderUsesDefinitionRangeOrDefaults() {
        #expect(spec(.dpi, .init(min: 200, max: 8000, step: 50))?.kind == .slider(min: 200, max: 8000, step: 50, deviceLimits: false))
        #expect(spec(.brightness)?.kind == .slider(min: 0, max: 100, step: 1, deviceLimits: false))
    }

    @Test func cameraControlsAskTheDeviceForLimitsUnlessSetsAreGiven() {
        #expect(spec(.cameraControl)?.kind == .slider(min: 0, max: 255, step: 1, deviceLimits: true))
        #expect(spec(.cameraControl, .init(values: [1, 0]))?.kind == .toggle)
        #expect(spec(.cameraControl, .init(values: [0, 1, 2]))?.kind == .choice([0, 1, 2]))
        #expect(spec(.cameraControl)?.section == .image)
    }

    @Test func lightingNeedsAStaticMode() {
        let zones = { (modes: [String]) in CapabilityParameters(zones: [LightingZone(id: "z", modes: modes)]) }
        #expect(spec(.lightingZone, zones(["static", "off", "wave"]))?.kind == .lighting(modes: ["static", "off", "wave"], zone: LightingZone(id: "z", modes: ["static", "off", "wave"])))
        #expect(spec(.lightingZone, zones(["static"]))?.kind == .lighting(modes: ["static"], zone: LightingZone(id: "z", modes: ["static"])))
        #expect(spec(.lightingZone, zones(["wave"])) == nil)
        #expect(spec(.lightingZone, zones(["static"]))?.readable == false)
    }

    @Test func newKindsHaveControls() {
        #expect(spec(.dpiStages, .init(min: 200, max: 8000, step: 50, slots: 5))?.kind == .dpiStages(min: 200, max: 8000, step: 50, slots: 5))
        #expect(spec(.dpiStages)?.section == .performance)
        #expect(spec(.perKeyLighting, .init(rows: 5, columns: 15))?.kind == .keyLighting(rows: 5, columns: 15))
        #expect(spec(.perKeyLighting)?.section == .lighting)
    }

    @Test func infoAndModeAndUnknownTypes() {
        #expect(spec(.info, access: .read)?.kind == .readout)
        #expect(spec(.deviceMode)?.kind == .hostControl)
        #expect(spec(.deviceMode)?.section == .advanced)
        #expect(spec(.battery, access: .read)?.kind == .battery)
        #expect(spec(.battery, access: .read)?.section == .info)
        #expect(spec(.keyRemap) == nil)
    }

    @Test func readOnlyCapabilitiesAreNotWritable() {
        #expect(spec(.dpi, access: .read)?.isWritable == false)
        #expect(spec(.dpi)?.isWritable == true)
    }

    @Test func bundledDefinitionsProduceControls() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["razer-huntsman-mini", "logitech-g203-lightsync", "logitech-brio-100"] {
            let data = try Data(contentsOf: root.appendingPathComponent("Definitions/\(name).json"))
            let definition = try JSONDecoder().decode(DeviceDefinition.self, from: data)
            let specs = ControlSpec.specs(for: definition)
            #expect(specs.count >= 2, "\(name) should expose controls")
        }
    }

    @Test func pollingRateIsAChoiceWithDefaults() {
        #expect(spec(.pollingRate)?.kind == .choice([125, 250, 500, 1000]))
        #expect(spec(.pollingRate, .init(values: [1000, 500]))?.kind == .choice([500, 1000]))
        #expect(spec(.pollingRate)?.section == .performance)
    }

    @Test func manualControlsAreBlockedByTheirAutomaticSwitch() {
        let exposure = ControlSpec.make(for: CapabilityDescriptor(id: "exposure_time", type: .cameraControl, access: .writeVolatile))
        #expect(exposure?.disabledWhen?.control == "exposure_auto" && exposure?.disabledWhen?.equals == 1)
        #expect(spec(.dpi)?.disabledWhen == nil)
    }

    @Test func lightingModesMapToValuesAndBack() {
        let red = MacHIDDomain.RGBColor(r: 255, g: 0, b: 0)
        #expect(LightingModes.value(for: "static", color: red) == .color(red))
        #expect(LightingModes.value(for: "off", color: red) == .text("off"))
        #expect(LightingModes.value(for: "reactive", color: red) == .effect(LightingEffect("reactive", color: red)))
        #expect(LightingModes.value(for: "spectrum", color: red) == .effect(LightingEffect("spectrum")))     // no color for colorless modes
        #expect(LightingModes.mode(of: .color(red)) == "static")
        #expect(LightingModes.mode(of: .text("off")) == "off")
        #expect(LightingModes.mode(of: .effect(LightingEffect("wave"))) == "wave")
        #expect(LightingModes.mode(of: nil) == nil)
    }
}
