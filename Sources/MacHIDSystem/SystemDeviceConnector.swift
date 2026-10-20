import MacHIDApplication
import MacHIDDomain
import MacHIDIOKit
import MacHIDLogitech
import MacHIDRazer
import MacHIDUVC

/// Composition root: picks the driver family and opens the matching transport.
public struct SystemDeviceConnector: DeviceConnector {
    private let decorate: @Sendable (any Transport) -> any Transport

    /// - Parameter decorate: optional wrapper applied to every transport (the CLI's `--trace` uses it).
    public init(decorate: @escaping @Sendable (any Transport) -> any Transport = { $0 }) {
        self.decorate = decorate
    }

    private func wrap(_ transport: any Transport) -> any Transport { decorate(transport) }

    public func connect(to device: DiscoveredDevice, definition: DeviceDefinition) async throws -> (driver: any DeviceDriver, transport: any Transport) {
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
