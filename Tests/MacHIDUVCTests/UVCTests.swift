import Testing
import MacHIDDomain
@testable import MacHIDUVC

/// Video Control part of the Logitech Brio 100's configuration descriptor, as read from a real device
/// (extension units kept, the streaming interfaces left out).
private let brioDescriptor: [UInt8] = [
    0x09, 0x04, 0x00, 0x00, 0x01, 0x0E, 0x01, 0x00, 0x00,                                  // interface 0: Video Control
    0x0D, 0x24, 0x01, 0x00, 0x01, 0xA0, 0x00, 0x00, 0x6C, 0xDC, 0x02, 0x01, 0x01,          // VC header
    0x12, 0x24, 0x02, 0x01, 0x01, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x0E, 0x00, 0x00, // camera terminal 1
    0x0B, 0x24, 0x05, 0x02, 0x01, 0x00, 0x40, 0x02, 0x5B, 0x17, 0x00,                      // processing unit 2
    0x1B, 0x24, 0x06, 0x05, 0xE4, 0x8E, 0x67, 0x69, 0x0F, 0x41, 0xDB, 0x40, 0xA8, 0x50, 0x74, 0x20, 0xD7, 0xD8, 0x24, 0x0E, 0x08, 0x01, 0x02, 0x02, 0x3F, 0x07, 0x00, // extension unit 5
    0x09, 0x24, 0x03, 0x03, 0x01, 0x01, 0x00, 0x05, 0x00,                                  // output terminal
    0x09, 0x04, 0x01, 0x00, 0x00, 0x0E, 0x02, 0x00, 0x00,                                  // interface 1: Video Streaming
]

@Suite struct DescriptorTests {
    @Test func parsesBrioUnitsAndControlBitmaps() throws {
        let descriptor = try UVCDescriptor.parse(configuration: brioDescriptor)
        #expect(descriptor.videoControlInterface == 0)
        #expect(descriptor.processingUnitID == 2)
        #expect(descriptor.processingControls == 0x175B)
        #expect(descriptor.cameraTerminalID == 1)
        #expect(descriptor.cameraControls == 0x0E)
    }

    @Test func rejectsDescriptorsWithoutVideoControl() {
        #expect(throws: DriverError.self) { try UVCDescriptor.parse(configuration: [0x09, 0x04, 0x01, 0x00, 0x00, 0x03, 0x01, 0x01, 0x00]) }
        #expect(throws: DriverError.self) { try UVCDescriptor.parse(configuration: []) }
    }

    @Test func survivesTruncatedAndMalformedInput() {
        for cut in [3, 10, 25, 40, 60] {
            _ = try? UVCDescriptor.parse(configuration: Array(brioDescriptor.prefix(cut)))
        }
        #expect(throws: DriverError.self) { try UVCDescriptor.parse(configuration: [0x00, 0x00, 0x00]) }
    }
}

private actor FakeCamera: Transport {
    struct Write: Equatable { let requestType: UInt8; let request: UInt8; let value: UInt16; let index: UInt16; let data: [UInt8] }
    private(set) var writes: [Write] = []
    private(set) var reads: [(request: UInt8, value: UInt16, index: UInt16)] = []
    private let descriptor: [UInt8]
    private let answer: @Sendable (UInt8, UInt16) -> [UInt8]

    init(descriptor: [UInt8] = brioDescriptor, answer: @escaping @Sendable (UInt8, UInt16) -> [UInt8]) {
        self.descriptor = descriptor
        self.answer = answer
    }

    func sendFeatureReport(reportID: UInt8, _ data: [UInt8]) async throws {}
    func getFeatureReport(reportID: UInt8, length: Int) async throws -> [UInt8] { [] }
    func usbConfigurationDescriptor() async throws -> [UInt8] { descriptor }

    func controlRead(requestType: UInt8, request: UInt8, value: UInt16, index: UInt16, length: Int) async throws -> [UInt8] {
        #expect(requestType == 0xA1)
        reads.append((request, value, index))
        return answer(request, value)
    }

    func controlWrite(requestType: UInt8, request: UInt8, value: UInt16, index: UInt16, data: [UInt8]) async throws {
        writes.append(Write(requestType: requestType, request: request, value: value, index: index, data: data))
    }
}

/// Brightness-like answers: min -64, max 64, resolution 1, current -10.
private let brightnessAnswers: @Sendable (UInt8, UInt16) -> [UInt8] = { request, _ in
    switch request {
    case 0x82: [0xC0, 0xFF]       // -64
    case 0x83: [0x40, 0x00]       // 64
    case 0x84: [0x01, 0x00]
    case 0x81: [0xF6, 0xFF]       // -10
    default: []
    }
}

private func capability(_ id: String) -> CapabilityDescriptor { CapabilityDescriptor(id: id, type: .cameraControl, access: .writeVolatile) }

@Suite struct DriverTests {
    @Test func listsSupportedControlsFromTheBitmap() async throws {
        let value = try await UVCDriver().read(CapabilityDescriptor(id: "info", type: .info, access: .read),
                                               using: FakeCamera { _, _ in [] })
        #expect(value == .text("brightness contrast saturation sharpness white_balance_temperature backlight_compensation gain power_line_frequency white_balance_auto exposure_auto exposure_time"))
    }

    @Test func readsSignedBrightnessWithCorrectAddressing() async throws {
        let camera = FakeCamera(answer: brightnessAnswers)
        #expect(try await UVCDriver().read(capability("brightness"), using: camera) == .int(-10))
        let read = try #require(await camera.reads.first)
        #expect(read.request == 0x81 && read.value == 0x0200)       // GET_CUR, selector 2 << 8
        #expect(read.index == 0x0200)                               // unit 2 << 8 | interface 0
    }

    @Test func unsignedControlsDoNotGoNegative() async throws {
        let camera = FakeCamera { _, _ in [0xF6, 0xFF] }
        #expect(try await UVCDriver().read(capability("contrast"), using: camera) == .int(0xFFF6))
    }

    @Test func shortRepliesAreZeroExtended() async throws {
        let camera = FakeCamera { _, _ in [0x2A] }
        #expect(try await UVCDriver().read(capability("gain"), using: camera) == .int(42))
    }

    @Test func writeSendsLittleEndianSetCurWithinTheCameraRange() async throws {
        let camera = FakeCamera(answer: brightnessAnswers)
        try await UVCDriver().write(.int(-20), to: capability("brightness"), using: camera)
        let write = try #require(await camera.writes.first)
        #expect(write == .init(requestType: 0x21, request: 0x01, value: 0x0200, index: 0x0200, data: [0xEC, 0xFF]))
    }

    @Test func outOfRangeAndOffStepValuesAreNeverSent() async {
        let camera = FakeCamera { request, _ in
            switch request {
            case 0x82: [0x00, 0x00]
            case 0x83: [0xFF, 0x00]
            case 0x84: [0x05, 0x00]   // steps of 5
            default: []
            }
        }
        await #expect(throws: DriverError.self) { try await UVCDriver().write(.int(256), to: capability("contrast"), using: camera) }
        await #expect(throws: DriverError.self) { try await UVCDriver().write(.int(-1), to: capability("contrast"), using: camera) }
        await #expect(throws: DriverError.self) { try await UVCDriver().write(.int(7), to: capability("contrast"), using: camera) }
        try? await UVCDriver().write(.int(10), to: capability("contrast"), using: camera)
        #expect(await camera.writes.count == 1)
    }

    @Test func flagsAndEnumerationsAreChecked() async throws {
        let camera = FakeCamera { _, _ in [] }
        await #expect(throws: DriverError.self) { try await UVCDriver().write(.int(2), to: capability("white_balance_auto"), using: camera) }
        await #expect(throws: DriverError.self) { try await UVCDriver().write(.int(3), to: capability("power_line_frequency"), using: camera) }
        await #expect(throws: DriverError.self) { try await UVCDriver().write(.text("on"), to: capability("white_balance_auto"), using: camera) }
        #expect(await camera.writes.isEmpty)
        try await UVCDriver().write(.int(1), to: capability("white_balance_auto"), using: camera)
        let write = try #require(await camera.writes.first)
        #expect(write.data == [1] && write.value == 0x0B00)
    }

    @Test func controlsTheCameraDoesNotAdvertiseAreRejected() async {
        // Same descriptor but with the processing unit's bitmap cleared.
        var descriptor = brioDescriptor
        let unit = descriptor.firstIndex(of: 0x5B)!
        descriptor[unit] = 0; descriptor[unit + 1] = 0
        let camera = FakeCamera(descriptor: descriptor, answer: brightnessAnswers)
        await #expect(throws: DriverError.self) { try await UVCDriver().read(capability("brightness"), using: camera) }
        await #expect(throws: DriverError.self) { try await UVCDriver().write(.int(0), to: capability("brightness"), using: camera) }
        #expect(await camera.writes.isEmpty)
    }

    @Test func unknownCapabilityIsRejected() async {
        await #expect(throws: DriverError.self) { try await UVCDriver().read(capability("zoom"), using: FakeCamera { _, _ in [] }) }
    }

    @Test func encodeDecodeRoundTrip() {
        #expect(UVCDriver.decode(UVCDriver.encode(-20, size: 2), size: 2, signed: true) == -20)
        #expect(UVCDriver.encode(0x1234, size: 2) == [0x34, 0x12])
        #expect(UVCDriver.decode([0xFF], size: 1, signed: false) == 255)
    }
}

@Suite struct LimitsTests {
    @Test func rangeControlsReportTheCamerasOwnLimits() async throws {
        let camera = FakeCamera(answer: brightnessAnswers)
        let limits = try await UVCDriver().limits(for: capability("brightness"), using: camera)
        #expect(limits?.min == -64 && limits?.max == 64 && limits?.step == 1)
    }

    @Test func flagsAndEnumerationsHaveNoDeviceLimits() async throws {
        let camera = FakeCamera { _, _ in [] }
        #expect(try await UVCDriver().limits(for: capability("white_balance_auto"), using: camera) == nil)
        #expect(try await UVCDriver().limits(for: capability("power_line_frequency"), using: camera) == nil)
    }
}


@Suite struct ExposureTests {
    /// Camera terminal is unit 1 on the Brio; AE mode GET_RES lists supported modes (manual + aperture priority = 0x09).
    private func camera(mode: Int = 8, modes: [UInt8] = [0x09]) -> FakeCamera {
        FakeCamera { request, value in
            switch (request, value) {
            case (0x81, 0x0200): [UInt8(mode)]
            case (0x84, 0x0200): modes
            case (0x82, 0x0400): [0x01, 0x00, 0x00, 0x00]          // min 1
            case (0x83, 0x0400): [0x40, 0x0D, 0x03, 0x00]          // max 200000 (20 s)
            case (0x84, 0x0400): [0x01, 0x00, 0x00, 0x00]
            case (0x81, 0x0400): [0xF4, 0x01, 0x00, 0x00]          // 500
            default: []
            }
        }
    }

    @Test func autoExposureReadsAsAFlag() async throws {
        #expect(try await UVCDriver().read(capability("exposure_auto"), using: camera(mode: 8)) == .int(1))
        #expect(try await UVCDriver().read(capability("exposure_auto"), using: camera(mode: 1)) == .int(0))
    }

    @Test func turningAutoOnPicksASupportedAutomaticMode() async throws {
        let transport = camera(modes: [0x09])
        try await UVCDriver().write(.int(1), to: capability("exposure_auto"), using: transport)
        let write = try #require(await transport.writes.first)
        // camera terminal (unit 1) addressed in wIndex, AE mode selector 2, aperture priority (8)
        #expect(write.index == 0x0100 && write.value == 0x0200 && write.data == [8])
        try await UVCDriver().write(.int(0), to: capability("exposure_auto"), using: transport)
        #expect(await transport.writes.last?.data == [1])
    }

    @Test func fallsBackToOtherAutomaticModesAndFailsWhenThereIsNone() async throws {
        #expect(UVCDriver.automaticExposureMode(supported: 0x14) == 4)
        #expect(UVCDriver.automaticExposureMode(supported: 0x0A) == 8)
        #expect(UVCDriver.automaticExposureMode(supported: 0x06) == 2)
        #expect(UVCDriver.automaticExposureMode(supported: 0x01) == nil)
        await #expect(throws: DriverError.self) {
            try await UVCDriver().write(.int(1), to: capability("exposure_auto"), using: camera(modes: [0x01]))
        }
    }

    @Test func exposureTimeUsesFourByteLimitsAndValues() async throws {
        let transport = camera()
        #expect(try await UVCDriver().limits(for: capability("exposure_time"), using: transport) .map { [$0.min, $0.max, $0.step] } == [1, 200_000, 1])
        #expect(try await UVCDriver().read(capability("exposure_time"), using: transport) == .int(500))
        try await UVCDriver().write(.int(1000), to: capability("exposure_time"), using: transport)
        let write = try #require(await transport.writes.first)
        #expect(write.data == [0xE8, 0x03, 0x00, 0x00] && write.index == 0x0100 && write.value == 0x0400)
        await #expect(throws: DriverError.self) { try await UVCDriver().write(.int(0), to: capability("exposure_time"), using: transport) }
    }
}

@Suite struct DefaultValueTests {
    @Test func limitsCarryTheCamerasOwnDefaultWhenItIsInRange() async throws {
        let camera = FakeCamera { request, _ in
            switch request {
            case 0x82: [0x00, 0x00]
            case 0x83: [0xFF, 0x00]
            case 0x84: [0x01, 0x00]
            case 0x87: [0x80, 0x00]
            default: []
            }
        }
        #expect(try await UVCDriver().limits(for: capability("contrast"), using: camera)?.defaultValue == 128)
    }

    @Test func aDefaultOutsideTheRangeIsIgnored() async throws {
        let camera = FakeCamera { request, _ in
            switch request {
            case 0x82: [0x00, 0x00]
            case 0x83: [0x0A, 0x00]
            case 0x84: [0x01, 0x00]
            case 0x87: [0xFF, 0x00]
            default: []
            }
        }
        #expect(try await UVCDriver().limits(for: capability("contrast"), using: camera)?.defaultValue == nil)
    }
}
