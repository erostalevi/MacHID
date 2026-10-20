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

    @Test func writesAreDisabled() async {
        let transport = FakeHidppTransport { _ in [] }
        await #expect(throws: DriverError.self) { try await HidppDriver().write(.int(800), to: dpiCapability, using: transport) }
        #expect(await transport.sent.isEmpty)
    }

    @Test func zeroDPIIsRejected() async {
        let transport = FakeHidppTransport { request in
            request.featureIndex == 0 ? [reply(to: request, parameters: [9])] : [reply(to: request, parameters: [0, 0, 0])]
        }
        await #expect(throws: HidppError.self) { try await HidppDriver().read(dpiCapability, using: transport) }
    }
}
