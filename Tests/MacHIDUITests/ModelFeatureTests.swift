import Foundation
import Testing
import MacHIDDomain
@testable import MacHIDUI

/// Uses the bundled definitions with no hardware (writes fail quietly; only the model state is checked).
@MainActor
struct ModelFeatureTests {
    private func model(_ category: DeviceCategory) -> AppModel { PreviewSupport.model(selecting: category) }

    @Test func perKeyPaintingStartsFromAFilledFrameAndChangesOneKey() {
        let model = model(.keyboard)
        let id = model.selectedDevice!.id
        #expect(!model.perKeyActive.contains(id))
        model.setPerKey(true, for: id)
        #expect(model.perKeyActive.contains(id))
        guard case .keyFrame(let filled)? = model.selectedDevice?.values["key_lighting"] else { Issue.record("no frame"); return }
        #expect(filled.count == KeyboardLayout.huntsmanMini.keys.count)

        model.brush = MacHIDDomain.RGBColor(r: 1, g: 2, b: 3)
        model.paintKey("esc", on: id)
        guard case .keyFrame(let painted)? = model.selectedDevice?.values["key_lighting"] else { Issue.record("no frame"); return }
        let esc = KeyboardLayout.huntsmanMini.key(id: "esc")!
        #expect(painted.count == filled.count)
        #expect(painted.first { $0.row == esc.row && $0.col == esc.col }?.color == MacHIDDomain.RGBColor(r: 1, g: 2, b: 3))

        model.fillKeys(with: nil, for: id)
        #expect(model.selectedDevice?.values["key_lighting"] == .keyFrame([]))
        model.setPerKey(false, for: id)
        #expect(!model.perKeyActive.contains(id))
    }

    @Test func paintingOnlyAppliesInTheLightingSection() {
        let model = model(.keyboard)
        let device = model.selectedDevice!
        model.setPerKey(true, for: device.id)
        model.selectedSection = .lighting
        #expect(model.isPainting(model.selectedDevice!))
        model.selectedSection = .buttons
        #expect(!model.isPainting(model.selectedDevice!))
    }

    @Test func dpiPresetsPersistAndCycle() {
        let model = model(.mouse)
        let id = model.selectedDevice!.id
        model.set(.text("400,800,1600"), capability: "dpi_stages", on: id)
        model.set(.int(800), capability: "dpi", on: id)
        model.cycleDPI(for: id)
        #expect(model.selectedDevice?.values["dpi"] == .int(1600))
        model.cycleDPI(for: id)
        #expect(model.selectedDevice?.values["dpi"] == .int(400))
    }

    @Test func matchingLightingCopiesTheColorToOtherDevices() {
        let model = model(.keyboard)
        let keyboard = model.devices.first { $0.category == .keyboard }!
        let mouse = model.devices.first { $0.category == .mouse }!
        model.set(.color(MacHIDDomain.RGBColor(r: 9, g: 8, b: 7)), capability: "backlight", on: keyboard.id)
        model.syncLighting(from: keyboard.id)
        #expect(model.devices.first { $0.id == mouse.id }?.values["backlight"] == .color(MacHIDDomain.RGBColor(r: 9, g: 8, b: 7)))
    }

    @Test func mouseAndKeyboardGetButtonsSection() {
        let model = model(.mouse)
        #expect(model.devices.first { $0.category == .mouse }!.sections.contains(.buttons))
        #expect(model.devices.first { $0.category == .keyboard }!.sections.contains(.buttons))
        #expect(!model.devices.first { $0.category == .camera }!.sections.contains(.buttons))
    }

    @Test func keyIDsMapToMacKeyCodesBothWays() {
        for key in KeyboardLayout.huntsmanMini.keys where key.id != "fn" && key.id != "menu" {
            let code = KeyboardKeyCodes.code(forKeyID: key.id)
            #expect(code != nil, "no key code for \(key.id)")
            if let code { #expect(KeyboardKeyCodes.keyID(forCode: code) == key.id) }
        }
    }
}
