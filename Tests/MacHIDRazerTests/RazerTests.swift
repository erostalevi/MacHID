import Testing
import MacHIDDomain
@testable import MacHIDRazer

/// Fake device: answers each request through `respond`, recording what was sent.
private actor FakeTransport: Transport {
    private(set) var sent: [RazerReport] = []
    private var pending: [UInt8] = []
    private let respond: @Sendable (RazerReport, Int) -> RazerReport
    private var count = 0

    init(respond: @escaping @Sendable (RazerReport, Int) -> RazerReport) { self.respond = respond }
    init(respond: @escaping @Sendable (RazerReport) -> RazerReport) { self.respond = { request, _ in respond(request) } }

    func sendFeatureReport(reportID: UInt8, _ data: [UInt8]) async throws {
        let request = try RazerReport.decode(data)
        sent.append(request)
        count += 1
        pending = respond(request, count).encoded()
    }

    func getFeatureReport(reportID: UInt8, length: Int) async throws -> [UInt8] { pending }
}

private func ok(_ request: RazerReport, arguments: [UInt8]? = nil) -> RazerReport {
    var response = request
    response.status = 0x02
    if let arguments { response.arguments = arguments + [UInt8](repeating: 0, count: 80 - arguments.count) }
    return response
}

private let model = RazerModel(usbId: USBID(vendor: 0x1532, product: 0x0257), lightingTransactionID: 0x3F)
private let fast = Duration.milliseconds(1)
private func driver() -> RazerDriver { RazerDriver(model: model, attempts: 3, settleDelay: fast) }
private let brightness = CapabilityDescriptor(id: "brightness", type: .brightness, access: .writeVolatile)
private let backlight = CapabilityDescriptor(id: "backlight", type: .lightingZone, access: .writeVolatile)
private let info = CapabilityDescriptor(id: "info", type: .info, access: .read)

@Suite struct ReportTests {
    @Test func staticColorMatchesDocumentedPacket() {
        // From the OpenRazer notes: 00 3f 0000 00 09 0f 02 010501000001ff0000
        let bytes = RazerCommands.staticColor(RGBColor(r: 0xFF, g: 0, b: 0), transactionID: 0x3F).encoded()
        #expect(bytes.count == 90)
        #expect(Array(bytes[0..<17]) == [0x00, 0x3F, 0x00, 0x00, 0x00, 0x09, 0x0F, 0x02, 0x01, 0x05, 0x01, 0x00, 0x00, 0x01, 0xFF, 0x00, 0x00])
        #expect(bytes[88] == 0xFF)   // XOR of bytes 2..<88, worked out by hand
        #expect(bytes[89] == 0x00)
    }

    @Test func crcCoversBytes2To87Only() {
        var bytes = [UInt8](repeating: 0, count: 90)
        bytes[0] = 0xAA; bytes[1] = 0xBB; bytes[88] = 0xCC; bytes[89] = 0xDD
        #expect(RazerReport.crc(of: bytes) == 0)
        bytes[2] = 0x01; bytes[87] = 0x03
        #expect(RazerReport.crc(of: bytes) == 0x02)
    }

    @Test func roundTrips() throws {
        let report = RazerReport(transactionID: 0x3F, commandClass: 0x0F, commandID: 0x04, dataSize: 3,
                                 arguments: [1, 5, 200], status: 0x02)
        #expect(try RazerReport.decode(report.encoded()) == report)
    }

    @Test func decodeRejectsWrongLength() {
        #expect(throws: DriverError.self) { try RazerReport.decode([UInt8](repeating: 0, count: 89)) }
    }

    @Test func decodeClampsOversizedDataSize() throws {
        var bytes = RazerReport(transactionID: 1, commandClass: 0, commandID: 0, dataSize: 0).encoded()
        bytes[5] = 0xFF
        #expect(try RazerReport.decode(bytes).dataSize == 80)
    }

    @Test func noneAndBrightnessPackets() {
        let none = RazerCommands.effectNone(transactionID: 0x3F)
        #expect(none.dataSize == 6 && none.arguments.prefix(3) == [1, 5, 0])
        let bright = RazerCommands.setBrightness(255, transactionID: 0x3F)
        #expect(bright.commandClass == 0x0F && bright.commandID == 0x04 && bright.arguments.prefix(3) == [1, 5, 255])
        #expect(RazerCommands.getBrightness(transactionID: 0x3F).commandID == 0x84)
        #expect(RazerCommands.firmwareVersion().transactionID == 0xFF)
    }
}

@Suite struct DriverTests {
    @Test func readsFirmware() async throws {
        let transport = FakeTransport { ok($0, arguments: [1, 7]) }
        #expect(try await driver().read(info, using: transport) == .text("v1.7"))
        let sent = await transport.sent
        #expect(sent.first?.commandClass == 0x00 && sent.first?.commandID == 0x81)
    }

    @Test func brightnessConvertsPercentToRaw() async throws {
        let transport = FakeTransport { ok($0) }
        try await driver().write(.int(100), to: brightness, using: transport)
        try await driver().write(.int(0), to: brightness, using: transport)
        try await driver().write(.int(50), to: brightness, using: transport)
        let raws = await transport.sent.filter { $0.commandClass == 0x0F }.map { $0.arguments[2] }
        #expect(raws == [255, 0, 128])
        #expect(RazerDriver.percent(fromRaw: 255) == 100 && RazerDriver.percent(fromRaw: 128) == 50)
    }

    @Test func readsBrightnessAsPercent() async throws {
        let transport = FakeTransport { ok($0, arguments: [1, 5, 255]) }
        #expect(try await driver().read(brightness, using: transport) == .int(100))
    }

    @Test func rejectsBadValuesWithoutTouchingDevice() async throws {
        let transport = FakeTransport { ok($0) }
        await #expect(throws: DriverError.self) { try await driver().write(.int(101), to: brightness, using: transport) }
        await #expect(throws: DriverError.self) { try await driver().write(.text("x"), to: brightness, using: transport) }
        await #expect(throws: DriverError.self) { try await driver().write(.text("rainbow"), to: backlight, using: transport) }
        await #expect(throws: DriverError.self) { try await driver().read(backlight, using: transport) }
        #expect(await transport.sent.isEmpty)
    }

    @Test func sendsColorAndOff() async throws {
        let transport = FakeTransport { ok($0) }
        try await driver().write(.color(RGBColor(r: 1, g: 2, b: 3)), to: backlight, using: transport)
        try await driver().write(.text("off"), to: backlight, using: transport)
        let sent = await transport.sent.filter { $0.commandClass == 0x0F }
        #expect(sent[0].arguments[2] == 0x01 && Array(sent[0].arguments[6...8]) == [1, 2, 3])
        #expect(sent[1].arguments[2] == 0x00 && sent[1].dataSize == 6)
        #expect(sent.allSatisfy { $0.transactionID == 0x3F })
    }

    @Test func retriesWhileBusyThenSucceeds() async throws {
        let transport = FakeTransport { request, attempt in
            var response = ok(request)
            if attempt < 3 { response.status = 0x01 }
            return response
        }
        try await driver().write(.int(10), to: brightness, using: transport)
        #expect(await transport.sent.count == 5)  // get mode: busy, busy, ok; then set mode; then brightness
    }

    @Test func failsWhenAlwaysBusyOrFailing() async {
        let busy = FakeTransport { var r = ok($0); r.status = 0x01; return r }
        await #expect(throws: DriverError.self) { try await driver().write(.int(10), to: brightness, using: busy) }
        for status: UInt8 in [0x03, 0x04, 0x05] {
            let failing = FakeTransport { var r = ok($0); r.status = status; return r }
            await #expect(throws: DriverError.self) { try await driver().write(.int(10), to: brightness, using: failing) }
        }
    }

    @Test func mismatchedResponseIsAnError() async {
        let transport = FakeTransport { var r = ok($0); r.commandID = 0x99; return r }
        await #expect(throws: DriverError.self) { try await driver().write(.int(10), to: brightness, using: transport) }
    }

    @Test func knowsHuntsmanMini() {
        #expect(RazerModel.model(for: USBID(vendor: 0x1532, product: 0x0257))?.lightingTransactionID == 0x3F)
        #expect(RazerModel.model(for: USBID(vendor: 0x1532, product: 0x0001)) == nil)
    }

    @Test func deviceModeReadAndWrite() async throws {
        let mode = CapabilityDescriptor(id: "device_mode", type: .deviceMode, access: .writeVolatile)
        let transport = FakeTransport { ok($0, arguments: [3, 0]) }
        #expect(try await driver().read(mode, using: transport) == .int(3))
        try await driver().write(.int(3), to: mode, using: transport)
        try await driver().write(.int(0), to: mode, using: transport)
        let sent = await transport.sent
        #expect(sent[0].commandID == 0x84 && sent[0].transactionID == 0xFF)
        #expect(sent[1].commandClass == 0x00 && sent[1].commandID == 0x04 && Array(sent[1].arguments.prefix(2)) == [3, 0] && sent[1].dataSize == 2)
        #expect(sent[2].arguments[0] == 0)
    }

    @Test func deviceModeRejectsFactoryTestMode() async {
        let mode = CapabilityDescriptor(id: "device_mode", type: .deviceMode, access: .writeVolatile)
        let transport = FakeTransport { ok($0) }
        await #expect(throws: DriverError.self) { try await driver().write(.int(2), to: mode, using: transport) }
        #expect(await transport.sent.isEmpty)
    }

    @Test func lightingWriteEntersDriverModeFirst() async throws {
        // Device reports normal mode (0): expect get mode, set mode 3, then the lighting command.
        let transport = FakeTransport { ok($0, arguments: [0, 0]) }
        try await driver().write(.color(RGBColor(r: 255, g: 0, b: 0)), to: backlight, using: transport)
        let sent = await transport.sent
        #expect(sent.map(\.commandID) == [0x84, 0x04, 0x02])
        #expect(sent[1].commandClass == 0x00 && sent[1].arguments[0] == 3)
    }

    @Test func lightingWriteSkipsModeChangeWhenAlreadyInDriverMode() async throws {
        let transport = FakeTransport { ok($0, arguments: [3, 0]) }
        try await driver().write(.int(40), to: brightness, using: transport)
        #expect(await transport.sent.map(\.commandID) == [0x84, 0x04])
    }

    @Test func effectsUseTheDocumentedPacketLayouts() async throws {
        let tid: UInt8 = 0x3F
        // OpenRazer examples: spectrum 010503000000, wave 010504002800/010504012800,
        // reactive 010505000101ffff00, starlight single 010507000301ff0000 (speed 3).
        let spectrum = RazerCommands.spectrum(transactionID: tid)
        #expect(spectrum.dataSize == 6 && Array(spectrum.arguments.prefix(6)) == [1, 5, 3, 0, 0, 0])
        let wave = RazerCommands.wave(direction: 1, transactionID: tid)
        #expect(Array(wave.arguments.prefix(6)) == [1, 5, 4, 1, 0x28, 0])
        let reactive = RazerCommands.reactive(speed: 1, color: RGBColor(r: 0xFF, g: 0xFF, b: 0), transactionID: tid)
        #expect(reactive.dataSize == 9 && Array(reactive.arguments.prefix(9)) == [1, 5, 5, 0, 1, 1, 0xFF, 0xFF, 0])
        let single = RazerCommands.starlight(speed: 3, color: RGBColor(r: 0xFF, g: 0, b: 0), transactionID: tid)
        #expect(single.dataSize == 9 && Array(single.arguments.prefix(9)) == [1, 5, 7, 0, 3, 1, 0xFF, 0, 0])
        let random = RazerCommands.starlight(speed: 9, color: nil, transactionID: tid)
        #expect(random.dataSize == 6 && random.arguments[4] == 3)       // speed clamps to 3
        #expect(RazerCommands.reactive(speed: 0, color: RGBColor(r: 0, g: 0, b: 0), transactionID: tid).arguments[4] == 1)
    }

    @Test func driverSendsEachEffectInDriverMode() async throws {
        let transport = FakeTransport { ok($0, arguments: [3, 0]) }       // already in driver mode
        for effect in [LightingEffect("spectrum"), LightingEffect("wave"),
                       LightingEffect("reactive", color: RGBColor(r: 1, g: 2, b: 3)), LightingEffect("starlight")] {
            try await driver().write(.effect(effect), to: backlight, using: transport)
        }
        let effects = await transport.sent.filter { $0.commandClass == 0x0F }.map { $0.arguments[2] }
        #expect(effects == [0x03, 0x04, 0x05, 0x07])
    }

    @Test func badEffectsAreRejectedBeforeSending() async {
        let transport = FakeTransport { ok($0) }
        await #expect(throws: DriverError.self) { try await driver().write(.effect(LightingEffect("reactive")), to: backlight, using: transport) }
        await #expect(throws: DriverError.self) { try await driver().write(.effect(LightingEffect("fireworks")), to: backlight, using: transport) }
        #expect(await transport.sent.filter { $0.commandClass == 0x0F }.isEmpty)
    }
}
