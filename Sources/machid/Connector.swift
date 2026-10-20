import MacHIDApplication
import MacHIDDomain
import MacHIDIOKit
import MacHIDLogitech
import MacHIDRazer

/// Composition root: picks the driver family and opens the matching transport.
struct SystemDeviceConnector: DeviceConnector {
    func connect(to device: DiscoveredDevice, definition: DeviceDefinition) async throws -> (driver: any DeviceDriver, transport: any Transport) {
        switch definition.driver {
        case "razer":
            guard let model = RazerModel.model(for: device.usbId) else { throw DriverError.unsupportedModel(device.usbId) }
            let transport = try IOKitHIDTransport(usbId: device.usbId, maxFeatureReportSize: RazerReport.size)
            return (RazerDriver(model: model), transport)
        case "logitech-gseries":
            // HID++ lives on the interface whose long output report is 20 bytes.
            let transport = try IOKitHIDTransport(usbId: device.usbId, selector: .outputReportSize(20))
            return (HidppDriver(), transport)
        default:
            throw DriverError.deviceFailure("no driver available yet for family '\(definition.driver)'")
        }
    }
}
