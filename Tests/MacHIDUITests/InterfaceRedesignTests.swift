import Foundation
import Testing
import MacHIDDomain
@testable import MacHIDUI

@MainActor
struct DeviceTabTests {
    private func model(_ category: DeviceCategory) -> AppModel { PreviewSupport.model(selecting: category) }

    @Test func everyDeviceHasInfoAndOnlyKeyboardsAndMiceHaveKeys() {
        let model = model(.mouse)
        for device in model.devices {
            #expect(device.tabs.contains(.info))
            #expect(device.tabs.contains(.keys) == (device.category == .mouse || device.category == .keyboard))
        }
        #expect(model.devices.first { $0.category == .camera }?.tabs.contains(.light) == true)
    }

    @Test func tabsMapToTheirSectionsAndBack() {
        for tab in DeviceTab.allCases { for section in tab.sections { #expect(DeviceTab.of(section) == tab) } }
        let all = Set(DeviceTab.allCases.flatMap(\.sections))
        #expect(all == Set(ControlSection.allCases))
    }

    @Test func selectingATabSelectsItsPrimarySection() {
        let model = model(.keyboard)
        model.selectedTab = .keys
        #expect(model.selectedSection == .buttons)
        model.selectedTab = .light
        #expect(model.selectedSection == .lighting)
        model.selectSection(at: 2)
        #expect(model.selectedTab == model.availableTabs[2])
    }
}

struct InputCatalogTests {
    @Test func searchFindsByNameAndGroup() {
        let f5 = InputCatalog.sections(matching: "f5", includeMouse: true, includeModifierKeys: true)
        #expect(f5.flatMap(\.choices).contains { $0.code == 96 })
        let mouse = InputCatalog.sections(matching: "mouse", includeMouse: true, includeModifierKeys: true)
        #expect(mouse.count == 1 && mouse[0].group == .mouse)
        #expect(InputCatalog.sections(matching: "zzzz", includeMouse: true, includeModifierKeys: true).isEmpty)
    }

    @Test func groupsAreHiddenWhenTheCallerCannotUseThem() {
        let keysOnly = InputCatalog.sections(matching: "", includeMouse: false, includeModifierKeys: false)
        #expect(!keysOnly.contains { $0.group == .mouse || $0.group == .modifiers })
    }

    @Test func noKeyIsListedTwiceAndEveryNameIsReadable() {
        let ids = InputCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for choice in InputCatalog.all where choice.kind == .keyboard { #expect(!choice.name.hasPrefix("Key ")) }
    }
}

struct ShiftModeDiagnosticsTests {
    private func mode(_ id: String, code: Int, kind: InputKind = .keyboard) -> ShiftMode {
        ShiftMode(id: id, name: id, trigger: InputTrigger(kind: kind, code: code))
    }

    @Test func warnsAboutSharedForbiddenAndShadowedTriggers() {
        var config = RemapConfig()
        config.shiftModes = [mode("a", code: 61), mode("b", code: 61), mode("esc", code: 53)]
        config.rules = [RemapRule(id: "r", trigger: InputTrigger(kind: .keyboard, code: 61), action: .disable)]
        let a = ShiftModeDiagnostics.warnings(for: config.shiftModes[0], in: config)
        #expect(a.contains(.sharedTrigger(otherName: "b")) && a.contains(.shadowsRule))
        #expect(ShiftModeDiagnostics.warnings(for: config.shiftModes[2], in: config).contains(.forbiddenTrigger))
    }

    @Test func countsRulesPerLayerAndPerMode() {
        var config = RemapConfig()
        config.shiftModes = [mode("a", code: 61), mode("b", code: 62)]
        func rule(_ id: String, _ modes: [String]) -> RemapRule { RemapRule(id: id, trigger: InputTrigger(kind: .keyboard, code: 0), action: .disable, shiftModeIDs: modes) }
        config.rules = [rule("1", []), rule("2", ["a"]), rule("3", ["a", "b"])]
        #expect(ShiftModeDiagnostics.ruleCount(in: config, layer: []) == 1)
        #expect(ShiftModeDiagnostics.ruleCount(in: config, layer: ["a"]) == 1)
        #expect(ShiftModeDiagnostics.ruleCount(in: config, mode: "a") == 2)
    }

    @Test func duplicatingCopiesRulesOntoTheNewMode() {
        var config = RemapConfig()
        config.shiftModes = [mode("a", code: 61), mode("b", code: 62)]
        config.rules = [RemapRule(id: "r", trigger: InputTrigger(kind: .keyboard, code: 0), action: .disable, shiftModeIDs: ["a", "b"])]
        let copy = ShiftModeDiagnostics.duplicate(config.shiftModes[0], in: config, newID: "c", name: "a copy")
        #expect(copy.mode.id == "c" && copy.mode.name == "a copy")
        #expect(copy.rules.count == 1 && copy.rules[0].shiftModeIDs == ["b", "c"] && copy.rules[0].id != "r")
    }
}
