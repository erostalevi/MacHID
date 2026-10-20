import Foundation
import Testing
import MacHIDDomain
@testable import MacHIDLogitech

/// Fake HID++ device exposing only the given features (id -> runtime index); `status` answers every other request.
private actor BatteryHidppTransport: Transport {
    private(set) var sent: [[UInt8]] = []
    private var inbox: [(reportID: UInt8, data: [UInt8])] = []
    private let features: [UInt16: UInt8]
    private let status: [UInt8]

    init(features: [UInt16: UInt8], status: [UInt8]) {
        self.features = features
        self.status = status
    }

    func sendFeatureReport(reportID: UInt8, _ data: [UInt8]) async throws {}
    func getFeatureReport(reportID: UInt8, length: Int) async throws -> [UInt8] { [] }

    func sendOutputReport(reportID: UInt8, _ data: [UInt8]) async throws {
        sent.append(data)
        guard let request = HidppMessage.decode(payload: data) else { return }
        var parameters = status
        if request.featureIndex == 0 {
            let id = UInt16(request.parameters[0]) << 8 | UInt16(request.parameters[1])
            parameters = [features[id] ?? 0]
        }
        let message = HidppMessage(deviceIndex: request.deviceIndex, featureIndex: request.featureIndex,
                                   function: request.function, softwareID: request.softwareID, parameters: parameters)
        inbox.append((HidppMessage.longReportID, message.encodedPayload()))
    }

    func nextInputReport(timeout: Duration) async throws -> (reportID: UInt8, data: [UInt8]) {
        guard !inbox.isEmpty else { throw DriverError.deviceFailure("timed out waiting for the device") }
        return inbox.removeFirst()
    }
}

@Suite struct HidppBatteryTests {
    private let battery = CapabilityDescriptor(id: "battery", type: .battery, access: .read)

    @Test func unifiedBatteryIsPreferred() async throws {
        let transport = BatteryHidppTransport(features: [0x1004: 4, 0x1000: 5], status: [73, 4, 1, 0])
        #expect(try await HidppDriver().read(battery, using: transport) == .battery(percent: 73, charging: true))
        let last = await transport.sent.last
        #expect(last?[1] == 4 && last?[2] == 0x18)   // feature index 4, function 1, software id 8
    }

    @Test func levelStatusFallbackUsesFunctionZero() async throws {
        let transport = BatteryHidppTransport(features: [0x1000: 5], status: [40, 30, 0])
        #expect(try await HidppDriver().read(battery, using: transport) == .battery(percent: 40, charging: false))
        #expect(await transport.sent.last?[2] == 0x08)
    }

    @Test func voltageFallbackEstimatesPercent() async throws {
        // 3811 mV = 0x0EE3 is 50 % in Solaar's table; flag bit 7 = charging.
        let transport = BatteryHidppTransport(features: [0x1001: 6], status: [0x0E, 0xE3, 0x80])
        #expect(try await HidppDriver().read(battery, using: transport) == .battery(percent: 50, charging: true))
    }

    @Test func noBatteryFeatureIsUnsupported() async {
        let transport = BatteryHidppTransport(features: [:], status: [])
        await #expect(throws: DriverError.unsupportedCapability("battery")) {
            try await HidppDriver().read(battery, using: transport)
        }
    }

    @Test func decodersHandleEdges() {
        #expect(HidppBattery.unified([0, 8, 0]) == .battery(percent: 90, charging: false))   // flags only
        #expect(HidppBattery.unified([0, 0, 9]) == .battery(percent: nil, charging: nil))
        #expect(HidppBattery.levelStatus([0, 0, 3]) == .battery(percent: nil, charging: false))
        #expect(HidppBattery.percent(forMillivolts: 5000) == 100 && HidppBattery.percent(forMillivolts: 3000) == 0)
    }

    @Test func batteryValueCodableKeepsOldValuesIntact() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let value = SettingValue.battery(percent: 12, charging: nil)
        #expect(try decoder.decode(SettingValue.self, from: encoder.encode(value)) == value)
        #expect(try decoder.decode(SettingValue.self, from: Data("\"off\"".utf8)) == .text("off"))
        #expect(try decoder.decode(SettingValue.self, from: Data("7".utf8)) == .int(7))
    }
}
