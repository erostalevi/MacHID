import Testing
import MacHIDDomain
@testable import MacHIDLogitech

/// Fake HID++ device: for every output report, `script` decides which input reports come back.
private actor FakeHidppTransport: Transport {
    private(set) var sent: [(reportID: UInt8, data: [UInt8])] = []
    private var inbox: [(reportID: UInt8, data: [UInt8])] = []
    private let script: @Sendable (HidppMessage) -> [(UInt8, [UInt8])]

    init(script: @escaping @Sendable (HidppMessage) -> [(UInt8, [UInt8])]) { self.script = script }

    func sendFeatureReport(reportID: UInt8, _ data: [UInt8]) async throws {}
    func getFeatureReport(reportID: UInt8, length: Int) async throws -> [UInt8] { [] }

    func sendOutputReport(reportID: UInt8, _ data: [UInt8]) async throws {
        sent.append((reportID, data))
        if let request = HidppMessage.decode(payload: data) {
            inbox += script(request).map { (reportID: $0.0, data: $0.1) }
        }
    }

    func nextInputReport(timeout: Duration) async throws -> (reportID: UInt8, data: [UInt8]) {
        guard !inbox.isEmpty else { throw DriverError.deviceFailure("timed out waiting for the device") }
        return inbox.removeFirst()
    }
}

private func reply(to request: HidppMessage, parameters: [UInt8], swid: UInt8? = nil, feature: UInt8? = nil) -> (UInt8, [UInt8]) {
    let message = HidppMessage(deviceIndex: request.deviceIndex, featureIndex: feature ?? request.featureIndex,
                               function: request.function, softwareID: swid ?? request.softwareID, parameters: parameters)
    return (HidppMessage.longReportID, message.encodedPayload())
}

private let dpiCapability = CapabilityDescriptor(id: "dpi", type: .dpi, access: .read)
private let infoCapability = CapabilityDescriptor(id: "info", type: .info, access: .read)

@Suite struct MessageTests {
    @Test func encodesLikeKnownTrafficLayout() {
        // Layout of the community-documented lighting packet: 11 ff 0e 3c 00 ... (function 3, software id 0xC)
        let message = HidppMessage(deviceIndex: 0xFF, featureIndex: 0x0E, function: 0x3, softwareID: 0xC,
                                   parameters: [0x00, 0x01, 0xFF, 0x00, 0x00, 0x02])
        let payload = message.encodedPayload()
        #expect(payload.count == 19)
        #expect(Array(payload.prefix(9)) == [0xFF, 0x0E, 0x3C, 0x00, 0x01, 0xFF, 0x00, 0x00, 0x02])
    }

    @Test func roundTripsAndRejectsWrongSize() {
        let message = HidppMessage(deviceIndex: 1, featureIndex: 2, function: 3, softwareID: 4, parameters: [9])
        #expect(HidppMessage.decode(payload: message.encodedPayload()) == message)
        #expect(HidppMessage.decode(payload: [UInt8](repeating: 0, count: 18)) == nil)
    }
}

@Suite struct ClientTests {
    private func client(_ transport: FakeHidppTransport) -> HidppClient { HidppClient(transport: transport, timeout: .milliseconds(200)) }

    @Test func protocolVersionPingsAndChecksEcho() async throws {
        let transport = FakeHidppTransport { [reply(to: $0, parameters: [4, 2, $0.parameters[2]])] }
        let version = try await client(transport).protocolVersion()
        #expect(version.major == 4 && version.minor == 2)
        let sent = await transport.sent
        #expect(sent.first?.reportID == 0x11 && sent.first?.data[2] == 0x18)  // function 1, software id 8
    }

    @Test func badPingEchoIsRejected() async {
        let transport = FakeHidppTransport { [reply(to: $0, parameters: [4, 2, 0x00])] }
        await #expect(throws: HidppError.self) { try await client(transport).protocolVersion() }
    }

    @Test func skipsNotificationsAndOtherSoftwareIDs() async throws {
        let transport = FakeHidppTransport { request in [
            reply(to: request, parameters: [1], swid: 0x03),              // someone else's reply
            reply(to: request, parameters: [1], feature: 0x07),           // notification from another feature
            (0x20, [0xFF, 0x00, 0x00]),                                    // unrelated report id
            reply(to: request, parameters: [7, 0]),                        // the real one
        ] }
        #expect(try await client(transport).featureIndex(for: 0x2201) == 7)
    }

    @Test func featureIndexZeroMeansNotFound() async {
        let transport = FakeHidppTransport { [reply(to: $0, parameters: [0, 0])] }
        await #expect(throws: HidppError.featureNotFound(0x8071)) { try await client(transport).featureIndex(for: 0x8071) }
    }

    @Test func errorReportBecomesDeviceError() async {
        // [dev][0xFF][failed feature index][failed function << 4 | swid][error code]
        let transport = FakeHidppTransport { request in
            [(HidppMessage.longReportID, [request.deviceIndex, 0xFF, request.featureIndex,
                                          request.function << 4 | request.softwareID, 0x05] + [UInt8](repeating: 0, count: 14))]
        }
        await #expect(throws: HidppError.device(code: 0x05)) { try await client(transport).featureIndex(for: 0x2201) }
    }

    @Test func errorForAnotherRequestIsIgnored() async throws {
        let transport = FakeHidppTransport { request in [
            (HidppMessage.longReportID, [request.deviceIndex, 0xFF, 0x42, 0x38, 0x05] + [UInt8](repeating: 0, count: 14)),
            reply(to: request, parameters: [7, 0]),
        ] }
        #expect(try await client(transport).featureIndex(for: 0x2201) == 7)
    }

    @Test func timesOutWhenSilent() async {
        let transport = FakeHidppTransport { _ in [] }
        await #expect(throws: DriverError.self) { try await client(transport).protocolVersion() }
    }
}

@Suite struct DriverTests {
    @Test func readsDPIThroughFeatureDiscovery() async throws {
        let transport = FakeHidppTransport { request in
            if request.featureIndex == 0x00, request.function == 0 { return [reply(to: request, parameters: [9, 0, 1])] }
            if request.featureIndex == 9, request.function == 2 { return [reply(to: request, parameters: [0, 0x06, 0x40, 0x03, 0x20])] } // 1600, default 800
            return []
        }
        #expect(try await HidppDriver().read(dpiCapability, using: transport) == .int(1600))
        let sent = await transport.sent.map(\.data)
        #expect(sent[1][1] == 9 && sent[1][2] == 0x28 && sent[1][3] == 0)  // function 2, swid 8, sensor 0
    }

    @Test func readsInfoAsProtocolVersion() async throws {
        let transport = FakeHidppTransport { [reply(to: $0, parameters: [4, 2, $0.parameters[2]])] }
        #expect(try await HidppDriver().read(infoCapability, using: transport) == .text("HID++ 4.2"))
    }

    @Test func zeroDPIIsRejected() async {
        let transport = FakeHidppTransport { request in
            request.featureIndex == 0 ? [reply(to: request, parameters: [9])] : [reply(to: request, parameters: [0, 0, 0])]
        }
        await #expect(throws: HidppError.self) { try await HidppDriver().read(dpiCapability, using: transport) }
    }
}

// MARK: - Simulated mouse for write tests

private let dpiFeature: UInt8 = 9
private let ledFeature: UInt8 = 5

/// Simulates a mouse with ADJUSTABLE_DPI (index 9) and COLOR_LED_EFFECTS (index 5, one zone).
private func simulatedMouse(effectIDs: [UInt16] = [0, 1, 3], hostControl: UInt8 = 0, echoDPI: Bool = true,
                            dpiList: [UInt8]? = nil) -> @Sendable (HidppMessage) -> [(UInt8, [UInt8])] {
    let list = dpiList ?? [0, 0x00, 0xC8, 0xE0, 0x32, 0x1F, 0x40]   // sensor 0: 200 .. 8000, step 50
    return { request in
        func answer(_ parameters: [UInt8]) -> [(UInt8, [UInt8])] { [reply(to: request, parameters: parameters)] }
        switch (request.featureIndex, request.function) {
        case (0x00, 0):
            let id = UInt16(request.parameters[0]) << 8 | UInt16(request.parameters[1])
            switch id {
            case 0x2201: return answer([dpiFeature, 0, 1])
            case 0x8070: return answer([ledFeature, 0, 1])
            default: return answer([0, 0, 0])
            }
        case (dpiFeature, 1): return answer(list)
        case (dpiFeature, 3):
            return answer(echoDPI ? [0, request.parameters[1], request.parameters[2]] : [0, 0, 0])
        case (ledFeature, 0): return answer([1])                                      // one zone
        case (ledFeature, 1): return answer([0, 0, 1, UInt8(effectIDs.count), 0])     // zone 0, N effects
        case (ledFeature, 2):
            let id = effectIDs[Int(request.parameters[1])]
            return answer([0, request.parameters[1], UInt8(id >> 8), UInt8(id & 0xFF)])
        case (ledFeature, 7): return answer([hostControl])
        case (ledFeature, 8), (ledFeature, 3): return answer(request.parameters)
        default: return []
        }
    }
}

private let backlightCapability = CapabilityDescriptor(id: "backlight", type: .lightingZone, access: .writeVolatile)
private let modeCapability = CapabilityDescriptor(id: "device_mode", type: .deviceMode, access: .writeVolatile)

private func calls(_ transport: FakeHidppTransport) async -> [(feature: UInt8, function: UInt8, parameters: [UInt8])] {
    await transport.sent.compactMap { HidppMessage.decode(payload: $0.data) }.map { ($0.featureIndex, $0.function, $0.parameters) }
}

@Suite struct DPIListTests {
    @Test func parsesRangeWithStep() {
        let list = HidppDPIList.parse([0, 0x00, 0xC8, 0xE0, 0x32, 0x1F, 0x40, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(list.values == [200, 8000] && list.step == 50)
        #expect(list.contains(200) && list.contains(3200) && list.contains(8000))
        #expect(!list.contains(3225) && !list.contains(150) && !list.contains(8050))
    }

    @Test func parsesExplicitList() {
        let list = HidppDPIList.parse([0, 0x03, 0x20, 0x06, 0x40, 0x0C, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(list.values == [800, 1600, 3200] && list.step == nil)
        #expect(list.contains(1600) && !list.contains(1000))
    }
}

@Suite struct WriteTests {
    @Test func dpiWriteSendsBigEndianValueToSensorZero() async throws {
        let transport = FakeHidppTransport(script: simulatedMouse())
        try await HidppDriver().write(.int(3200), to: dpiCapability, using: transport)
        let sent = await calls(transport)
        let set = try #require(sent.last)
        #expect(set.feature == dpiFeature && set.function == 3)
        #expect(Array(set.parameters.prefix(3)) == [0, 0x0C, 0x80])
    }

    @Test func unsupportedDPIIsNeverSent() async {
        let transport = FakeHidppTransport(script: simulatedMouse())
        await #expect(throws: DriverError.self) { try await HidppDriver().write(.int(3225), to: dpiCapability, using: transport) }
        await #expect(throws: DriverError.self) { try await HidppDriver().write(.int(0), to: dpiCapability, using: transport) }
        #expect(await calls(transport).allSatisfy { !($0.feature == dpiFeature && $0.function == 3) })
    }

    @Test func dpiEchoMismatchIsAnError() async {
        let transport = FakeHidppTransport(script: { request in
            request.featureIndex == dpiFeature && request.function == 3
                ? [reply(to: request, parameters: [0, 0x03, 0x20])]
                : simulatedMouse()(request)
        })
        await #expect(throws: HidppError.self) { try await HidppDriver().write(.int(3200), to: dpiCapability, using: transport) }
    }

    @Test func dpiWriteAcceptsDevicesThatDoNotEcho() async throws {
        let transport = FakeHidppTransport(script: simulatedMouse(echoDPI: false))
        try await HidppDriver().write(.int(800), to: dpiCapability, using: transport)
    }

    @Test func staticColorTakesHostControlThenSetsFixedEffectInRAM() async throws {
        let transport = FakeHidppTransport(script: simulatedMouse(effectIDs: [0, 3, 1], hostControl: 0))
        try await HidppDriver().write(.color(RGBColor(r: 0xFF, g: 0x10, b: 0x20)), to: backlightCapability, using: transport)
        let sent = await calls(transport)
        let ledCalls = sent.filter { $0.feature == ledFeature }.map(\.function)
        #expect(ledCalls == [7, 8, 0, 1, 2, 2, 2, 3])   // read control, take control, zone info, scan 3 effects, set
        #expect(sent.first { $0.function == 8 }?.parameters.first == 1)
        let set = try #require(sent.last)
        // effect id 1 (fixed) is at position 2 in this device's list
        #expect(Array(set.parameters.prefix(5)) == [0, 2, 0xFF, 0x10, 0x20])
        #expect(set.parameters[12] == 0)                // persistence flag must stay 0 (RAM only)
    }

    @Test func alreadyInHostControlSkipsTakeover() async throws {
        let transport = FakeHidppTransport(script: simulatedMouse(hostControl: 1))
        try await HidppDriver().write(.color(RGBColor(r: 1, g: 2, b: 3)), to: backlightCapability, using: transport)
        #expect(await calls(transport).allSatisfy { !($0.feature == ledFeature && $0.function == 8) })
    }

    @Test func offUsesTheDisabledEffect() async throws {
        let transport = FakeHidppTransport(script: simulatedMouse(effectIDs: [1, 0]))
        try await HidppDriver().write(.text("off"), to: backlightCapability, using: transport)
        let set = try #require(await calls(transport).last)
        #expect(set.function == 3 && set.parameters[0] == 0 && set.parameters[1] == 1)   // disabled is at position 1
    }

    @Test func missingEffectFailsBeforeSetting() async {
        let transport = FakeHidppTransport(script: simulatedMouse(effectIDs: [3, 4]))
        await #expect(throws: DriverError.self) {
            try await HidppDriver().write(.color(RGBColor(r: 1, g: 1, b: 1)), to: backlightCapability, using: transport)
        }
        #expect(await calls(transport).allSatisfy { !($0.feature == ledFeature && $0.function == 3) })
    }

    @Test func deviceModeReadsAndWrites() async throws {
        let transport = FakeHidppTransport(script: simulatedMouse(hostControl: 1))
        #expect(try await HidppDriver().read(modeCapability, using: transport) == .int(1))
        try await HidppDriver().write(.int(0), to: modeCapability, using: transport)
        let set = try #require(await calls(transport).last)
        #expect(set.feature == ledFeature && set.function == 8 && set.parameters[0] == 0)
        await #expect(throws: DriverError.self) { try await HidppDriver().write(.int(2), to: modeCapability, using: transport) }
    }

    @Test func wrongValueTypesAreRejected() async {
        let transport = FakeHidppTransport(script: simulatedMouse())
        await #expect(throws: DriverError.self) { try await HidppDriver().write(.text("x"), to: dpiCapability, using: transport) }
        await #expect(throws: DriverError.self) { try await HidppDriver().write(.text("rainbow"), to: backlightCapability, using: transport) }
        #expect(await transport.sent.isEmpty)
    }
}
