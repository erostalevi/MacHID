import AppKit
import MacHIDIOKit

enum PermissionActions {
    /// Prompts once; if the system already decided, opens the Input Monitoring pane instead.
    @MainActor static func requestInputMonitoring() {
        if InputMonitoringPermission.request() { return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}
