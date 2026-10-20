import MacHIDApplication
import MacHIDDomain
import MacHIDIOKit
import MacHIDLogitech
import MacHIDRazer
import MacHIDUVC

/// Composition root: picks the driver family and opens the matching transport.
public struct SystemDeviceConnector: DeviceConnector {
    private let decorate: @Sendable (any Transport) -> any Transport
    private let pluginCode: @Sendable (String) -> (script: String, permissions: PluginPermissions)?
    private let hostLauncher: any PluginHostLauncher

    /// - Parameter decorate: optional wrapper applied to every transport (the CLI's `--trace` uses it).
    /// - Parameters:
    ///   - pluginCode: finds the stored script and approved permissions of an installed code plugin by id.
    ///   - hostLauncher: starts the sandboxed script host.
    public init(decorate: @escaping @Sendable (any Transport) -> any Transport = { $0 },
                pluginCode: @escaping @Sendable (String) -> (script: String, permissions: PluginPermissions)? = { InstalledPluginCode.lookup(id: $0) },
                hostLauncher: any PluginHostLauncher = SandboxedPluginHostLauncher()) {
        self.decorate = decorate
        self.pluginCode = pluginCode
        self.hostLauncher = hostLauncher
    }

    private func wrap(_ transport: any Transport) -> any Transport { decorate(transport) }

    public func connect(to device: DiscoveredDevice, definition: DeviceDefinition) async throws -> (driver: any DeviceDriver, transport: any Transport) {
        switch definition.driver {
        case "razer":
            guard let model = RazerModel.model(for: device.usbId, options: definition.driverOptions) else { throw DriverError.unsupportedModel(device.usbId) }
            let transport = try IOKitHIDTransport(usbId: device.usbId, maxFeatureReportSize: RazerReport.size)
            return (RazerDriver(model: model), wrap(transport))
        case "logitech-gseries":
            // HID++ lives on the interface whose long output report is 20 bytes.
            let transport = try IOKitHIDTransport(usbId: device.usbId, selector: .outputReportSize(20))
            return (HidppDriver(), wrap(transport))
        case "uvc":
            return (UVCDriver(), wrap(try IOKitUSBTransport(usbId: device.usbId)))
        case let family where family.hasPrefix("plugin:"):
            let id = String(family.dropFirst("plugin:".count))
            guard let code = pluginCode(id) else { throw DriverError.deviceFailure("the plugin '\(id)' is not installed or has no script") }
            guard code.permissions.transport == .hid else { throw DriverError.deviceFailure("code plugins can only use HID") }
            // Interface choice is by report size (IOHIDDevice does not expose the interface number).
            let options = definition.driverOptions ?? [:]
            let selector: HIDInterfaceSelector
            if let size = options["feature_report_size"].flatMap(Int.init), (1...4096).contains(size) { selector = .featureReportSize(size) }
            else if let size = options["output_report_size"].flatMap(Int.init), (1...4096).contains(size) { selector = .outputReportSize(size) }
            else { throw DriverError.deviceFailure("a code plugin definition needs driver_options feature_report_size or output_report_size") }
            let transport = try IOKitHIDTransport(usbId: device.usbId, selector: selector)
            return (PluginDriver(pluginID: id, script: code.script, permissions: code.permissions, launcher: hostLauncher), wrap(transport))
        default:
            throw DriverError.deviceFailure("no driver available yet for family '\(definition.driver)'")
        }
    }
}
