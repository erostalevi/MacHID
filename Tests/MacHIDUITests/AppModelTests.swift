import Foundation
import Testing
import MacHIDApplication
import MacHIDDomain
@testable import MacHIDUI

private final class MutableEnumerator: DeviceEnumerator, @unchecked Sendable {
    private let lock = NSLock()
    private var devices: [DiscoveredDevice]
    init(_ devices: [DiscoveredDevice]) { self.devices = devices }
    func set(_ devices: [DiscoveredDevice]) { lock.lock(); self.devices = devices; lock.unlock() }
    func enumerate() throws -> [DiscoveredDevice] { lock.lock(); defer { lock.unlock() }; return devices }
}

private actor FakeDriver: DeviceDriver {
    nonisolated let familyID = "fake"
    private(set) var writes: [(String, SettingValue)] = []
    private var failing = false
    func setFailing(_ value: Bool) { failing = value }
    func read(_ capability: CapabilityDescriptor, using transport: any Transport) async throws -> SettingValue {
        capability.id == "info" ? .text("fw 1") : .int(50)
    }
    func write(_ value: SettingValue, to capability: CapabilityDescriptor, using transport: any Transport) async throws {
        if failing { throw DriverError.deviceFailure("nope") }
        writes.append((capability.id, value))
    }
    func limits(for capability: CapabilityDescriptor, using transport: any Transport) async throws -> ValueLimits? {
        capability.type == .cameraControl ? ValueLimits(min: 0, max: 200, step: 2) : nil
    }
}

private actor NullTransport: Transport {
    func sendFeatureReport(reportID: UInt8, _ data: [UInt8]) async throws {}
    func getFeatureReport(reportID: UInt8, length: Int) async throws -> [UInt8] { [] }
}

private struct FakeConnector: DeviceConnector {
    let driver: FakeDriver
    func connect(to device: DiscoveredDevice, definition: DeviceDefinition) async throws -> (driver: any DeviceDriver, transport: any Transport) {
        (driver, NullTransport())
    }
}

private actor MemoryRepository: ProfileRepository {
    private var profiles: [Profile] = []
    func load() -> [Profile] { profiles }
    func save(_ profile: Profile) { profiles.removeAll { $0.id == profile.id }; profiles.append(profile) }
    func delete(id: String) { profiles.removeAll { $0.id == id } }
}

private let keyboardID = USBID(vendor: 1, product: 1)
private let cameraID = USBID(vendor: 2, product: 2)
private let hubID = USBID(vendor: 3, product: 3)

private let keyboard = DeviceDefinition(id: "kbd", name: "Kbd", category: .keyboard, usbIds: [keyboardID], driver: "fake", capabilities: [
    CapabilityDescriptor(id: "info", type: .info, access: .read),
    CapabilityDescriptor(id: "brightness", type: .brightness, access: .writeVolatile, parameters: .init(min: 0, max: 100, step: 1)),
    CapabilityDescriptor(id: "backlight", type: .lightingZone, access: .writeVolatile,
                         parameters: .init(zones: [LightingZone(id: "z", modes: ["static", "off"])])),
    CapabilityDescriptor(id: "device_mode", type: .deviceMode, access: .writeVolatile, parameters: .init(values: [0, 3])),
])
private let camera = DeviceDefinition(id: "cam", name: "Cam", category: .camera, usbIds: [cameraID], driver: "fake", capabilities: [
    CapabilityDescriptor(id: "contrast", type: .cameraControl, access: .writeVolatile),
])

@MainActor
private func makeModel(devices: [DiscoveredDevice], changes: AsyncStream<Void>? = nil) -> (AppModel, MutableEnumerator, FakeDriver, MemoryRepository) {
    let enumerator = MutableEnumerator(devices)
    let inventory = DeviceInventory(enumerator: enumerator, catalog: DefinitionCatalog(definitions: [keyboard, camera]))
    let driver = FakeDriver()
    let repository = MemoryRepository()
    let defaults = UserDefaults(suiteName: "machid-test-\(UUID().uuidString)")!
    let model = AppModel(inventory: inventory, control: DeviceControl(inventory: inventory, connector: FakeConnector(driver: driver)),
                         repository: repository, defaults: defaults, writeDelay: .milliseconds(20), deviceChanges: changes, permissionCheck: { true })
    return (model, enumerator, driver, repository)
}

private let kbdDevice = DiscoveredDevice(usbId: keyboardID, name: "Keyboard")
private let camDevice = DiscoveredDevice(usbId: cameraID, name: "Camera")
private let hubDevice = DiscoveredDevice(usbId: hubID, name: "Hub")

@MainActor
@Suite struct AppModelTests {
    @Test func listsSupportedDevicesAndLoadsValues() async {
        let (model, _, _, _) = makeModel(devices: [kbdDevice, hubDevice, camDevice])
        await model.refreshDevices()
        #expect(model.devices.map(\.name) == ["Camera", "Keyboard"])
        #expect(model.selectedDeviceID == model.devices.first?.id)
        let kbd = model.devices.first { $0.name == "Keyboard" }
        #expect(kbd?.values["brightness"] == .int(50))
        #expect(kbd?.values["info"] == .text("fw 1"))
        #expect(kbd?.values["backlight"] == nil)                     // not readable: never requested
        #expect(model.devices.first { $0.name == "Camera" }?.limits["contrast"] == ValueLimits(min: 0, max: 200, step: 2))
    }

    @Test func followsHotPlugAndKeepsSelectionValid() async {
        let (model, enumerator, _, _) = makeModel(devices: [kbdDevice])
        await model.refreshDevices()
        #expect(model.devices.count == 1)
        enumerator.set([kbdDevice, camDevice])
        await model.refreshDevices()
        #expect(model.devices.count == 2)
        model.selectedDeviceID = "0002:0002"
        enumerator.set([kbdDevice])
        await model.refreshDevices()
        #expect(model.devices.map(\.name) == ["Keyboard"])
        #expect(model.selectedDeviceID == "0001:0001")
    }

    @Test func draggingASliderSendsOnlyTheLastValue() async {
        let (model, _, driver, _) = makeModel(devices: [kbdDevice])
        await model.refreshDevices()
        let id = model.devices[0].id
        for value in [10, 20, 30, 40] { model.set(.int(value), capability: "brightness", on: id) }
        #expect(model.devices[0].values["brightness"] == .int(40))   // the UI follows immediately
        await model.flushWrites()
        let writes = await driver.writes
        #expect(writes.count == 1 && writes[0].1 == .int(40))
    }

    @Test func failedWritesSurfaceAnError() async {
        let (model, _, driver, _) = makeModel(devices: [kbdDevice])
        await model.refreshDevices()
        await driver.setFailing(true)
        model.set(.int(5), capability: "brightness", on: model.devices[0].id)
        await model.flushWrites()
        #expect(model.devices[0].lastError != nil)
        #expect(model.banner?.contains("Keyboard") == true)
    }

    @Test func rejectedValuesAreReportedNotSent() async {
        let (model, _, driver, _) = makeModel(devices: [kbdDevice])
        await model.refreshDevices()
        model.set(.int(500), capability: "brightness", on: model.devices[0].id)
        await model.flushWrites()
        #expect(await driver.writes.isEmpty)
        #expect(model.devices[0].lastError?.contains("out of range") == true)
    }

    @Test func profilesSaveApplyAndSkipHostControl() async throws {
        let (model, _, driver, _) = makeModel(devices: [kbdDevice, camDevice])
        await model.refreshDevices()
        let id = try #require(model.devices.first { $0.name == "Keyboard" }?.id)
        model.set(.int(70), capability: "brightness", on: id)
        model.set(.color(RGBColor(r: 1, g: 2, b: 3)), capability: "backlight", on: id)
        model.set(.int(3), capability: "device_mode", on: id)
        await model.flushWrites()

        let profile = try #require(await model.saveProfile(named: "  Work ", from: id))
        #expect(profile.name == "Work")
        let saved = try #require(profile.settings["kbd"])
        #expect(saved["brightness"] == .int(70) && saved["backlight"] == .color(RGBColor(r: 1, g: 2, b: 3)))
        #expect(saved["device_mode"] == nil && saved["info"] == nil)          // never stored
        #expect(model.profiles(for: id).map(\.name) == ["Work"])
        #expect(model.profiles(for: model.devices.first { $0.name == "Camera" }!.id).isEmpty)
        #expect(model.activeProfile(for: id)?.id == profile.id)

        model.set(.int(10), capability: "brightness", on: id)
        await model.flushWrites()
        let before = await driver.writes.count
        await model.applyProfile(profile.id, to: id)
        let applied = await driver.writes.dropFirst(before)
        #expect(applied.map(\.0).sorted() == ["backlight", "brightness"])
        #expect(model.devices.first { $0.id == id }?.values["brightness"] == .int(70))
    }

    @Test func blankProfileNamesAreRefusedAndDeletionClearsActive() async throws {
        let (model, _, _, _) = makeModel(devices: [kbdDevice])
        await model.refreshDevices()
        let id = model.devices[0].id
        #expect(await model.saveProfile(named: "   ", from: id) == nil)
        let profile = try #require(await model.saveProfile(named: "A", from: id))
        await model.deleteProfile(profile.id)
        #expect(model.profiles.isEmpty && model.activeProfile(for: id) == nil)
    }

    @Test func selectionWrapsInBothDirections() async {
        let (model, _, _, _) = makeModel(devices: [kbdDevice, camDevice])
        await model.refreshDevices()
        let first = model.devices[0].id, second = model.devices[1].id
        #expect(model.selectedDeviceID == first)
        model.selectNextDevice()
        #expect(model.selectedDeviceID == second)
        model.selectNextDevice()
        #expect(model.selectedDeviceID == first)
        model.selectNextDevice(offset: -1)
        #expect(model.selectedDeviceID == second)
    }

    @Test func aChangeEventRefreshesWithoutWaitingForTheSlowPoll() async {
        var continuation: AsyncStream<Void>.Continuation!
        let stream = AsyncStream<Void> { continuation = $0 }
        let (model, enumerator, _, _) = makeModel(devices: [kbdDevice], changes: stream)
        model.start(pollInterval: .seconds(60))
        for _ in 0..<100 where model.devices.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(model.devices.count == 1)

        enumerator.set([kbdDevice, camDevice])
        continuation.yield()
        for _ in 0..<100 where model.devices.count < 2 { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(model.devices.count == 2)
        model.stop()
    }
}
