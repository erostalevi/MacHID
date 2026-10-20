import Foundation
import Testing
import MacHIDDomain
@testable import MacHIDRazer

private actor Recorder: Transport {
    private(set) var sent: [[UInt8]] = []
    private var pending: [UInt8] = []

    func sendFeatureReport(reportID: UInt8, _ data: [UInt8]) async throws {
        sent.append(data)
        var response = try RazerReport.decode(data)
        response.status = 0x02
        if response.commandClass == 0x00 && response.commandID == 0x84 { response.arguments[0] = 3 }   // driver mode
        pending = response.encoded()
    }
    func getFeatureReport(reportID: UInt8, length: Int) async throws -> [UInt8] { pending }
    /// Lighting reports only (class 0x0F).
    var lighting: [[UInt8]] { sent.filter { $0[6] == 0x0F } }
}

private let mini = RazerModel(usbId: USBID(vendor: 0x1532, product: 0x0257), lightingTransactionID: 0x3F)
private func driver() -> RazerDriver { RazerDriver(model: mini, attempts: 2, settleDelay: .milliseconds(1)) }
private let backlight = CapabilityDescriptor(id: "backlight", type: .lightingZone, access: .writeVolatile)
private let keys = CapabilityDescriptor(id: "key_lighting", type: .perKeyLighting, access: .writeVolatile,
                                        parameters: CapabilityParameters(rows: 5, columns: 15))
private let red = RGBColor(r: 0xFF, g: 0, b: 0)
private let green = RGBColor(r: 0, g: 0xFF, b: 0)

/// 90-byte frame: status 0, tid 0x3F, data size, class 0x0F, command, args, CRC (XOR of bytes 2..<88), reserved 0.
private func frame(size: UInt8, command: UInt8, _ args: [UInt8], crc: UInt8) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 90)
    bytes[1] = 0x3F; bytes[5] = size; bytes[6] = 0x0F; bytes[7] = command
    bytes.replaceSubrange(8..<(8 + args.count), with: args)
    bytes[88] = crc
    return bytes
}

@Suite struct RazerFeatureReportTests {
    @Test func breathingRandomSingleDual() {
        #expect(RazerCommands.breathing(color: nil, secondColor: nil, transactionID: 0x3F).encoded()
                == frame(size: 6, command: 2, [1, 5, 2], crc: 0x0D))
        #expect(RazerCommands.breathing(color: green, secondColor: nil, transactionID: 0x3F).encoded()
                == frame(size: 9, command: 2, [1, 5, 2, 1, 0, 1, 0, 0xFF, 0], crc: 0xFD))
        #expect(RazerCommands.breathing(color: green, secondColor: red, transactionID: 0x3F).encoded()
                == frame(size: 0x0C, command: 2, [1, 5, 2, 2, 0, 2, 0, 0xFF, 0, 0xFF, 0, 0], crc: 0x07))
    }

    @Test func starlightDual() {
        let report = RazerCommands.starlight(speed: 3, color: red, secondColor: green, transactionID: 0x3F)
        #expect(report.encoded() == frame(size: 0x0C, command: 2, [1, 5, 7, 0, 3, 2, 0xFF, 0, 0, 0, 0xFF, 0], crc: 0x03))
    }

    @Test func waveDirectionZero() {
        #expect(RazerCommands.wave(direction: 0, transactionID: 0x3F).encoded()
                == frame(size: 6, command: 2, [1, 5, 4, 0, 0x28], crc: 0x23))
    }

    @Test func customFrameRowAndActivation() {
        let row = RazerCommands.customFrameRow(row: 2, startColumn: 0, colors: [red, green, RGBColor(r: 0, g: 0, b: 0xFF)],
                                               transactionID: 0x3F)
        #expect(row.encoded() == frame(size: 0x47, command: 3, [0, 0, 2, 0, 2, 0xFF, 0, 0, 0, 0xFF, 0, 0, 0, 0xFF], crc: 0xB4))
        #expect(RazerCommands.activateCustomFrame(transactionID: 0x3F).encoded()
                == frame(size: 0x0C, command: 2, [0, 0, 8], crc: 0x09))
    }
}

@Suite struct RazerFeatureDriverTests {
    @Test func effectsMapToCommands() async throws {
        let transport = Recorder()
        let effects = [
            LightingEffect("breathing"),
            LightingEffect("breathing", color: green),
            LightingEffect("breathing", color: green, secondColor: red),
            LightingEffect("wave", direction: 0),
            LightingEffect("reactive", color: red, speed: 4),
            LightingEffect("starlight", color: red, speed: 1, secondColor: green),
            LightingEffect("starlight", speed: 3),
        ]
        for effect in effects { try await driver().write(.effect(effect), to: backlight, using: transport) }
        let lighting = await transport.lighting
        #expect(lighting.map { $0[5] } == [6, 9, 12, 6, 9, 12, 6])
        #expect(lighting.map { $0[10] } == [2, 2, 2, 4, 5, 7, 7])
        #expect(lighting[3][11] == 0 && lighting[4][12] == 4 && lighting[5][12] == 1 && lighting[6][12] == 3)
    }

    @Test func invalidEffectParametersAreRejectedBeforeSending() async {
        let transport = Recorder()
        let bad = [LightingEffect("wave", direction: 2), LightingEffect("reactive", color: red, speed: 5),
                   LightingEffect("starlight", speed: 4), LightingEffect("breathing", secondColor: red)]
        for effect in bad {
            await #expect(throws: DriverError.self) { try await driver().write(.effect(effect), to: backlight, using: transport) }
        }
        #expect(await transport.sent.isEmpty)
    }

    @Test func keyFrameSendsFiveRowsThenActivates() async throws {
        let transport = Recorder()
        try await driver().write(.keyFrame([KeyColor(row: 0, col: 1, color: red), KeyColor(row: 4, col: 14, color: green),
                                            KeyColor(row: 0, col: 1, color: green)]), to: keys, using: transport)
        let lighting = await transport.lighting
        #expect(lighting.count == 6)
        for (index, bytes) in lighting.prefix(5).enumerated() {
            #expect(bytes[1] == 0x3F && bytes[5] == 0x47 && bytes[7] == 0x03)
            #expect(Array(bytes[8..<13]) == [0, 0, UInt8(index), 0, 14])
            #expect(bytes[88] == RazerReport.crc(of: bytes))
        }
        #expect(Array(lighting[0][13..<22]) == [0, 0, 0, 0, 0xFF, 0, 0, 0, 0])      // col 0 dark, col 1 green (last wins)
        #expect(Array(lighting[4][55..<58]) == [0, 0xFF, 0])                           // col 14 starts at byte 13 + 3*14
        #expect(lighting[5] == RazerCommands.activateCustomFrame(transactionID: 0x3F).encoded())
    }

    @Test func keyFrameOutsideMatrixIsRejected() async {
        let transport = Recorder()
        for key in [KeyColor(row: 5, col: 0, color: red), KeyColor(row: 0, col: 15, color: red), KeyColor(row: -1, col: 0, color: red)] {
            await #expect(throws: DriverError.self) { try await driver().write(.keyFrame([key]), to: keys, using: transport) }
        }
        await #expect(throws: DriverError.self) { try await driver().write(.text("x"), to: keys, using: transport) }
        await #expect(throws: DriverError.self) { try await driver().read(keys, using: transport) }
        #expect(await transport.sent.isEmpty)
    }

    @Test func matrixSizeComesFromOptions() {
        let id = USBID(vendor: 0x1532, product: 0x0257)
        #expect(RazerModel.model(for: id, options: nil)?.matrixRows == 5)
        #expect(RazerModel.model(for: id, options: ["matrix_columns": "22", "matrix_rows": "6"])?.matrixColumns == 22)
        #expect(RazerModel.model(for: id, options: ["matrix_columns": "99"])?.matrixColumns == 15)
    }
}

@Suite struct ValueAndLayoutTests {
    @Test func oldEffectJSONStillDecodesAndNewFieldsRoundTrip() throws {
        let old = try JSONDecoder().decode(SettingValue.self, from: Data(#"{"effect":"reactive","color":{"r":1,"g":2,"b":3}}"#.utf8))
        #expect(old == .effect(LightingEffect("reactive", color: RGBColor(r: 1, g: 2, b: 3))))
        let value = SettingValue.effect(LightingEffect("starlight", color: red, speed: 2, direction: 1, secondColor: green))
        #expect(try JSONDecoder().decode(SettingValue.self, from: JSONEncoder().encode(value)) == value)
    }

    @Test func keyFrameRoundTripsAsArray() throws {
        let value = SettingValue.keyFrame([KeyColor(row: 1, col: 2, color: red)])
        let data = try JSONEncoder().encode(value)
        #expect(String(decoding: data, as: UTF8.self).hasPrefix("["))
        #expect(try JSONDecoder().decode(SettingValue.self, from: data) == value)
        #expect(try JSONDecoder().decode(SettingValue.self, from: Data("[]".utf8)) == .keyFrame([]))
    }

    @Test func huntsmanMiniLayoutIsConsistent() {
        let layout = KeyboardLayout.huntsmanMini
        #expect(layout.keys.count == 61 && layout.matrixRows == 5 && layout.matrixColumns == 15)
        #expect(Set(layout.keys.map(\.id)).count == 61)
        #expect(Set(layout.keys.map { $0.row * 100 + $0.col }).count == 61)             // no two keys share a cell
        #expect(layout.keys.allSatisfy { (0..<5).contains($0.row) && (0..<15).contains($0.col) })
        #expect(layout.width == 15 && layout.height == 5)
        for row in 0..<5 {      // every row is exactly 15u wide with no gaps or overlaps
            let rowKeys = layout.keys.filter { $0.row == row }.sorted { $0.x < $1.x }
            var edge = 0.0
            for key in rowKeys { #expect(key.x == edge); edge += key.width }
            #expect(edge == 15)
        }
        #expect(layout.key(id: "space")?.col == 7 && layout.key(id: "fn")?.col == 12)
        #expect(layout.key(row: 2, col: 2)?.label == "A")
        #expect(layout.key(atX: 5, y: 4.5)?.id == "space" && layout.key(atX: 0.5, y: 0.5)?.id == "esc")
        #expect(layout.key(atX: 15.5, y: 0.5) == nil)
        #expect(layout.keys.filter { !$0.matrixCrossChecked }.map(\.id).sorted() == ["backslash", "esc"])
        #expect(layout.frame(filling: red).count == 61)
    }
}
