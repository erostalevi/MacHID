import Foundation
import Testing
import MacHIDApplication
import MacHIDDomain
@testable import MacHIDSystem

private actor Counting: DeviceConnector {
    private(set) var connects = 0
    private(set) var discards = 0
    func connect(to device: DiscoveredDevice, definition: DeviceDefinition) async throws -> (driver: any DeviceDriver, transport: any Transport) {
        connects += 1
        return (NoDriver(), NoTransport())
    }
    func discard(_ device: DiscoveredDevice) async { discards += 1 }
}

private struct NoDriver: DeviceDriver {
    let familyID = "none"
    func read(_ capability: CapabilityDescriptor, using transport: any Transport) async throws -> SettingValue { .int(0) }
    func write(_ value: SettingValue, to capability: CapabilityDescriptor, using transport: any Transport) async throws {}
}
private struct NoTransport: Transport {
    func sendFeatureReport(reportID: UInt8, _ data: [UInt8]) async throws {}
    func getFeatureReport(reportID: UInt8, length: Int) async throws -> [UInt8] { [] }
}

private let idA = USBID(vendor: 1, product: 1)
private let idB = USBID(vendor: 2, product: 2)
private let definition = DeviceDefinition(id: "d", name: "D", category: .other, usbIds: [idA, idB], driver: "none", capabilities: [])

@Suite struct SessionPoolTests {
    @Test func reusesTheSessionForTheSameDevice() async throws {
        let inner = Counting()
        let pool = SessionPool(wrapping: inner)
        let device = DiscoveredDevice(usbId: idA, name: "A")
        for _ in 0..<5 { _ = try await pool.connect(to: device, definition: definition) }
        #expect(await inner.connects == 1)
        _ = try await pool.connect(to: DiscoveredDevice(usbId: idB, name: "B"), definition: definition)
        let open = await pool.openSessionCount
        #expect(await inner.connects == 2 && open == 2)
    }

    @Test func discardForcesAFreshSession() async throws {
        let inner = Counting()
        let pool = SessionPool(wrapping: inner)
        let device = DiscoveredDevice(usbId: idA, name: "A")
        _ = try await pool.connect(to: device, definition: definition)
        await pool.discard(device)
        _ = try await pool.connect(to: device, definition: definition)
        let discards = await inner.discards
        #expect(await inner.connects == 2 && discards == 1)
    }

    @Test func idleSessionsExpire() async throws {
        let inner = Counting()
        let pool = SessionPool(wrapping: inner, idleTimeout: .milliseconds(30))
        let device = DiscoveredDevice(usbId: idA, name: "A")
        _ = try await pool.connect(to: device, definition: definition)
        try await Task.sleep(for: .milliseconds(80))
        _ = try await pool.connect(to: device, definition: definition)
        #expect(await inner.connects == 2)
    }

    @Test func closeAllEmptiesThePool() async throws {
        let pool = SessionPool(wrapping: Counting())
        _ = try await pool.connect(to: DiscoveredDevice(usbId: idA, name: "A"), definition: definition)
        await pool.closeAll()
        #expect(await pool.openSessionCount == 0)
    }
}
