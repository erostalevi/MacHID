import AppKit

/// Reports the app the user switches to, so per-app profile rules can apply. MacHID's own windows are ignored:
/// opening MacHID to edit a rule must not switch profiles.
@MainActor
final class FrontmostAppMonitor {
    /// Lives as long as the app, so there is no `deinit` to unregister.
    private var token: NSObjectProtocol?

    init(model: AppModel, ownBundleID: String? = Bundle.main.bundleIdentifier) {
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak model] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier, id != ownBundleID else { return }
            Task { @MainActor in await model?.frontmostAppChanged(id) }
        }
        if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, id != ownBundleID {
            Task { @MainActor [weak model] in await model?.frontmostAppChanged(id) }
        }
    }

    func stop() {
        if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        token = nil
    }
}

/// Start at login, through the system's login item service.
enum LoginItem {
    static var isEnabled: Bool { SMAppServiceBridge.isEnabled }
    static func set(_ enabled: Bool) throws { try SMAppServiceBridge.set(enabled) }
}
