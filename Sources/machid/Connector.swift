import MacHIDApplication
import MacHIDDomain
import MacHIDIOKit
import MacHIDLogitech
import MacHIDRazer
import MacHIDUVC

/// Composition root: picks the driver family and opens the matching transport.
struct SystemDeviceConnector: DeviceConnector {
    let trace: Bool

    private func wrap(_ transport: any Transport) -> any Transport { trace ? TracingTransport(inner: transport) : transport }

    func connect(to device: DiscoveredDevice, definition: DeviceDefinition) async throws -> (driver: any DeviceDriver, transport: any Transport) {
        switch definition.driver {
        case "razer":
            guard let model = RazerModel.model(for: device.usbId) else { throw DriverError.unsupportedModel(device.usbId) }
            let transport = try IOKitHIDTransport(usbId: device.usbId, maxFeatureReportSize: RazerReport.size)
            return (RazerDriver(model: model), wrap(transport))
        case "logitech-gseries":
            // HID++ lives on the interface whose long output report is 20 bytes.
            let transport = try IOKitHIDTransport(usbId: device.usbId, selector: .outputReportSize(20))
            return (HidppDriver(), wrap(transport))
        case "uvc":
            return (UVCDriver(), wrap(try IOKitUSBTransport(usbId: device.usbId)))
        default:
            throw DriverError.deviceFailure("no driver available yet for family '\(definition.driver)'")
        }
    }
}
