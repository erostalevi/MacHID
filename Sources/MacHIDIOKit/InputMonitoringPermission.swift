import IOKit.hid

/// Whether this process may open HID devices (macOS "Input Monitoring"). Checking never prompts.
public enum InputMonitoringPermission {
    public static var isGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Shows the system prompt the first time; afterwards the user must change it in System Settings.
    @discardableResult
    public static func request() -> Bool { IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
}
