import Testing
@testable import MacHIDUI

@Suite struct BatteryAlertPolicyTests {
    @Test func alertsOncePerLevelPerCycle() {
        var policy = BatteryAlertPolicy()
        #expect(policy.threshold(for: 40, charging: false, device: "a") == nil)
        #expect(policy.threshold(for: 15, charging: false, device: "a") == 15)
        #expect(policy.threshold(for: 14, charging: false, device: "a") == nil)   // same level again
        #expect(policy.threshold(for: 5, charging: false, device: "a") == 5)
        #expect(policy.threshold(for: 4, charging: false, device: "a") == nil)
    }

    @Test func chargingStartsANewCycle() {
        var policy = BatteryAlertPolicy()
        #expect(policy.threshold(for: 10, charging: false, device: "a") == 15)
        #expect(policy.threshold(for: 11, charging: true, device: "a") == nil)    // charging: never alerts
        #expect(policy.threshold(for: 12, charging: false, device: "a") == 15)    // charging ended the cycle: alerts again
    }

    @Test func skippingBothLevelsAnnouncesOnlyTheLowerOne() {
        var policy = BatteryAlertPolicy()
        #expect(policy.threshold(for: 4, charging: nil, device: "a") == 5)
        #expect(policy.threshold(for: 4, charging: nil, device: "a") == nil)
    }

    @Test func devicesAreIndependentAndUnknownReadingsIgnored() {
        var policy = BatteryAlertPolicy()
        #expect(policy.threshold(for: nil, charging: nil, device: "a") == nil)
        #expect(policy.threshold(for: 15, charging: false, device: "a") == 15)
        #expect(policy.threshold(for: 15, charging: false, device: "b") == 15)
    }

    @Test func climbingAboveResetLevelStartsANewCycle() {
        var policy = BatteryAlertPolicy()
        #expect(policy.threshold(for: 15, charging: false, device: "a") == 15)
        #expect(policy.threshold(for: 60, charging: false, device: "a") == nil)
        #expect(policy.threshold(for: 15, charging: false, device: "a") == 15)
    }
}

@Suite struct BatteryDisplayTests {
    @Test func symbolsAndLowFlags() {
        #expect(BatteryDisplay.symbolName(percent: 100) == "battery.100percent")
        #expect(BatteryDisplay.symbolName(percent: 60) == "battery.50percent")
        #expect(BatteryDisplay.symbolName(percent: 20) == "battery.25percent")
        #expect(BatteryDisplay.symbolName(percent: 3) == "battery.0percent")
        #expect(BatteryDisplay.isLow(percent: 15, charging: false))
        #expect(!BatteryDisplay.isLow(percent: 16, charging: nil))
        #expect(!BatteryDisplay.isLow(percent: 5, charging: true))
        #expect(BatteryDisplay.isCritical(percent: 5, charging: nil))
    }
}
