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
        #expect(spec(.lightingZone, zones(["static", "off"]))?.kind == .color(canTurnOff: true))
        #expect(spec(.lightingZone, zones(["static"]))?.kind == .color(canTurnOff: false))
        #expect(spec(.lightingZone, zones(["wave"])) == nil)
        #expect(spec(.lightingZone, zones(["static"]))?.readable == false)
    }

    @Test func infoAndModeAndUnknownTypes() {
        #expect(spec(.info, access: .read)?.kind == .readout)
        #expect(spec(.deviceMode)?.kind == .hostControl)
        #expect(spec(.deviceMode)?.section == .advanced)
        #expect(spec(.battery, access: .read) == nil)
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
}
