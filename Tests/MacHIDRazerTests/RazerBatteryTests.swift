import Testing
import MacHIDDomain
@testable import MacHIDRazer

/// Fake device: answers each request through `respond`, recording what was sent.
private actor BatteryFakeTransport: Transport {
    private(set) var sent: [RazerReport] = []
    private var pending: [UInt8] = []
    private let respond: @Sendable (RazerReport) -> RazerReport

    init(respond: @escaping @Sendable (RazerReport) -> RazerReport) { self.respond = respond }

    func sendFeatureReport(reportID: UInt8, _ data: [UInt8]) async throws {
        let request = try RazerReport.decode(data)
        sent.append(request)
        pending = respond(request).encoded()
    }

    func getFeatureReport(reportID: UInt8, length: Int) async throws -> [UInt8] { pending }
}

private func answer(_ request: RazerReport, status: UInt8 = 0x02, arguments: [UInt8] = []) -> RazerReport {
    var response = request
    response.status = status
    response.arguments = arguments + [UInt8](repeating: 0, count: 80 - arguments.count)
    return response
}

@Suite struct RazerBatteryTests {
    private let battery = CapabilityDescriptor(id: "battery", type: .battery, access: .read)
    private let fast = Duration.milliseconds(1)

    @Test func readsLevelAndChargingWithModelTransactionID() async throws {
        let transport = BatteryFakeTransport { request in
            answer(request, arguments: [0, request.commandID == 0x80 ? 128 : 1])
        }
        let model = RazerModel(usbId: USBID(vendor: 0x1532, product: 0x0001), lightingTransactionID: 0x3F, batteryTransactionID: 0x1F)
        let value = try await RazerDriver(model: model, attempts: 1, settleDelay: fast).read(battery, using: transport)
        #expect(value == .battery(percent: 50, charging: true))
        let sent = await transport.sent
        #expect(sent.map(\.commandID) == [0x80, 0x84])
        #expect(sent.allSatisfy { $0.transactionID == 0x1F && $0.commandClass == 0x07 })
    }

    @Test func missingChargingQueryStillReportsLevel() async throws {
        let transport = BatteryFakeTransport { request in
            request.commandID == 0x80 ? answer(request, arguments: [0, 255]) : answer(request, status: 0x05)
        }
        let model = RazerModel(usbId: USBID(vendor: 0x1532, product: 0x0001), lightingTransactionID: 0x3F)
        let value = try await RazerDriver(model: model, attempts: 1, settleDelay: fast).read(battery, using: transport)
        #expect(value == .battery(percent: 100, charging: nil))
    }

    @Test func optionsSetBatteryTransactionID() {
        let id = USBID(vendor: 0x1532, product: 0x00AA)
        let model = RazerModel.model(for: id, options: ["lighting_transaction_id": "0x3F", "battery_transaction_id": "0xFF"])
        #expect(model?.batteryTransactionID == 0xFF)
        #expect(RazerModel.model(for: id, options: ["battery_transaction_id": "0xFF"]) == nil)
    }
}
