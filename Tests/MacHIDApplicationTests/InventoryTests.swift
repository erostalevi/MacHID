import Foundation
import Testing
import MacHIDDomain
@testable import MacHIDApplication

private struct FakeEnumerator: DeviceEnumerator {
    let devices: [DiscoveredDevice]
    func enumerate() throws -> [DiscoveredDevice] { devices }
}

private let mouseID = USBID(vendor: 0x046d, product: 0xc092)
private let hubID = USBID(vendor: 0x05e3, product: 0x0610)

private let mouseDefinition = DeviceDefinition(
    id: "mouse", name: "Mouse", category: .mouse, usbIds: [mouseID], driver: "d", capabilities: [])

@Suite struct InventoryTests {
    private func inventory() -> DeviceInventory {
        DeviceInventory(
            enumerator: FakeEnumerator(devices: [
                DiscoveredDevice(usbId: hubID, name: "Hub"),
                DiscoveredDevice(usbId: mouseID, name: "G203"),
            ]),
            catalog: DefinitionCatalog(definitions: [mouseDefinition]))
    }

    @Test func supportedOnlyHidesUnknownDevices() throws {
        let items = try inventory().items(includeUnsupported: false)
        #expect(items.map(\.device.usbId) == [mouseID])
        #expect(items.first?.definition?.id == "mouse")
    }

    @Test func includeUnsupportedShowsEverythingSortedByName() throws {
        let items = try inventory().items(includeUnsupported: true)
        #expect(items.map(\.device.name) == ["G203", "Hub"])
        #expect(items.last?.isSupported == false)
    }

    @Test func itemLookupByID() throws {
        #expect(try inventory().item(for: hubID)?.device.name == "Hub")
        #expect(try inventory().item(for: USBID(vendor: 9, product: 9)) == nil)
    }
}

@Suite struct DiscoveryTests {
    @Test func redactsSerialToLastFour() {
        #expect(DiscoveredDevice.redactSerial("ABCDEF123456") == "3456")
        #expect(DiscoveredDevice.redactSerial("12") == "12")
        #expect(DiscoveredDevice.redactSerial("") == nil)
        #expect(DiscoveredDevice.redactSerial(nil) == nil)
    }

    @Test func formatsBCD() {
        #expect(DiscoveredDevice.formatBCD(0x0201) == "2.01")
        #expect(DiscoveredDevice.formatBCD(0x0310) == "3.10")
        #expect(DiscoveredDevice.formatBCD(0x1203) == "12.03")
    }

    @Test func catalogFirstDefinitionWinsOnDuplicateID() {
        let a = DeviceDefinition(id: "a", name: "A", category: .mouse, usbIds: [mouseID], driver: "x", capabilities: [])
        let b = DeviceDefinition(id: "b", name: "B", category: .mouse, usbIds: [mouseID], driver: "x", capabilities: [])
        #expect(DefinitionCatalog(definitions: [a, b]).definition(for: mouseID)?.id == "a")
    }

    @Test func catalogLoadReportsInvalidFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("machid-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"id":"ok","name":"Ok","category":"mouse","usb_ids":["1111:2222"],"driver":"d","capabilities":[]}"#.utf8)
            .write(to: dir.appendingPathComponent("ok.json"))
        try Data("not json".utf8).write(to: dir.appendingPathComponent("bad.json"))
        let (catalog, errors) = try DefinitionCatalog.load(directory: dir)
        #expect(catalog.definitions.map(\.id) == ["ok"])
        #expect(errors.count == 1 && errors[0].hasPrefix("bad.json"))
    }
}

// MARK: - DeviceControl

private actor RecordingTransport: Transport {
    func sendFeatureReport(reportID: UInt8, _ data: [UInt8]) async throws {}
    func getFeatureReport(reportID: UInt8, length: Int) async throws -> [UInt8] { [] }
}

private actor RecordingDriver: DeviceDriver {
    nonisolated let familyID = "fake"
    private(set) var writes: [(String, SettingValue)] = []
    func read(_ capability: CapabilityDescriptor, using transport: any Transport) async throws -> SettingValue { .int(42) }
    func write(_ value: SettingValue, to capability: CapabilityDescriptor, using transport: any Transport) async throws {
        writes.append((capability.id, value))
    }
}

private struct FakeConnector: DeviceConnector {
    let driver: RecordingDriver
    func connect(to device: DiscoveredDevice, definition: DeviceDefinition) async throws -> (driver: any DeviceDriver, transport: any Transport) {
        (driver, RecordingTransport())
    }
}

private let controllable = DeviceDefinition(
    id: "kbd", name: "Kbd", category: .keyboard, usbIds: [mouseID], driver: "fake",
    capabilities: [
        CapabilityDescriptor(id: "info", type: .info, access: .read),
        CapabilityDescriptor(id: "brightness", type: .brightness, access: .writeVolatile, parameters: .init(min: 0, max: 100, step: 1)),
        CapabilityDescriptor(id: "dpi", type: .dpi, access: .writeVolatile, parameters: .init(min: 200, max: 1000, step: 100)),
        CapabilityDescriptor(id: "saved", type: .profileSlots, access: .writePersistent),
        CapabilityDescriptor(id: "backlight", type: .lightingZone, access: .writeVolatile,
                             parameters: .init(zones: [LightingZone(id: "z", modes: ["static", "off"])])),
    ])

@Suite struct DeviceControlTests {
    private func make() -> (DeviceControl, RecordingDriver) {
        let driver = RecordingDriver()
        let inventory = DeviceInventory(
            enumerator: FakeEnumerator(devices: [DiscoveredDevice(usbId: mouseID, name: "Kbd"), DiscoveredDevice(usbId: hubID, name: "Hub")]),
            catalog: DefinitionCatalog(definitions: [controllable]))
        return (DeviceControl(inventory: inventory, connector: FakeConnector(driver: driver)), driver)
    }

    @Test func readGoesThroughDriver() async throws {
        #expect(try await make().0.read(mouseID, capability: "brightness") == .int(42))
    }

    @Test func validWriteReachesDriver() async throws {
        let (control, driver) = make()
        try await control.write(mouseID, capability: "brightness", value: .int(80))
        try await control.write(mouseID, capability: "backlight", value: .color(RGBColor(r: 1, g: 2, b: 3)))
        try await control.write(mouseID, capability: "backlight", value: .text("off"))
        #expect(await driver.writes.count == 3)
    }

    @Test func rejectedWritesNeverReachDriver() async {
        let (control, driver) = make()
        await #expect(throws: ControlError.outOfRange("101 > 100")) { try await control.write(mouseID, capability: "brightness", value: .int(101)) }
        await #expect(throws: ControlError.outOfRange("-1 < 0")) { try await control.write(mouseID, capability: "brightness", value: .int(-1)) }
        await #expect(throws: ControlError.self) { try await control.write(mouseID, capability: "dpi", value: .int(250)) }
        await #expect(throws: ControlError.notWritable("info")) { try await control.write(mouseID, capability: "info", value: .int(1)) }
        await #expect(throws: ControlError.persistentWriteBlocked("saved")) { try await control.write(mouseID, capability: "saved", value: .int(1)) }
        await #expect(throws: ControlError.unknownCapability("nope")) { try await control.write(mouseID, capability: "nope", value: .int(1)) }
        await #expect(throws: ControlError.self) { try await control.write(mouseID, capability: "backlight", value: .text("rainbow")) }
        await #expect(throws: ControlError.self) { try await control.write(mouseID, capability: "brightness", value: .text("x")) }
        await #expect(throws: ControlError.unsupportedDevice(hubID)) { try await control.write(hubID, capability: "brightness", value: .int(1)) }
        await #expect(throws: ControlError.deviceNotFound(USBID(vendor: 9, product: 9))) { try await control.read(USBID(vendor: 9, product: 9), capability: "info") }
        #expect(await driver.writes.isEmpty)
    }
}
