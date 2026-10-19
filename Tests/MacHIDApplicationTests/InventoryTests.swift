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
